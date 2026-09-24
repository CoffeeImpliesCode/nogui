/*
 * nogui iOS shim: the Objective-C half of the mobile adapters.
 *
 * Why Objective-C: UIKit's accessibility API is an Objective-C informal
 * protocol, `UIAccessibilityElement` is an Objective-C class, and an element
 * only participates in the tree by being a real object the framework retains
 * and asks. Writing the element subclass here is what makes VoiceOver read
 * real UIKit objects rather than a description of them.
 *
 * Built by `zig cc` as Objective-C with ARC, for iOS only. Five invariants
 * hold for every entry point:
 *
 *   1. MAIN THREAD. UIKit accepts main-thread work only. Every entry point that
 *      touches a framework checks `[NSThread isMainThread]` and returns
 *      NOGUI_MOBILE_ERR_THREAD otherwise, so a marshalling mistake is a typed
 *      refusal rather than undefined behaviour inside the framework. The two
 *      entry points that return `void` cannot report a wrong thread, so they
 *      skip the framework work and always finish their own teardown.
 *   2. TYPED FAILURE. A refusal is one of the NOGUI_MOBILE_ERR_* codes, and a
 *      framework that raises an exception instead of returning an error is
 *      caught and reported as NOGUI_MOBILE_ERR_FAULT.
 *   3. NO HIDDEN OWNERSHIP. The `UIWindow *` arrives from SDL and stays SDL's.
 *      The bridge holds it weakly: a window that went away leaves the bridge
 *      detached instead of messaging a deallocated object.
 *   4. NO BORROWED PAYLOAD OUTLIVES THE CALL. Every buffer in an update is
 *      copied. The copy keeps the numeric facts and erases the borrowed
 *      pointers, so nothing the framework can reach points into memory the
 *      adapter has already recycled.
 *   5. ONE LOCK, ONE ORDER. The framework calls the element's methods on its
 *      own accessibility thread while the host updates the tree on the main
 *      thread, so every read and write of bridge state happens under the
 *      process-wide lock below, and no host callback is made while that lock
 *      is held.
 *
 * The `NoGuiElement` subclass is the whole point of the file. Each published
 * node becomes one real `UIAccessibilityElement`, and that object answers the
 * framework's own questions — its label, its value, its hint, its traits, both
 * of its frames, whether it is an element, whether its subtree is modal, what
 * its children are, and what happens when the screen reader activates it. An
 * activation is not a log line: it is a real request handed to the Zig
 * adapter, which replays it through the core's ordinary activation, edit and
 * focus seams.
 *
 * IDENTITY. The id the platform holds is `native_id`, never a position in the
 * update's array. An element is created once per native id and kept for the
 * bridge's whole life, so a reorder costs nothing and a removal cannot make an
 * id address whatever node moved into its place. A node the update no longer
 * publishes is retired: the framework may still hold the object, so the object
 * is emptied and its link to the bridge is cut, and every action on it refuses
 * rather than aiming at a different node.
 *
 * TEXT. A synthetic element cannot be edited: UIKit gives a screen reader no
 * way to type into one, so a text node published as an element is announced and
 * nothing more. A node with a real control bound to it is published as THAT
 * control instead — the control is the app's, the shim's proxy stands in for
 * its delegate and watches the control's editing-changed event as a target of
 * its own, the core's text and selection are written in with the proxy
 * silenced so a republish is not mistaken for an edit, and the platform's
 * committed edits come back out as requests with the character indices the
 * header states, which count Unicode code points and not composed character
 * sequences. The proxy is the ONLY thing that speaks for a bound node: a
 * synthetic element beside the real control is refused there rather than
 * allowed to answer the same question a second time, and the proxy's own
 * requests still pass every other gate — the id must resolve in the published
 * tree, the action must be in the mask that publication carried, and the
 * host callback runs under a bridge reference so a concurrent `free` waits
 * rather than being returned into.
 * Marked text is never reported: while an input method composes, the
 * control's text is nobody's text yet, and an authoritative update leaves the
 * composition alone rather than cancelling it. With nothing bound, a text node
 * stays a plain announcement and advertises no edit surface at all.
 */
#import <UIKit/UIKit.h>

#include "nogui_mobile.h"

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* ── the process-wide bridge lock ───────────────────────────────────────── */

/*
 * One lock, because the accessibility server thread and the main thread read
 * and write the same bridge. It is recursive so a helper may be called from a
 * section that already holds it, which keeps the discipline readable: whoever
 * takes the lock releases it, and nobody else takes it.
 */
static pthread_mutex_t nogui_lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP;

static void nogui_lock_acquire(void)
{
    pthread_mutex_lock(&nogui_lock);
}

static void nogui_lock_release(void)
{
    pthread_mutex_unlock(&nogui_lock);
}

/* ── shared helpers ──────────────────────────────────────────────────────── */

static int32_t nogui_guard_main(void)
{
    return [NSThread isMainThread] ? NOGUI_MOBILE_OK : NOGUI_MOBILE_ERR_THREAD;
}

/* Copy a borrowed UTF-8 argument into an NSString. NULL is how a caller asks
 * for "no string"; bytes that are not valid UTF-8 are refused rather than
 * repaired, because a repaired label is a different label. A length with no
 * buffer behind it is a caller's mistake and is refused, not read. */
static NSString *nogui_string(const char *utf8, size_t len, int32_t *status)
{
    if (utf8 == NULL) {
        if (len != 0) {
            *status = NOGUI_MOBILE_ERR_ARGUMENT;
        }
        return nil;
    }
    if (len > NOGUI_MOBILE_MAX_TEXT) {
        *status = NOGUI_MOBILE_ERR_BUFFER;
        return nil;
    }
    if (len == 0) {
        return @"";
    }
    NSString *text = [[NSString alloc] initWithBytes:utf8
                                            length:len
                                          encoding:NSUTF8StringEncoding];
    if (text == nil) {
        *status = NOGUI_MOBILE_ERR_ARGUMENT;
        return nil;
    }
    return text;
}

static UIWindow *nogui_window(void *handle)
{
    return (__bridge UIWindow *)handle;
}

/* The first responder anywhere in this view's tree. A `UIWindow` is a view, so
 * the same walk answers for the window itself: a window with no root view
 * controller is still a real hierarchy, and refusing to look into it would
 * report "nothing is being edited" on a device that is editing. */
static UIResponder *nogui_first_responder(UIView *view)
{
    if (view == nil) {
        return nil;
    }
    if ([view isFirstResponder]) {
        return view;
    }
    for (UIView *child in view.subviews) {
        UIResponder *found = nogui_first_responder(child);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

/* Whether a responder is one the system keyboard types into. UIKit drives the
 * system keyboard from a `UITextInput` responder, so a responder that is not
 * one cannot have raised it. */
static BOOL nogui_is_text_input(UIResponder *responder)
{
    return responder != nil && [responder conformsToProtocol:@protocol(UITextInput)];
}

/* ── E04: safe area ──────────────────────────────────────────────────────── */

/*
 * `safeAreaInsets` is UIKit's own answer, in points, measured inward from the
 * window's bounds. It already accounts for the status bar, the home indicator,
 * a notch and a rounded corner, and it is the value a layout has to respect. A
 * window that reports zeroes is a real reading on a device with none of those,
 * not a missing measurement, so this never invents a default.
 */
int32_t nogui_ios_window_safe_area(void *ui_window, nogui_mobile_insets *out)
{
    int32_t status = nogui_guard_main();
    if (status != NOGUI_MOBILE_OK) {
        return status;
    }
    if (ui_window == NULL || out == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    UIWindow *window = nogui_window(ui_window);
    if (window == nil) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    UIEdgeInsets insets;
    @try {
        insets = window.safeAreaInsets;
    }
    @catch (NSException *fault) {
        (void)fault;
        return NOGUI_MOBILE_ERR_FAULT;
    }
    out->top = (double)insets.top;
    out->left = (double)insets.left;
    out->bottom = (double)insets.bottom;
    out->right = (double)insets.right;
    return NOGUI_MOBILE_OK;
}

/* ── E04: keyboard ──────────────────────────────────────────────────────── */

/*
 * The keyboard is measured, not inferred.
 *
 * `-[UIResponder inputView]` is nil for a responder that wants the system
 * keyboard: the system keyboard is not the responder's input view, it is a
 * view UIKit owns. A shim that asks the first responder for its input view
 * therefore concludes "nothing is being edited" on a device that is editing,
 * and the layout it drives never moves. So this file uses the two real
 * sources, in order of directness:
 *
 *   1. An input view that EXISTS belongs to the app, and a view the app owns
 *      can be measured: its frame converted into the window's own points is a
 *      measurement, not an inference.
 *   2. Otherwise the keyboard is the system one, and the only public record of
 *      where it is lies in `UIKeyboardDidShowNotification`,
 *      `UIKeyboardDidChangeFrameNotification` and `UIKeyboardDidHideNotification`.
 *      Those are recorded, and the frame is converted from screen coordinates
 *      into the CURRENT window's points at query time, so a rotation or a
 *      second window reports its own geometry.
 *
 * Only the "did" notifications are recorded. A "will" notification carries a
 * frame that is still animating, and publishing an in-flight rectangle as the
 * keyboard's frame would be a guess; every "will" is followed by its "did", so
 * recording only the settled notifications loses nothing.
 *
 * The observers are installed from `+load`, which runs before
 * `UIApplicationMain`, so no keyboard can ever appear without a notification
 * being recorded. That is what makes a quiet "not on screen" a measurement
 * rather than an absence of evidence. The tokens are kept and the observers
 * are removed symmetrically: nothing is registered per query, and nothing is
 * left holding a block that outlives the process.
 *
 * `supported` and `visible` stay separate answers. Every iOS device ships a
 * software keyboard, so the platform can raise one; whether one is on screen
 * right now is a different fact, and `status` says whether the platform
 * answered at all.
 */
typedef struct nogui_keyboard_reading {
    /* The last settled notification said the keyboard is on screen. */
    int32_t showing;
    /* That keyboard's frame, in the coordinate space of its screen. */
    CGRect screen_frame;
} nogui_keyboard_reading;

/* Written and read on the main thread only: the blocks are delivered on the
 * main operation queue, and every reader is behind the main-thread guard. */
static nogui_keyboard_reading nogui_keyboard;
static id nogui_keyboard_tokens[3];

static BOOL nogui_keyboard_frame(NSNotification *note, CGRect *out)
{
    NSNumber *boxed = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (boxed == nil) {
        return NO;
    }
    return [boxed getValue:out] != NO;
}

static void nogui_keyboard_settle(NSNotification *note, int32_t showing)
{
    CGRect frame = CGRectZero;
    if (!nogui_keyboard_frame(note, &frame)) {
        return;
    }
    nogui_keyboard.screen_frame = frame;
    /* UIKit says a keyboard is hidden with a degenerate frame rather than with
     * a separate notification, so an off-screen frame settles it as hidden
     * whichever notification carried it. */
    nogui_keyboard.showing = CGRectIsEmpty(frame) ? 0 : showing;
}

static void nogui_keyboard_observe(void)
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    nogui_keyboard_tokens[0] = [center
        addObserverForName:UIKeyboardDidShowNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    nogui_keyboard_settle(note, 1);
                }];
    nogui_keyboard_tokens[1] = [center
        addObserverForName:UIKeyboardDidChangeFrameNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    nogui_keyboard_settle(note, 1);
                }];
    nogui_keyboard_tokens[2] = [center
        addObserverForName:UIKeyboardDidHideNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    nogui_keyboard_settle(note, 0);
                }];
}

static void nogui_keyboard_forget(void)
{
    for (size_t i = 0; i < sizeof(nogui_keyboard_tokens) / sizeof(nogui_keyboard_tokens[0]); ++i) {
        if (nogui_keyboard_tokens[i] != nil) {
            [[NSNotificationCenter defaultCenter] removeObserver:nogui_keyboard_tokens[i]];
            nogui_keyboard_tokens[i] = nil;
        }
    }
    nogui_keyboard.screen_frame = CGRectZero;
    nogui_keyboard.showing = 0;
}

/* The keyboard's own frame and whether it is on screen. */
int32_t nogui_ios_window_keyboard(void *ui_window, nogui_mobile_keyboard *out)
{
    int32_t status = nogui_guard_main();
    if (status != NOGUI_MOBILE_OK) {
        return status;
    }
    if (ui_window == NULL || out == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    memset(out, 0, sizeof(*out));
    UIWindow *window = nogui_window(ui_window);
    if (window == nil) {
        out->status = NOGUI_MOBILE_ERR_UNAVAILABLE;
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    /* iOS ships a software keyboard on every device, so the platform can raise
     * one. Whether it is raised is measured below. */
    out->supported = 1;
    @try {
        UIResponder *responder = nogui_first_responder((UIView *)window);
        /* An input view exists only when the app supplied one. A view the app
         * owns is a direct measurement, and it is only on screen once UIKit
         * has put it in a window. */
        UIView *input = responder != nil ? responder.inputView : nil;
        if (input != nil && input.window != nil && !input.hidden && !CGRectIsEmpty(input.bounds)) {
            CGRect in_window = [window convertRect:input.bounds fromView:input];
            out->visible = 1;
            out->frame.x0 = (double)in_window.origin.x;
            out->frame.y0 = (double)in_window.origin.y;
            out->frame.x1 = (double)(in_window.origin.x + in_window.size.width);
            out->frame.y1 = (double)(in_window.origin.y + in_window.size.height);
            out->status = NOGUI_MOBILE_OK;
            return NOGUI_MOBILE_OK;
        }
        /* No app-owned input view, so only the system keyboard can be up, and
         * the system keyboard needs a text-input responder. A responder that is
         * not one refutes the reading whatever the last notification said,
         * which is what catches a dismissal that produced no hide. */
        if (nogui_is_text_input(responder) && nogui_keyboard.showing && !CGRectIsEmpty(nogui_keyboard.screen_frame)) {
            /* The notification's frame is in its screen's coordinates, so it is
             * converted into THIS window's points rather than assumed to match. */
            CGRect in_window = [window convertRect:nogui_keyboard.screen_frame fromWindow:nil];
            if (in_window.size.width > 0.0 && in_window.size.height > 0.0) {
                out->visible = 1;
                out->frame.x0 = (double)in_window.origin.x;
                out->frame.y0 = (double)in_window.origin.y;
                out->frame.x1 = (double)(in_window.origin.x + in_window.size.width);
                out->frame.y1 = (double)(in_window.origin.y + in_window.size.height);
                out->status = NOGUI_MOBILE_OK;
                return NOGUI_MOBILE_OK;
            }
        }
        /* Not on screen. The observers were installed before UIKit could raise
         * one, so a process that has seen no show cannot have one up, and a
         * process that has seen a hide has none up. Either way this is a
         * measurement and not a missing reading. */
        out->status = NOGUI_MOBILE_OK;
    }
    @catch (NSException *fault) {
        (void)fault;
        memset(out, 0, sizeof(*out));
        out->status = NOGUI_MOBILE_ERR_FAULT;
        return NOGUI_MOBILE_ERR_FAULT;
    }
    return NOGUI_MOBILE_OK;
}

/* ── E04: memory pressure ────────────────────────────────────────────────── */

/*
 * `UIApplicationDidReceiveMemoryWarningNotification` is UIKit's own signal and
 * is delivered on the main thread. The level is stored atomically because the
 * header lets any thread ask for it, and that read still has to be a race-free
 * read. iOS publishes exactly one level, so the recorded value is WARNING:
 * claiming a CRITICAL the platform never announced would be a stronger claim
 * than the evidence supports.
 */
static _Atomic int32_t nogui_ios_pressure = NOGUI_MOBILE_IOS_PRESSURE_NONE;
static id nogui_pressure_token;

int32_t nogui_ios_memory_pressure(void)
{
    return atomic_load_explicit(&nogui_ios_pressure, memory_order_relaxed);
}

/* One class, one `+load`, so both platform signals are guaranteed to be
 * listening before the app can raise either of them. */
@interface NoGuiPlatformObservers : NSObject
@end

@implementation NoGuiPlatformObservers

+ (void)load
{
    nogui_pressure_token = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    (void)note;
                    atomic_store_explicit(&nogui_ios_pressure,
                                          NOGUI_MOBILE_IOS_PRESSURE_WARNING,
                                          memory_order_relaxed);
                }];
    nogui_keyboard_observe();
}

@end

/* The observer tokens are owned, so the process releases them when it ends. An
 * iOS app is normally killed rather than exited, in which case the process
 * reclaiming the memory is the release; this makes the exit path symmetric
 * instead of leaving blocks registered against a torn-down runtime. */
__attribute__((destructor)) static void nogui_platform_teardown(void)
{
    if (nogui_pressure_token != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:nogui_pressure_token];
        nogui_pressure_token = nil;
    }
    nogui_keyboard_forget();
}

/* ── E05: UIAccessibility ─────────────────────────────────────────────────── */

@class NoGuiElement;
@class NoGuiCustomAction;
@class NoGuiBridgeOwner;
@interface NoGuiTextProxy : NSObject <UITextFieldDelegate, UITextViewDelegate>
/* `atomic` for the same reason the element's owner is: the platform's thread
 * reads it while teardown clears it. */
@property(atomic, strong) NoGuiBridgeOwner *owner;
@property(nonatomic, weak) id<UITextFieldDelegate> field_delegate;
@property(nonatomic, weak) id<UITextViewDelegate> view_delegate;
@property(nonatomic, weak) UIView *input;
@property(nonatomic, assign) uint64_t native_id;
/* Set while the core's own text and selection are being written into the
 * control, so the callbacks those writes cause are not reported as edits. */
@property(nonatomic, assign) int32_t syncing;
/* The window the proxy put the control into itself, which it takes out again
 * only while that is still the arrangement in place. Weak, like the bridge's own
 * window: it belongs to the host and is destroyed with it. */
@property(nonatomic, weak) UIWindow *added_window;

/* Set while the shim is one of the control's editing-changed targets, so that
 * unbind removes exactly the registration bind made. */
@property(nonatomic, assign) int32_t editing_changed_target;
/* The text the control showed when a composition started, and the selection the
 * composition started from. Together they are the value a committed edit is
 * measured against: the difference between them and the control's text after
 * the input method commits is exactly what changed. */
@property(nonatomic, copy) NSString *origin_text;
@property(nonatomic, assign) NSRange origin_range;
/* An input method is composing: the control's text is marked, not committed. */
@property(nonatomic, assign) int32_t composing;
/* The composition committed and the change is waiting for the observation that
 * shows the control's text after the change. */
@property(nonatomic, assign) int32_t commit_pending;
@end

struct nogui_mobile_bridge {
    void *user;
    nogui_mobile_action_fn on_action;
    nogui_mobile_dirty_fn on_dirty;
    /* Weak: the window belongs to SDL and is destroyed with it. */
    __weak UIWindow *window;
    /* The bridge's own copy of the last update's NUMERIC fields. The caller
     * borrows its buffers only for the update call and the framework is asked
     * about these long after it returned, so the facts have to outlive the
     * call. The copy carries no borrowed pointer. */
    nogui_mobile_node *nodes;
    size_t nodes_len;
    /* Native ids, never dense indices: the root and the focus must keep their
     * identity across an update that reordered the array. */
    uint64_t root;
    uint64_t focus;
    /* The focus native id already handed to the framework. */
    uint64_t announced_focus;
    int32_t tree_initialized;
    int32_t detached;
    int32_t dead;
    /* References in flight from the framework's own thread. `_free` waits for
     * these, so no host call can return into a context the host has torn
     * down. */
    int32_t refs;
    /* The object the framework's elements reach the bridge through. The struct
     * owns this one reference, and clearing the field in `_free` is what hands
     * it back: ARC runs no destructor for a struct released with `free`. */
    __strong NoGuiBridgeOwner *owner;
    /* Real platform text inputs bound to a semantic node, and the proxies that
     * observe them. A bound input is what the published tree shows for that
     * node, because only a real control can be edited and focused. */
    NSMutableDictionary<NSNumber *, UIView *> *inputs;
    NSMutableDictionary<NSNumber *, NoGuiTextProxy *> *proxies;
    /* Owned publication indexes and objects; clear explicitly before free(). */
    __strong NSMutableDictionary<NSNumber *, NSNumber *> *index_by_id;
    __strong NSMutableDictionary<NSNumber *, NSArray *> *children;
    __strong NSMutableDictionary<NSNumber *, NoGuiElement *> *elements;
    /* The host's own report of whether this window has focus. It decides where
     * a focus announcement goes, never what the tree contains. */
    int32_t window_focused;
};

/*
 * The lifetime handle between the framework's objects and the bridge's storage.
 *
 * The framework may hold an element for as long as it likes, and it calls the
 * element's methods from a thread the host does not control, so the storage
 * cannot be released while any of them can still reach it. An element keeps a
 * strong reference to this object, this object hands out counted references to
 * the storage, and `_free` stops the flow and waits for the counts it already
 * handed out. The property on the element is `atomic` for the same reason: a
 * plain property read racing with a write to nil would itself be the dangling
 * pointer this exists to prevent.
 */
@interface NoGuiBridgeOwner : NSObject
@property(nonatomic, assign) nogui_mobile_bridge *storage;
- (nogui_mobile_bridge *)acquire;
- (void)drop;
- (void)kill;
@end

@implementation NoGuiBridgeOwner

- (nogui_mobile_bridge *)acquire
{
    nogui_lock_acquire();
    nogui_mobile_bridge *storage = self.storage;
    if (storage == NULL || storage->dead) {
        nogui_lock_release();
        return NULL;
    }
    storage->refs += 1;
    nogui_lock_release();
    return storage;
}

- (void)drop
{
    nogui_lock_acquire();
    self.storage->refs -= 1;
    nogui_lock_release();
}

- (void)kill
{
    nogui_lock_acquire();
    self.storage->dead = 1;
    nogui_lock_release();
}

@end

/* Everything an element answers from, read under the lock and used after it.
 * A plain copy of numbers cannot be invalidated by a concurrent update, which
 * is what lets the framework's thread read a consistent node. */
typedef struct nogui_snapshot {
    int32_t live;
    uint8_t role;
    uint32_t states;
    uint32_t actions;
    nogui_mobile_rect bounds;
    CGRect screen_frame;
    int32_t has_numeric;
    double numeric_value;
    /* The node is a row of a list, or the container of rows. */
    int32_t rows;
} nogui_snapshot;

static nogui_snapshot nogui_snapshot_empty(void)
{
    nogui_snapshot snapshot;
    memset(&snapshot, 0, sizeof(snapshot));
    return snapshot;
}

/* One request, described once. A call site fills in what it knows and leaves
 * the rest absent, so no call site can invent a payload. */
typedef struct nogui_emit_request {
    uint8_t action;
    uint8_t data;
    /* UTF-8, valid only for the duration of the call it is handed to. */
    const char *value;
    size_t value_len;
    int32_t custom_action;
    int64_t anchor;
    int64_t focus;
} nogui_emit_request;

/* The shape of every action that carries no payload. */
#define NOGUI_EMIT(ACTION)                                                                 \
    ((nogui_emit_request){ .action = (ACTION), .data = NOGUI_MOBILE_DATA_NONE, .anchor = -1, .focus = -1 })

/*
 * One shape for every action the framework can ask a node to perform.
 *
 * The mask the core published decides whether the framework is answered at
 * all, and the id must still resolve to the node it was issued for: a retained
 * element for a node this update no longer publishes produces no request at
 * all, rather than a request aimed at whatever replaced it.
 *
 * `control_proxy` is the one caller that is exempt from the bound-node rule
 * below, and it is exempt because it is not a second answer. A node with a
 * real input bound publishes THAT control, and a synthetic `NoGuiElement`
 * asking on its behalf would be a second, wrong answer to the same question —
 * so an element produces nothing there. The proxy that stands in for the
 * control is the opposite case: the edit it reports IS the control's edit, and
 * the bridge's action path is the only route that edit has. It is admitted
 * only on an identity check made here, under the lock, against the pair the
 * binding itself recorded: `control_proxy` must be the proxy this bridge holds
 * for this very `native_id`, and the control it watches must be the control
 * this bridge holds for that id. Nothing else can pose as the bound control.
 *
 * Every other check is unchanged and still runs for that path: the id must
 * resolve in the published tree, the action must be in the mask that
 * publication carried, and the host callback is made with the lock released and
 * a reference held across it, so a `free` that races with it waits instead of
 * returning into freed memory. The caller must already hold a reference to
 * `bridge`.
 */
static BOOL nogui_emit(nogui_mobile_bridge *bridge,
                       uint64_t native_id,
                       nogui_emit_request spec,
                       NoGuiTextProxy *control_proxy)
{
    nogui_mobile_action_fn on_action = NULL;
    void *user = NULL;
    nogui_lock_acquire();
    NSNumber *index = [bridge->index_by_id objectForKey:@(native_id)];
    size_t at = index != nil ? (size_t)index.unsignedLongLongValue : (size_t)-1;
    if (at == (size_t)-1 || at >= bridge->nodes_len || bridge->nodes[at].native_id != native_id) {
        nogui_lock_release();
        return NO;
    }
    if (bridge->inputs != nil && [bridge->inputs objectForKey:@(native_id)] != nil) {
        /* The node's editor is a real control, so only that control's own proxy
         * may speak for it. Read both halves of the binding and compare them:
         * the proxy has to be the one recorded for this id AND still watching
         * the control recorded for it, so a proxy that has been replaced, or
         * one whose control was taken away, stops answering for the node. */
        NoGuiTextProxy *bound_proxy = [bridge->proxies objectForKey:@(native_id)];
        if (control_proxy == nil || bound_proxy != control_proxy ||
            control_proxy.input == nil ||
            [bridge->inputs objectForKey:@(native_id)] != control_proxy.input) {
            nogui_lock_release();
            return NO;
        }
    }
    if ((bridge->nodes[at].actions & (1u << spec.action)) == 0) {
        nogui_lock_release();
        return NO;
    }
    on_action = bridge->on_action;
    user = bridge->user;
    bridge->refs += 1;
    nogui_lock_release();

    nogui_mobile_request request;
    memset(&request, 0, sizeof(request));
    request.action = spec.action;
    /* The id the platform held, which is the id the Zig side resolves. */
    request.target = native_id;
    request.data = spec.data;
    request.value = spec.value;
    request.value_len = spec.value_len;
    request.custom_action = spec.custom_action;
    request.anchor_index = spec.anchor;
    request.focus_index = spec.focus;
    BOOL handled = NO;
    if (on_action != NULL) {
        @try {
            on_action(user, &request);
            handled = YES;
        }
        @catch (NSException *fault) {
            /* A host that refuses a request is a refusal, not a success the
             * framework should act on. */
            (void)fault;
            handled = NO;
        }
    }
    nogui_lock_acquire();
    bridge->refs -= 1;
    nogui_lock_release();
    return handled;
}

/* ── real platform text inputs ───────────────────────────────────────────── */

/*
 * A bound text input is the one place the platform's own editing is read from.
 *
 * A synthetic `UIAccessibilityElement` cannot be edited: UIKit gives a screen
 * reader no way to type into it, so a text node published as one is announced
 * and nothing else. The host supplies a real control, and the published tree
 * shows THAT for the node. The shim then does three things and nothing else:
 * it copies the core's authoritative text and selection into the control, it
 * reads the platform's committed edits back out as requests, and it stands
 * aside while it does the first of those, so the callbacks those writes cause
 * are not reported back as edits nobody made.
 */

/* What the platform counts is UTF-16 offsets; what the header counts is
 * characters, and the core's characters are UNICODE CODE POINTS. That is not
 * the same as a composed character sequence: a base letter and a following
 * combining acute mark are two code points and the core counts two, while
 * `rangeOfComposedCharacterSequenceAtIndex` would call them one. A surrogate
 * pair is one code point in two UTF-16 units, so an offset that lands between
 * the halves has no code point boundary there: it is refused rather than
 * quietly moved to a neighbouring character. */
static BOOL nogui_codepoint_index(NSString *text, NSUInteger utf16, int64_t *out)
{
    if (utf16 > text.length) {
        return NO;
    }
    NSUInteger at = 0;
    int64_t seen = 0;
    while (at < utf16) {
        unichar unit = [text characterAtIndex:at];
        if (unit >= 0xD800 && unit <= 0xDBFF) {
            if (at + 1 >= utf16) {
                /* The offset falls between the halves of a pair. */
                return NO;
            }
            unichar low = [text characterAtIndex:at + 1];
            if (low < 0xDC00 || low > 0xDFFF) {
                /* A high surrogate with no low half: not a code point. */
                return NO;
            }
            seen += 1;
            at += 2;
            continue;
        }
        if (unit >= 0xDC00 && unit <= 0xDFFF) {
            /* A low surrogate with no high half: not a code point. */
            return NO;
        }
        seen += 1;
        at += 1;
    }
    *out = seen;
    return YES;
}

static NSUInteger nogui_utf16_offset(NSString *text, int64_t codepoints)
{
    NSUInteger length = text.length;
    NSUInteger at = 0;
    int64_t seen = 0;
    while (at < length && seen < codepoints) {
        unichar unit = [text characterAtIndex:at];
        NSUInteger step = 1;
        if (unit >= 0xD800 && unit <= 0xDBFF && at + 1 < length) {
            unichar low = [text characterAtIndex:at + 1];
            if (low >= 0xDC00 && low <= 0xDFFF) {
                step = 2;
            }
        }
        at += step;
        seen += 1;
    }
    return at;
}

/* Only the two concrete controls whose delegate this shim can stand in for are
 * supported. A responder that merely conforms to `UITextInput` — a text view of
 * the app's own making — has no delegate to intercept, so it is refused rather
 * than made to look editable. */
static BOOL nogui_input_is_field(UIView *input)
{
    return [input isKindOfClass:[UITextField class]];
}

static BOOL nogui_input_is_view(UIView *input)
{
    return [input isKindOfClass:[UITextView class]];
}

static NSString *nogui_input_text(UIView *input)
{
    if (nogui_input_is_field(input)) {
        return ((UITextField *)input).text;
    }
    if (nogui_input_is_view(input)) {
        return ((UITextView *)input).text;
    }
    return nil;
}

static void nogui_input_set_text(UIView *input, NSString *text)
{
    if (nogui_input_is_field(input)) {
        ((UITextField *)input).text = text;
    } else if (nogui_input_is_view(input)) {
        ((UITextView *)input).text = text;
    }
}

static NSRange nogui_input_selection(UIView *input)
{
    if (nogui_input_is_field(input)) {
        return ((UITextField *)input).selectedRange;
    }
    if (nogui_input_is_view(input)) {
        return ((UITextView *)input).selectedRange;
    }
    return NSMakeRange(0, 0);
}

static void nogui_input_set_selection(UIView *input, NSRange range)
{
    if (nogui_input_is_field(input)) {
        ((UITextField *)input).selectedRange = range;
    } else if (nogui_input_is_view(input)) {
        ((UITextView *)input).selectedRange = range;
    }
}

/* A range the platform will accept: inside the text, and never upside down. */
static NSRange nogui_input_clamp(NSString *text, NSRange range)
{
    NSUInteger length = text.length;
    if (range.location > length) {
        range.location = length;
    }
    if (range.length > length - range.location) {
        range.length = length - range.location;
    }
    return range;
}

/* Whether the control is in the middle of composing: the marked text the input
 * method has shown but not committed is the one state in which the control's
 * text is not a text anyone has decided on yet. */
static BOOL nogui_input_is_composing(UIView *input)
{
    if (!nogui_input_is_field(input) && !nogui_input_is_view(input)) {
        return NO;
    }
    return ((id<UITextInput>)input).markedTextRange != nil;
}

/*
 * The delegate the shim installs, which is also the delegate the app had.
 *
 * A text field's delegate protocol says one thing about a change the user made,
 * and it is asked before the change is applied. Nothing in it reports what the
 * control's text became afterwards, which is the only thing a committed
 * composition can be measured from, so standing in is not enough on its own.
 * UIKit's own statement that the text changed is the control's editing-changed
 * event, so the shim takes that too: for a field it is a second target beside
 * the app's own, removed again on unbind. Standing in as delegate costs the app
 * nothing because every callback is handed to the delegate it replaced, and the
 * original is kept weakly and put back on unbind.
 */

@implementation NoGuiTextProxy

/* One replacement, expressed the way the core can apply it: the range it
 * replaces, in the code points of the text the core holds, and the text that
 * takes its place. A range that ends inside a surrogate pair is refused, because
 * there is no code point boundary there and aiming at a neighbouring character
 * would be a silent corruption. */
- (void)nogui_report_replacement:(NSString *)replacement range:(NSRange)range base:(NSString *)base
{
    int64_t anchor = 0;
    int64_t focus = 0;
    if (!nogui_codepoint_index(base, range.location, &anchor) ||
        !nogui_codepoint_index(base, NSMaxRange(range), &focus)) {
        return;
    }
    NoGuiBridgeOwner *owner = self.owner;
    nogui_mobile_bridge *bridge = [owner acquire];
    if (bridge == NULL) {
        return;
    }
    nogui_emit_request spec;
    memset(&spec, 0, sizeof(spec));
    spec.action = NOGUI_MOBILE_ACTION_REPLACE_SELECTED_TEXT;
    spec.data = NOGUI_MOBILE_DATA_VALUE;
    /* Borrowed for the call only, which is all the host needs: the control keeps
     * the string alive underneath it. */
    const char *utf8 = [replacement UTF8String];
    spec.value = utf8;
    spec.value_len = utf8 != NULL ? strlen(utf8) : 0;
    spec.anchor = anchor;
    spec.focus = focus;
    /* `self` is the identity check: this call comes from the proxy standing in
     * for the bound control, which is what makes the request the control's own
     * edit rather than a second answer about it. */
    (void)nogui_emit(bridge, self.native_id, spec, self);
    [owner drop];
}

/*
 * The veto point, which is where a real edit becomes visible.
 *
 * The delegate that was replaced answers first, because a delegate that refuses
 * the change means no text changed and nothing should be reported. What the
 * call carries is not always the change either: while an input method is
 * composing, the control is holding marked text nobody has committed, so
 * nothing is sent, and the text and selection the composition started from are
 * remembered. The commit arrives as a further call with no marked text, and
 * that one is the difference between those two values and the control's text
 * afterwards — delivered once, from the next observation that shows the change.
 */
- (void)nogui_observe_edit:(NSString *)replacement range:(NSRange)range
{
    if (self.syncing != 0) {
        return;
    }
    if (nogui_input_is_composing(self.input)) {
        if (self.composing == 0) {
            self.composing = 1;
            /* The control still shows the pre-composition text and the selection
             * the composition started from, because nothing has been applied
             * yet at a veto point. */
            self.origin_text = nogui_input_text(self.input);
            self.origin_range = nogui_input_selection(self.input);
        }
        return;
    }
    if (self.composing != 0) {
        /* The commit. Its text is not this call's replacement string: what
         * changed is the difference the control ends up with, so it is delivered
         * once when that text is observable. */
        self.commit_pending = 1;
        return;
    }
    [self nogui_report_replacement:replacement range:range base:nogui_input_text(self.input)];
}

/* Deliver a committed composition, once, from an observation made after the
 * change was applied. */
- (BOOL)nogui_deliver_commit
{
    if (self.syncing != 0 || self.commit_pending == 0 || self.composing == 0) {
        return NO;
    }
    if (nogui_input_is_composing(self.input)) {
        return NO;
    }
    NSString *base = self.origin_text != nil ? self.origin_text : @"";
    NSString *now = nogui_input_text(self.input);
    NSRange origin = self.origin_range;
    self.composing = 0;
    self.commit_pending = 0;
    self.origin_text = nil;
    self.origin_range = NSMakeRange(0, 0);
    if (now == nil) {
        return NO;
    }
    /* What followed the replaced range is still there, so the text between the
     * start of the range and the start of that tail is what the input method put
     * there. */
    NSUInteger tail = base.length > NSMaxRange(origin) ? base.length - NSMaxRange(origin) : 0;
    if (now.length < origin.location || now.length - origin.location < tail) {
        /* The control's text is no longer the core's with one range replaced, so
         * the only statement both can agree on is the whole text. */
        [self nogui_report_replacement:now range:NSMakeRange(0, base.length) base:base];
        return YES;
    }
    [self nogui_report_replacement:[now substringWithRange:NSMakeRange(origin.location, now.length - tail - origin.location)]
                            range:origin
                             base:base];
    return YES;
}

/* The user moved the caret or extended a selection, outside any composition. */
- (void)nogui_report_selection
{
    if (self.syncing != 0 || self.composing != 0 || nogui_input_is_composing(self.input)) {
        return;
    }
    NoGuiBridgeOwner *owner = self.owner;
    nogui_mobile_bridge *bridge = [owner acquire];
    if (bridge == NULL) {
        return;
    }
    NSString *text = nogui_input_text(self.input);
    NSRange range = nogui_input_selection(self.input);
    int64_t anchor = 0;
    int64_t focus = 0;
    if (text != nil && nogui_codepoint_index(text, range.location, &anchor) &&
        nogui_codepoint_index(text, NSMaxRange(range), &focus)) {
        nogui_emit_request spec;
        memset(&spec, 0, sizeof(spec));
        spec.action = NOGUI_MOBILE_ACTION_SET_TEXT_SELECTION;
        spec.data = NOGUI_MOBILE_DATA_TEXT_SELECTION;
        spec.anchor = anchor;
        spec.focus = focus;
        (void)nogui_emit(bridge, self.native_id, spec, self);
    }
    [owner drop];
}

- (BOOL)textField:(UITextField *)textField
    shouldChangeCharactersInRange:(NSRange)range
                replacementString:(NSString *)string
{
    BOOL answer = YES;
    if ([self.field_delegate respondsToSelector:_cmd]) {
        answer = [self.field_delegate textField:textField
                      shouldChangeCharactersInRange:range
                              replacementString:string];
    }
    if (answer) {
        [self nogui_observe_edit:string range:range];
    }
    return answer;
}

- (BOOL)textView:(UITextView *)textView
    shouldChangeTextInRange:(NSRange)range
            replacementText:(NSString *)text
{
    BOOL answer = YES;
    if ([self.view_delegate respondsToSelector:_cmd]) {
        answer = [self.view_delegate textView:textView
                       shouldChangeTextInRange:range
                               replacementText:text];
    }
    if (answer) {
        [self nogui_observe_edit:text range:range];
    }
    return answer;
}

- (void)textViewDidChange:(UITextView *)textView
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate textViewDidChange:textView];
    }
    (void)[self nogui_deliver_commit];
}

- (void)textViewDidChangeSelection:(UITextView *)textView
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate textViewDidChangeSelection:textView];
    }
    if ([self nogui_deliver_commit]) {
        /* The commit carries the new text; the caret that came with it belongs to
         * the next publication, so it is not announced as a second request. */
        return;
    }
    [self nogui_report_selection];
}

/* Only a text field reports a selection from iOS 13, and asking for the
 * callback below that is a runtime question, not a build one. A commit is
 * delivered by the editing-changed event; delivering it here as well costs
 * nothing when that event already came, because a commit is delivered once. */
- (void)textFieldDidChangeSelection:(UITextField *)textField
{
    if (@available(iOS 13.0, *)) {
        if ([self.field_delegate respondsToSelector:_cmd]) {
            [self.field_delegate textFieldDidChangeSelection:textField];
        }
        if ([self nogui_deliver_commit]) {
            return;
        }
        [self nogui_report_selection];
    }
}

/* The control's own statement that its text has changed, sent once the changed
 * text is the control's — including the change an input method makes when it
 * commits the marked text it was showing, which is the observation a committed
 * composition is measured from. A field's delegate protocol has no callback
 * that comes after the change, so this event is the one that says the text is
 * now what it is. A text view is not a control and sends no such event; it keeps
 * the delegate callback it really has, `textViewDidChange:`. */
- (void)nogui_editing_changed:(id)sender
{
    if (sender != self.input) {
        return;
    }
    (void)[self nogui_deliver_commit];
}

/* ── everything below is the app's own delegate, handed straight through ── */

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField
{
    return [self.field_delegate textFieldShouldBeginEditing:textField];
}

- (void)textFieldDidBeginEditing:(UITextField *)textField
{
    [self.field_delegate textFieldDidBeginEditing:textField];
}

- (BOOL)textFieldShouldEndEditing:(UITextField *)textField
{
    return [self.field_delegate textFieldShouldEndEditing:textField];
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    [self.field_delegate textFieldDidEndEditing:textField];
}

- (BOOL)textFieldShouldClear:(UITextField *)textField
{
    return [self.field_delegate textFieldShouldClear:textField];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    return [self.field_delegate textFieldShouldReturn:textField];
}

- (BOOL)textField:(UITextField *)textField
    shouldInteractWithURL:(NSURL *)url
                  inRange:(NSRange)characterRange
              interaction:(UITextItemInteraction)interaction
{
    if ([self.field_delegate respondsToSelector:_cmd]) {
        return [self.field_delegate textField:textField
                      shouldInteractWithURL:url
                                    inRange:characterRange
                                interaction:interaction];
    }
    return NO;
}

- (BOOL)textField:(UITextField *)textField
    shouldInteractWithTextAttachment:(NSTextAttachment *)textAttachment
                              inRange:(NSRange)characterRange
                          interaction:(UITextItemInteraction)interaction
{
    if ([self.field_delegate respondsToSelector:_cmd]) {
        return [self.field_delegate textField:textField
      shouldInteractWithTextAttachment:textAttachment
                                    inRange:characterRange
                                interaction:interaction];
    }
    return NO;
}

- (BOOL)textViewShouldBeginEditing:(UITextView *)textView
{
    return [self.view_delegate textViewShouldBeginEditing:textView];
}

- (void)textViewDidBeginEditing:(UITextView *)textView
{
    [self.view_delegate textViewDidBeginEditing:textView];
}

- (BOOL)textViewShouldEndEditing:(UITextView *)textView
{
    return [self.view_delegate textViewShouldEndEditing:textView];
}

- (void)textViewDidEndEditing:(UITextView *)textView
{
    [self.view_delegate textViewDidEndEditing:textView];
}

- (void)textViewDidChange:(UITextView *)textView
{
    [self.view_delegate textViewDidChange:textView];
}

- (BOOL)textView:(UITextView *)textView shouldChangeFontSizeForText:(NSTextRange *)textRange
{
    return [self.view_delegate textView:textView shouldChangeFontSizeForText:textRange];
}

- (BOOL)textView:(UITextView *)textView
    shouldInteractWithURL:(NSURL *)url
                  inRange:(NSRange)characterRange
              interaction:(UITextItemInteraction)interaction
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        return [self.view_delegate textView:textView
                     shouldInteractWithURL:url
                                   inRange:characterRange
                               interaction:interaction];
    }
    return NO;
}

- (BOOL)textView:(UITextView *)textView
    shouldInteractWithTextAttachment:(NSTextAttachment *)textAttachment
                              inRange:(NSRange)characterRange
                          interaction:(UITextItemInteraction)interaction
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        return [self.view_delegate textView:textView
      shouldInteractWithTextAttachment:textAttachment
                                    inRange:characterRange
                                interaction:interaction];
    }
    return NO;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate scrollViewDidScroll:scrollView];
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate scrollViewWillBeginDragging:scrollView];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate scrollViewDidEndDragging:scrollView willDecelerate:decelerate];
    }
}

- (void)scrollViewWillBeginDecelerating:(UIScrollView *)scrollView
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate scrollViewWillBeginDecelerating:scrollView];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate scrollViewDidEndDecelerating:scrollView];
    }
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate scrollViewDidEndScrollingAnimation:scrollView];
    }
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView
{
    if (@available(iOS 11.0, *)) {
        if ([self.view_delegate respondsToSelector:_cmd]) {
            [self.view_delegate scrollViewDidScrollToTop:scrollView];
        }
    }
}

- (BOOL)scrollViewShouldScrollToTop:(UIScrollView *)scrollView
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        return [self.view_delegate scrollViewShouldScrollToTop:scrollView];
    }
    return NO;
}

- (void)scrollViewWillBeginZooming:(UIScrollView *)scrollView withView:(UIView *)view
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate scrollViewWillBeginZooming:scrollView withView:view];
    }
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate scrollViewDidZoom:scrollView];
    }
}

- (void)scrollViewWillEndZooming:(UIScrollView *)scrollView
                       withView:(UIView *)view
                        atScale:(CGFloat)scale
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate scrollViewWillEndZooming:scrollView withView:view atScale:scale];
    }
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView
                     withView:(UIView *)view
                      atScale:(CGFloat)scale
{
    if ([self.view_delegate respondsToSelector:_cmd]) {
        [self.view_delegate scrollViewDidEndZooming:scrollView withView:view atScale:scale];
    }
}

@end

/*
 * One published node, as a real accessibility element.
 *
 * The element owns everything the framework will read: the strings and the
 * screen-space frame as its own properties, the rest through the bridge. That
 * split is what makes an element safe to keep between updates — nothing it
 * answers points into a buffer the adapter has already recycled.
 */
@interface NoGuiElement : UIAccessibilityElement
/* The id the platform holds, and the id every request is aimed at. */
@property(nonatomic, assign) uint64_t native_id;
/* `atomic` so the accessibility thread's read and `_free`'s write to nil are
 * one synchronised event rather than a race on a pointer. */
@property(atomic, strong) NoGuiBridgeOwner *owner;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *value_text;
@property(nonatomic, copy) NSString *hint_text;
@property(nonatomic, copy) NSString *placeholder_text;
@property(nonatomic, copy) NSArray<NoGuiCustomAction *> *custom_actions;
@property(nonatomic, assign) CGRect screen_frame;
@property(nonatomic, assign) int32_t rows;
@end

/*
 * One named action the app attached to a node.
 *
 * `UIAccessibilityCustomAction` is itself an accessibility element, and a
 * framework that performs one activates that element. Subclassing it to carry
 * the node's native id and the app's own action id is what makes the performed
 * action name the right one: a shared target with a single selector could not
 * tell two custom actions on the same node apart.
 */
@interface NoGuiCustomAction : UIAccessibilityCustomAction
@property(atomic, strong) NoGuiBridgeOwner *owner;
@property(nonatomic, assign) uint64_t native_id;
@property(nonatomic, assign) int32_t custom_id;
@end

/* The strings for one node, materialised before anything is mutated, so a
 * refused string leaves the previously published tree exactly as it was. */
@interface NoGuiFacts : NSObject
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *value;
@property(nonatomic, copy) NSString *hint;
@property(nonatomic, copy) NSString *placeholder;
@property(nonatomic, copy) NSArray<NoGuiCustomAction *> *customs;
@end

@implementation NoGuiFacts
@end

@implementation NoGuiElement

/* The current node behind this element, or a dead snapshot when the element is
 * no longer the live element for its id. Three conditions are checked: a
 * retired element has no owner at all, an id the current update no longer
 * publishes resolves to nothing, and a node with a real input bound is answered
 * by that control instead. None of them can fall through to a node the app did
 * not publish, and none of them can let a synthetic element stand in for an
 * editable one. */
- (nogui_snapshot)nogui_read
{
    nogui_snapshot snapshot = nogui_snapshot_empty();
    NoGuiBridgeOwner *owner = self.owner;
    nogui_mobile_bridge *bridge = [owner acquire];
    if (bridge == NULL) {
        return snapshot;
    }
    nogui_lock_acquire();
    NSNumber *index = [bridge->inputs objectForKey:@(self.native_id)] == nil
                          ? [bridge->index_by_id objectForKey:@(self.native_id)]
                          : nil;
    if (index != nil) {
        size_t at = (size_t)index.unsignedLongLongValue;
        if (at < bridge->nodes_len && bridge->nodes[at].native_id == self.native_id) {
            const nogui_mobile_node *entry = &bridge->nodes[at];
            snapshot.live = 1;
            snapshot.role = entry->role;
            snapshot.states = entry->states;
            snapshot.actions = entry->actions;
            snapshot.bounds = entry->bounds;
            snapshot.has_numeric = entry->has_numeric_value != 0;
            snapshot.numeric_value = entry->numeric_value;
            snapshot.rows = self.rows;
            snapshot.screen_frame = self.screen_frame;
        }
    }
    nogui_lock_release();
    [owner drop];
    return snapshot;
}

- (NSString *)accessibilityLabel
{
    nogui_lock_acquire();
    NSString *label = self.label;
    nogui_lock_release();
    return label;
}

- (NSString *)accessibilityHint
{
    nogui_lock_acquire();
    NSString *hint = self.hint_text;
    nogui_lock_release();
    return hint;
}

/* A text field's visible label while it holds no text. UIKit names this
 * separately from the label so a screen reader can tell the prompt from the
 * name, and the core publishes exactly that fact. */
- (NSString *)accessibilityPlaceholderValue
{
    nogui_lock_acquire();
    NSString *placeholder = self.placeholder_text;
    nogui_lock_release();
    return placeholder;
}

- (NSString *)accessibilityValue
{
    nogui_snapshot snapshot = [self nogui_read];
    if (!snapshot.live) {
        return nil;
    }
    nogui_lock_acquire();
    NSString *value = self.value_text;
    nogui_lock_release();
    if (value != nil) {
        return value;
    }
    if (!snapshot.has_numeric) {
        return nil;
    }
    /* A numeric control's value is a number, and a screen reader announces what
     * it is given. UIKit's own text input fields announce a bare number, so
     * this formats one the same way rather than inventing a range string for a
     * control whose range the framework has no way to read back. */
    return [NSString stringWithFormat:@"%g", snapshot.numeric_value];
}

- (UIAccessibilityTraits)accessibilityTraits
{
    nogui_snapshot snapshot = [self nogui_read];
    if (!snapshot.live) {
        return UIAccessibilityTraitNone;
    }
    /* UIKit's trait values are the documented public bit masks. The mapping is
     * role-driven for the affordance and state-driven for the condition,
     * because those are two different facts about a node and a screen reader
     * announces them differently. A role UIKit has no trait for contributes
     * nothing, rather than borrowing a trait that means something else. */
    UIAccessibilityTraits traits = UIAccessibilityTraitNone;
    switch (snapshot.role) {
    case NOGUI_MOBILE_ROLE_BUTTON:
    case NOGUI_MOBILE_ROLE_SWITCH:
    case NOGUI_MOBILE_ROLE_TAB:
    case NOGUI_MOBILE_ROLE_CHECK_BOX:
    case NOGUI_MOBILE_ROLE_RADIO_BUTTON:
        traits |= UIAccessibilityTraitButton;
        break;
    case NOGUI_MOBILE_ROLE_TEXT_RUN:
    case NOGUI_MOBILE_ROLE_LABEL:
        traits |= UIAccessibilityTraitStaticText;
        break;
    case NOGUI_MOBILE_ROLE_IMAGE:
        traits |= UIAccessibilityTraitImage;
        break;
    case NOGUI_MOBILE_ROLE_SEARCH_INPUT:
        traits |= UIAccessibilityTraitSearchField;
        break;
    case NOGUI_MOBILE_ROLE_SLIDER:
    case NOGUI_MOBILE_ROLE_SPIN_BUTTON:
        traits |= UIAccessibilityTraitAdjustable;
        break;
    case NOGUI_MOBILE_ROLE_TAB_LIST:
        traits |= UIAccessibilityTraitTabBar;
        break;
    default:
        break;
    }
    if ((snapshot.states & NOGUI_MOBILE_STATE_SELECTED) != 0) {
        traits |= UIAccessibilityTraitSelected;
    }
    /* A checked box is the selected state. A mixed one has no trait in UIKit, so
     * it is left for the app to describe through its own value rather than
     * announced as something the platform cannot say. */
    if ((snapshot.states & NOGUI_MOBILE_STATE_CHECKED_ON) != 0) {
        traits |= UIAccessibilityTraitSelected;
    }
    if ((snapshot.states & NOGUI_MOBILE_STATE_DISABLED) != 0) {
        traits |= UIAccessibilityTraitNotEnabled;
    }
    /* A busy node and a live region are the two cases UIKit describes with this
     * trait: the content changes while the app runs. */
    if ((snapshot.states & (NOGUI_MOBILE_STATE_BUSY | NOGUI_MOBILE_STATE_LIVE_REGION)) != 0) {
        traits |= UIAccessibilityTraitUpdatesFrequently;
    }
    /* Modality is not a trait: UIKit states it with `accessibilityIsModal`, and
     * `UIAccessibilityTraitCausesPageTurn` would make VoiceOver navigate the
     * node as if it turned a page, which is a different claim. */
    return traits;
}

- (BOOL)isAccessibilityElement
{
    /* A node the core hid is announced but not seen. It stays in the tree so a
     * screen reader can still reach it, and it reports itself as not an element
     * so VoiceOver does not draw a focus ring for it. */
    nogui_snapshot snapshot = [self nogui_read];
    if (!snapshot.live) {
        return NO;
    }
    return (snapshot.states & NOGUI_MOBILE_STATE_HIDDEN) == 0;
}

- (BOOL)accessibilityIsModal
{
    nogui_snapshot snapshot = [self nogui_read];
    if (!snapshot.live) {
        return NO;
    }
    /* Modality is authored in the core, so this only forwards it. A subtree the
     * app did not mark modal is never treated as modal here. */
    return (snapshot.states & NOGUI_MOBILE_STATE_MODAL) != 0;
}

/* The bounds the core published, in the space of this element's container.
 * The container is the window, which is the space the core published in and
 * the space the header states safe-area and keyboard frames in. */
- (CGRect)accessibilityFrameInContainerSpace
{
    nogui_snapshot snapshot = [self nogui_read];
    if (!snapshot.live) {
        return CGRectZero;
    }
    return CGRectMake(snapshot.bounds.x0,
                      snapshot.bounds.y0,
                      snapshot.bounds.x1 - snapshot.bounds.x0,
                      snapshot.bounds.y1 - snapshot.bounds.y0);
}

/* The same rectangle in screen coordinates, converted once on the main thread
 * during the update that published the bounds. Converting here instead would
 * call UIKit geometry from the accessibility thread, which UIKit does not
 * accept. */
- (CGRect)accessibilityFrame
{
    nogui_snapshot snapshot = [self nogui_read];
    if (!snapshot.live) {
        return CGRectZero;
    }
    return snapshot.screen_frame;
}

- (nullable NSArray *)accessibilityElements
{
    NoGuiBridgeOwner *owner = self.owner;
    nogui_mobile_bridge *bridge = [owner acquire];
    if (bridge == NULL) {
        return nil;
    }
    nogui_lock_acquire();
    NSArray *found = nil;
    NSNumber *index = [bridge->index_by_id objectForKey:@(self.native_id)];
    if (index != nil) {
        found = [bridge->children objectForKey:@(self.native_id)];
    }
    nogui_lock_release();
    [owner drop];
    if (found.count == 0) {
        return nil;
    }
    return found;
}

- (NSArray<NoGuiCustomAction *> *)accessibilityCustomActions
{
    nogui_lock_acquire();
    NSArray<NoGuiCustomAction *> *customs = self.custom_actions;
    nogui_lock_release();
    return customs;
}

/* A list of rows is announced with its positions by UIKit when the container
 * says it holds a list. A node that is not a list of rows makes no such claim. */
- (UIAccessibilityContainerType)accessibilityContainerType
{
    nogui_snapshot snapshot = [self nogui_read];
    if (!snapshot.live) {
        return UIAccessibilityContainerTypeNone;
    }
    if (snapshot.rows != 0 || snapshot.role == NOGUI_MOBILE_ROLE_LIST || snapshot.role == NOGUI_MOBILE_ROLE_LIST_BOX) {
        return UIAccessibilityContainerTypeList;
    }
    return UIAccessibilityContainerTypeNone;
}

- (BOOL)nogui_perform:(uint8_t)action
{
    NoGuiBridgeOwner *owner = self.owner;
    nogui_mobile_bridge *bridge = [owner acquire];
    if (bridge == NULL) {
        return NO;
    }
    /* A synthetic element is never the bound control's proxy, and a node with a
     * real input bound is answered by that control instead. */
    BOOL handled = nogui_emit(bridge, self.native_id, NOGUI_EMIT(action), NULL);
    [owner drop];
    return handled;
}

- (BOOL)accessibilityActivate
{
    nogui_snapshot snapshot = [self nogui_read];
    if (!snapshot.live) {
        return NO;
    }
    /* A node the core offers to click is clicked. A node it only offers to
     * expand or collapse is toggled, because activation is the only gesture
     * UIKit gives a collapsible control, and the published state decides which
     * way it goes. A node that offers both is a button first. */
    if ((snapshot.actions & (1u << NOGUI_MOBILE_ACTION_CLICK)) != 0) {
        return [self nogui_perform:NOGUI_MOBILE_ACTION_CLICK];
    }
    if ((snapshot.actions & (1u << NOGUI_MOBILE_ACTION_EXPAND)) != 0) {
        return [self nogui_perform:NOGUI_MOBILE_ACTION_EXPAND];
    }
    if ((snapshot.actions & (1u << NOGUI_MOBILE_ACTION_COLLAPSE)) != 0) {
        return [self nogui_perform:NOGUI_MOBILE_ACTION_COLLAPSE];
    }
    return NO;
}

- (void)accessibilityIncrement
{
    (void)[self nogui_perform:NOGUI_MOBILE_ACTION_INCREMENT];
}

- (void)accessibilityDecrement
{
    (void)[self nogui_perform:NOGUI_MOBILE_ACTION_DECREMENT];
}

- (BOOL)accessibilityScroll:(UIAccessibilityScrollDirection)direction
{
    /* UIKit has no core action for a sideways scroll, so it is refused instead
     * of being aimed at the nearest one. */
    if (direction == UIAccessibilityScrollDirectionUp) {
        return [self nogui_perform:NOGUI_MOBILE_ACTION_SCROLL_UP];
    }
    if (direction == UIAccessibilityScrollDirectionDown) {
        return [self nogui_perform:NOGUI_MOBILE_ACTION_SCROLL_DOWN];
    }
    return NO;
}

- (BOOL)accessibilityScrollToVisibleElement
{
    return [self nogui_perform:NOGUI_MOBILE_ACTION_SCROLL_INTO_VIEW];
}

@end

@implementation NoGuiCustomAction

- (BOOL)accessibilityActivate
{
    NoGuiBridgeOwner *owner = self.owner;
    nogui_mobile_bridge *bridge = [owner acquire];
    if (bridge == NULL) {
        return NO;
    }
    uint64_t native_id = self.native_id;
    int32_t custom_id = self.custom_id;
    /* A named action the app has since withdrawn must not fire. The live
     * element is asked whether it still offers this id, and a retired element
     * offers nothing. */
    nogui_lock_acquire();
    BOOL offered = NO;
    NoGuiElement *element = [bridge->elements objectForKey:@(native_id)];
    if (element != nil && element.owner != nil) {
        for (NoGuiCustomAction *live in element.custom_actions) {
            if (live.custom_id == custom_id) {
                offered = YES;
                break;
            }
        }
    }
    nogui_lock_release();
    if (offered) {
        nogui_emit_request spec;
        memset(&spec, 0, sizeof(spec));
        spec.action = NOGUI_MOBILE_ACTION_CUSTOM;
        spec.data = NOGUI_MOBILE_DATA_CUSTOM_ACTION;
        spec.custom_action = custom_id;
        spec.anchor = -1;
        spec.focus = -1;
        BOOL handled = nogui_emit(bridge, native_id, spec, NULL);
        [owner drop];
        return handled;
    }
    [owner drop];
    return NO;
}

@end

/* ── the bridge ──────────────────────────────────────────────────────────── */

/*
 * A node the current update no longer publishes stops answering. The framework
 * may still hold the object, so the object is emptied rather than released: a
 * retained element then refuses every question and every action instead of
 * describing, or acting on, whatever its id names now. Called with the lock
 * held.
 */
static void nogui_ios_retire_element(NoGuiElement *element)
{
    if (element == nil) {
        return;
    }
    for (NoGuiCustomAction *custom in element.custom_actions) {
        custom.owner = nil;
    }
    element.owner = nil;
    element.custom_actions = nil;
    element.label = nil;
    element.value_text = nil;
    element.hint_text = nil;
    element.placeholder_text = nil;
    element.rows = 0;
    element.screen_frame = CGRectZero;
    [element setAccessibilityCustomActions:nil];
}

/*
 * Put back what a binding took from one control: the delegate the app had, the
 * control's editing-changed target, and the window the control was put into so
 * UIKit could make it first responder. The control itself is the app's, and the
 * shim never owns it. The proxy is silenced first, so none of this teardown is
 * reported as an edit, and cut from the bridge at the end, so a callback that
 * still arrives reaches no storage. UIKit does not tolerate any of this off the
 * main thread, which is what the one caller that cannot be there defers.
 */
static void nogui_unbind_control(UIView *input, NoGuiTextProxy *proxy)
{
    if (proxy == nil) {
        return;
    }
    proxy.syncing = 1;
    /* Only a delegate the shim still owns is replaced. An app that swapped the
     * delegate after the binding is left as it is. */
    if (nogui_input_is_field(input) && (id)((UITextField *)input).delegate == (id)proxy) {
        ((UITextField *)input).delegate = proxy.field_delegate;
    } else if (nogui_input_is_view(input) && (id)((UITextView *)input).delegate == (id)proxy) {
        ((UITextView *)input).delegate = proxy.view_delegate;
    }
    /* The event registration is undone pair for pair, and only where bind made
     * it, so a target the app registered for itself is never touched. */
    if (proxy.editing_changed_target != 0) {
        proxy.editing_changed_target = 0;
        if (nogui_input_is_field(input)) {
            [(UITextField *)input removeTarget:proxy
                                        action:@selector(nogui_editing_changed:)
                              forControlEvents:UIControlEventEditingChanged];
        }
    }
    /* The window the shim put the control into is taken away again, but only
     * while the control is still a direct subview of that window: an app that
     * moved it into a view of its own, or a later binding that put the same
     * control somewhere, is left as it is. */
    if (proxy.added_window != nil && input.superview == proxy.added_window) {
        [input removeFromSuperview];
    }
    proxy.added_window = nil;
    proxy.owner = nil;
    proxy.input = nil;
}

static void nogui_unbind_key(nogui_mobile_bridge *bridge, NSNumber *key)
{
    nogui_unbind_control([bridge->inputs objectForKey:key], [bridge->proxies objectForKey:key]);
    [bridge->proxies removeObjectForKey:key];
    [bridge->inputs removeObjectForKey:key];
}

static void nogui_unbind_all(nogui_mobile_bridge *bridge)
{
    if (bridge->inputs == nil) {
        return;
    }
    /* Restoring a delegate and removing a target are UIKit work, and `_free` can
     * be called off the main thread even though it cannot report that it was. The
     * teardown is finished on the main thread instead, in a block that holds each
     * proxy alive until it runs: a control does NOT retain its targets, so
     * releasing a proxy while the control still lists it is a message into freed
     * memory. That block touches no bridge, so nothing waits for it, and nothing
     * needs to: the storage is freed as soon as this returns, which is why every
     * proxy is cut off from its owner here, on the thread that is about to free
     * it. A callback that arrives before the block runs then finds no owner to
     * reach freed memory through. `owner` is atomic for exactly this. */
    if (![NSThread isMainThread]) {
        NSArray<NoGuiTextProxy *> *held = [bridge->proxies allValues];
        for (NoGuiTextProxy *proxy in held) {
            proxy.owner = nil;
        }
        bridge->proxies = nil;
        bridge->inputs = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            /* Unattended and inside the main run loop, so a fault here has
             * nowhere to be reported to and must not be left to unwind. */
            @try {
                for (NoGuiTextProxy *proxy in held) {
                    nogui_unbind_control(proxy.input, proxy);
                }
            }
            @catch (NSException *fault) {
                (void)fault;
            }
        });
        return;
    }
    for (NSNumber *key in [bridge->inputs allKeys]) {
        nogui_unbind_key(bridge, key);
    }
    bridge->proxies = nil;
    bridge->inputs = nil;
}

/*
 * Copy the core's authoritative text and selection into the bound control, and
 * the core's strings onto the surface a screen reader reads. The control is
 * silenced for the duration, so the callbacks these writes cause are not
 * reported back as edits nobody made; that silence is the only thing standing
 * between a republish and a feedback loop. Called with the lock held, on the
 * main thread, from the update that published the node.
 */
static void nogui_sync_mirror(nogui_mobile_bridge *bridge,
                              uint64_t native_id,
                              const nogui_mobile_node *node,
                              NoGuiFacts *facts)
{
    NSNumber *key = @(native_id);
    UIView *input = [bridge->inputs objectForKey:key];
    if (input == nil) {
        return;
    }
    NoGuiTextProxy *proxy = [bridge->proxies objectForKey:key];
    if (proxy == nil) {
        return;
    }
    proxy.syncing = 1;
    NSString *text = facts.value != nil ? facts.value : @"";
    /* An input method mid-composition owns the control's text. Writing the
     * core's committed value over it would throw away what the user is typing
     * and cancel the composition, so the text and the selection are left alone
     * until it commits. Everything a screen reader reads is still written,
     * because none of it is the text. */
    if (!nogui_input_is_composing(input)) {
        if (![text isEqualToString:nogui_input_text(input)]) {
            nogui_input_set_text(input, text);
        }
        /* A run that published no character table says so with a negative
         * offset, and then the control keeps whatever selection it has. */
        if (node->text_selection_anchor >= 0 && node->text_selection_focus >= 0) {
            NSUInteger low = nogui_utf16_offset(text, node->text_selection_anchor);
            NSUInteger high = nogui_utf16_offset(text, node->text_selection_focus);
            if (high < low) {
                NSUInteger swap = low;
                low = high;
                high = swap;
            }
            NSRange wanted = nogui_input_clamp(text, NSMakeRange(low, high - low));
            if (!NSEqualRanges(wanted, nogui_input_selection(input))) {
                nogui_input_set_selection(input, wanted);
            }
        }
        /* The core's value is now the control's value, so any composition that
         * starts from here measures itself against this. */
        proxy.composing = 0;
        proxy.commit_pending = 0;
        proxy.origin_text = nil;
        proxy.origin_range = NSMakeRange(0, 0);
    }
    /* The core is authoritative about the strings a screen reader speaks, so
     * they are written onto the control. Its value is not: a real text control
     * already speaks its own text, and overriding that would announce the text
     * twice. */
    input.accessibilityLabel = facts.label;
    input.accessibilityHint = facts.hint;
    input.accessibilityPlaceholderValue = facts.placeholder;
    input.accessibilityFrameInContainerSpace =
        CGRectMake(node->bounds.x0,
                   node->bounds.y0,
                   node->bounds.x1 - node->bounds.x0,
                   node->bounds.y1 - node->bounds.y0);
    /* A node the core disables is a control the app refuses to edit, and a
     * real control has one way to say so. Presentation is left to the app. */
    input.enabled = (node->states & NOGUI_MOBILE_STATE_DISABLED) == 0;
    proxy.syncing = 0;
}

/* Release the published tree and the storage behind it. Called with the lock
 * held, from a main-thread entry point, so it never runs concurrently with an
 * update. */
static void nogui_ios_a11y_release(nogui_mobile_bridge *bridge)
{
    if (bridge == nil) {
        return;
    }
    /* Bindings belong to the tree they mirror, so they go when the tree does. */
    nogui_unbind_all(bridge);
    if (bridge->elements != nil) {
        for (NSNumber *key in [bridge->elements allKeys]) {
            nogui_ios_retire_element(bridge->elements[key]);
        }
    }
    bridge->elements = nil;
    bridge->children = nil;
    bridge->index_by_id = nil;
    free(bridge->nodes);
    bridge->nodes = NULL;
    bridge->nodes_len = 0;
    bridge->root = NOGUI_MOBILE_NO_NODE;
    bridge->focus = NOGUI_MOBILE_NO_NODE;
    bridge->announced_focus = NOGUI_MOBILE_NO_NODE;
    /* A re-attached adapter has no live tree, so the next update must
     * re-declare the whole thing rather than patch one that no longer exists. */
    bridge->tree_initialized = 0;
    bridge->detached = 1;
    bridge->window = nil;
}

nogui_mobile_bridge *nogui_ios_a11y_new(
    void *user,
    nogui_mobile_action_fn on_action,
    nogui_mobile_dirty_fn on_dirty)
{
    if (on_action == NULL) {
        return NULL;
    }
    nogui_mobile_bridge *bridge = calloc(1, sizeof(*bridge));
    if (bridge == NULL) {
        return NULL;
    }
    NoGuiBridgeOwner *owner = [[NoGuiBridgeOwner alloc] init];
    if (owner == nil) {
        free(bridge);
        return NULL;
    }
    owner.storage = bridge;
    /* The struct's field takes over the reference. Nothing else keeps the owner
     * alive on purpose: the framework's elements hold their own, and a handle
     * that outlived every element would keep storage alive that nothing can
     * reach. */
    bridge->owner = owner;
    bridge->user = user;
    bridge->on_action = on_action;
    bridge->on_dirty = on_dirty;
    bridge->detached = 1;
    /* A window the host has just attached is the one it is working on, so a
     * focus announcement is allowed until the host says otherwise. */
    bridge->window_focused = 1;
    return bridge;
}

void nogui_ios_a11y_free(nogui_mobile_bridge *bridge)
{
    if (bridge == nil) {
        return;
    }
    UIWindow *window = nil;
    if ([NSThread isMainThread]) {
        @try {
            window = bridge->window;
            if (window != nil) {
                [window setAccessibilityElements:nil];
            }
        }
        @catch (NSException *fault) {
            (void)fault;
        }
    }
    /* Read once, before the storage is touched: the local keeps the handle
     * alive while the bridge stops handing out references. */
    NoGuiBridgeOwner *owner = bridge->owner;
    [owner kill];
    nogui_lock_acquire();
    nogui_ios_a11y_release(bridge);
    nogui_lock_release();
    /* Every element and named action was retired above and the bridge refuses
     * new references from here on, so the count can only fall. Each reference
     * is held for a read or a host callback that must return promptly, which is
     * what makes this wait short. */
    for (;;) {
        nogui_lock_acquire();
        int32_t refs = bridge->refs;
        nogui_lock_release();
        if (refs == 0) {
            break;
        }
        sched_yield();
    }
    /* The struct's reference is handed back here, after the last one that could
     * reach the struct is gone. */
    bridge->owner = nil;
    free(bridge);
    owner = nil;
}

int32_t nogui_ios_a11y_attach(nogui_mobile_bridge *bridge, void *ui_window)
{
    int32_t status = nogui_guard_main();
    if (status != NOGUI_MOBILE_OK) {
        return status;
    }
    if (bridge == nil || ui_window == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    UIWindow *window = nogui_window(ui_window);
    if (window == nil) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    UIWindow *previous = nil;
    nogui_lock_acquire();
    if (bridge->dead) {
        nogui_lock_release();
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    /* One window at a time. A tree that belonged to the previous window is not
     * this window's tree, and the release also clears `tree_initialized` and
     * `detached`, which the assignment below then undoes. */
    previous = bridge->window;
    nogui_ios_a11y_release(bridge);
    bridge->window = window;
    bridge->detached = 0;
    nogui_lock_release();
    if (previous != nil && previous != window) {
        @try {
            [previous setAccessibilityElements:nil];
        }
        @catch (NSException *fault) {
            (void)fault;
        }
    }
    return NOGUI_MOBILE_OK;
}

void nogui_ios_a11y_detach(nogui_mobile_bridge *bridge)
{
    if (bridge == nil) {
        return;
    }
    if ([NSThread isMainThread]) {
        @try {
            UIWindow *window = bridge->window;
            if (window != nil) {
                [window setAccessibilityElements:nil];
            }
        }
        @catch (NSException *fault) {
            (void)fault;
        }
    }
    nogui_lock_acquire();
    nogui_ios_a11y_release(bridge);
    nogui_lock_release();
}

/* The framework's own attachment: a node is in the tree because UIKit holds the
 * element, not because the adapter said so. */
int32_t nogui_ios_a11y_is_active(const nogui_mobile_bridge *bridge)
{
    if (bridge == nil) {
        return 0;
    }
    /* The question is about framework state, which only the main thread may
     * read, and this answer carries no thread code to report a wrong one with.
     * An off-main caller is told "not active", which only makes a host publish
     * an update it would have published anyway. */
    if (![NSThread isMainThread]) {
        return 0;
    }
    UIWindow *window = nil;
    int32_t idle = 1;
    nogui_lock_acquire();
    idle = bridge->dead || bridge->detached || bridge->window == nil;
    window = bridge->window;
    nogui_lock_release();
    if (idle || window == nil) {
        return 0;
    }
    @try {
        /* A screen reader has to be running, and the window has to be carrying
         * the elements this bridge published. */
        if (!UIAccessibilityIsVoiceOverRunning()) {
            return 0;
        }
        return window.accessibilityElements.count != 0 ? 1 : 0;
    }
    @catch (NSException *fault) {
        (void)fault;
        return 0;
    }
}

/*
 * Record whether the app considers this window the focused one.
 *
 * This decides where a focus announcement goes and nothing else. A window the
 * app has not focused is still a window a user can be reading, and hiding its
 * elements would delete controls that have nothing to do with the focus state
 * — so the tree stays exactly as published. Losing focus also forgets the last
 * announced focus, so regaining it moves the screen reader again rather than
 * looking unchanged.
 */
int32_t nogui_ios_a11y_set_window_focused(nogui_mobile_bridge *bridge, int32_t focused)
{
    int32_t status = nogui_guard_main();
    if (status != NOGUI_MOBILE_OK) {
        return status;
    }
    if (bridge == nil) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    UIWindow *window = nil;
    nogui_lock_acquire();
    if (!bridge->dead) {
        window = bridge->window;
        bridge->window_focused = focused != 0 ? 1 : 0;
        if (focused == 0) {
            bridge->announced_focus = NOGUI_MOBILE_NO_NODE;
        }
    }
    nogui_lock_release();
    if (window == nil) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    @try {
        if (focused != 0) {
            /* A focused window is the one being read, and it must not shadow
             * what any other window holds. */
            [window setAccessibilityViewIsModal:NO];
        }
    }
    @catch (NSException *fault) {
        (void)fault;
        return NOGUI_MOBILE_ERR_FAULT;
    }
    return NOGUI_MOBILE_OK;
}

int32_t nogui_ios_a11y_layout_changed(nogui_mobile_bridge *bridge)
{
    int32_t status = nogui_guard_main();
    if (status != NOGUI_MOBILE_OK) {
        return status;
    }
    if (bridge == nil) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    UIWindow *window = nil;
    nogui_lock_acquire();
    if (!bridge->dead) {
        window = bridge->window;
    }
    nogui_lock_release();
    /* There is nothing to describe without a window. Beyond that the platform
     * has no answer to give: `UIAccessibilityPostNotification` returns nothing,
     * so a system that declined to post cannot be observed from here, and
     * saying otherwise would be a claim the API cannot support. */
    if (window == nil) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    @try {
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
    }
    @catch (NSException *fault) {
        (void)fault;
        return NOGUI_MOBILE_ERR_FAULT;
    }
    return NOGUI_MOBILE_OK;
}

/*
 * Bind an app-owned real text input to a semantic node.
 *
 * The control stays the app's: the shim holds it weakly, restores the delegate
 * it replaced, removes the editing-changed target it added, and takes the
 * control out of the window again if it put it there.
 * What the binding adds is the published tree showing the control for that node
 * — so a screen reader can actually edit and focus it — and the two directions
 * of text: the core's text and selection are written in, and the platform's
 * committed edits are read out as requests.
 *
 * A shape the shim cannot observe is refused rather than made to look
 * editable, and a node the current tree does not publish is refused too: a
 * mirror with nothing to mirror would be a control the user could type into and
 * the app would never hear about.
 */
int32_t nogui_ios_a11y_bind_text_input(nogui_mobile_bridge *bridge, void *ui_text_input, uint64_t native_id)
{
    int32_t status = nogui_guard_main();
    if (status != NOGUI_MOBILE_OK) {
        return status;
    }
    if (bridge == nil || ui_text_input == NULL || native_id == NOGUI_MOBILE_NO_NODE) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    UIView *input = (__bridge UIView *)ui_text_input;
    if (!nogui_input_is_field(input) && !nogui_input_is_view(input)) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    NoGuiTextProxy *proxy = [[NoGuiTextProxy alloc] init];
    if (proxy == nil) {
        return NOGUI_MOBILE_ERR_MEMORY;
    }
    int32_t refused = NOGUI_MOBILE_OK;
    @try {
        nogui_lock_acquire();
        if (bridge->dead || bridge->detached) {
            refused = NOGUI_MOBILE_ERR_UNAVAILABLE;
        } else if (bridge->nodes_len != 0 && [bridge->index_by_id objectForKey:@(native_id)] == nil) {
            /* A tree is published and this is not a node in it. */
            refused = NOGUI_MOBILE_ERR_ARGUMENT;
        } else {
            NSNumber *key = @(native_id);
            /* A control already bound elsewhere is released first, so one
             * control is never answering for two nodes. */
            UIView *other = nil;
            NSNumber *other_key = nil;
            if (bridge->inputs != nil) {
                for (NSNumber *candidate in [bridge->inputs allKeys]) {
                    if ([bridge->inputs[candidate] isEqual:input]) {
                        other = bridge->inputs[candidate];
                        other_key = candidate;
                        break;
                    }
                }
            }
            if (other != nil && ![other_key isEqualToNumber:key]) {
                nogui_unbind_key(bridge, other_key);
            }
            if (bridge->inputs != nil && [bridge->inputs[key] isEqual:input]) {
                nogui_unbind_key(bridge, key);
            }
            if (bridge->inputs == nil) {
                bridge->inputs = [NSMutableDictionary dictionary];
                bridge->proxies = [NSMutableDictionary dictionary];
            }
            proxy.native_id = native_id;
            proxy.input = input;
            proxy.owner = bridge->owner;
            if (nogui_input_is_field(input)) {
                UITextField *field = (UITextField *)input;
                proxy.field_delegate = field.delegate;
                field.delegate = proxy;
                /* A field's committed text is observable only through this
                 * event, so the shim becomes a target of its own. It is added
                 * beside whatever the app registered, never in place of it, and
                 * unbind removes exactly this pair. */
                [field addTarget:proxy
                           action:@selector(nogui_editing_changed:)
                 forControlEvents:UIControlEventEditingChanged];
                proxy.editing_changed_target = 1;
            } else {
                UITextView *view = (UITextView *)input;
                proxy.view_delegate = view.delegate;
                view.delegate = proxy;
            }
            /* A control that is in no window can never become first responder,
             * which is what editing and focusing mean. It is put into this
             * bridge's own window so the platform can do that, and taken out
             * again on unbind — from that window, and only while the control is
             * still a direct subview of it, so an app that has since moved the
             * control somewhere of its own keeps it where it put it. */
            UIWindow *window = bridge->window;
            if (window != nil && input.window == nil) {
                [window addSubview:input];
                proxy.added_window = window;
            }
            [bridge->proxies setObject:proxy forKey:key];
            [bridge->inputs setObject:input forKey:key];
            /* A node already published is mirrored now, so the control is
             * correct before any screen reader can reach it. */
            if (bridge->nodes_len != 0) {
                NSNumber *index = [bridge->index_by_id objectForKey:key];
                size_t at = index != nil ? (size_t)index.unsignedLongLongValue : (size_t)-1;
                if (at != (size_t)-1 && at < bridge->nodes_len) {
                    NoGuiFacts *facts = [[NoGuiFacts alloc] init];
                    int32_t string_status = NOGUI_MOBILE_OK;
                    const nogui_mobile_node *node = &bridge->nodes[at];
                    facts.label = nogui_string(node->label, node->label_len, &string_status);
                    facts.hint = nogui_string(node->hint, node->hint_len, &string_status);
                    facts.placeholder = nogui_string(node->placeholder, node->placeholder_len, &string_status);
                    const char *value = node->text;
                    size_t value_len = node->text_len;
                    if (value == NULL || value_len == 0) {
                        value = node->value;
                        value_len = node->value_len;
                    }
                    facts.value = nogui_string(value, value_len, &string_status);
                    if (string_status == NOGUI_MOBILE_OK) {
                        nogui_sync_mirror(bridge, native_id, node, facts);
                    }
                }
            }
        }
        nogui_lock_release();
    }
    @catch (NSException *fault) {
        (void)fault;
        nogui_lock_release();
        return NOGUI_MOBILE_ERR_FAULT;
    }
    if (refused == NOGUI_MOBILE_OK) {
        /* The tree the screen reader is looking at is now out of date: a node
         * that was an announcement is an editable control. The next update
         * replaces the element, this makes the change visible before it. */
        @try {
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
        }
        @catch (NSException *fault) {
            (void)fault;
            return NOGUI_MOBILE_ERR_FAULT;
        }
    }
    return refused;
}

void nogui_ios_a11y_unbind_text_input(nogui_mobile_bridge *bridge)
{
    if (bridge == nil) {
        return;
    }
    if (![NSThread isMainThread]) {
        /* Undoing UIKit work is main-thread work, and this entry point cannot
         * report a wrong thread. The bridge keeps the binding, and the next
         * main-thread entry point that releases the tree puts it back. */
        return;
    }
    @try {
        nogui_lock_acquire();
        nogui_unbind_all(bridge);
        nogui_lock_release();
    }
    @catch (NSException *fault) {
        (void)fault;
        nogui_lock_release();
    }
}

/* One published row, carrying its own sort key so the order needs no context. */
typedef struct nogui_row_order {
    size_t owner;
    uint32_t position;
    size_t dense;
} nogui_row_order;

static int nogui_row_compare(const void *left, const void *right)
{
    const nogui_row_order *a = left;
    const nogui_row_order *b = right;
    if (a->owner != b->owner) {
        return a->owner < b->owner ? -1 : 1;
    }
    if (a->position != b->position) {
        return a->position < b->position ? -1 : 1;
    }
    if (a->dense != b->dense) {
        return a->dense < b->dense ? -1 : 1;
    }
    return 0;
}

/*
 * Turn one update into the published tree. Called with the lock held, on the
 * main thread, and it never calls the host: the build either completes and
 * swaps itself in, or it leaves the previously published tree exactly as it
 * was. `out_published` receives the array the window is about to be given.
 */
static int32_t nogui_ios_a11y_build(nogui_mobile_bridge *bridge,
                                    const nogui_mobile_tree *update,
                                    NSArray **out_published)
{
    const size_t count = update->nodes_len;
    int32_t status = NOGUI_MOBILE_OK;
    size_t root_index = (size_t)-1;
    nogui_mobile_node *copy = NULL;
    NSMutableDictionary<NSNumber *, NSNumber *> *index_by_id = nil;
    NSMutableDictionary<NSNumber *, NoGuiElement *> *elements = nil;
    NSMutableDictionary<NSNumber *, NSArray *> *children = nil;
    NSMutableArray<NoGuiFacts *> *facts = nil;
    nogui_row_order *rows = NULL;
    size_t row_total = 0;
    size_t *edge_offset = NULL;
    size_t *edge_child = NULL;
    size_t *edge_owner = NULL;
    size_t *edge_fill = NULL;
    size_t edge_total = 0;
    uint8_t *colour = NULL;
    uint8_t *owns_rows = NULL;
    uint8_t *emitted = NULL;
    size_t *stack_node = NULL;
    size_t *stack_at = NULL;

    if (count == 0 && (update->root != NOGUI_MOBILE_NO_NODE || update->focus != NOGUI_MOBILE_NO_NODE)) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }

    /* A length with no array behind it is a caller's mistake, and reading it
     * would be a crash rather than a refusal. */
    if (count != 0 && update->nodes == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }

    /* 1. The numeric copy, with every borrowed pointer erased, and the id index
     *    the framework's requests are resolved through. */
    index_by_id = [NSMutableDictionary dictionaryWithCapacity:count];
    if (count != 0) {
        copy = calloc(count, sizeof(*copy));
        if (copy == NULL) {
            status = NOGUI_MOBILE_ERR_MEMORY;
            goto done;
        }
    }
    for (size_t i = 0; i < count; ++i) {
        const nogui_mobile_node *node = &update->nodes[i];
        if (node->native_id == NOGUI_MOBILE_NO_NODE) {
            status = NOGUI_MOBILE_ERR_ARGUMENT;
            goto done;
        }
        if ([index_by_id objectForKey:@(node->native_id)] != nil) {
            status = NOGUI_MOBILE_ERR_ARGUMENT;
            goto done;
        }
        [index_by_id setObject:@(i) forKey:@(node->native_id)];
        if (node->native_id == update->root) {
            root_index = i;
        }
        if ((node->children_len != 0 && node->children == NULL) ||
            (node->custom_actions_len != 0 && node->custom_actions == NULL)) {
            status = NOGUI_MOBILE_ERR_ARGUMENT;
            goto done;
        }
        copy[i] = *node;
        copy[i].label = NULL;
        copy[i].label_len = 0;
        copy[i].value = NULL;
        copy[i].value_len = 0;
        copy[i].hint = NULL;
        copy[i].hint_len = 0;
        copy[i].placeholder = NULL;
        copy[i].placeholder_len = 0;
        copy[i].text = NULL;
        copy[i].text_len = 0;
        copy[i].children = NULL;
        copy[i].children_len = 0;
        copy[i].custom_actions = NULL;
        copy[i].custom_actions_len = 0;
    }
    if (count != 0 && root_index == (size_t)-1) {
        /* A root that names no published node is an argument the caller got
         * wrong, not a tree with no top. */
        status = NOGUI_MOBILE_ERR_ARGUMENT;
        goto done;
    }
    /* `parent` is what the published tree is built from, and its absence is
     * NOGUI_MOBILE_NO_INDEX, so dense index zero is a parent like any other. The
     * root is the one node that has none: a second node without one is a
     * second root, and the header states one root. */
    for (size_t i = 0; i < count; ++i) {
        uint64_t parent = update->nodes[i].parent;
        if (i == root_index) {
            if (parent != NOGUI_MOBILE_NO_INDEX) {
                status = NOGUI_MOBILE_ERR_ARGUMENT;
                goto done;
            }
            continue;
        }
        if (parent == NOGUI_MOBILE_NO_INDEX || parent >= count || parent == i) {
            status = NOGUI_MOBILE_ERR_ARGUMENT;
            goto done;
        }
    }

    /* 2. The published child edges. Membership is `parent`, which is dense and
     *    unambiguous now that absence has a value of its own; order is each
     *    container's own `children` list, so a reorder in the update's array
     *    costs nothing and the order the app declared is the order published. A
     *    container that does not enumerate every child still gets them: the
     *    listed ones in the declared order, then the rows it owns by their
     *    published position, then the rest in update order. A child listed by a
     *    container that is not its parent is refused, because the two fields
     *    then disagree about the tree and only one of them can be published. */
    if (count != 0) {
        rows = calloc(count, sizeof(*rows));
        edge_offset = calloc(count + 1, sizeof(*edge_offset));
        edge_child = calloc(count, sizeof(*edge_child));
        edge_owner = calloc(count, sizeof(*edge_owner));
        edge_fill = calloc(count + 1, sizeof(*edge_fill));
        owns_rows = calloc(count, sizeof(*owns_rows));
        emitted = calloc(count, sizeof(*emitted));
        if (rows == NULL || edge_offset == NULL || edge_child == NULL || edge_owner == NULL ||
            edge_fill == NULL || owns_rows == NULL || emitted == NULL) {
            status = NOGUI_MOBILE_ERR_MEMORY;
            goto done;
        }
        /* The rows a container owns, ordered by the position the app gave. */
        for (size_t i = 0; i < count; ++i) {
            const nogui_mobile_node *node = &update->nodes[i];
            if (node->member_of == NOGUI_MOBILE_NO_INDEX || !node->has_set) {
                continue;
            }
            if (node->member_of >= count || node->member_of == i) {
                status = NOGUI_MOBILE_ERR_ARGUMENT;
                goto done;
            }
            rows[row_total].owner = (size_t)node->member_of;
            rows[row_total].position = node->set_position;
            rows[row_total].dense = i;
            row_total += 1;
        }
        if (row_total > 1) {
            qsort(rows, row_total, sizeof(*rows), nogui_row_compare);
        }
        /* The declared order first, then the owned rows, then whatever neither
         * named. The pairs are collected in that order and bucketed by owner
         * below, which leaves each container's children in the order they were
         * collected. */
        for (size_t p = 0; p < count; ++p) {
            const nogui_mobile_node *node = &update->nodes[p];
            for (size_t k = 0; k < node->children_len; ++k) {
                uint64_t child = node->children[k];
                if (child >= count || child == p || child == root_index) {
                    /* Out of range, a node that is its own child, or the root
                     * claimed as a child: none of them is a tree UIKit can
                     * walk. */
                    status = NOGUI_MOBILE_ERR_ARGUMENT;
                    goto done;
                }
                if (update->nodes[child].parent != p) {
                    status = NOGUI_MOBILE_ERR_ARGUMENT;
                    goto done;
                }
                if (emitted[child] != 0) {
                    /* The same child listed twice under one parent. */
                    status = NOGUI_MOBILE_ERR_ARGUMENT;
                    goto done;
                }
                emitted[child] = 1;
                edge_child[edge_total] = (size_t)child;
                edge_owner[edge_total] = p;
                edge_total += 1;
            }
        }
        for (size_t r = 0; r < row_total; ++r) {
            if (emitted[rows[r].dense] == 0) {
                emitted[rows[r].dense] = 1;
                edge_child[edge_total] = rows[r].dense;
                edge_owner[edge_total] = rows[r].owner;
                edge_total += 1;
            }
        }
        for (size_t i = 0; i < count; ++i) {
            if (i == root_index || emitted[i] != 0) {
                continue;
            }
            emitted[i] = 1;
            edge_child[edge_total] = i;
            edge_owner[edge_total] = (size_t)update->nodes[i].parent;
            edge_total += 1;
        }
        /* Bucket by owner: the offsets become each container's slice, and the
         * order inside a slice is the order the pairs were collected in. */
        for (size_t e = 0; e < edge_total; ++e) {
            edge_offset[edge_owner[e] + 1] += 1;
        }
        for (size_t p = 0; p < count; ++p) {
            edge_offset[p + 1] += edge_offset[p];
        }
        memcpy(edge_fill, edge_offset, (count + 1) * sizeof(*edge_fill));
        size_t *bucketed = calloc(count, sizeof(*bucketed));
        if (bucketed == NULL) {
            status = NOGUI_MOBILE_ERR_MEMORY;
            goto done;
        }
        for (size_t e = 0; e < edge_total; ++e) {
            bucketed[edge_fill[edge_owner[e]]++] = edge_child[e];
        }
        memcpy(edge_child, bucketed, edge_total * sizeof(*edge_child));
        free(bucketed);
        for (size_t r = 0; r < row_total; ++r) {
            owns_rows[rows[r].owner] = 1;
        }
    }

    /* 3. No loop, and nothing left stranded. The parent fields already rule out
     *    a forest, so this pass exists for what they do not: a cycle. UIKit
     *    walks the published edges recursively and would never come back from
     *    one, and a node it cannot reach is a control no screen reader could
     *    ever operate. */
    if (count != 0) {
        colour = calloc(count, sizeof(*colour));
        stack_node = calloc(count, sizeof(*stack_node));
        stack_at = calloc(count, sizeof(*stack_at));
        if (colour == NULL || stack_node == NULL || stack_at == NULL) {
            status = NOGUI_MOBILE_ERR_MEMORY;
            goto done;
        }
        size_t top = 0;
        size_t visited = 1;
        stack_node[0] = root_index;
        stack_at[0] = edge_offset[root_index];
        colour[root_index] = 1;
        while (top != 0) {
            size_t node = stack_node[top - 1];
            size_t at = stack_at[top - 1];
            if (at >= edge_offset[node + 1]) {
                colour[node] = 2;
                top -= 1;
                continue;
            }
            stack_at[top - 1] = at + 1;
            size_t child = edge_child[at];
            if (colour[child] == 1) {
                status = NOGUI_MOBILE_ERR_ARGUMENT;
                goto done;
            }
            if (colour[child] == 0) {
                if (top >= count) {
                    status = NOGUI_MOBILE_ERR_ARGUMENT;
                    goto done;
                }
                colour[child] = 1;
                visited += 1;
                stack_node[top] = child;
                stack_at[top] = edge_offset[child];
                top += 1;
            }
        }
        if (visited != count) {
            status = NOGUI_MOBILE_ERR_ARGUMENT;
            goto done;
        }
    }

    /* 4. Every string, before anything is mutated. */
    facts = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; ++i) {
        const nogui_mobile_node *node = &update->nodes[i];
        int32_t string_status = NOGUI_MOBILE_OK;
        NoGuiFacts *entry = [[NoGuiFacts alloc] init];
        if (entry == nil) {
            status = NOGUI_MOBILE_ERR_MEMORY;
            goto done;
        }
        entry.label = nogui_string(node->label, node->label_len, &string_status);
        /* A text run's own text is the more specific value, so it wins over a
         * control's value string when a node carries both. */
        const char *value = node->text;
        size_t value_len = node->text_len;
        if (value == NULL || value_len == 0) {
            value = node->value;
            value_len = node->value_len;
        }
        entry.value = nogui_string(value, value_len, &string_status);
        entry.hint = nogui_string(node->hint, node->hint_len, &string_status);
        entry.placeholder = nogui_string(node->placeholder, node->placeholder_len, &string_status);
        if (string_status != NOGUI_MOBILE_OK) {
            status = string_status;
            goto done;
        }
        /* The app's own named actions become real `UIAccessibilityCustomAction`
         * objects, one per name, so a screen reader announces the app's wording
         * rather than a generic "activate". A node that published none has an
         * empty list, which is different from a list of unnamed entries. */
        if (node->custom_actions != NULL && node->custom_actions_len != 0) {
            NSMutableArray<NoGuiCustomAction *> *customs =
                [NSMutableArray arrayWithCapacity:node->custom_actions_len];
            for (size_t slot = 0; slot < node->custom_actions_len; ++slot) {
                const nogui_mobile_custom_action *named = &node->custom_actions[slot];
                NSString *name = nogui_string(named->name, named->name_len, &string_status);
                if (string_status != NOGUI_MOBILE_OK) {
                    status = string_status;
                    goto done;
                }
                if (name == nil) {
                    /* A named action with no name has nothing for a screen
                     * reader to announce, and UIKit's own initialiser refuses
                     * it, so it is refused here instead. */
                    status = NOGUI_MOBILE_ERR_ARGUMENT;
                    goto done;
                }
                NoGuiCustomAction *custom = [[NoGuiCustomAction alloc] initWithName:name];
                if (custom == nil) {
                    status = NOGUI_MOBILE_ERR_MEMORY;
                    goto done;
                }
                custom.native_id = node->native_id;
                custom.custom_id = named->id;
                [customs addObject:custom];
            }
            entry.customs = customs;
        }
        [facts addObject:entry];
    }

    /* 5. One element per native id, kept for the bridge's whole life. A node
     *    this update no longer publishes is retired instead, and a binding whose
     *    node is gone is put back, because the mirror had a node to mirror. */
    elements = [NSMutableDictionary dictionaryWithCapacity:count];
    for (size_t i = 0; i < count; ++i) {
        uint64_t native_id = update->nodes[i].native_id;
        NoGuiElement *element = nil;
        if (bridge->elements != nil) {
            element = [bridge->elements objectForKey:@(native_id)];
        }
        if (element == nil || element.owner == nil) {
            element = [[NoGuiElement alloc] initWithAccessibilityContainer:bridge->window];
            if (element == nil) {
                status = NOGUI_MOBILE_ERR_MEMORY;
                goto done;
            }
            element.native_id = native_id;
        }
        [elements setObject:element forKey:@(native_id)];
    }
    if (bridge->elements != nil) {
        for (NSNumber *key in [bridge->elements allKeys]) {
            if ([elements objectForKey:key] == nil) {
                nogui_ios_retire_element(bridge->elements[key]);
            }
        }
    }
    if (bridge->inputs != nil) {
        for (NSNumber *key in [bridge->inputs allKeys]) {
            if ([index_by_id objectForKey:key] == nil) {
                nogui_unbind_key(bridge, key);
            }
        }
    }

    /* 6. The facts, the frames, the mirrors and the child order, all under the
     *    lock. */
    children = [NSMutableDictionary dictionaryWithCapacity:count];
    UIWindow *window = bridge->window;
    for (size_t i = 0; i < count; ++i) {
        uint64_t native_id = update->nodes[i].native_id;
        NoGuiElement *element = [elements objectForKey:@(native_id)];
        NoGuiFacts *entry = [facts objectAtIndex:i];
        /* The screen frame is converted here, once, on the main thread, so the
         * accessibility thread never calls UIKit geometry. The element's
         * container is the window, so the core's bounds are already in the
         * window's own points. */
        CGRect in_window = CGRectMake(copy[i].bounds.x0,
                                      copy[i].bounds.y0,
                                      copy[i].bounds.x1 - copy[i].bounds.x0,
                                      copy[i].bounds.y1 - copy[i].bounds.y0);
        if (bridge->inputs != nil && [bridge->inputs objectForKey:@(native_id)] != nil) {
            /* A node with a real control is answered by that control: it takes
             * the core's text, selection and strings, and the synthetic element
             * beside it stays silent so nothing advertises an edit surface that
             * is not there. */
            nogui_sync_mirror(bridge, native_id, &copy[i], entry);
            continue;
        }
        element.owner = bridge->owner;
        element.label = entry.label;
        element.value_text = entry.value;
        element.hint_text = entry.hint;
        element.placeholder_text = entry.placeholder;
        element.rows = owns_rows[i];
        element.screen_frame = window != nil ? [window convertRect:in_window toView:nil] : in_window;
        for (NoGuiCustomAction *custom in entry.customs) {
            custom.owner = bridge->owner;
        }
        element.custom_actions = entry.customs;
    }
    for (size_t p = 0; p < count; ++p) {
        size_t begin = edge_offset[p];
        size_t end = edge_offset[p + 1];
        if (begin == end) {
            continue;
        }
        /* A list may hold elements, real controls, or both: a node is published
         * as whichever of the two it actually has. */
        NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:end - begin];
        for (size_t at = begin; at < end; ++at) {
            uint64_t native_id = update->nodes[edge_child[at]].native_id;
            UIView *input = bridge->inputs != nil ? [bridge->inputs objectForKey:@(native_id)] : nil;
            [ordered addObject:input != nil ? (id)input : (id)[elements objectForKey:@(native_id)]];
        }
        [children setObject:[ordered copy] forKey:@(update->nodes[p].native_id)];
    }

    /* 7. A container with exactly one child is not a container: UIKit then
     *    treats that child as the screen's own element and stops descending, so
     *    the children are published one level down instead. */
    NSArray *published = nil;
    if (count != 0) {
        UIView *root_input = bridge->inputs != nil ? [bridge->inputs objectForKey:@(update->root)] : nil;
        id root_object = root_input != nil ? (id)root_input : (id)[elements objectForKey:@(update->root)];
        NSArray *root_children = [children objectForKey:@(update->root)];
        published = root_object != nil && root_children.count == 0 ? @[root_object] : (root_children ?: @[]);
    } else {
        published = @[];
    }

    /* 8. Commit. Nothing below this point can fail. */
    free(bridge->nodes);
    bridge->nodes = copy;
    bridge->nodes_len = count;
    bridge->index_by_id = index_by_id;
    bridge->children = children;
    bridge->elements = elements;
    bridge->root = update->root;
    bridge->focus = update->focus;
    bridge->tree_initialized = update->has_tree_init;
    *out_published = published;
    copy = NULL;
    index_by_id = nil;
    children = nil;
    elements = nil;
    status = NOGUI_MOBILE_OK;

done:
    free(copy);
    free(rows);
    free(edge_offset);
    free(edge_child);
    free(edge_owner);
    free(edge_fill);
    free(colour);
    free(owns_rows);
    free(emitted);
    free(stack_node);
    free(stack_at);
    return status;
}

int32_t nogui_ios_a11y_update(nogui_mobile_bridge *bridge, const nogui_mobile_tree *update)
{
    int32_t status = nogui_guard_main();
    if (status != NOGUI_MOBILE_OK) {
        return status;
    }
    if (bridge == nil || update == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    NSArray *published = nil;
    UIWindow *window = nil;
    int32_t reinit = 0;
    id announce = nil;
    nogui_lock_acquire();
    if (bridge->dead) {
        nogui_lock_release();
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    if (bridge->detached || bridge->window == nil) {
        nogui_lock_release();
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    window = bridge->window;
    @try {
        status = nogui_ios_a11y_build(bridge, update, &published);
    }
    @catch (NSException *fault) {
        (void)fault;
        status = NOGUI_MOBILE_ERR_FAULT;
    }
    if (status == NOGUI_MOBILE_OK) {
        reinit = bridge->tree_initialized;
        /* The core moved its focus: the framework's own screen-changed
         * notification with the element as its argument is the documented way
         * to have the screen reader land on it. A node with a real control bound
         * is announced as that control, because the control is what the tree
         * publishes for it. A focus the update names but does not publish
         * announces nothing and stays pending, and a focus on a window the app
         * has not focused is not announced at all — that is what focus
         * reporting means, and the tree itself is untouched. An update with no
         * focus forgets the last one, so a later return to the same node moves
         * the screen reader again instead of looking unchanged. */
        if (bridge->focus == NOGUI_MOBILE_NO_NODE) {
            bridge->announced_focus = NOGUI_MOBILE_NO_NODE;
        } else if (bridge->focus != bridge->announced_focus && bridge->window_focused != 0) {
            UIView *input = bridge->inputs != nil ? [bridge->inputs objectForKey:@(bridge->focus)] : nil;
            if (input != nil) {
                bridge->announced_focus = bridge->focus;
                announce = input;
            } else if (bridge->elements != nil) {
                NoGuiElement *target = [bridge->elements objectForKey:@(bridge->focus)];
                if (target != nil && target.owner != nil) {
                    bridge->announced_focus = bridge->focus;
                    announce = target;
                }
            }
        }
    }
    /* Keep both bridge and callback context alive across framework re-entry. */
    nogui_mobile_dirty_fn on_dirty = bridge->on_dirty;
    void *user = bridge->user;
    if (status == NOGUI_MOBILE_OK) {
        bridge->refs += 1;
    }
    nogui_lock_release();
    if (status != NOGUI_MOBILE_OK) {
        return status;
    }
    /* Published outside the lock: the tree is already complete, and the
     * framework may ask about it the moment the window is given it. */
    @try {
        [window setAccessibilityElements:published];
        if (reinit != 0) {
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
        }
        if (announce != nil) {
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, announce);
        }
        if (on_dirty != NULL) {
            on_dirty(user);
        }
    }
    @catch (NSException *fault) {
        (void)fault;
        return NOGUI_MOBILE_ERR_FAULT;
    }
    @finally {
        nogui_lock_acquire();
        bridge->refs -= 1;
        nogui_lock_release();
    }
    return NOGUI_MOBILE_OK;
}
