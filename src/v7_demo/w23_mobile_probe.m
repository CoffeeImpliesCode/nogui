/*
 * W23 mobile probe — the consumer's OWN UIKit text control.
 *
 * UIKit cannot type into a synthetic accessibility element, so the consumer
 * half of E05 has to hand the bridge a real `UITextField`. This file is that
 * real control: it creates one, parents it into the `UIWindow` SDL already
 * owns, keeps it alive for as long as the binding borrows it, follows the
 * committed layout with its frame, and lets the run read back what UIKit
 * actually holds.
 *
 * WHAT THIS IS NOT
 *
 * This is a CONSUMER FIXTURE, not a second host runtime. It declares no
 * accessibility node, no tree, no request, no bridge and no window policy. It
 * links nothing from `src/v7_host/mobile/shim/nogui_ios.m`; the only bridge
 * call in the whole flow is the one the Zig side already makes, through
 * `mobile.accessibility.Adapter.bindTextInput`. Everything the control does to
 * the model travels that bridge's own action path.
 *
 * THE ONE RULE THIS FILE EXISTS TO KEEP
 *
 * No delegate. No control-event target. No second forwarder. The shim installs
 * its own `NoGuiTextProxy` as `field.delegate` and adds itself as a target for
 * `UIControlEventEditingChanged` when the binding is made, and it restores both
 * when the binding is undone. Anything this file adds alongside those would be
 * a second route for the same edit into one model, which is the one thing the
 * bridge contract forbids. So this file only ever touches geometry, ownership
 * and the control's own presentation.
 *
 * OWNERSHIP
 *
 * `nogui_w23_probe_field` is the single strong reference. The shim holds its
 * own reference only for as long as the binding lasts and drops it at unbind,
 * and it holds the delegate and the control weakly, so this file is what keeps
 * a bound control alive. `nogui_w23_probe_release` is the only thing that gives
 * that reference up, and the Zig side calls it after the unbind and after the
 * detach, while the window still exists.
 *
 * THREADS
 *
 * Every entry point here is UIKit work and refuses to run anywhere but the main
 * thread, naming the wrong thread rather than doing it. On iOS the application
 * main runs on the main thread — SDL's `postFinishLaunch` calls
 * `SDL_CallMainFunction` from the UIKit run loop — so the Zig consumer's own
 * thread is the one this file expects.
 *
 * BUILD
 *
 * Compiled as Objective-C with ARC (`-fobjc-arc`) and blocks (`-fblocks`),
 * linking `UIKit` and `Foundation`. It includes no host header and needs no
 * include path: the ABI below is declared here, once, for the Zig side to
 * mirror.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <math.h>
#include <stddef.h>
#include <stdint.h>

/* Result codes. The same shape and the same meanings as the shim's own wire
 * values (`nogui_mobile.h`), restated rather than included: this file is a
 * consumer of the platform, not of the host, and it must keep compiling on a
 * target where no host shim exists at all. */
enum {
    NOGUI_W23_PROBE_OK = 0,
    /* Not the main thread. */
    NOGUI_W23_PROBE_ERR_THREAD = -1,
    /* A required handle was NULL, or an argument was out of range. */
    NOGUI_W23_PROBE_ERR_ARGUMENT = -2,
    /* This target offers no such control, or one is already owned. */
    NOGUI_W23_PROBE_ERR_UNAVAILABLE = -3,
    /* UIKit raised an exception this fixture caught. */
    NOGUI_W23_PROBE_ERR_FAULT = -5,
    /* An allocation failed inside UIKit. */
    NOGUI_W23_PROBE_ERR_MEMORY = -6
};

/* The one control this fixture owns. Strong: it must outlive the binding that
 * borrows it, and the shim gives its own reference back at unbind. */
static UITextField *nogui_w23_probe_field = nil;

static int32_t nogui_w23_probe_guard(void **out_input)
{
    if (out_input != NULL) {
        *out_input = NULL;
    }
    if (![NSThread isMainThread]) {
        return NOGUI_W23_PROBE_ERR_THREAD;
    }
    return NOGUI_W23_PROBE_OK;
}

/* Is this the control this fixture created? A release of anything else would be
 * a release of a pointer the caller never owned here. */
static int32_t nogui_w23_probe_check(void *input)
{
    if (![NSThread isMainThread]) {
        return NOGUI_W23_PROBE_ERR_THREAD;
    }
    if (input == NULL || input != (__bridge void *)nogui_w23_probe_field) {
        return NOGUI_W23_PROBE_ERR_ARGUMENT;
    }
    return NOGUI_W23_PROBE_OK;
}

/* 1 on a build that actually carries this fixture, 0 on one that does not, so
 * the Zig side can tell "no control was made" from "there is no probe here". */
int32_t nogui_w23_probe_available(void)
{
    return 1;
}

/*
 * Create the real control inside the window SDL owns, at `rect`.
 *
 * `ui_window` is the `UIWindow *` the host publishes as
 * `SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER` — the same window the bridge was
 * attached to, not a window invented here. Parenting the control there is what
 * lets it become first responder at all: a control in no window is a control
 * the platform can neither focus nor edit.
 *
 * `rect` is the committed text rectangle in window-logical units, which on UIKit
 * are the window's own points, so no scale is applied anywhere in this file.
 *
 * On success `*out_input` receives the control, which the caller borrows for
 * `bindTextInput` and must return here before the window is destroyed.
 */
int32_t nogui_w23_probe_create(void *ui_window, double x, double y, double w, double h, void **out_input)
{
    int32_t status = nogui_w23_probe_guard(out_input);
    if (status != NOGUI_W23_PROBE_OK) {
        return status;
    }
    if (ui_window == NULL || out_input == NULL) {
        return NOGUI_W23_PROBE_ERR_ARGUMENT;
    }
    /* An empty rectangle is not a control a user could ever reach, so it is
     * refused rather than made invisible. */
    if (!(w > 0.0) || !(h > 0.0) || !isfinite(x) || !isfinite(y) || !isfinite(w) || !isfinite(h)) {
        return NOGUI_W23_PROBE_ERR_ARGUMENT;
    }
    UIWindow *window = (__bridge UIWindow *)ui_window;
    if (![window isKindOfClass:[UIWindow class]]) {
        return NOGUI_W23_PROBE_ERR_ARGUMENT;
    }
    /* One control, one binding: a second create without a release would leave
     * a live control behind with no path back to it. */
    if (nogui_w23_probe_field != nil) {
        return NOGUI_W23_PROBE_ERR_UNAVAILABLE;
    }
    UITextField *field = nil;
    @try {
        field = [[UITextField alloc] initWithFrame:CGRectMake(x, y, w, h)];
        if (field == nil) {
            return NOGUI_W23_PROBE_ERR_MEMORY;
        }
        /* No delegate and no target: the shim installs its own forwarding proxy
         * when the binding is made, and a second editor is what the bridge
         * contract forbids. */
        field.delegate = nil;
        /* The app paints this rectangle itself every frame, through noapi. A
         * control that drew an opaque box over it would hide the frame the run
         * is reporting, so the field contributes the caret and the composition
         * and leaves the pixels to the application. */
        field.backgroundColor = [UIColor clearColor];
        field.borderStyle = UITextBorderStyleNone;
        /* The published run is what the bridge reads back, and a UIKit-side
         * autocorrection or capitalisation rule would make the control's text
         * differ from the model's without the model ever being told. */
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.smartQuotesType = UITextSmartQuotesTypeNo;
        field.smartDashesType = UITextSmartDashesTypeNo;
        field.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
        field.spellCheckingType = UITextSpellCheckingTypeNo;
        field.clearButtonMode = UITextFieldViewModeNever;
        [window addSubview:field];
    }
    @catch (NSException *fault) {
        (void) fault;
        field = nil;
        return NOGUI_W23_PROBE_ERR_FAULT;
    }
    if (field.window == nil) {
        /* UIKit refused to parent it, which would leave a control nothing can
         * focus. */
        return NOGUI_W23_PROBE_ERR_UNAVAILABLE;
    }
    nogui_w23_probe_field = field;
    *out_input = (__bridge void *)field;
    return NOGUI_W23_PROBE_OK;
}

/* Follow the committed rectangle. Called on every safe-area, keyboard and
 * orientation move, so the control the platform edits is always over the box
 * the core actually laid out. */
int32_t nogui_w23_probe_frame(void *input, double x, double y, double w, double h)
{
    int32_t status = nogui_w23_probe_check(input);
    if (status != NOGUI_W23_PROBE_OK) {
        return status;
    }
    if (!(w > 0.0) || !(h > 0.0) || !isfinite(x) || !isfinite(y) || !isfinite(w) || !isfinite(h)) {
        return NOGUI_W23_PROBE_ERR_ARGUMENT;
    }
    @try {
        nogui_w23_probe_field.frame = CGRectMake(x, y, w, h);
    }
    @catch (NSException *fault) {
        (void) fault;
        return NOGUI_W23_PROBE_ERR_FAULT;
    }
    return NOGUI_W23_PROBE_OK;
}

/* What UIKit's own geometry says this control is right now. The run compares it
 * with the rectangle it asked for, so "aligned" is a reading and not a claim. */
int32_t nogui_w23_probe_read_frame(void *input, double *out_x, double *out_y, double *out_w, double *out_h)
{
    int32_t status = nogui_w23_probe_check(input);
    if (status != NOGUI_W23_PROBE_OK) {
        return status;
    }
    if (out_x == NULL || out_y == NULL || out_w == NULL || out_h == NULL) {
        return NOGUI_W23_PROBE_ERR_ARGUMENT;
    }
    CGRect box = nogui_w23_probe_field.frame;
    *out_x = box.origin.x;
    *out_y = box.origin.y;
    *out_w = box.size.width;
    *out_h = box.size.height;
    return NOGUI_W23_PROBE_OK;
}

/* The control's native selection, in UTF-16 units — UIKit's own unit, and the
 * one the model's UTF-16 selection is compared against. */
int32_t nogui_w23_probe_read_selection(void *input, int64_t *out_start, int64_t *out_end)
{
    int32_t status = nogui_w23_probe_check(input);
    if (status != NOGUI_W23_PROBE_OK) {
        return status;
    }
    if (out_start == NULL || out_end == NULL) {
        return NOGUI_W23_PROBE_ERR_ARGUMENT;
    }
    *out_start = 0;
    *out_end = 0;
    id<UITextRange> range = nogui_w23_probe_field.selectedTextRange;
    if (range == nil) {
        return NOGUI_W23_PROBE_OK;
    }
    NSInteger start = [nogui_w23_probe_field offsetFromPosition:nogui_w23_probe_field.beginningOfDocument
                                                       toPosition:range.start];
    NSInteger end = [nogui_w23_probe_field offsetFromPosition:nogui_w23_probe_field.beginningOfDocument
                                                     toPosition:range.end];
    if (start < 0 || end < 0) {
        return NOGUI_W23_PROBE_ERR_FAULT;
    }
    *out_start = (int64_t) start;
    *out_end = (int64_t) end;
    return NOGUI_W23_PROBE_OK;
}

/*
 * Does the control hold exactly these bytes?
 *
 * The model's value is UTF-8 and the control's is NSString, so this is where
 * the two representations are actually compared rather than assumed equal. 1 is
 * equal, 0 is not; anything negative is a refusal, and a refusal is never read
 * as agreement.
 */
int32_t nogui_w23_probe_text_equals(void *input, const char *utf8, size_t len)
{
    int32_t status = nogui_w23_probe_check(input);
    if (status != NOGUI_W23_PROBE_OK) {
        return status;
    }
    if (len != 0 && utf8 == NULL) {
        return NOGUI_W23_PROBE_ERR_ARGUMENT;
    }
    NSString *want = [[NSString alloc] initWithBytes:len == 0 ? (const void *) "" : (const void *) utf8
                                              length:len
                                            encoding:NSUTF8StringEncoding];
    if (want == nil) {
        /* Bytes that are not UTF-8 cannot be compared to an NSString, and
         * calling that a mismatch would blame the control for the model's
         * own encoding. */
        return NOGUI_W23_PROBE_ERR_ARGUMENT;
    }
    return [nogui_w23_probe_field.text isEqualToString:want] ? 1 : 0;
}

/*
 * Give the control up: stop being first responder, leave the window, drop the
 * one strong reference.
 *
 * The caller must already have unbound the bridge, because the shim restores
 * the delegate and removes its target by touching this control. Doing it in the
 * other order would leave a live proxy on a freed view.
 */
int32_t nogui_w23_probe_release(void *input)
{
    int32_t status = nogui_w23_probe_check(input);
    if (status != NOGUI_W23_PROBE_OK) {
        return status;
    }
    UITextField *field = nogui_w23_probe_field;
    /* Cleared first: from here on this fixture owns nothing, so a re-entrant
     * release cannot free the same control twice. */
    nogui_w23_probe_field = nil;
    @try {
        if (field.isFirstResponder) {
            [field resignFirstResponder];
        }
        [field removeFromSuperview];
    }
    @catch (NSException *fault) {
        (void) fault;
        /* The strong reference is already gone, which is the part that must
         * not be skipped; UIKit raising here cannot bring it back. */
        return NOGUI_W23_PROBE_ERR_FAULT;
    }
    return NOGUI_W23_PROBE_OK;
}