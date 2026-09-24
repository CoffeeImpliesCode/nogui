/*
 * Owned C ABI for the nogui macOS adapters.
 *
 * This header is the WHOLE boundary between the Zig host and AppKit. It
 * declares no SDK type: every framework object crosses as an opaque
 * `void *` that the Zig side obtained from an SDL window property and never
 * owns, and every string is a NUL-terminated UTF-8 buffer the callee copies
 * before returning. Nothing here allocates memory the caller has to free, so
 * a frame callback on the host never has to unwind an Objective-C allocation.
 *
 * Four rules hold for every entry point:
 *
 *   1. MAIN THREAD. A function that touches AppKit, Security or CoreVideo
 *      checks `[NSThread isMainThread]` and returns
 *      NOGUI_MACOS_ERR_THREAD when the caller is anywhere else. The Zig side
 *      marshals through SDL's main-thread queue, so a wrong thread is a
 *      visible defect instead of a crash inside AppKit. A `void` release
 *      cannot report anything, so it refuses by doing nothing, and the rule
 *      that follows is the caller's: run it on the main thread, and release
 *      nothing that handle keeps alive until it has run.
 *   2. TYPED FAILURE. A refusal is one of the NOGUI_MACOS_ERR_* codes, never
 *      a silent success and never an uninitialised out-parameter.
 *   3. NO HIDDEN OWNERSHIP. A `void *` the caller passes in stays owned by the
 *      caller for the whole call. A `void *` the caller gets back is either a
 *      handle this header documents (created by a `_new` function, released by
 *      the matching `_free`) or a borrowed SDK object.
 *   4. A NON-NEGATIVE RETURN IS A VALUE. An entry point that reports a fact
 *      rather than only success returns that fact as a non-negative number
 *      and a refusal as a negative code, so a caller has to read the sign
 *      before it reads the number. The Zig `Status` mapping treats only zero
 *      as success, so `raw < 0` is what separates a value the platform gave
 *      on purpose from a refusal; handing a value-bearing return straight to
 *      that mapping reports a fault for an answer the platform meant.
 */
#ifndef NOGUI_MACOS_H
#define NOGUI_MACOS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Result codes. Zero is success; every negative value names a refusal. */
enum {
    NOGUI_MACOS_OK = 0,
    /* The caller is not on the macOS main thread. */
    NOGUI_MACOS_ERR_THREAD = -1,
    /* A required handle was NULL. */
    NOGUI_MACOS_ERR_ARGUMENT = -2,
    /* A string argument was not valid UTF-8. */
    NOGUI_MACOS_ERR_ENCODING = -3,
    /* The platform refused the request (locked store, denied access, ...). */
    NOGUI_MACOS_ERR_REFUSED = -4,
    /* The platform does not offer this capability on this system. */
    NOGUI_MACOS_ERR_UNAVAILABLE = -5,
    /* The caller's buffer was too small. The required size is reported. */
    NOGUI_MACOS_ERR_BUFFER = -6,
    /* The framework raised an exception that this shim caught. */
    NOGUI_MACOS_ERR_FAULT = -7,
    /* An allocation failed. */
    NOGUI_MACOS_ERR_MEMORY = -8
};

/* Longest string any entry point will copy into an SDK object. A longer one
 * is refused with NOGUI_MACOS_ERR_BUFFER rather than truncated into a
 * half-valid NSString. */
#define NOGUI_MACOS_MAX_TEXT 65536
/* Tabs reported for one window. A larger group is reported truncated. */
#define NOGUI_MACOS_MAX_TABS 64
/* Planes a pixel buffer can have. CoreVideo's limit is 4. */
#define NOGUI_MACOS_MAX_PLANES 4

/* ── Windows ─────────────────────────────────────────────────────────────── */

/* The tab group a window belongs to, in visual tab order. The type is named
 * apart from nogui_macos_tab_group so the record and the function that fills
 * it do not collide in a Zig view of this header. */
typedef struct nogui_macos_tabs {
    uint32_t count;
    /* More windows are in the group than `windows` can hold. */
    uint32_t truncated;
    /* The selected tab, or NULL when the group is not the focused one. */
    void *selected;
    void *windows[NOGUI_MACOS_MAX_TABS];
} nogui_macos_tabs;

/* Fill `out` with the window's tab group.
 * NOGUI_MACOS_OK when the window is in a group, NOGUI_MACOS_ERR_UNAVAILABLE
 * when it is not tabbed at all, and a failure code when the read failed. */
int32_t nogui_macos_tab_group(void *window, nogui_macos_tabs *out);

/* `addTabbedWindow:ordered:`. `above` is non-zero for NSWindowAbove.
 * NOGUI_MACOS_OK writes the new parent AppKit chose into `out_parent`; the
 * caller reads the group back rather than trusting the ordering. A missing
 * window, a worker thread and an AppKit refusal are three different answers,
 * so the status reports which one it was instead of every failure arriving as
 * the same NULL parent. */
int32_t nogui_macos_tab_merge(void *host, void *guest, int32_t above, void **out_parent);
int32_t nogui_macos_tab_merge_all(void *window);
int32_t nogui_macos_tab_select_next(void *window);
int32_t nogui_macos_tab_select_previous(void *window);
/* `moveTabToNewWindow:`. Detaching a window that is not the selected tab has
 * no public AppKit path, so this refuses instead of moving the wrong tab. */
int32_t nogui_macos_tab_detach(void *window);
/* 0 automatic, 1 preferred, 2 disallowed (NSWindowTabbingMode). */
int32_t nogui_macos_tab_set_mode(void *window, int32_t mode);
int32_t nogui_macos_tab_mode(void *window);
int32_t nogui_macos_tab_set_identifier(void *window, const char *identifier);
int32_t nogui_macos_tab_allows_automatic(int32_t enabled);
/* 0 manual, 1 always, 2 in full screen, or NOGUI_MACOS_ERR_UNAVAILABLE. */
int32_t nogui_macos_tab_user_preference(void);

/* NSWindowTitleVisibility: 0 visible, 1 hidden. Pass -1 to read. */
int32_t nogui_macos_window_title_visibility(void *window, int32_t visibility);
int32_t nogui_macos_window_titlebar_transparent(void *window, int32_t transparent);
int32_t nogui_macos_window_set_title(void *window, const char *utf8);
/* The titlebar separator. macOS 11 introduced a public style enum; the
 * colour property this entry point used to name is not in the public
 * headers, so an older system reports NOGUI_MACOS_ERR_UNAVAILABLE.
 * 0 automatic, 1 none, 2 line, 3 shadow. */
int32_t nogui_macos_window_titlebar_separator(void *window, int32_t style);
/* NSWindowButton: 0 close, 1 miniaturize, 2 zoom, 3 fullscreen. Pass -1 to
 * read without changing anything, the same sentinel the titlebar readers use. */
int32_t nogui_macos_window_button_visible(void *window, int32_t kind, int32_t visible);
/* NSWindow.isDocumentEdited. Pass -1 to read. */
int32_t nogui_macos_window_document_edited(void *window, int32_t edited);
/* The proxy icon path. NULL clears `representedURL`. */
int32_t nogui_macos_window_set_represented_path(void *window, const char *path);
/* Read one of the platform's strings. Every string the adapters read back
 * comes through this one entry point, so there is a single buffer contract
 * instead of one per source: on NOGUI_MACOS_ERR_BUFFER the required length
 * is in `*out_len` and the caller retries with a larger buffer. */
typedef enum nogui_macos_string_source {
    NOGUI_MACOS_STRING_WINDOW_TITLE = 0,
    NOGUI_MACOS_STRING_WINDOW_REPRESENTED_PATH = 1,
    NOGUI_MACOS_STRING_SERVICES_LABEL = 2,
    NOGUI_MACOS_STRING_RECENT_LIST = 3,
    NOGUI_MACOS_STRING_FIND_TEXT = 4,
    NOGUI_MACOS_STRING_FIND_OPTIONS = 5,
    NOGUI_MACOS_STRING_BUNDLE_ID = 6
} nogui_macos_string_source;

/* `index` is the Services menu index and is ignored by the other sources.
 * `handle` is the window for the two window sources and NULL otherwise. */
int32_t nogui_macos_read_string(
    int32_t source,
    int32_t index,
    void *handle,
    char *buffer,
    size_t capacity,
    size_t *out_len
);
int32_t nogui_macos_window_is_key(void *window);
int32_t nogui_macos_window_is_main(void *window);
int32_t nogui_macos_window_make_key_and_order_front(void *window);
int32_t nogui_macos_window_order_out(void *window);
/* The window's content view, retained for the caller. The accessibility
 * adapter is its only user, and it hands the pointer straight to AccessKit,
 * which takes its own reference. */
void *nogui_macos_window_content_view(void *window);
void nogui_macos_content_view_release(void *view);
/* Backing scale factor of the screen the window is on. */
double nogui_macos_window_backing_scale(void *window);

/* The window's Objective-C class name, NUL-terminated into `buffer` and
 * reported through the same contract as every other string: on
 * NOGUI_MACOS_ERR_BUFFER `*out_len` is the length a retry needs. The
 * accessibility adapter needs this because AccessKit adds its focus forwarder
 * to a window CLASS, so the class of the window that was actually handed over
 * is the one that has to be patched — a name assumed here would put the
 * forwarder on a class no window has. */
int32_t nogui_macos_window_class_name(
    void *window,
    char *buffer,
    size_t capacity,
    size_t *out_len
);

/* ── Application ─────────────────────────────────────────────────────────── */

typedef struct nogui_macos_app_events {
    void *user;
    /* The Dock icon or a reopen file asked for a window. `visible` is the
     * platform's `hasVisibleWindows` argument. */
    void (*on_reopen)(void *user, int32_t visible);
    void (*on_become_active)(void *user);
    void (*on_resign_active)(void *user);
    void (*on_will_terminate)(void *user);
} nogui_macos_app_events;

/* Install an application delegate that forwards every selector it does not
 * implement to the delegate already registered, so SDL keeps its own
 * behaviour. The returned handle is released with `_remove`. */
void *nogui_macos_app_events_install(const nogui_macos_app_events *events);
void nogui_macos_app_events_remove(void *handle);

int32_t nogui_macos_app_activate(void);
int32_t nogui_macos_app_hide(void);
int32_t nogui_macos_app_unhide(void);
int32_t nogui_macos_app_hide_others(void);
int32_t nogui_macos_app_show_all(void);
/* `[NSApp reopen:]`, the action the Quit Applications shortcut uses. */
int32_t nogui_macos_app_reopen(void);
int32_t nogui_macos_app_is_active(void);
int32_t nogui_macos_app_is_hidden(void);
/* NSApplicationActivationPolicy: 0 regular, 1 accessory, 2 prohibited. */
int32_t nogui_macos_app_set_activation_policy(int32_t policy);
int32_t nogui_macos_app_activation_policy(void);
int32_t nogui_macos_app_dock_badge(const char *utf8);
/* The bundle identifier, which UserNotifications and the recent-documents
 * menu both require. Read it through NOGUI_MACOS_STRING_BUNDLE_ID. */

/* ── Menus ───────────────────────────────────────────────────────────────── */

/* One node of a flattened menu model. A node with `kind` 0 is a menu and
 * `parent` is the index of the menu that owns it, or -1 for the menu bar. */
typedef struct nogui_macos_menu_node {
    int32_t parent;
    /* 0 menu, 1 item, 2 separator, 3 the platform's own Open Recent menu. */
    int32_t kind;
    /* 0 a W10 action to dispatch, 1 a system action, -1 neither. */
    int32_t action_kind;
    /* The row's routing tag: the high bits name the menu the row belongs to
     * (0 the menu bar, 1 the Dock menu) and the low bits are the row's index
     * inside that menu's own table. The `index` an `on_item` callback receives
     * is this value, which is how a click in either installed menu names its
     * own row. -1 for a node that is not a row: a menu, a separator or the
     * Open Recent header. */
    int32_t action_index;
    /* menus.SystemAction ordinal, or -1. */
    int32_t system_action;
    /* -1 ask the host, 0 disabled, 1 enabled. */
    int32_t enabled;
    int32_t checked;
    uint32_t id;
    const char *label;
    /* A key equivalent such as "n" or "cmd+s", or NULL. */
    const char *shortcut;
} nogui_macos_menu_node;

typedef struct nogui_macos_menu_model {
    const nogui_macos_menu_node *nodes;
    size_t nodes_len;
} nogui_macos_menu_model;

typedef struct nogui_macos_menu_callbacks {
    void *user;
    /* A menu item was chosen. `index` is the routing tag its node carried; see
     * `nogui_macos_menu_node.action_index`. */
    void (*on_item)(void *user, int32_t index, int32_t system_action);
    /* A recent document was chosen from the Open Recent submenu. */
    void (*on_recent)(void *user, int32_t index);
} nogui_macos_menu_callbacks;

/* The handle is the controller; it owns the callbacks, the NSMenu objects,
 * and the node table the Dock menu holds. Freeing it detaches every menu it
 * installed.
 *
 * NULL means the menu could not be built, and `status` then names the reason.
 * The status is an out-parameter because a pointer does not fit in the int32
 * this ABI returns everywhere else. A handle is handed over ONCE, on the path
 * that succeeds: every refusal releases what it built inside this call and
 * hands back nothing, because a NULL answer leaves the caller no handle to
 * release it with. `model` is read and copied during the call and need not
 * outlive it; `user` is borrowed for as long as the handle is, so the record
 * it names must outlive the free that releases this handle. */
void *nogui_macos_menu_new(
    const nogui_macos_menu_model *model,
    const nogui_macos_menu_callbacks *callbacks,
    void *user,
    int32_t *status
);
int32_t nogui_macos_menu_install(void *handle);
/* Main thread only. Off it this does nothing, so a caller that keeps the
 * record its callbacks name must not release it on the strength of having
 * called this. */
void nogui_macos_menu_free(void *handle);

/* Rebuild the Dock menu from a flat node table that uses the same encoding
 * as the menu bar. A node with `kind` 3 becomes the Open Recent submenu,
 * which the platform fills from the recent-documents store. */
int32_t nogui_macos_dock_menu_set(
    void *handle,
    const nogui_macos_menu_model *model
);

/* Open Recent. */
int32_t nogui_macos_recent_add(const char *path);
int32_t nogui_macos_recent_clear(void);

/* ── Services ────────────────────────────────────────────────────────────── */

typedef struct nogui_macos_services_callbacks {
    void *user;
    /* Another app sent this app a service. `send_type` and `return_type` are
     * NULL when the request named no such type, and `text` is the string
     * flavour of the pasteboard, or NULL when it holds none. The callback
     * answers with the text to write back, or NULL to write nothing. */
    const char *(*on_perform)(
        void *user,
        const char *send_type,
        const char *return_type,
        const char *text,
        size_t text_len
    );
    /* The host's own selection, for a service this app sends. The returned
     * string stays valid for the duration of the call; NULL means the host
     * has no selection to offer. */
    const char *(*on_write)(void *user);
    /* Validate one Services menu item before AppKit enables it. */
    int32_t (*on_validate)(void *user, const char *label);
} nogui_macos_services_callbacks;

/* ── Accessibility ───────────────────────────────────────────────────────── */

/* Whether this process is trusted to serve an accessibility tree. macOS only
 * lets a trusted process answer accessibility requests, and a process cannot
 * grant itself that, so `false` is a fact the host reports rather than
 * something it retries. Reads nothing and prompts nothing. */
int32_t nogui_macos_accessibility_is_trusted(void);

/* Ask macOS to show its "grant accessibility access" prompt. This is a request
 * to a person, so the host calls it only in answer to an action. Returns
 * NOGUI_MACOS_OK when the prompt was shown, NOGUI_MACOS_ERR_UNAVAILABLE when
 * the system declined to show it, and the failure codes otherwise. The answer
 * arrives later, read back with `nogui_macos_accessibility_is_trusted`. */
int32_t nogui_macos_accessibility_request_trust(void);

/* The character palette inserts through the window's first responder, so the
 * host answers an insertion with a callback the responder holds. C reads a
 * declaration top to bottom, so the type is declared here, ahead of the
 * responder that takes it, rather than down in the text-input section. */
typedef struct nogui_macos_text_callbacks {
    void *user;
    /* AppKit inserted text into the mirror. `location` and `length` are the
     * replacement range in UTF-16 code units of the mirrored string, which
     * is the text the host passed to `_mirror`. */
    void (*on_insert)(void *user, const char *utf8, size_t len, uint64_t location, uint64_t length);
} nogui_macos_text_callbacks;

/* The responder view that receives an incoming service and a palette
 * insertion. It is one object because both arrive through the window's
 * first responder, and it is kept zero-sized so the host's own painting is
 * unaffected. */
void *nogui_macos_responder_new(
    void *window,
    const nogui_macos_services_callbacks *services,
    const nogui_macos_text_callbacks *text
);
void nogui_macos_responder_free(void *responder);

/* Advertise this app as a service provider. `send_types` and `return_types`
 * are uniform type identifiers such as "public.utf8-plain-text". */
int32_t nogui_macos_services_register(
    void *responder,
    const char *const *send_types,
    size_t send_types_len,
    const char *const *return_types,
    size_t return_types_len
);
/* Number of services the system put in the Services menu. */
int32_t nogui_macos_services_menu_count(void);
/* Send the Services menu item at `index` to its own target. */
int32_t nogui_macos_services_invoke(int32_t index);

/* ── Text input: the character palette and the find pasteboard ───────────── */

/* Replace the mirrored text and its selection. The mirror exists only so
 * AppKit's text-input client has real content to insert into; the host's own
 * edit stays the authority. */
int32_t nogui_macos_text_mirror(
    void *responder,
    const char *utf8,
    size_t len,
    uint64_t selection_location,
    uint64_t selection_length
);
int32_t nogui_macos_text_make_first_responder(void *responder);
/* `[NSApp orderFrontCharacterPalette:]`. The palette is dismissed by the
 * system when the first responder changes, which is why there is no close
 * entry point to get wrong. */
int32_t nogui_macos_text_open_character_palette(void);
/* The Find pasteboard, which the system Find panel and the app share. */
int32_t nogui_macos_find_pasteboard_write(const char *utf8, size_t len);
int32_t nogui_macos_find_pasteboard_clear(void);
/* 0 empty, 1 only the string flavor, 2 other flavors; negative on failure. */
int32_t nogui_macos_find_pasteboard_content(void);
/* The finder's search options, as a property list string. */
int32_t nogui_macos_find_options_write(const char *plist);

/* ── Credentials ─────────────────────────────────────────────────────────── */

/* Read, write or delete one generic password. `secret` and `secret_len` are
 * unused for a read. Every result is a NOGUI_MACOS_ERR_* code; the returned
 * buffer is copied into and owned by the caller's allocator. */
int32_t nogui_macos_keychain_read(
    const char *service,
    const char *account,
    const char *access_group,
    char *secret,
    size_t capacity,
    size_t *out_len
);
int32_t nogui_macos_keychain_write(
    const char *service,
    const char *account,
    const char *access_group,
    const char *secret,
    size_t secret_len
);
int32_t nogui_macos_keychain_delete(const char *service, const char *account, const char *access_group);
/* The Security status of the last call, so the host can separate a locked
 * store, a dismissed prompt and a denied item without re-deriving codes. */
int32_t nogui_macos_keychain_last_status(void);

/* ── Notifications ───────────────────────────────────────────────────────── */

typedef struct nogui_macos_notification_action {
    const char *identifier;
    const char *title;
    int32_t destructive;
    int32_t foreground;
} nogui_macos_notification_action;

typedef struct nogui_macos_notification_callbacks {
    void *user;
    /* The user answered a notification. `identifier` is the request the host
     * named, or NULL when the centre delivered something the host cannot
     * match to a request it made; `action` is UN's default identifier for a
     * plain click. A NULL identifier is not a request this host may guess
     * at, so the callback has to be able to see it. */
    void (*on_response)(void *user, const char *identifier, const char *action);
    /* The centre rejected a request. `status` is a NOGUI_MACOS_ERR_* code. */
    void (*on_error)(void *user, const char *identifier, int32_t status);
    /* The authorization answer. `status` is 0 not determined, 1 denied,
     * 2 authorized, or a negative platform error code. macOS has three
     * reachable states: `provisional` and `ephemeral` are iOS and App Clip
     * authorizations that this platform cannot report. */
    void (*on_authorization)(void *user, int32_t status);
} nogui_macos_notification_callbacks;

void *nogui_macos_notifications_new(const nogui_macos_notification_callbacks *callbacks, void *user);
void nogui_macos_notifications_free(void *handle);

/* `options` is a `UNAuthorizationOptions` mask passed straight through: 1 is
 * badge, 2 is sound, 4 is alert. There is deliberately no provisional bit,
 * because `UNAuthorizationOptionProvisional` is declared unavailable on
 * macOS. Asking shows the system prompt, so a host calls this only on a
 * user's action. */
int32_t nogui_macos_notifications_request_authorization(void *handle, int32_t options);
/* Read the authorization the platform last reported. -1 means no answer has
 * arrived yet, which is a different state from a denial. */
int32_t nogui_macos_notifications_authorization(void *handle);
/* Ask the platform for the current settings without prompting. The answer
 * arrives through `on_authorization` and updates the cached value. */
int32_t nogui_macos_notifications_query_authorization(void *handle);
/* Register the category and its actions before adding a request that names
 * it, which is what UserNotifications requires. */
int32_t nogui_macos_notifications_set_category(
    void *handle,
    const char *identifier,
    const nogui_macos_notification_action *actions,
    size_t actions_len,
    int32_t allows_in_carplay
);
/* `thread` is 0 passive, 1 active, 2 time sensitive, 3 critical. */
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
);
int32_t nogui_macos_notifications_remove(void *handle, const char *identifier);

/* ── Frames ──────────────────────────────────────────────────────────────── */

/* A CoreVideo pixel buffer the caller owns ONE reference to. `describe` takes
 * a reference of its OWN for the frame it returns and releases exactly that
 * one when the frame is released, so the caller's reference is untouched. */
void *nogui_macos_pixel_buffer_create(uint32_t width, uint32_t height, uint32_t pixel_format);
void nogui_macos_pixel_buffer_retain(void *buffer);
void nogui_macos_pixel_buffer_release(void *buffer);

/* One plane of a locked buffer. */
typedef struct nogui_macos_plane {
    const uint8_t *data;
    size_t len;
    uint32_t stride;
    uint32_t width;
    uint32_t height;
} nogui_macos_plane;

typedef struct nogui_macos_frame_layout {
    uint32_t pixel_format;
    uint32_t width;
    uint32_t height;
    uint32_t plane_count;
    uint32_t bytes_per_row;
    /* The lowest plane's address, and the span from there to the end of the
     * highest plane. A planar buffer whose planes are NOT in one span has no
     * offset this descriptor can express, so the consumer reports that
     * instead of being handed an offset that would read outside it. */
    const uint8_t *base;
    size_t base_len;
    /* 0 sRGB, 1 display P3, 2 linear, or NOGUI_MACOS_ERR_UNAVAILABLE. */
    int32_t color_space;
    /* 1 when the buffer carries a non-premultiplied alpha. */
    int32_t unpremultiplied;
    nogui_macos_plane planes[NOGUI_MACOS_MAX_PLANES];
} nogui_macos_frame_layout;

/* Lock a pixel buffer for reading. NOGUI_MACOS_ERR_UNAVAILABLE means the
 * buffer is not CPU addressable, which is a real answer: the host reports it
 * instead of importing the buffer's IOSurface. The returned `data` pointers
 * are CONST: the lock promises the caller not to store through them. */
int32_t nogui_macos_frame_lock(void *buffer, nogui_macos_frame_layout *out);
int32_t nogui_macos_frame_unlock(void *buffer);

/* Lock the SAME buffer for WRITING. CoreVideo asks for no permission flag at
 * all, which is what makes the mapping the producer's own storage rather than
 * a promise not to touch it: a caller may store through the returned `data`
 * until it calls `nogui_macos_frame_unlock_write`. CoreVideo requires the
 * unlock to carry the flags the lock took, so these two are a pair and
 * neither substitutes for the read pair above.
 *
 * This is how a PRODUCER fills a buffer. Describing a buffer for upload locks
 * it read-only for the whole lifetime of the frame, so storing through a
 * described buffer would write memory the lock forbids. */
int32_t nogui_macos_frame_lock_write(void *buffer, nogui_macos_frame_layout *out);
int32_t nogui_macos_frame_unlock_write(void *buffer);

/* ── Preferences ─────────────────────────────────────────────────────────── */

/* The user's scroll bar preference as AppKit resolves it, read from
 * `NSScroller.preferredScrollerStyle`. Apple documents that value as the
 * Appearance panel's "Show scroll bars" setting for the current user, and,
 * when the user chose "Automatically based on input device", as a function of
 * the pointing devices and their scroll capability settings:
 * https://developer.apple.com/documentation/appkit/nsscroller/preferredscrollerstyle
 * `NSScrollerStyle` is exactly legacy or overlay:
 * https://developer.apple.com/documentation/appkit/nscroller/style
 *
 * Returns 0 legacy, 1 overlay, or a NOGUI_MACOS_ERR_* code. A style this SDK
 * does not name is NOGUI_MACOS_ERR_UNAVAILABLE, because a code this header
 * cannot name is a fact the caller has to keep as "not observed".
 *
 * macOS publishes no scroll-to-click preference, and AppKit has no API for
 * one, so there is deliberately no entry point that could report one. A
 * caller that wants to know what a scroll bar click does has to ask the
 * framework, not a defaults key. */
int32_t nogui_macos_preferred_scroller_style(void);

/* `NSProcessInfo.thermalState`, the system's own reported thermal state:
 * https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property
 * `NSProcessInfoThermalState` is nominal, fair, serious or critical:
 * https://developer.apple.com/documentation/foundation/nsprocessinfothermalstate
 *
 * Returns 0 nominal, 1 fair, 2 serious, 3 critical, or a NOGUI_MACOS_ERR_*
 * code. A state this SDK does not name is NOGUI_MACOS_ERR_UNAVAILABLE. This
 * is a state the OS reports; it is never derived from a temperature reading,
 * which is a sensor value and not the same fact. */
int32_t nogui_macos_thermal_state(void);

#ifdef __cplusplus
}
#endif

#endif /* NOGUI_MACOS_H */
