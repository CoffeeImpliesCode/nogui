/*
 * nogui macOS shim: the only translation unit in the project that speaks
 * Objective-C.
 *
 * Why Objective-C at all: AppKit, Security, UserNotifications and CoreVideo
 * are Objective-C frameworks. Writing the adapter in Objective-C keeps the
 * ABI in `nogui_macos.h` the honest one, and every call below is written
 * exactly as the SDK declares it instead of through a translated
 * approximation of a translated approximation.
 *
 * Built by `zig cc` as Objective-C with ARC. Every entry point is wrapped so
 * an Objective-C exception becomes a NOGUI_MACOS_ERR_FAULT code instead of
 * unwinding through a Zig frame, and every AppKit entry point checks the
 * thread first, because AppKit's own contract is a single main thread and a
 * violation there is undefined behaviour rather than a refusal.
 */
/*
 * ARC is load-bearing, not a preference. Every object this file builds is a
 * strong local or a strong property, and it is released when that scope or
 * that owner ends — which is what releases a controller and the part of a menu
 * it had already built when `nogui_macos_menu_new` refuses a model. The few
 * objects that cross the ABI as opaque handles are handed over with
 * `__bridge_retained` and taken back with CFRelease, so a caller owns exactly
 * one release either way. A build without ARC would leak all of that in
 * silence rather than fail loudly, so the build fails here instead.
 */
#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "nogui_macos.m is built with -fobjc-arc: every object's ownership here depends on it"
#endif
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreVideo/CoreVideo.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <Security/Security.h>
#import <UserNotifications/UserNotifications.h>

#include "nogui_macos.h"

#include <string.h>

/* ── shared helpers ──────────────────────────────────────────────────────── */

static BOOL nogui_on_main_thread(void)
{
    return [NSThread isMainThread];
}

/* Copy a NUL-terminated UTF-8 argument into an NSString. NULL is not an
 * error by itself: it is how a caller asks for "no string", and the calling
 * function decides whether that is acceptable. */
static NSString *nogui_string(const char *utf8)
{
    if (utf8 == NULL) {
        return nil;
    }
    return [NSString stringWithUTF8String:utf8];
}

/* Report a bounded string into a caller's buffer. Always NUL terminates and
 * always reports the full length the caller needs, so a retry with a large
 * enough buffer always succeeds. */
static int32_t nogui_report(const char *bytes, size_t len, char *buffer, size_t capacity, size_t *out_len)
{
    if (out_len != NULL) {
        *out_len = len;
    }
    if (buffer == NULL || capacity == 0) {
        return NOGUI_MACOS_ERR_BUFFER;
    }
    if (len + 1 > capacity) {
        buffer[0] = '\0';
        return NOGUI_MACOS_ERR_BUFFER;
    }
    if (len > 0) {
        memcpy(buffer, bytes, len);
    }
    buffer[len] = '\0';
    return NOGUI_MACOS_OK;
}

static int32_t nogui_report_ns(NSString *text, char *buffer, size_t capacity, size_t *out_len)
{
    if (text == nil) {
        return nogui_report("", 0, buffer, capacity, out_len);
    }
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8 == nil) {
        return NOGUI_MACOS_ERR_ENCODING;
    }
    return nogui_report((const char *)utf8.bytes, (size_t)utf8.length, buffer, capacity, out_len);
}

static NSWindow *nogui_window(void *handle)
{
    return (__bridge NSWindow *)handle;
}

/* Defined with the find-pasteboard section, declared here because the
 * unified string reader reaches it from above. */
static NSPasteboard *nogui_find_pasteboard(void);

/* ── windows: tabs ───────────────────────────────────────────────────────── */

int32_t nogui_macos_tab_group(void *window, nogui_macos_tabs *out)
{
    if (window == NULL || out == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    memset(out, 0, sizeof(*out));
    @try {
        NSArray<NSWindow *> *tabs = [nogui_window(window) tabbedWindows];
        if (tabs == nil) {
            /* Not tabbed is a real answer, not a failure: the caller asked
             * about a window that shows no tab bar. */
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        out->count = (uint32_t)tabs.count;
        if (out->count > NOGUI_MACOS_MAX_TABS) {
            out->truncated = 1;
            out->count = NOGUI_MACOS_MAX_TABS;
        }
        for (uint32_t index = 0; index < out->count; index++) {
            out->windows[index] = (__bridge void *)tabs[index];
        }
        NSWindow *key = [NSApp keyWindow];
        NSWindow *main = [NSApp mainWindow];
        NSWindow *selected = key != nil ? key : main;
        if (selected != nil) {
            for (NSUInteger index = 0; index < tabs.count; index++) {
                if (tabs[index] == selected) {
                    out->selected = (__bridge void *)selected;
                    break;
                }
            }
        }
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_tab_merge(void *host, void *guest, int32_t above, void **out_parent)
{
    if (host == NULL || guest == NULL || out_parent == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSWindowOrderingMode order = above != 0 ? NSWindowAbove : NSWindowBelow;
        [nogui_window(host) addTabbedWindow:nogui_window(guest) ordered:order];
        /* AppKit chooses which window ends up hosting the tab bar, so the
         * caller reads the group back rather than being told a guess. */
        NSArray<NSWindow *> *tabs = [nogui_window(host) tabbedWindows];
        *out_parent = (__bridge void *)(tabs.firstObject ?: nogui_window(host));
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        /* AppKit throws when the two windows disagree about the grouping
         * identifier. That is a refusal and it is the caller's to resolve, so
         * it is reported as one rather than as a fault of this shim. */
        (void)exception;
        return NOGUI_MACOS_ERR_REFUSED;
    }
}

int32_t nogui_macos_tab_merge_all(void *window)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        [nogui_window(window) mergeAllWindows:nil];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

/* `selectNextTab:` and `selectPreviousTab:` are declared to take a sender,
 * so they are invoked through NSInvocation rather than called with a cast
 * sender they do not have. */
static int32_t nogui_tab_action(void *window, SEL selector)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        if ([nogui_window(window) tabbedWindows].count < 2) {
            /* One tab has neither a previous nor a next tab. The caller is
             * told so instead of being handed an unchanged group. */
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        NSMethodSignature *signature = [NSWindow instanceMethodSignatureForSelector:selector];
        if (signature == nil) {
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = nogui_window(window);
        invocation.selector = selector;
        id sender = nil;
        [invocation setArgument:&sender atIndex:2];
        [invocation invoke];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_tab_select_next(void *window)
{
    return nogui_tab_action(window, @selector(selectNextTab:));
}

int32_t nogui_macos_tab_select_previous(void *window)
{
    return nogui_tab_action(window, @selector(selectPreviousTab:));
}

int32_t nogui_macos_tab_detach(void *window)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSWindow *target = nogui_window(window);
        if ([target tabbedWindows] == nil) {
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        NSWindow *key = [NSApp keyWindow];
        NSWindow *main = [NSApp mainWindow];
        NSWindow *selected = key != nil ? key : main;
        if (selected != target) {
            /* `moveTabToNewWindow:` acts on the selected tab only, and no
             * public API selects an arbitrary tab. Refusing here is what
             * keeps a detach request from detaching the wrong window. */
            return NOGUI_MACOS_ERR_REFUSED;
        }
        [target moveTabToNewWindow:nil];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_tab_set_mode(void *window, int32_t mode)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    if (mode < 0 || mode > 2) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    @try {
        NSWindowTabbingMode value = NSWindowTabbingModeAutomatic;
        if (mode == 1) {
            value = NSWindowTabbingModePreferred;
        } else if (mode == 2) {
            value = NSWindowTabbingModeDisallowed;
        }
        [nogui_window(window) setTabbingMode:value];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_tab_mode(void *window)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        return (int32_t)[nogui_window(window) tabbingMode];
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_tab_set_identifier(void *window, const char *identifier)
{
    if (window == NULL || identifier == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSString *value = nogui_string(identifier);
        if (value == nil) {
            return NOGUI_MACOS_ERR_ENCODING;
        }
        [nogui_window(window) setTabbingIdentifier:value];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_tab_allows_automatic(int32_t enabled)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        [NSWindow setAllowsAutomaticWindowTabbing:enabled != 0];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_tab_user_preference(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        if (![NSWindow respondsToSelector:@selector(userTabbingPreference)]) {
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        return (int32_t)[NSWindow userTabbingPreference];
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

/* ── windows: titlebar, document ─────────────────────────────────────────── */

int32_t nogui_macos_window_title_visibility(void *window, int32_t visibility)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    if (visibility < -1 || visibility > 1) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    @try {
        NSWindow *target = nogui_window(window);
        if (visibility >= 0) {
            [target setTitleVisibility:visibility == 0 ? NSWindowTitleVisible : NSWindowTitleHidden];
        }
        return [target titleVisibility] == NSWindowTitleVisible ? 0 : 1;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_window_titlebar_transparent(void *window, int32_t transparent)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSWindow *target = nogui_window(window);
        if (transparent >= 0) {
            [target setTitlebarAppearsTransparent:transparent != 0];
        }
        return [target titlebarAppearsTransparent] ? 1 : 0;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_window_set_title(void *window, const char *utf8)
{
    if (window == NULL || utf8 == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSString *value = nogui_string(utf8);
        if (value == nil) {
            return NOGUI_MACOS_ERR_ENCODING;
        }
        [nogui_window(window) setTitle:value];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_window_titlebar_separator(void *window, int32_t style)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        if (style < 0 || style > 3) {
            return NOGUI_MACOS_ERR_ARGUMENT;
        }
        if (@available(macOS 11.0, *)) {
            NSWindow *target = nogui_window(window);
            /* A window without a title bar has no separator to draw, which is
             * a refusal the caller can act on rather than a change that did
             * nothing. */
            if (([target styleMask] & NSWindowStyleMaskTitled) == 0) {
                return NOGUI_MACOS_ERR_UNAVAILABLE;
            }
            NSTitlebarSeparatorStyle value = NSTitlebarSeparatorStyleAutomatic;
            if (style == 1) {
                value = NSTitlebarSeparatorStyleNone;
            } else if (style == 2) {
                value = NSTitlebarSeparatorStyleLine;
            } else if (style == 3) {
                value = NSTitlebarSeparatorStyleShadow;
            }
            [target setTitlebarSeparatorStyle:value];
            return (int32_t)[target titlebarSeparatorStyle];
        }
        /* The colour property this entry point used to name is not in the
         * public headers of a system older than macOS 11. */
        return NOGUI_MACOS_ERR_UNAVAILABLE;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_window_button_visible(void *window, int32_t kind, int32_t visible)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    if (kind < 0 || kind > 3) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    @try {
        NSWindow *target = nogui_window(window);
        NSWindowButton type = NSWindowCloseButton;
        if (kind == 1) {
            type = NSWindowMiniaturizeButton;
        } else if (kind == 2) {
            type = NSWindowZoomButton;
        } else if (kind == 3) {
            type = NSWindowFullScreenButton;
        }
        NSButton *button = [target standardWindowButton:type];
        if (button == nil) {
            /* The style mask has no such button, so there is none to show. */
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        if (visible >= 0) {
            [button setHidden:visible == 0];
        }
        return [button isHidden] ? 0 : 1;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_window_document_edited(void *window, int32_t edited)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSWindow *target = nogui_window(window);
        if (edited >= 0) {
            [target setDocumentEdited:edited != 0];
        }
        return [target isDocumentEdited] ? 1 : 0;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_window_set_represented_path(void *window, const char *path)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSWindow *target = nogui_window(window);
        if (path == NULL) {
            [target setRepresentedURL:nil];
            return NOGUI_MACOS_OK;
        }
        NSString *value = nogui_string(path);
        if (value == nil) {
            return NOGUI_MACOS_ERR_ENCODING;
        }
        [target setRepresentedURL:[NSURL fileURLWithPath:value]];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}


int32_t nogui_macos_window_is_key(void *window)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    return [nogui_window(window) isKeyWindow] ? 1 : 0;
}

int32_t nogui_macos_window_is_main(void *window)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    return [nogui_window(window) isMainWindow] ? 1 : 0;
}

int32_t nogui_macos_window_make_key_and_order_front(void *window)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        [nogui_window(window) makeKeyAndOrderFront:nil];
        return [nogui_window(window) isVisible] ? 1 : 0;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_window_order_out(void *window)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        [nogui_window(window) orderOut:nil];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

void *nogui_macos_window_content_view(void *window)
{
    if (window == NULL || !nogui_on_main_thread()) {
        return NULL;
    }
    @try {
        return (__bridge_retained void *)[nogui_window(window) contentView];
    } @catch (NSException *exception) {
        (void)exception;
        return NULL;
    }
}

void nogui_macos_content_view_release(void *view)
{
    if (view == NULL || !nogui_on_main_thread()) {
        return;
    }
    /* The retain came from `__bridge_retained`, so this is the matching
     * release and not a second one: the view itself is still owned by its
     * window. */
    CFRelease(view);
}

int32_t nogui_macos_read_string(
    int32_t source,
    int32_t index,
    void *handle,
    char *buffer,
    size_t capacity,
    size_t *out_len
)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    if (out_len != NULL) {
        *out_len = 0;
    }
    @try {
        switch (source) {
        case NOGUI_MACOS_STRING_WINDOW_TITLE: {
            if (handle == NULL) {
                return NOGUI_MACOS_ERR_ARGUMENT;
            }
            return nogui_report_ns([nogui_window(handle) title], buffer, capacity, out_len);
        }
        case NOGUI_MACOS_STRING_WINDOW_REPRESENTED_PATH: {
            if (handle == NULL) {
                return NOGUI_MACOS_ERR_ARGUMENT;
            }
            return nogui_report_ns([nogui_window(handle) representedURL].path, buffer, capacity, out_len);
        }
        case NOGUI_MACOS_STRING_SERVICES_LABEL: {
            NSMenu *menu = [NSApp servicesMenu];
            if (menu == nil || index < 0 || index >= (int32_t)menu.numberOfItems) {
                return NOGUI_MACOS_ERR_ARGUMENT;
            }
            return nogui_report_ns([menu itemAtIndex:index].title, buffer, capacity, out_len);
        }
        case NOGUI_MACOS_STRING_RECENT_LIST: {
            NSArray<NSURL *> *urls = [NSDocumentController sharedDocumentController].recentDocumentURLs;
            NSMutableString *joined = [[NSMutableString alloc] init];
            for (NSURL *url in urls) {
                if (joined.length > 0) {
                    [joined appendString:@"\n"];
                }
                [joined appendString:[url path]];
            }
            return nogui_report_ns(joined, buffer, capacity, out_len);
        }
        case NOGUI_MACOS_STRING_FIND_TEXT: {
            NSPasteboard *board = nogui_find_pasteboard();
            if (board == nil) {
                return NOGUI_MACOS_ERR_UNAVAILABLE;
            }
            return nogui_report_ns([board stringForType:NSPasteboardTypeString], buffer, capacity, out_len);
        }
        case NOGUI_MACOS_STRING_FIND_OPTIONS: {
            NSPasteboard *board = nogui_find_pasteboard();
            if (board == nil) {
                return NOGUI_MACOS_ERR_UNAVAILABLE;
            }
            id plist = [board propertyListForType:NSPasteboardTypeTextFinderOptions];
            if (plist == nil) {
                return nogui_report("", 0, buffer, capacity, out_len);
            }
            NSData *xml = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                      format:NSPropertyListXMLFormat_v1_0
                                                                     options:0
                                                                       error:NULL];
            if (xml == nil) {
                return NOGUI_MACOS_ERR_ENCODING;
            }
            return nogui_report((const char *)xml.bytes, (size_t)xml.length, buffer, capacity, out_len);
        }
        case NOGUI_MACOS_STRING_BUNDLE_ID: {
            NSString *identifier = [NSBundle mainBundle].bundleIdentifier;
            if (identifier == nil) {
                /* An unbundled executable has no identifier, and
                 * UserNotifications and the recent-documents menu both refuse
                 * to work without one. An empty string keeps that visible. */
                return nogui_report("", 0, buffer, capacity, out_len);
            }
            return nogui_report_ns(identifier, buffer, capacity, out_len);
        }
        default:
            return NOGUI_MACOS_ERR_ARGUMENT;
        }
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

double nogui_macos_window_backing_scale(void *window)
{
    if (window == NULL || !nogui_on_main_thread()) {
        return 0.0;
    }
    @try {
        NSWindow *target = nogui_window(window);
        NSRect on_screen = [target convertRectToScreen:[target frame]];
        for (NSScreen *screen in [NSScreen screens]) {
            if (NSIntersectsRect([screen frame], on_screen)) {
                return (double)[screen backingScaleFactor];
            }
        }
        return (double)[target backingScaleFactor];
    } @catch (NSException *exception) {
        (void)exception;
        return 0.0;
    }
}

int32_t nogui_macos_window_class_name(void *window, char *buffer, size_t capacity, size_t *out_len)
{
    if (window == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        /* The runtime's own answer, which names the class the receiver really
         * is. `[NSWindow class]` would name the base class instead, and a
         * forwarder added there would reach every window rather than the
         * subclass this one is. */
        const char *name = object_getClassName((__bridge id)nogui_window(window));
        if (name == NULL) {
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        return nogui_report(name, strlen(name), buffer, capacity, out_len);
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

/* ── application and its delegate ────────────────────────────────────────── */

@class NoguiMenuController;

/* The delegate this shim installs. Every selector it does not implement is
 * forwarded to the delegate already registered, so SDL keeps its own
 * application behaviour while the host observes reopen and activation. */
@interface NoguiAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, weak) id previous;
@property(nonatomic, strong) NSMenu *(^dockMenuProvider)(void);
@property(nonatomic, assign) nogui_macos_app_events events;
@end

@implementation NoguiAppDelegate

- (BOOL)respondsToSelector:(SEL)selector
{
    if ([super respondsToSelector:selector]) {
        return YES;
    }
    id previous = self.previous;
    return previous != nil && [previous respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector
{
    id previous = self.previous;
    if (previous != nil && ![super respondsToSelector:selector] &&
        [previous respondsToSelector:selector]) {
        return previous;
    }
    return [super forwardingTargetForSelector:selector];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag
{
    nogui_macos_app_events events = self.events;
    if (events.on_reopen != NULL) {
        events.on_reopen(events.user, flag ? 1 : 0);
    }
    id previous = self.previous;
    if (previous != nil && [previous respondsToSelector:_cmd]) {
        return [previous applicationShouldHandleReopen:sender hasVisibleWindows:flag];
    }
    return flag;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    nogui_macos_app_events events = self.events;
    if (events.on_become_active != NULL) {
        events.on_become_active(events.user);
    }
    id previous = self.previous;
    if (previous != nil && [previous respondsToSelector:_cmd]) {
        [previous applicationDidBecomeActive:notification];
    }
}

- (void)applicationDidResignActive:(NSNotification *)notification
{
    nogui_macos_app_events events = self.events;
    if (events.on_resign_active != NULL) {
        events.on_resign_active(events.user);
    }
    id previous = self.previous;
    if (previous != nil && [previous respondsToSelector:_cmd]) {
        [previous applicationDidResignActive:notification];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    nogui_macos_app_events events = self.events;
    if (events.on_will_terminate != NULL) {
        events.on_will_terminate(events.user);
    }
    id previous = self.previous;
    if (previous != nil && [previous respondsToSelector:_cmd]) {
        [previous applicationWillTerminate:notification];
    }
}

- (NSMenu *)applicationDockMenu:(NSApplication *)sender
{
    (void)sender;
    NSMenu *(^provider)(void) = self.dockMenuProvider;
    return provider != nil ? provider() : nil;
}

@end

void *nogui_macos_app_events_install(const nogui_macos_app_events *events)
{
    if (events == NULL || !nogui_on_main_thread()) {
        return NULL;
    }
    @try {
        NoguiAppDelegate *delegate = [[NoguiAppDelegate alloc] init];
        delegate.previous = [NSApp delegate];
        delegate.events = *events;
        [NSApp setDelegate:delegate];
        return (__bridge_retained void *)delegate;
    } @catch (NSException *exception) {
        (void)exception;
        return NULL;
    }
}

void nogui_macos_app_events_remove(void *handle)
{
    if (handle == NULL || !nogui_on_main_thread()) {
        return;
    }
    @try {
        NoguiAppDelegate *delegate = (__bridge NoguiAppDelegate *)handle;
        if ([NSApp delegate] == delegate) {
            [NSApp setDelegate:delegate.previous];
        }
        delegate.events = (nogui_macos_app_events){0};
        delegate.dockMenuProvider = nil;
        CFRelease(handle);
    } @catch (NSException *exception) {
        (void)exception;
    }
}

int32_t nogui_macos_app_activate(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        if (@available(macOS 14.0, *)) {
            [NSApp activate];
        } else {
            [NSApp activateIgnoringOtherApps:YES];
        }
        return [NSApp isActive] ? 1 : 0;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_app_hide(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        [NSApp hide:nil];
        return [NSApp isHidden] ? 1 : 0;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_app_unhide(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        [NSApp unhide:nil];
        return [NSApp isHidden] ? 0 : 1;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_app_hide_others(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        [NSApp hideOtherApps:nil];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_app_show_all(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        [NSApp unhideAllApplications];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_app_reopen(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        [NSApp reopen:nil];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_app_is_active(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    return [NSApp isActive] ? 1 : 0;
}

int32_t nogui_macos_app_is_hidden(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    return [NSApp isHidden] ? 1 : 0;
}

int32_t nogui_macos_app_set_activation_policy(int32_t policy)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    if (policy < 0 || policy > 2) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    @try {
        NSApplicationActivationPolicy value = NSApplicationActivationPolicyRegular;
        if (policy == 1) {
            value = NSApplicationActivationPolicyAccessory;
        } else if (policy == 2) {
            value = NSApplicationActivationPolicyProhibited;
        }
        return [NSApp setActivationPolicy:value] ? 1 : 0;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_app_activation_policy(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        return (int32_t)[NSApp activationPolicy];
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_app_dock_badge(const char *utf8)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        if (utf8 == NULL) {
            [[NSApp dockTile] setBadgeLabel:nil];
            return NOGUI_MACOS_OK;
        }
        NSString *value = nogui_string(utf8);
        if (value == nil) {
            return NOGUI_MACOS_ERR_ENCODING;
        }
        [[NSApp dockTile] setBadgeLabel:value];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}


@class NoguiMenuController;
/* Defined with the menu builder below and declared here because the
 * controller reaches them from its own methods. */
static NSArray<NSNumber *> *nogui_system_actions(const nogui_macos_menu_model *model);
static NSMenu *nogui_build_menu(
    NoguiMenuController *controller,
    const nogui_macos_menu_model *model,
    int32_t parent,
    int32_t *status,
    NSArray<NSNumber *> *system_actions,
    size_t *visited
);

/* ── accessibility ───────────────────────────────────────────────────────── */

int32_t nogui_macos_accessibility_is_trusted(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    /* A read. It contacts nothing and prompts nothing, so a host may poll it
     * from its own frame to report whether VoiceOver can see the app. */
    return AXIsProcessTrusted() ? 1 : 0;
}

int32_t nogui_macos_accessibility_request_trust(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSDictionary *options = @{
            (__bridge id)kAXTrustedCheckOptionPrompt : @YES,
        };
        /* A request to a person: this shows the system prompt, so the host
         * calls it only in answer to an action. macOS answers the prompt
         * asynchronously, so the outcome of the request is read back with
         * `nogui_macos_accessibility_is_trusted` rather than returned here. */
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
            /* The prompt is already on screen, or the process is refused.
             * Both are the same fact for a caller that has to ask again. */
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

/* ── menus ───────────────────────────────────────────────────────────────── */

@interface NoguiMenuController : NSObject
@property(nonatomic, strong) NSMenu *mainMenu;
@property(nonatomic, assign) nogui_macos_menu_model dockModel;
@property(nonatomic, copy) NSArray<NSNumber *> *mainSystemActions;
@property(nonatomic, copy) NSArray<NSNumber *> *dockSystemActions;
@property(nonatomic, assign) nogui_macos_menu_callbacks callbacks;
@end

@implementation NoguiMenuController

- (void)menuItemChosen:(NSMenuItem *)sender
{
    nogui_macos_menu_callbacks callbacks = self.callbacks;
    if (callbacks.on_item == NULL) {
        return;
    }
    /* The node's system action rides along on the item, so a click in the
     * Dock menu and a click in the menu bar are reported the same way. */
    int32_t system_action = -1;
    if ([sender.representedObject isKindOfClass:[NSNumber class]]) {
        system_action = (int32_t)[(NSNumber *)sender.representedObject intValue];
    }
    callbacks.on_item(callbacks.user, (int32_t)sender.tag, system_action);
}

- (void)recentDocumentChosen:(NSMenuItem *)sender
{
    nogui_macos_menu_callbacks callbacks = self.callbacks;
    if (callbacks.on_recent == NULL) {
        return;
    }
    callbacks.on_recent(callbacks.user, (int32_t)sender.tag);
}

- (NSMenu *)buildDockMenu
{
    if (self.dockModel.nodes == NULL || self.dockModel.nodes_len == 0) {
        return nil;
    }
    self.dockSystemActions = nogui_system_actions(&self.dockModel);
    size_t visited = 0;
    int32_t status = NOGUI_MACOS_OK;
    NSMenu *menu =
        nogui_build_menu(self, &self.dockModel, -1, &status, self.dockSystemActions, &visited);
    if (status != NOGUI_MACOS_OK) {
        return nil;
    }
    if (visited != self.dockModel.nodes_len) {
        /* A node whose parent names no menu would be dropped in silence, so
         * the Dock menu is refused instead of showing less than it was given. */
        return nil;
    }
    return menu;
}

@end

static NSArray<NSNumber *> *nogui_system_actions(const nogui_macos_menu_model *model)
{
    NSMutableArray<NSNumber *> *actions = [[NSMutableArray alloc] initWithCapacity:model->nodes_len];
    for (size_t index = 0; index < model->nodes_len; index++) {
        [actions addObject:@(model->nodes[index].system_action)];
    }
    return actions;
}

/* Parse "cmd+shift+n" into a key equivalent and its modifier mask. A
 * shortcut this grammar cannot name is refused, so a menu bar is never
 * installed with a silently dropped key equivalent. */
static BOOL nogui_parse_shortcut(const char *text, NSString **key, NSEventModifierFlags *mask)
{
    if (text == NULL || key == NULL || mask == NULL) {
        return NO;
    }
    NSString *raw = nogui_string(text);
    if (raw == nil) {
        return NO;
    }
    NSEventModifierFlags flags = 0;
    NSString *last = nil;
    for (NSString *part in [raw componentsSeparatedByString:@"+"]) {
        NSString *token = [part lowercaseString];
        if ([token isEqualToString:@"cmd"] || [token isEqualToString:@"command"]) {
            flags |= NSEventModifierFlagCommand;
        } else if ([token isEqualToString:@"shift"]) {
            flags |= NSEventModifierFlagShift;
        } else if ([token isEqualToString:@"opt"] || [token isEqualToString:@"alt"] ||
                   [token isEqualToString:@"option"]) {
            flags |= NSEventModifierFlagOption;
        } else if ([token isEqualToString:@"ctrl"] || [token isEqualToString:@"control"]) {
            flags |= NSEventModifierFlagControl;
        } else if ([token isEqualToString:@"fn"]) {
            flags |= NSEventModifierFlagFunction;
        } else {
            if (last != nil) {
                return NO;
            }
            last = token;
        }
    }
    if (last == nil) {
        return NO;
    }
    NSDictionary<NSString *, NSString *> *named = @{
        @"return" : @"\r",
        @"enter" : @"\r",
        @"space" : @" ",
        @"tab" : @"\t",
        @"backspace" : @"\b",
        @"escape" : @"\x1b",
        @"delete" : @"\x7f",
    };
    NSString *resolved = named[last];
    if (resolved != nil) {
        *key = resolved;
        *mask = flags;
        return YES;
    }
    if (last.length == 1) {
        *key = last;
        *mask = flags;
        return YES;
    }
    return NO;
}

static NSMenu *nogui_build_recent_menu(NoguiMenuController *controller)
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
    menu.autoenablesItems = NO;
    NSDocumentController *documents = [NSDocumentController sharedDocumentController];
    if (documents == nil) {
        return menu;
    }
    NSArray<NSURL *> *urls = documents.recentDocumentURLs;
    for (NSUInteger index = 0; index < urls.count; index++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[urls[index] lastPathComponent]
                                                      action:@selector(recentDocumentChosen:)
                                               keyEquivalent:@""];
        item.target = controller;
        item.tag = (NSInteger)index;
        item.enabled = YES;
        item.toolTip = [urls[index] path];
        [menu addItem:item];
    }
    return menu;
}

/* Build the NSMenu for one level of a flattened model, recursing into the
 * submenu of every node that owns children.
 *
 * A node's `parent` is the index of the menu that owns it, or -1 for the menu
 * bar itself. Every level becomes one NSMenu, so the top-level call returns
 * the bar and each nested call returns the items of one menu title. A node
 * whose `parent` names no menu is never reached, which is why the builder
 * counts what it visited and the caller checks the count.
 *
 * `*status` is the reason the menu could not be built, or OK. A build that
 * fails returns nil and never a partly built menu, so AppKit is never left
 * pointing at half a model. */
static NSMenu *nogui_build_menu(
    NoguiMenuController *controller,
    const nogui_macos_menu_model *model,
    int32_t parent,
    int32_t *status,
    NSArray<NSNumber *> *system_actions,
    size_t *visited
)
{
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    for (size_t index = 0; index < model->nodes_len; index++) {
        const nogui_macos_menu_node *node = &model->nodes[index];
        if (node->parent != parent) {
            continue;
        }
        *visited += 1;
        if (node->kind == 0) {
            NSString *label = nogui_string(node->label);
            if (label == nil) {
                *status = NOGUI_MACOS_ERR_ENCODING;
                return nil;
            }
            /* The children of this node are the next level, so the builder
             * recurses here rather than pairing items with a remembered
             * "last menu", which is what left every submenu empty. */
            NSMenu *submenu =
                nogui_build_menu(controller, model, (int32_t)index, status, system_actions, visited);
            if (submenu == nil) {
                return nil;
            }
            NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:label
                                                            action:NULL
                                                     keyEquivalent:@""];
            header.submenu = submenu;
            [menu addItem:header];
            continue;
        }
        if (node->kind == 2) {
            [menu addItem:[NSMenuItem separatorItem]];
            continue;
        }
        if (node->kind == 3) {
            NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:@"Open Recent"
                                                            action:NULL
                                                     keyEquivalent:@""];
            header.submenu = nogui_build_recent_menu(controller);
            [menu addItem:header];
            continue;
        }
        NSString *label = nogui_string(node->label);
        if (label == nil) {
            *status = NOGUI_MACOS_ERR_ENCODING;
            return nil;
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label
                                                      action:@selector(menuItemChosen:)
                                               keyEquivalent:@""];
        if (node->action_index < 0) {
            /* A clickable row with no routing tag would report a tag that names
             * no row, so the table is refused here instead of installed as a
             * menu whose clicks cannot be resolved. */
            *status = NOGUI_MACOS_ERR_ARGUMENT;
            return nil;
        }
        item.target = controller;
        /* The tag is the node's own routing value, not its position in this
         * table: the host packs the menu the row belongs to and the row inside
         * that menu into one integer, so a click in the Dock menu and a click
         * in the menu bar cannot name each other's rows. */
        item.tag = (NSInteger)node->action_index;
        item.enabled = node->enabled < 0 ? YES : (node->enabled != 0);
        item.state = node->checked != 0 ? NSControlStateValueOn : NSControlStateValueOff;
        int32_t system_action = -1;
        if (index < (size_t)system_actions.count) {
            system_action = system_actions[index].intValue;
        }
        item.representedObject = @(system_action);
        if (node->shortcut != NULL) {
            NSString *key = nil;
            NSEventModifierFlags mask = 0;
            if (!nogui_parse_shortcut(node->shortcut, &key, &mask)) {
                *status = NOGUI_MACOS_ERR_ARGUMENT;
                return nil;
            }
            item.keyEquivalent = key;
            item.keyEquivalentModifierMask = mask;
        }
        [menu addItem:item];
    }
    return menu;
}

void *nogui_macos_menu_new(
    const nogui_macos_menu_model *model,
    const nogui_macos_menu_callbacks *callbacks,
    void *user,
    int32_t *status
)
{
    if (status == NULL) {
        return NULL;
    }
    if (model == NULL || callbacks == NULL) {
        *status = NOGUI_MACOS_ERR_ARGUMENT;
        return NULL;
    }
    if (!nogui_on_main_thread()) {
        *status = NOGUI_MACOS_ERR_THREAD;
        return NULL;
    }
    @try {
        /* The controller belongs to THIS FRAME until the retained hand-out at
         * the end. `init` takes one reference, ARC gives it back when the local
         * goes out of scope, and that is the whole ownership story until the
         * `__bridge_retained` below hands a second one to the caller. */
        NoguiMenuController *controller = [[NoguiMenuController alloc] init];
        controller.callbacks = *callbacks;
        controller.callbacks.user = user;
        controller.mainSystemActions = nogui_system_actions(model);
        int32_t built = NOGUI_MACOS_OK;
        size_t visited = 0;
        NSMenu *bar =
            nogui_build_menu(controller, model, -1, &built, controller.mainSystemActions, &visited);
        if (bar == nil) {
            *status = built;
        } else if (visited != model->nodes_len) {
            /* A node whose parent names no menu is never reached, so the bar
             * would quietly show less than the model holds. Refusing is the
             * only honest answer for a model the caller got wrong. */
            *status = NOGUI_MACOS_ERR_ARGUMENT;
        } else {
            controller.mainMenu = bar;
            *status = NOGUI_MACOS_OK;
            /* The one hand-out, on the one path that succeeds. Everything that
             * reaches the caller is owned by the caller from here, and only
             * from here. */
            return (__bridge_retained void *)controller;
        }
        /* ONE refusal exit, and the frame's own release on it. The nil store is
         * the single release of the reference `init` just took, stated here
         * rather than left to the end of the scope because this is the one case
         * the caller cannot undo: a NULL answer carries no handle, so a
         * controller that outlived this call would have nothing left to be
         * released with. `bar` — whole or partial — goes with it, as does the
         * callback table, which never left the controller. */
        controller = nil;
        return NULL;
    } @catch (NSException *exception) {
        (void)exception;
        *status = NOGUI_MACOS_ERR_FAULT;
        return NULL;
    }
}

int32_t nogui_macos_menu_install(void *handle)
{
    if (handle == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NoguiMenuController *controller = (__bridge NoguiMenuController *)handle;
        if (controller.mainMenu == nil) {
            return NOGUI_MACOS_ERR_ARGUMENT;
        }
        [NSApp setMainMenu:controller.mainMenu];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

/* Releases a model the shim copied itself: the node table and every string in
 * it. A model the CALLER owns is never passed here. */
static void nogui_menu_model_free(nogui_macos_menu_model *model)
{
    if (model->nodes == NULL) {
        return;
    }
    for (size_t index = 0; index < model->nodes_len; index++) {
        free((void *)model->nodes[index].label);
        free((void *)model->nodes[index].shortcut);
    }
    free((void *)model->nodes);
    *model = (nogui_macos_menu_model){0};
}

int32_t nogui_macos_dock_menu_set(void *handle, const nogui_macos_menu_model *model)
{
    if (handle == NULL || model == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NoguiMenuController *controller = (__bridge NoguiMenuController *)handle;
        /* The replacement is copied in full BEFORE the model the controller
         * holds is released. A Dock menu can be set as often as a host likes,
         * so overwriting dockModel without releasing it leaks a node table and
         * every label and shortcut in it, without bound; releasing first
         * instead would leave the controller with no menu at all whenever the
         * copy or the build below refuses the new model. */
        nogui_macos_menu_model next = (nogui_macos_menu_model){0};
        if (model->nodes_len != 0) {
            size_t bytes = model->nodes_len * sizeof(nogui_macos_menu_node);
            nogui_macos_menu_node *copy = malloc(bytes);
            if (copy == NULL) {
                return NOGUI_MACOS_ERR_MEMORY;
            }
            /* The node table and every string in it are copied, because the
             * Dock menu is rebuilt on demand long after this call returns and
             * the caller's storage may already be gone. A shortcut is a
             * string like a label, so it is copied the same way. */
            for (size_t index = 0; index < model->nodes_len; index++) {
                copy[index] = model->nodes[index];
                /* The caller's pointers are dropped before anything can fail,
                 * so every entry in the table holds either a string this shim
                 * allocated or NULL and never a pointer into the caller's own
                 * storage. That is what makes releasing a PARTIAL copy safe:
                 * without this the entry being copied still names the caller's
                 * arena, and free() on that is a free() of memory this shim
                 * never allocated. */
                const char *label = copy[index].label;
                const char *shortcut = copy[index].shortcut;
                copy[index].label = NULL;
                copy[index].shortcut = NULL;
                if (label != NULL) {
                    size_t length = strlen(label) + 1;
                    char *owned = malloc(length);
                    if (owned == NULL) {
                        nogui_menu_model_free(&(nogui_macos_menu_model){copy, index + 1});
                        return NOGUI_MACOS_ERR_MEMORY;
                    }
                    memcpy(owned, label, length);
                    copy[index].label = owned;
                }
                if (shortcut != NULL) {
                    size_t length = strlen(shortcut) + 1;
                    char *owned = malloc(length);
                    if (owned == NULL) {
                        nogui_menu_model_free(&(nogui_macos_menu_model){copy, index + 1});
                        return NOGUI_MACOS_ERR_MEMORY;
                    }
                    memcpy(owned, shortcut, length);
                    copy[index].shortcut = owned;
                }
            }
            next = (nogui_macos_menu_model){copy, model->nodes_len};
        }
        /* Everything below works on the LOCAL copy. The model the
         * controller holds is neither read nor released until the build has
         * proved the copy sound, so a model this call refuses leaves the
         * Dock menu the controller already had in place, and that menu stays
         * usable at the next Dock click. */
        int installed = 0;
        @try {
            /* The model is built once here so a malformed one is reported at
             * the call that caused it rather than at the next Dock click,
             * when the person would just see nothing. */
            NSArray<NSNumber *> *next_actions = nogui_system_actions(&next);
            int32_t built = NOGUI_MACOS_OK;
            size_t visited = 0;
            NSMenu *built_menu =
                nogui_build_menu(controller, &next, -1, &built, next_actions, &visited);
            if (built_menu == nil) {
                return built;
            }
            if (visited != next.nodes_len) {
                return NOGUI_MACOS_ERR_ARGUMENT;
            }
            /* The copy is good, so it takes the place of the model the
             * controller held. That model is released here and nowhere else,
             * exactly once, and never before its replacement is known good. */
            nogui_menu_model_free(&controller->dockModel);
            controller->dockModel = next;
            installed = 1;
            controller.dockSystemActions = next_actions;
            id delegate = [NSApp delegate];
            if ([delegate isKindOfClass:[NoguiAppDelegate class]]) {
                NoguiAppDelegate *app_delegate = (NoguiAppDelegate *)delegate;
                app_delegate.dockMenuProvider = ^NSMenu *(void) {
                    return [controller buildDockMenu];
                };
            }
            return NOGUI_MACOS_OK;
        } @finally {
            /* A refusal above returns, and a raise unwinds, while the copy is
             * still owned here rather than by the controller. */
            if (!installed) {
                nogui_menu_model_free(&next);
            }
        }
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

/* Release the controller, and with it every menu it installed, the node table
 * the Dock menu holds and the callback table both menus report into.
 *
 * Main thread only, like every AppKit call in here. A `void` entry point has
 * no code to report a refusal with, so off that thread this does nothing, and
 * the caller's obligation follows directly from that: nothing was detached, so
 * a record the callbacks name must not be released on the strength of having
 * called this. The caller checks the thread before it calls, because releasing
 * that record is what this call exists to make safe. */
void nogui_macos_menu_free(void *handle)
{
    if (handle == NULL || !nogui_on_main_thread()) {
        return;
    }
    @try {
        NoguiMenuController *controller = (__bridge NoguiMenuController *)handle;
        if (controller.mainMenu != nil && [NSApp mainMenu] == controller.mainMenu) {
            [NSApp setMainMenu:nil];
        }
        id delegate = [NSApp delegate];
        if ([delegate isKindOfClass:[NoguiAppDelegate class]]) {
            ((NoguiAppDelegate *)delegate).dockMenuProvider = nil;
        }
        nogui_menu_model_free(&controller->dockModel);
        controller.callbacks = (nogui_macos_menu_callbacks){0};
        controller.mainMenu = nil;
        CFRelease(handle);
    } @catch (NSException *exception) {
        (void)exception;
    }
}

int32_t nogui_macos_recent_add(const char *path)
{
    if (path == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSString *value = nogui_string(path);
        if (value == nil) {
            return NOGUI_MACOS_ERR_ENCODING;
        }
        NSDocumentController *controller = [NSDocumentController sharedDocumentController];
        if (controller == nil) {
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        [controller noteNewRecentDocumentURL:[NSURL fileURLWithPath:value]];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_recent_clear(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSDocumentController *controller = [NSDocumentController sharedDocumentController];
        if (controller == nil) {
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        [controller clearRecentDocuments:nil];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}


/* ── services and the character palette ──────────────────────────────────── */

/* The one view that receives both an incoming service and a palette
 * insertion. Both arrive through the window's first responder, so they share
 * an object instead of two views fighting over that role. The view is kept
 * zero-sized so it draws nothing: the host paints its own text. */
@interface NoguiResponderView : NSTextView
@property(nonatomic, assign) nogui_macos_services_callbacks services;
@property(nonatomic, assign) nogui_macos_text_callbacks text;
@end

@implementation NoguiResponderView

- (BOOL)performService:(NSPasteboard *)pboard
             sendTypes:(NSArray<NSPasteboardType> *)sendTypes
           returnTypes:(NSArray<NSPasteboardType> *)returnTypes
{
    nogui_macos_services_callbacks callbacks = self.services;
    if (callbacks.on_perform == NULL) {
        return NO;
    }
    NSString *text = [pboard stringForType:NSPasteboardTypeString];
    NSString *send = sendTypes.firstObject;
    NSString *returned = returnTypes.firstObject;
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    const char *reply = callbacks.on_perform(
        callbacks.user,
        send.UTF8String,
        returned.UTF8String,
        utf8.bytes,
        utf8.length);
    if (reply == NULL) {
        return NO;
    }
    /* The service's answer goes back through the same pasteboard, which is
     * how a macOS service returns data to the app that sent it. */
    [pboard clearContents];
    [pboard setString:[NSString stringWithUTF8String:reply] forType:NSPasteboardTypeString];
    return YES;
}

- (BOOL)validateServiceMenuItem:(NSMenuItem *)item
{
    nogui_macos_services_callbacks callbacks = self.services;
    if (callbacks.on_validate == NULL) {
        return NO;
    }
    return callbacks.on_validate(callbacks.user, item.title.UTF8String) != 0;
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard
                              types:(NSArray<NSPasteboardType> *)types
{
    /* The outbound half of a service: another app asked this one to send,
     * and the host's own selection is what goes. */
    nogui_macos_services_callbacks callbacks = self.services;
    if (callbacks.on_write == NULL) {
        return NO;
    }
    const char *selection = callbacks.on_write(callbacks.user);
    if (selection == NULL) {
        return NO;
    }
    NSString *text = [NSString stringWithUTF8String:selection];
    if (text == nil) {
        return NO;
    }
    [pboard clearContents];
    if (![pboard setString:text forType:NSPasteboardTypeString]) {
        return NO;
    }
    for (NSPasteboardType type in types) {
        if (![type isEqualToString:NSPasteboardTypeString] && ![pboard setString:text forType:type]) {
            /* A service that promised another type and could not produce it
             * has not been written, so the send is refused rather than
             * half-completed. */
            [pboard clearContents];
            return NO;
        }
    }
    return YES;
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    nogui_macos_text_callbacks callbacks = self.text;
    if (callbacks.on_insert == NULL) {
        return;
    }
    NSString *inserted = nil;
    if ([string isKindOfClass:[NSString class]]) {
        inserted = (NSString *)string;
    } else if ([string respondsToSelector:@selector(string)]) {
        inserted = [string string];
    }
    if (inserted == nil) {
        return;
    }
    NSData *utf8 = [inserted dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8 == nil) {
        return;
    }
    /* The mirror is not edited here. The host owns the text, recomputes the
     * result, and writes it back through `nogui_macos_text_mirror`, so the
     * NSTextView never becomes a second copy of the document. */
    callbacks.on_insert(
        callbacks.user,
        (const char *)utf8.bytes,
        (size_t)utf8.length,
        (uint64_t)replacementRange.location,
        (uint64_t)replacementRange.length);
}

@end

void *nogui_macos_responder_new(
    void *window,
    const nogui_macos_services_callbacks *services,
    const nogui_macos_text_callbacks *text
)
{
    if (window == NULL) {
        return NULL;
    }
    if (!nogui_on_main_thread()) {
        return NULL;
    }
    @try {
        NSView *content = [nogui_window(window) contentView];
        if (content == nil) {
            return NULL;
        }
        NSRect frame = NSZeroRect;
        NoguiResponderView *view = [[NoguiResponderView alloc] initWithFrame:frame];
        view.services = *services;
        view.text = *text;
        [content addSubview:view positioned:NSWindowAbove relativeTo:nil];
        return (__bridge_retained void *)view;
    } @catch (NSException *exception) {
        (void)exception;
        return NULL;
    }
}

void nogui_macos_responder_free(void *responder)
{
    if (responder == NULL || !nogui_on_main_thread()) {
        return;
    }
    @try {
        NoguiResponderView *view = (__bridge NoguiResponderView *)responder;
        [view removeFromSuperview];
        view.services = (nogui_macos_services_callbacks){0};
        view.text = (nogui_macos_text_callbacks){0};
        CFRelease(responder);
    } @catch (NSException *exception) {
        (void)exception;
    }
}

int32_t nogui_macos_services_register(
    void *responder,
    const char *const *send_types,
    size_t send_types_len,
    const char *const *return_types,
    size_t return_types_len
)
{
    if (responder == NULL || send_types == NULL || return_types == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSMutableArray<NSPasteboardType> *sends = [[NSMutableArray alloc] init];
        for (size_t index = 0; index < send_types_len; index++) {
            NSString *value = nogui_string(send_types[index]);
            if (value == nil) {
                return NOGUI_MACOS_ERR_ENCODING;
            }
            [sends addObject:value];
        }
        NSMutableArray<NSPasteboardType> *returns = [[NSMutableArray alloc] init];
        for (size_t index = 0; index < return_types_len; index++) {
            NSString *value = nogui_string(return_types[index]);
            if (value == nil) {
                return NOGUI_MACOS_ERR_ENCODING;
            }
            [returns addObject:value];
        }
        NSResponder *target = (__bridge NSResponder *)responder;
        [NSApp setServicesProvider:target];
        [NSApp registerServicesMenuSendTypes:sends returnTypes:returns];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_services_menu_count(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSMenu *menu = [NSApp servicesMenu];
        return menu == nil ? 0 : (int32_t)menu.numberOfItems;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}


int32_t nogui_macos_services_invoke(int32_t index)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSMenu *menu = [NSApp servicesMenu];
        if (menu == nil || index < 0 || index >= (int32_t)menu.numberOfItems) {
            return NOGUI_MACOS_ERR_ARGUMENT;
        }
        NSMenuItem *item = [menu itemAtIndex:index];
        if (item.action == NULL) {
            /* The system listed something this process cannot invoke, which
             * is a refusal rather than a silent no-op. */
            return NOGUI_MACOS_ERR_REFUSED;
        }
        return [NSApp sendAction:item.action to:item.target from:item] ? 1 : 0;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_text_mirror(
    void *responder,
    const char *utf8,
    size_t len,
    uint64_t selection_location,
    uint64_t selection_length
)
{
    if (responder == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NoguiResponderView *view = (__bridge NoguiResponderView *)responder;
        NSString *text = (utf8 == NULL || len == 0)
            ? @""
            : [[NSString alloc] initWithBytes:utf8 length:len encoding:NSUTF8StringEncoding];
        if (text == nil) {
            return NOGUI_MACOS_ERR_ENCODING;
        }
        [view setString:text];
        /* AppKit addresses an NSTextView in UTF-16 code units, so the host's
         * byte offsets are converted here and nowhere else. */
        NSUInteger unit_length = [text lengthOfBytesUsingEncoding:NSUTF16StringEncoding] / 2;
        NSUInteger location = (NSUInteger)selection_location;
        NSUInteger length = (NSUInteger)selection_length;
        if (location > unit_length) {
            location = unit_length;
        }
        if (length > unit_length - location) {
            length = unit_length - location;
        }
        [view setSelectedRange:NSMakeRange(location, length)];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_text_make_first_responder(void *responder)
{
    if (responder == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSResponder *view = (__bridge NSResponder *)responder;
        NSWindow *window = view.window;
        if (window == nil) {
            /* The view is not in a window yet, so nothing can become first
             * responder. Reporting that beats claiming a focus it does not
             * have. */
            return NOGUI_MACOS_ERR_REFUSED;
        }
        return [window makeFirstResponder:view] ? 1 : 0;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_text_open_character_palette(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        [NSApp orderFrontCharacterPalette:nil];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

/* ── the find pasteboard ─────────────────────────────────────────────────── */

static NSPasteboard *nogui_find_pasteboard(void)
{
    return [NSPasteboard pasteboardWithName:NSPasteboardNameFind];
}

int32_t nogui_macos_find_pasteboard_content(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSPasteboard *board = nogui_find_pasteboard();
        if (board == nil) {
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        NSArray<NSPasteboardType> *types = [board types];
        if (types.count == 0) {
            return 0;
        }
        if (types.count == 1 && [types[0] isEqualToString:NSPasteboardTypeString]) {
            return 1;
        }
        return 2;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_find_pasteboard_write(const char *utf8, size_t len)
{
    if (utf8 == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    if (len > NOGUI_MACOS_MAX_TEXT) {
        return NOGUI_MACOS_ERR_BUFFER;
    }
    @try {
        NSPasteboard *board = nogui_find_pasteboard();
        if (board == nil) {
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        NSString *text = [[NSString alloc] initWithBytes:utf8 length:len encoding:NSUTF8StringEncoding];
        if (text == nil) {
            return NOGUI_MACOS_ERR_ENCODING;
        }
        [board clearContents];
        return [board setString:text forType:NSPasteboardTypeString] ? NOGUI_MACOS_OK : NOGUI_MACOS_ERR_REFUSED;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}


int32_t nogui_macos_find_pasteboard_clear(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSPasteboard *board = nogui_find_pasteboard();
        if (board == nil) {
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        [board clearContents];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}


int32_t nogui_macos_find_options_write(const char *plist)
{
    if (plist == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSPasteboard *board = nogui_find_pasteboard();
        if (board == nil) {
            return NOGUI_MACOS_ERR_UNAVAILABLE;
        }
        NSData *xml = [NSData dataWithBytes:plist length:strlen(plist)];
        id parsed = [NSPropertyListSerialization propertyListWithData:xml
                                                               options:NSPropertyListImmutable
                                                                format:NULL
                                                                 error:NULL];
        if (parsed == nil) {
            /* The finder is given a property list, so text that is not one
             * is refused instead of being dropped on the pasteboard. */
            return NOGUI_MACOS_ERR_ENCODING;
        }
        [board clearContents];
        return [board setPropertyList:parsed forType:NSPasteboardTypeTextFinderOptions]
            ? NOGUI_MACOS_OK
            : NOGUI_MACOS_ERR_REFUSED;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

/* ── keychain ────────────────────────────────────────────────────────────── */

/* The Security status of the most recent call, so the host can separate a
 * locked store from a dismissed prompt from a denied item without matching
 * raw OSStatus values of its own. */
static OSStatus nogui_keychain_status = errSecSuccess;

int32_t nogui_macos_keychain_last_status(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    return (int32_t)nogui_keychain_status;
}

static NSDictionary *nogui_keychain_query(NSString *service, NSString *account, NSString *group)
{
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge id)kSecAttrService] = service;
    query[(__bridge id)kSecAttrAccount] = account;
    query[(__bridge id)kSecUseDataProtectionKeychain] = @YES;
    if (group != nil) {
        /* The data-protection keychain has no named collections, so a query's
         * collection names the access group instead. An app without the
         * matching entitlement gets errSecMissingEntitlement, which the host
         * reports as a denial rather than quietly using the default group. */
        query[(__bridge id)kSecAttrAccessGroup] = group;
    }
    return query;
}

int32_t nogui_macos_keychain_read(
    const char *service,
    const char *account,
    const char *access_group,
    char *secret,
    size_t capacity,
    size_t *out_len
)
{
    if (service == NULL || account == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    if (out_len != NULL) {
        *out_len = 0;
    }
    @try {
        NSMutableDictionary *query = [nogui_keychain_query(nogui_string(service),
                                                          nogui_string(account),
                                                          access_group == NULL ? nil : nogui_string(access_group))
                                         mutableCopy];
        query[(__bridge id)kSecReturnData] = @YES;
        query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        CFTypeRef found = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &found);
        nogui_keychain_status = status;
        if (status != errSecSuccess) {
            if (found != NULL) {
                CFRelease(found);
            }
            return nogui_status_code(status);
        }
        NSData *data = (__bridge_transfer NSData *)found;
        if (data == nil) {
            return NOGUI_MACOS_ERR_FAULT;
        }
        if (capacity == 0 || data.length + 1 > capacity) {
            if (out_len != NULL) {
                *out_len = (size_t)data.length;
            }
            if (secret != NULL && capacity > 0) {
                secret[0] = '\0';
            }
            return NOGUI_MACOS_ERR_BUFFER;
        }
        memcpy(secret, data.bytes, (size_t)data.length);
        secret[data.length] = '\0';
        if (out_len != NULL) {
            *out_len = (size_t)data.length;
        }
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        nogui_keychain_status = errSecInternalError;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_keychain_write(
    const char *service,
    const char *account,
    const char *access_group,
    const char *secret,
    size_t secret_len
)
{
    if (service == NULL || account == NULL || secret == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSString *service_name = nogui_string(service);
        NSString *account_name = nogui_string(account);
        NSString *group = access_group == NULL ? nil : nogui_string(access_group);
        NSMutableDictionary *query = [nogui_keychain_query(service_name, account_name, group) mutableCopy];
        NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
        attributes[(__bridge id)kSecValueData] = [NSData dataWithBytes:secret length:secret_len];

        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                        (__bridge CFDictionaryRef)attributes);
        if (status == errSecItemNotFound) {
            /* A first write is an add. Doing it this way means a caller does
             * not have to know whether the item already exists. */
            [query removeObjectForKey:(__bridge id)kSecReturnData];
            [query removeObjectForKey:(__bridge id)kSecMatchLimit];
            [query addEntriesFromDictionary:attributes];
            status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
        }
        nogui_keychain_status = status;
        return nogui_status_code(status);
    } @catch (NSException *exception) {
        (void)exception;
        nogui_keychain_status = errSecInternalError;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_keychain_delete(const char *service, const char *account, const char *access_group)
{
    if (service == NULL || account == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSDictionary *query = nogui_keychain_query(nogui_string(service),
                                                  nogui_string(account),
                                                  access_group == NULL ? nil : nogui_string(access_group));
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
        nogui_keychain_status = status;
        return nogui_status_code(status);
    } @catch (NSException *exception) {
        (void)exception;
        nogui_keychain_status = errSecInternalError;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

/* ── user notifications ──────────────────────────────────────────────────── */

/* Hand a native answer to Zig on the main queue, and read the callback table
 * there and nowhere else.
 *
 * The framework picks the queue an authorization request, a settings query, an
 * add-request and a delegate response are answered on, and those are private
 * queues of its own. Only the main thread may free the centre, and the free
 * clears the callback table, so a handler that read the table where the
 * framework answered raced that clear: a struct read torn across two writes, or
 * a call into a user pointer the caller had already released.
 *
 * Every answer is marshalled here first, which makes the table single threaded
 * and orders every handler against the free: a handler can only run before the
 * free or after it, never during it, and after the free every entry in the
 * table is NULL, so it calls nothing.
 *
 * `dispatch_async` never waits on the queue it targets, so a framework
 * callback that already answered on the main thread hops once instead of
 * deadlocking against itself. */
static void nogui_marshal_to_main(dispatch_block_t work)
{
    dispatch_async(dispatch_get_main_queue(), work);
}

@interface NoguiNotificationCentre : NSObject <UNUserNotificationCenterDelegate>
{
    /* The answer is cached where the framework gave it, on a queue it owns,
     * while the host reads this from the main thread, so the cell is atomic.
     * The callback table below cannot be: only the main queue writes it, and
     * only the main queue reads it. */
    @public atomic_int authorization;
}
/* Read and written on the main queue alone, so the table needs no lock. */
@property(nonatomic, assign) nogui_macos_notification_callbacks callbacks;
/* The categories this process has registered. The centre's own set is
 * REPLACED by every `setNotificationCategories:`, so a second category
 * registered naively would delete the first and its notifications would show
 * no buttons. The set is accumulated here and submitted whole. */
@property(nonatomic, strong) NSMutableSet<UNNotificationCategory *> *categories;
@end

@implementation NoguiNotificationCentre

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    /* A foreground app that never presented a banner would look broken, so a
     * notification is shown with sound rather than dropped. */
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound |
                      UNNotificationPresentationOptionList);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler
{
    /* The response, the delegate and the handler are captured by the block, so
     * ARC keeps all three alive until the main queue runs it. The table is read
     * inside the block: read here it would cross the hop still holding a user
     * pointer the free may already have retired. */
    nogui_marshal_to_main(^{
        @autoreleasepool {
            nogui_macos_notification_callbacks callbacks = self.callbacks;
            if (callbacks.on_response != NULL) {
                callbacks.on_response(
                    callbacks.user,
                    response.notification.request.identifier.UTF8String,
                    response.actionIdentifier.UTF8String);
            }
            /* The system waits for this handler, so it is called on every path
             * out of the block, including the retired table above. */
            completionHandler();
        }
    });
}

@end

void *nogui_macos_notifications_new(const nogui_macos_notification_callbacks *callbacks, void *user)
{
    if (callbacks == NULL) {
        return NULL;
    }
    if (!nogui_on_main_thread()) {
        return NULL;
    }
    @try {
        if ([NSBundle mainBundle].bundleIdentifier == nil) {
            /* UserNotifications refuses to work in a process with no bundle
             * identifier, which is every unbundled executable. Reporting that
             * here keeps the refusal where the caller can see it. */
            return NULL;
        }
        NoguiNotificationCentre *centre = [[NoguiNotificationCentre alloc] init];
        /* No answer has arrived yet, which is not the same as a denial. */
        atomic_store(&centre->authorization, -1);
        centre.callbacks = *callbacks;
        centre.callbacks.user = user;
        [UNUserNotificationCenter currentNotificationCenter].delegate = centre;
        return (__bridge_retained void *)centre;
    } @catch (NSException *exception) {
        (void)exception;
        return NULL;
    }
}

void nogui_macos_notifications_free(void *handle)
{
    if (handle == NULL || !nogui_on_main_thread()) {
        return;
    }
    @try {
        NoguiNotificationCentre *centre = (__bridge NoguiNotificationCentre *)handle;
        if ([UNUserNotificationCenter currentNotificationCenter].delegate == centre) {
            [UNUserNotificationCenter currentNotificationCenter].delegate = nil;
        }
        /* Retiring the table is what this free is for. Every handler that
         * reaches Zig is a main-queue block and this free runs on that same
         * thread, so a handler is never running while this runs, and one that
         * runs after it finds every entry NULL. The CFRelease below drops the
         * retain from `new`, and a block still holding the centre keeps the
         * object alive until it runs, so no block reads a centre that is gone. */
        centre.callbacks = (nogui_macos_notification_callbacks){0};
        CFRelease(handle);
    } @catch (NSException *exception) {
        (void)exception;
    }
}

int32_t nogui_macos_notifications_request_authorization(void *handle, int32_t options)
{
    if (handle == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NoguiNotificationCentre *centre = (__bridge NoguiNotificationCentre *)handle;
        /* `options` is already a `UNAuthorizationOptions` mask: 1 badge,
         * 2 sound, 4 alert. Re-mapping it here would be a second numbering to
         * keep in step with the SDK's, and this one was already out of step.
         * `UNAuthorizationOptionProvisional` is deliberately absent: it is
         * declared unavailable on macOS, so a macOS build could not name it.
         * Any bit the SDK adds later is the caller's to pass through. */
        UNAuthorizationOptions flags = (UNAuthorizationOptions)options;
        [[UNUserNotificationCenter currentNotificationCenter]
            requestAuthorizationWithOptions:flags
                          completionHandler:^(BOOL granted, NSError *error) {
            int32_t answer = granted ? 2 : 1;
            if (error != nil) {
                /* An NSError code is negative, which is how the host tells a
                 * failed query from an authorization state it can act on. */
                answer = (int32_t)error.code;
            }
            /* The cell is atomic, so the platform's own answer is cached
             * where it arrives, on a queue of the framework's choosing. */
            atomic_store(&centre->authorization, answer);
            /* The table is not atomic, and the block retains the centre, so
             * the answer reaches Zig from the main queue or not at all. */
            nogui_marshal_to_main(^{
                nogui_macos_notification_callbacks callbacks = centre.callbacks;
                if (callbacks.on_authorization != NULL) {
                    callbacks.on_authorization(callbacks.user, answer);
                }
            });
        }];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_notifications_authorization(void *handle)
{
    if (handle == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    NoguiNotificationCentre *centre = (__bridge NoguiNotificationCentre *)handle;
    /* -1 means no answer has arrived yet. That is a different state from a
     * denial, and a caller that cannot tell them apart would either prompt
     * for nothing or report a refusal the user never made. */
    return atomic_load(&centre->authorization);
}

int32_t nogui_macos_notifications_query_authorization(void *handle)
{
    if (handle == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NoguiNotificationCentre *centre = (__bridge NoguiNotificationCentre *)handle;
        [[UNUserNotificationCenter currentNotificationCenter]
            getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            int32_t answer = 0;
            switch (settings.authorizationStatus) {
            case UNAuthorizationStatusNotDetermined:
                answer = 0;
                break;
            case UNAuthorizationStatusDenied:
                answer = 1;
                break;
            case UNAuthorizationStatusAuthorized:
                answer = 2;
                break;
            /* `UNAuthorizationStatusProvisional` and `...Ephemeral` are
             * declared unavailable on macOS: provisional is an iOS, tvOS and
             * watchOS authorization and ephemeral is an App Clip one. Listing
             * them here would not compile against a macOS SDK, and a state
             * this platform cannot report must not be one the host can
             * receive. macOS has three reachable states. */
            @default:
                answer = NOGUI_MACOS_ERR_UNAVAILABLE;
                break;
            }
            /* A settings query answers on the same private queue an
             * authorization request does, so it is marshalled the same way. */
            atomic_store(&centre->authorization, answer);
            nogui_marshal_to_main(^{
                nogui_macos_notification_callbacks callbacks = centre.callbacks;
                if (callbacks.on_authorization != NULL) {
                    callbacks.on_authorization(callbacks.user, answer);
                }
            });
        }];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_notifications_set_category(
    void *handle,
    const char *identifier,
    const nogui_macos_notification_action *actions,
    size_t actions_len,
    int32_t allows_in_carplay
)
{
    if (handle == NULL || identifier == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        /* The accumulated set lives on the centre, so this C function reaches
         * it through the handle it was given rather than through a `self` it
         * does not have. */
        NoguiNotificationCentre *centre = (__bridge NoguiNotificationCentre *)handle;
        NSMutableArray<UNNotificationAction *> *built = [[NSMutableArray alloc] init];
        for (size_t index = 0; index < actions_len; index++) {
            NSString *key = nogui_string(actions[index].identifier);
            NSString *title = nogui_string(actions[index].title);
            if (key == nil || title == nil) {
                return NOGUI_MACOS_ERR_ENCODING;
            }
            UNNotificationActionOptions options = 0;
            if (actions[index].destructive) {
                options |= UNNotificationActionOptionDestructive;
            }
            if (actions[index].foreground) {
                options |= UNNotificationActionOptionForeground;
            }
            [built addObject:[UNNotificationAction actionWithIdentifier:key
                                                                 title:title
                                                               options:options]];
        }
        NSString *name = nogui_string(identifier);
        if (name == nil) {
            return NOGUI_MACOS_ERR_ENCODING;
        }
        UNNotificationCategoryOptions category_options = UNNotificationCategoryOptionNone;
        if (allows_in_carplay) {
            category_options = UNNotificationCategoryOptionAllowInCarPlay;
        }
        UNNotificationCategory *category = [UNNotificationCategory categoryWithIdentifier:name
                                                                                actions:built
                                                                          intentIdentifiers:@[]
                                                                                  options:category_options];
        if (centre.categories == nil) {
            centre.categories = [[NSMutableSet alloc] init];
        }
        /* One category per identifier: re-registering with new actions
         * replaces the old one and leaves every other category alone. */
        [centre.categories removeObject:category];
        [centre.categories addObject:category];
        [[UNUserNotificationCenter currentNotificationCenter]
            setNotificationCategories:centre.categories];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_notifications_add(
    void *handle,
    const char *identifier,
    const char *title,
    const char *subtitle,
    const char *body,
    const char *category,
    const char *icon_path,
    const char *sound,
    int32_t thread,
    int32_t badge
)
{
    if (handle == NULL || identifier == NULL || title == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    if (thread < 0 || thread > 3) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    @try {
        NoguiNotificationCentre *centre = (__bridge NoguiNotificationCentre *)handle;
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        NSString *title_text = nogui_string(title);
        if (title_text == nil) {
            return NOGUI_MACOS_ERR_ENCODING;
        }
        content.title = title_text;
        if (subtitle != NULL) {
            content.subtitle = nogui_string(subtitle);
        }
        if (body != NULL) {
            content.body = nogui_string(body);
        }
        if (category != NULL) {
            content.categoryIdentifier = nogui_string(category);
        }
        if (badge > 0) {
            content.badge = @(badge);
        }
        if (icon_path != NULL) {
            NSString *image_path = nogui_string(icon_path);
            NSImage *image = image_path == nil ? nil : [[NSImage alloc] initWithContentsOfFile:image_path];
            if (image == nil) {
                /* A notification whose icon cannot be read is refused rather
                 * than sent with a blank attachment the caller did not ask
                 * for. */
                return NOGUI_MACOS_ERR_ARGUMENT;
            }
            content.image = image;
        }
        if (sound != NULL) {
            NSString *sound_name = nogui_string(sound);
            if (sound_name == nil) {
                return NOGUI_MACOS_ERR_ENCODING;
            }
            if ([sound_name isEqualToString:@"default"]) {
                content.sound = [UNNotificationSound defaultSound];
            } else {
                UNNotificationSound *named = [UNNotificationSound soundNamed:sound_name];
                if (named == nil) {
                    return NOGUI_MACOS_ERR_ARGUMENT;
                }
                content.sound = named;
            }
        }
        if (@available(macOS 12.0, *)) {
            /* The interruption level arrived in macOS 12. Before it there is
             * one level and the request carries none, so the platform's own
             * default stands rather than a guessed substitute. */
            content.interruptionLevel = UNNotificationInterruptionLevelActive;
            if (thread == 0) {
                content.interruptionLevel = UNNotificationInterruptionLevelPassive;
            } else if (thread == 2) {
                content.interruptionLevel = UNNotificationInterruptionLevelTimeSensitive;
            } else if (thread == 3) {
                content.interruptionLevel = UNNotificationInterruptionLevelCritical;
            }
        }
        /* The identifier is copied into an NSString before it is captured, and
         * the block below retains that copy, so the answer names the request
         * this call added rather than whatever the caller's stack frame
         * became. */
        NSString *name = nogui_string(identifier);
        if (name == nil) {
            return NOGUI_MACOS_ERR_ENCODING;
        }
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:name
                                                                             content:content
                                                                             trigger:nil];
        [[UNUserNotificationCenter currentNotificationCenter]
            addNotificationRequest:request
             withCompletionHandler:^(NSError *error) {
            if (error == nil) {
                /* An accepted request is the answer this host already reported
                 * from `submit`. Nothing reaches Zig, and nothing is read that
                 * the free could have retired. */
                return;
            }
            int32_t code = (int32_t)error.code;
            nogui_marshal_to_main(^{
                @autoreleasepool {
                    nogui_macos_notification_callbacks callbacks = centre.callbacks;
                    if (callbacks.on_error == NULL) {
                        return;
                    }
                    callbacks.on_error(callbacks.user, name.UTF8String, code);
                }
            });
        }];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_notifications_remove(void *handle, const char *identifier)
{
    if (handle == NULL || identifier == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSString *name = nogui_string(identifier);
        if (name == nil) {
            return NOGUI_MACOS_ERR_ENCODING;
        }
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        /* A notification can be on screen and still waiting to be delivered,
         * so both queues are cleared for a dismissal to be complete. */
        [center removeDeliveredNotificationsWithIdentifiers:@[name]];
        [center removePendingNotificationRequestsWithIdentifiers:@[name]];
        return NOGUI_MACOS_OK;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

/* ── frames ──────────────────────────────────────────────────────────────── */

void *nogui_macos_pixel_buffer_create(uint32_t width, uint32_t height, uint32_t pixel_format)
{
    if (width == 0 || height == 0) {
        return NULL;
    }
    if (!nogui_on_main_thread()) {
        return NULL;
    }
    CVPixelBufferRef buffer = NULL;
    /* A null attribute dictionary produces a plain CPU-addressable buffer.
     * Nothing here asks for an IOSurface, so no frame this module creates can
     * be imported as a GPU resource behind the host's back. */
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          (size_t)width,
                                          (size_t)height,
                                          (OSType)pixel_format,
                                          NULL,
                                          &buffer);
    if (status != kCVReturnSuccess || buffer == NULL) {
        return NULL;
    }
    return (void *)buffer;
}

void nogui_macos_pixel_buffer_retain(void *buffer)
{
    if (buffer == NULL) {
        return;
    }
    CVPixelBufferRetain((CVPixelBufferRef)buffer);
}

void nogui_macos_pixel_buffer_release(void *buffer)
{
    if (buffer == NULL) {
        return;
    }
    CVPixelBufferRelease((CVPixelBufferRef)buffer);
}

static int32_t nogui_color_space_of(CVPixelBufferRef buffer)
{
    CFTypeRef value = CVBufferGetAttachment(buffer,
                                            kCVImageBufferColorSpaceKey,
                                            kCVAttachmentMode_ShouldPropagate);
    if (value == NULL) {
        return NOGUI_MACOS_ERR_UNAVAILABLE;
    }
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringRef name = (CFStringRef)value;
        if (CFEqual(name, kCGColorSpaceSRGB)) {
            return 0;
        }
        if (CFEqual(name, kCGColorSpaceDisplayP3)) {
            return 1;
        }
        if (CFEqual(name, kCGColorSpaceLinearSRGB)) {
            return 2;
        }
        return NOGUI_MACOS_ERR_UNAVAILABLE;
    }
    if (CFGetTypeID(value) == CGColorSpaceGetTypeID()) {
        CGColorSpaceRef space = (CGColorSpaceRef)value;
        /* `CGColorSpaceCreateWithName` follows the Create Rule, so creating
         * these per frame would leak three references per frame. They are
         * process-lifetime constants instead. */
        static CGColorSpaceRef srgb = NULL;
        static CGColorSpaceRef display_p3 = NULL;
        static CGColorSpaceRef linear_srgb = NULL;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            display_p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
            linear_srgb = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
        });
        if (srgb != NULL && CGColorSpaceEqualToColorSpace(space, srgb)) {
            return 0;
        }
        if (display_p3 != NULL && CGColorSpaceEqualToColorSpace(space, display_p3)) {
            return 1;
        }
        if (linear_srgb != NULL && CGColorSpaceEqualToColorSpace(space, linear_srgb)) {
            return 2;
        }
    }
    return NOGUI_MACOS_ERR_UNAVAILABLE;
}

static int32_t nogui_alpha_of(CVPixelBufferRef buffer)
{
    NSDictionary *attachments =
        (__bridge_transfer NSDictionary *)CVBufferCopyAttachments(buffer, kCVAttachmentMode_ShouldPropagate);
    if (attachments == nil) {
        return 0;
    }
    NSNumber *info = attachments[(__bridge id)kCVImageBufferAlphaInfoKey];
    if (info == nil) {
        /* CoreVideo's default for a 32-bit buffer is premultiplied. */
        return 0;
    }
    int32_t raw = info.intValue;
    if (raw == kCVImageBufferAlpha_UnpremultipliedFirst || raw == kCVImageBufferAlpha_UnpremultipliedLast) {
        return 1;
    }
    return 0;
}

/* One lock, one layout walk, two permissions. `flags` is what CoreVideo is
 * asked for and what every unlock on the failure paths below carries, because
 * a buffer may only be unlocked with the flags it was locked with. */
static int32_t nogui_lock_and_describe(
    CVPixelBufferRef pixel_buffer,
    nogui_macos_frame_layout *out,
    CVPixelBufferLockFlags flags)
{
    memset(out, 0, sizeof(*out));
    if (CVPixelBufferIsPlanar(pixel_buffer) == false &&
        CVPixelBufferGetBytesPerRow(pixel_buffer) == 0) {
        return NOGUI_MACOS_ERR_UNAVAILABLE;
    }
    CVReturn locked = CVPixelBufferLockBaseAddress(pixel_buffer, flags);
    if (locked != kCVReturnSuccess) {
        /* A GPU-backed buffer refuses this lock. The host reports that and does
         * not reach for the IOSurface behind it. */
        return NOGUI_MACOS_ERR_UNAVAILABLE;
    }
    out->pixel_format = (uint32_t)CVPixelBufferGetPixelFormatType(pixel_buffer);
    out->width = (uint32_t)CVPixelBufferGetWidth(pixel_buffer);
    out->height = (uint32_t)CVPixelBufferGetHeight(pixel_buffer);
    out->color_space = nogui_color_space_of(pixel_buffer);
    out->unpremultiplied = nogui_alpha_of(pixel_buffer);
    if (CVPixelBufferIsPlanar(pixel_buffer)) {
        size_t planes = CVPixelBufferGetPlaneCount(pixel_buffer);
        if (planes > NOGUI_MACOS_MAX_PLANES) {
            CVPixelBufferUnlockBaseAddress(pixel_buffer, flags);
            return NOGUI_MACOS_ERR_REFUSED;
        }
        out->plane_count = (uint32_t)planes;
        for (size_t index = 0; index < planes; index++) {
            const uint8_t *data = CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, index);
            if (data == NULL) {
                CVPixelBufferUnlockBaseAddress(pixel_buffer, flags);
                return NOGUI_MACOS_ERR_FAULT;
            }
            uint32_t stride = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, index);
            uint32_t plane_height = CVPixelBufferGetHeightOfPlane(pixel_buffer, index);
            out->planes[index].data = data;
            out->planes[index].stride = stride;
            out->planes[index].width = CVPixelBufferGetWidthOfPlane(pixel_buffer, index);
            out->planes[index].height = plane_height;
            out->planes[index].len = (size_t)stride * (size_t)plane_height;
        }
        /* The containing span is from the lowest plane address to the end of
         * the highest. CoreVideo allocates all planes of a CPU buffer in one
         * block, so this is one allocation; a GPU-backed multi-plane buffer is
         * not locked at all and never reaches here. Reporting plane 0's span
         * instead would put every later plane outside it and the consumer
         * would refuse a frame it could describe. */
        {
            const uint8_t *lowest = NULL;
            const uint8_t *highest_end = NULL;
            for (size_t index = 0; index < planes; index++) {
                const uint8_t *start = out->planes[index].data;
                const uint8_t *end = start + out->planes[index].len;
                if (lowest == NULL || start < lowest) {
                    lowest = start;
                }
                if (highest_end == NULL || end > highest_end) {
                    highest_end = end;
                }
            }
            out->base = lowest;
            out->base_len = (size_t)(highest_end - lowest);
        }
    } else {
        const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(pixel_buffer);
        if (base == NULL) {
            CVPixelBufferUnlockBaseAddress(pixel_buffer, flags);
            return NOGUI_MACOS_ERR_FAULT;
        }
        uint32_t stride = CVPixelBufferGetBytesPerRow(pixel_buffer);
        out->plane_count = 1;
        out->bytes_per_row = stride;
        out->base = base;
        out->planes[0].data = base;
        out->planes[0].stride = stride;
        out->planes[0].width = out->width;
        out->planes[0].height = out->height;
        out->planes[0].len = (size_t)stride * (size_t)out->height;
        out->base_len = out->planes[0].len;
    }
    return NOGUI_MACOS_OK;
}

int32_t nogui_macos_frame_lock(void *buffer, nogui_macos_frame_layout *out)
{
    if (buffer == NULL || out == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    return nogui_lock_and_describe((CVPixelBufferRef)buffer, out, kCVPixelBufferLock_ReadOnly);
}

int32_t nogui_macos_frame_lock_write(void *buffer, nogui_macos_frame_layout *out)
{
    if (buffer == NULL || out == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    /* No permission flag at all: CoreVideo's write lock, which is what makes
     * the mapping the producer's own storage rather than a promise not to
     * touch it. */
    return nogui_lock_and_describe((CVPixelBufferRef)buffer, out, 0);
}

int32_t nogui_macos_frame_unlock(void *buffer)
{
    if (buffer == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    CVPixelBufferRef pixel_buffer = (CVPixelBufferRef)buffer;
    return CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess
        ? NOGUI_MACOS_OK
        : NOGUI_MACOS_ERR_FAULT;
}

int32_t nogui_macos_frame_unlock_write(void *buffer)
{
    if (buffer == NULL) {
        return NOGUI_MACOS_ERR_ARGUMENT;
    }
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    CVPixelBufferRef pixel_buffer = (CVPixelBufferRef)buffer;
    return CVPixelBufferUnlockBaseAddress(pixel_buffer, 0) == kCVReturnSuccess
        ? NOGUI_MACOS_OK
        : NOGUI_MACOS_ERR_FAULT;
}

/* ── preferences ─────────────────────────────────────────────────────────── */

/* Each style is compared against the SDK constant rather than against an
 * ordinal copied out of a header, so the mapping follows what the constant
 * means instead of what number this SDK happens to give it. */
int32_t nogui_macos_preferred_scroller_style(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSScrollerStyle style = [NSScroller preferredScrollerStyle];
        if (style == NSScrollerStyleLegacy) {
            return 0;
        }
        if (style == NSScrollerStyleOverlay) {
            return 1;
        }
        /* A style this SDK does not name is not "legacy, probably". It is a
         * system value the caller cannot map, so the read reports that rather
         * than answering with a guess it would have to publish as a user
         * preference. */
        return NOGUI_MACOS_ERR_UNAVAILABLE;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}

int32_t nogui_macos_thermal_state(void)
{
    if (!nogui_on_main_thread()) {
        return NOGUI_MACOS_ERR_THREAD;
    }
    @try {
        NSProcessInfoThermalState state = [[NSProcessInfo processInfo] thermalState];
        if (state == NSProcessInfoThermalStateNominal) {
            return 0;
        }
        if (state == NSProcessInfoThermalStateFair) {
            return 1;
        }
        if (state == NSProcessInfoThermalStateSerious) {
            return 2;
        }
        if (state == NSProcessInfoThermalStateCritical) {
            return 3;
        }
        /* Same rule as the scroller style: a state the SDK does not name is
         * reported as not available instead of being rounded into the
         * nearest severity this SDK does know. */
        return NOGUI_MACOS_ERR_UNAVAILABLE;
    } @catch (NSException *exception) {
        (void)exception;
        return NOGUI_MACOS_ERR_FAULT;
    }
}
