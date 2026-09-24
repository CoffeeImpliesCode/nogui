/*
 * Owned C ABI for the nogui mobile adapters (E04 lifecycle, E05 semantics).
 *
 * This header is the WHOLE boundary between the Zig host and UIKit / the
 * Android framework. It declares no SDK type: every platform object crosses as
 * an opaque `void *` the caller obtained from SDL and never owns, and every
 * string is a NUL-terminated UTF-8 buffer the callee copies before returning.
 * Nothing here allocates memory the caller has to free, so a frame callback on
 * the host never has to unwind an Objective-C or JNI allocation.
 *
 * Four rules hold for every entry point:
 *
 *   1. UI THREAD. A function that touches UIKit, or that calls into the
 *      Android framework through JNI, checks the platform's own main-thread
 *      answer and returns NOGUI_MOBILE_ERR_THREAD when the caller is anywhere
 *      else. The Zig side marshals through SDL's main-thread queue, so a wrong
 *      thread is a visible defect instead of a crash inside a framework.
 *   2. TYPED FAILURE. A refusal is one of the NOGUI_MOBILE_ERR_* codes, never
 *      a silent success and never an uninitialised out-parameter.
 *   3. NO HIDDEN OWNERSHIP. A `void *` the caller passes in stays owned by the
 *      caller for the whole call. A `void *` the caller gets back is either a
 *      handle this header documents (created by a `_new`, released by the
 *      matching `_free`) or a borrowed SDK object.
 *   4. NO BORROWED PAYLOAD OUTLIVES THE CALL. Every string in a tree or a
 *      request is valid only for the duration of the call that receives it.
 *      The Zig adapter copies what it keeps into its own bounded ring.
 *
 * PLATFORM SPLIT. Exactly one of the two implementation files is compiled per
 * target: `nogui_ios.m` for iOS and `nogui_android.c` for Android. Both
 * implement the same shapes with their own symbol prefixes, so a build never
 * carries both and a missing platform is a link error at the point of use
 * rather than a silent no-op. A target with neither file compiled reports
 * NOGUI_MOBILE_ERR_UNAVAILABLE from every entry point rather than pretending.
 */
#ifndef NOGUI_MOBILE_H
#define NOGUI_MOBILE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Result codes. Zero is success; every negative value names a refusal. */
enum {
    NOGUI_MOBILE_OK = 0,
    /* The caller is not on the platform UI thread. */
    NOGUI_MOBILE_ERR_THREAD = -1,
    /* A required handle was NULL, or an argument was out of range. */
    NOGUI_MOBILE_ERR_ARGUMENT = -2,
    /* The platform does not offer this capability on this target. */
    NOGUI_MOBILE_ERR_UNAVAILABLE = -3,
    /* The platform refused a well-formed request. */
    NOGUI_MOBILE_ERR_REFUSED = -4,
    /* The framework raised an exception this shim caught. */
    NOGUI_MOBILE_ERR_FAULT = -5,
    /* An allocation failed inside the platform. */
    NOGUI_MOBILE_ERR_MEMORY = -6,
    /* The caller's buffer was too small; the required length is reported. */
    NOGUI_MOBILE_ERR_BUFFER = -7
};

/* Longest string any entry point copies into a platform object. A longer one
 * is refused with NOGUI_MOBILE_ERR_BUFFER rather than truncated into a
 * half-valid NSString or CharSequence. */
#define NOGUI_MOBILE_MAX_TEXT 65536
/* Bytes a text-selection action payload may carry. */
#define NOGUI_MOBILE_MAX_ACTION_TEXT 4096

/* ── E04: window and input lifecycle ────────────────────────────────────── */

/* Top-left window coordinates: UIKit logical points on iOS, physical device
 * pixels on Android. The Zig host converts Android facts using the observed
 * SDL logical/device PixelScale, never display DPI/density. */
typedef struct nogui_mobile_rect {
    double x0;
    double y0;
    double x1;
    double y1;
} nogui_mobile_rect;

/* Insets inward from the window bounds, in the platform units above.
 * Four zeroes is a measured answer, not an unknown measurement. */
typedef struct nogui_mobile_insets {
    double top;
    double left;
    double bottom;
    double right;
} nogui_mobile_insets;

/* Whether the window has a screen keyboard this platform can raise at all. */
typedef struct nogui_mobile_keyboard {
    /* NOGUI_MOBILE_OK only when the platform answered the question. */
    int32_t status;
    /* The platform has a screen keyboard for this window. */
    int32_t supported;
    /* It is on screen right now. */
    int32_t visible;
    /* The keyboard's own frame in window points, valid when `visible`. */
    nogui_mobile_rect frame;
} nogui_mobile_keyboard;

/* iOS. `ui_window` is the `UIWindow *` SDL published as
 * SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER; it stays owned by SDL. */
int32_t nogui_ios_window_safe_area(void *ui_window, nogui_mobile_insets *out);
int32_t nogui_ios_window_keyboard(void *ui_window, nogui_mobile_keyboard *out);
/* NOGUI_MOBILE_IOS_PRESSURE_* for the last application memory warning. */
int32_t nogui_ios_memory_pressure(void);

/* `env` is SDL_GetAndroidJNIEnv's thread-local JNIEnv. SDL_GetAndroidActivity
 * returns a caller-owned LOCAL reference; release it after these calls. */
int32_t nogui_android_window_insets(void *env, void *activity, nogui_mobile_insets *out);
int32_t nogui_android_window_keyboard(void *env, void *activity, nogui_mobile_keyboard *out);
/* Give a back request back to the system. The application's policy decides
 * whether one was consumed; this is the platform's own handling of a request
 * nothing consumed, which on Android moves the task to the background. It runs
 * on the UI thread and reports whether the framework did it, so a refusal is a
 * refusal rather than a deferral that silently did nothing. */
int32_t nogui_android_defer_back(void *env, void *activity);
/* NOGUI_MOBILE_ANDROID_TRIM_* for the last onTrimMemory level. */
int32_t nogui_android_memory_pressure(void);
void nogui_android_release_local(void *env, void *object);

enum {
    NOGUI_MOBILE_IOS_PRESSURE_NONE = 0,
    NOGUI_MOBILE_IOS_PRESSURE_WARNING = 1,
    NOGUI_MOBILE_IOS_PRESSURE_CRITICAL = 2
};

/* Android `ComponentCallbacks2.OnTrimMemory` levels, named rather than
 * numbered so a caller never has to remember the platform's own order. The
 * running levels are the ones an app can act on; the UI-hidden and background
 * levels are a lifecycle fact, not pressure, and map to NONE deliberately. */
enum {
    NOGUI_MOBILE_ANDROID_TRIM_NONE = 0,
    NOGUI_MOBILE_ANDROID_TRIM_RUNNING_LOW = 1,
    NOGUI_MOBILE_ANDROID_TRIM_RUNNING_CRITICAL = 2,
    NOGUI_MOBILE_ANDROID_TRIM_BACKGROUND = 3,
    NOGUI_MOBILE_ANDROID_TRIM_UI_HIDDEN = 4,
    NOGUI_MOBILE_ANDROID_TRIM_COMPLETE = 5
};

/* ── E05: native semantics ──────────────────────────────────────────────── */

/* Role discriminants. These are the AccessKit wire values the nogui core
 * already publishes, so a mobile adapter forwards the core's own value rather
 * than inventing a second table it would have to keep in step. */
enum {
    NOGUI_MOBILE_ROLE_UNKNOWN = 0,
    NOGUI_MOBILE_ROLE_TEXT_RUN = 1,
    NOGUI_MOBILE_ROLE_LABEL = 3,
    NOGUI_MOBILE_ROLE_IMAGE = 4,
    NOGUI_MOBILE_ROLE_LIST_ITEM = 7,
    NOGUI_MOBILE_ROLE_GENERIC_CONTAINER = 14,
    NOGUI_MOBILE_ROLE_CHECK_BOX = 15,
    NOGUI_MOBILE_ROLE_RADIO_BUTTON = 16,
    NOGUI_MOBILE_ROLE_TEXT_INPUT = 17,
    NOGUI_MOBILE_ROLE_BUTTON = 18,
    NOGUI_MOBILE_ROLE_LIST = 24,
    NOGUI_MOBILE_ROLE_SWITCH = 29,
    NOGUI_MOBILE_ROLE_MULTILINE_TEXT_INPUT = 31,
    NOGUI_MOBILE_ROLE_SEARCH_INPUT = 32,
    NOGUI_MOBILE_ROLE_DIALOG = 66,
    NOGUI_MOBILE_ROLE_GROUP = 78,
    NOGUI_MOBILE_ROLE_LIST_BOX = 87,
    NOGUI_MOBILE_ROLE_PROGRESS_INDICATOR = 101,
    NOGUI_MOBILE_ROLE_RADIO_GROUP = 102,
    NOGUI_MOBILE_ROLE_SCROLL_VIEW = 108,
    NOGUI_MOBILE_ROLE_SLIDER = 113,
    NOGUI_MOBILE_ROLE_SPIN_BUTTON = 114,
    NOGUI_MOBILE_ROLE_TAB = 120,
    NOGUI_MOBILE_ROLE_TAB_LIST = 121,
    NOGUI_MOBILE_ROLE_TAB_PANEL = 122,
    NOGUI_MOBILE_ROLE_TOOLBAR = 127,
    NOGUI_MOBILE_ROLE_TOOLTIP = 128,
    NOGUI_MOBILE_ROLE_WINDOW = 133
};

/* Node states. Authored in the core; the bit layout is the bridge's. */
enum {
    NOGUI_MOBILE_STATE_HIDDEN = 1u << 0,
    NOGUI_MOBILE_STATE_DISABLED = 1u << 1,
    NOGUI_MOBILE_STATE_FOCUSED = 1u << 2,
    NOGUI_MOBILE_STATE_SELECTED = 1u << 3,
    NOGUI_MOBILE_STATE_EXPANDED = 1u << 4,
    NOGUI_MOBILE_STATE_COLLAPSED = 1u << 5,
    NOGUI_MOBILE_STATE_REQUIRED = 1u << 6,
    NOGUI_MOBILE_STATE_INVALID = 1u << 7,
    NOGUI_MOBILE_STATE_MODAL = 1u << 8,
    NOGUI_MOBILE_STATE_MULTISELECTABLE = 1u << 9,
    NOGUI_MOBILE_STATE_READ_ONLY = 1u << 10,
    NOGUI_MOBILE_STATE_BUSY = 1u << 11,
    NOGUI_MOBILE_STATE_LIVE_REGION = 1u << 12,
    NOGUI_MOBILE_STATE_CHECKED_ON = 1u << 13,
    NOGUI_MOBILE_STATE_CHECKED_OFF = 1u << 14,
    NOGUI_MOBILE_STATE_CHECKED_MIXED = 1u << 15
};

/* Action discriminants, and the supported-action bitmask. Bit N of the mask is
 * NOGUI_MOBILE_ACTION_* == N, which is also the core's own Action value, so the
 * mapping is the identity on the low 16 bits and there is nothing to translate
 * in either direction. */
enum {
    NOGUI_MOBILE_ACTION_CLICK = 0,
    NOGUI_MOBILE_ACTION_FOCUS = 1,
    NOGUI_MOBILE_ACTION_BLUR = 2,
    NOGUI_MOBILE_ACTION_COLLAPSE = 3,
    NOGUI_MOBILE_ACTION_EXPAND = 4,
    NOGUI_MOBILE_ACTION_CUSTOM = 5,
    NOGUI_MOBILE_ACTION_DECREMENT = 6,
    NOGUI_MOBILE_ACTION_INCREMENT = 7,
    NOGUI_MOBILE_ACTION_REPLACE_SELECTED_TEXT = 10,
    NOGUI_MOBILE_ACTION_SCROLL_DOWN = 11,
    NOGUI_MOBILE_ACTION_SCROLL_UP = 14,
    NOGUI_MOBILE_ACTION_SCROLL_INTO_VIEW = 15,
    NOGUI_MOBILE_ACTION_SET_TEXT_SELECTION = 18,
    NOGUI_MOBILE_ACTION_SET_VALUE = 20
};

/* One named action the app attached to a node. `id` is the app's own
 * identifier and `name` is what a screen reader announces, so a virtualized row
 * selection reaches the app's model through a name the user can hear. */
typedef struct nogui_mobile_custom_action {
    int32_t id;
    const char *name;
    size_t name_len;
} nogui_mobile_custom_action;

/* Action payload discriminants. These are the same values the AccessKit
 * bridge already uses, so the Zig side reuses one `NativeData` for both. */
enum {
    NOGUI_MOBILE_DATA_NONE = 0,
    NOGUI_MOBILE_DATA_CUSTOM_ACTION = 1,
    NOGUI_MOBILE_DATA_VALUE = 2,
    NOGUI_MOBILE_DATA_NUMERIC_VALUE = 3,
    NOGUI_MOBILE_DATA_SCROLL_TO_POINT = 6,
    NOGUI_MOBILE_DATA_SET_SCROLL_OFFSET = 7,
    NOGUI_MOBILE_DATA_TEXT_SELECTION = 8
};

/* `checked` for a node whose kind cannot be toggled. */
#define NOGUI_MOBILE_CHECKED_NOT_TOGGLEABLE (-1)

/* One node. Slices are borrowed only during update and copied by the shim.
 * Bounds use UIKit points on iOS and physical SDL-window pixels on Android.
 *
 * A node the core refuses to act on — hidden or disabled — publishes an empty
 * action mask, so a screen reader is offered nothing rather than an action the
 * app would reject.
 *
 * STABLE IDENTITY. A node carries TWO identities, and the difference is the
 * whole point:
 *
 *   * `semantic_id` is the core's own `NodeId`: a hash of a live stable owner
 *     and a structural scope. It survives a reorder, a move and a re-layout,
 *     and it changes when the owner does.
 *   * `native_id` is what the platform is allowed to hold. It is allocated once
 *     per semantic identity and is NEVER REUSED for a different identity while
 *     this bridge lives, so an id the platform kept from an earlier tree can
 *     only ever resolve to the node it was issued for — or to nothing, once
 *     that node is gone.
 *
 * A platform addresses an accessibility node by an integer id and hands that
 * integer back on every later call, so the integer has to be a name rather than
 * a position. A dense index would not be: an index that is still in range after
 * a removal would address whatever node moved into it, and a screen reader
 * would drive the wrong control.
 *
 * `parent`, `children` and `member_of` ARE dense indices into the same update,
 * and they stay that way: they are internal to the shim, the platform never
 * sees them, and a reorder among them costs nothing because the identities the
 * platform holds are elsewhere. */
typedef struct nogui_mobile_node {
    /* The core's stable identity, carried so the shim can key its own map. */
    uint64_t semantic_id;
    /* Positive <=INT32_MAX, stable, never reused for a different identity. */
    uint64_t native_id;
    /* Dense parent index, or `NOGUI_MOBILE_NO_INDEX`. */
    uint64_t parent;
    uint8_t role;
    uint32_t states;
    uint32_t actions;
    nogui_mobile_rect bounds;
    const char *label;
    size_t label_len;
    const char *value;
    size_t value_len;
    const char *hint;
    size_t hint_len;
    const char *placeholder;
    size_t placeholder_len;
    /* The editable text of a text run, or NULL for a node with no run. */
    const char *text;
    size_t text_len;
    /* CHARACTER offsets into `text`, or -1 when the run published no character
     * table and is therefore not addressable there. */
    int64_t text_selection_anchor;
    int64_t text_selection_focus;
    int32_t multiline;
    int32_t checked;
    double numeric_value;
    int32_t has_numeric_value;
    double min_numeric_value;
    double max_numeric_value;
    int32_t has_numeric_range;
    /* Dense indices into this update. Internal to the shim. */
    const uint64_t *children;
    size_t children_len;
    /* Dense list index for a virtualized row, or `NOGUI_MOBILE_NO_INDEX`. */
    uint64_t member_of;
    uint32_t set_position;
    uint32_t set_size;
    int32_t has_set;
    /* The named actions the app attached to this node, in the app's order. A
     * platform that can announce a named action is given these; a platform
     * that cannot still receives the built-in mask unchanged. */
    const nogui_mobile_custom_action *custom_actions;
    size_t custom_actions_len;
} nogui_mobile_node;

/* Native ids are positive, stable names assigned by the Zig adapter. */
#define NOGUI_MOBILE_NO_NODE ((uint64_t)0)
/* Dense index zero is valid; absence must not alias it. */
#define NOGUI_MOBILE_NO_INDEX UINT64_MAX

/* One tree update. `has_tree_init` must be set on the first update and on any
 * update that re-declares the tree, which is what makes a re-attached screen
 * reader see the whole tree rather than an empty one. */
typedef struct nogui_mobile_tree {
    /* Native ids, not dense indices: the root has to keep its identity across
     * an update that reordered the array. */
    uint64_t root;
    int32_t has_tree_init;
    const char *toolkit;
    size_t toolkit_len;
    uint64_t focus;
    const nogui_mobile_node *nodes;
    size_t nodes_len;
} nogui_mobile_tree;

/* One action the screen reader performed. Every slice is valid only for the
 * duration of the callback. The callback runs on the platform's accessibility
 * thread, so it must copy and return. */
typedef struct nogui_mobile_request {
    uint8_t action;
    /* The `native_id` the request was addressed to. The shim resolves it
     * through its own map, so an id whose node is gone produces no request at
     * all rather than a request aimed at whatever replaced it. */
    uint64_t target;
    uint8_t data;
    /* UTF-8. The shim has already converted whatever the platform speaks, so
     * the Zig side never sees a platform encoding. */
    const char *value;
    size_t value_len;
    double numeric_value;
    int32_t custom_action;
    /* CHARACTER indices, not byte offsets. The core addresses text in UTF-8
     * bytes and both mobile platforms address it in characters, so the
     * conversion belongs to the Zig side and happens in both directions. */
    int64_t anchor_index;
    int64_t focus_index;
} nogui_mobile_request;

typedef void (*nogui_mobile_action_fn)(void *user, const nogui_mobile_request *request);
typedef void (*nogui_mobile_dirty_fn)(void *user);

typedef struct nogui_mobile_bridge nogui_mobile_bridge;

/* iOS. The bridge owns a `UIAccessibilityElement` subclass per published node
 * and installs them as the window's real accessibility elements, so VoiceOver
 * reads real UIKit objects. */
nogui_mobile_bridge *nogui_ios_a11y_new(
    void *user,
    nogui_mobile_action_fn on_action,
    nogui_mobile_dirty_fn on_dirty
);
void nogui_ios_a11y_free(nogui_mobile_bridge *bridge);
/* `ui_window` is borrowed from SDL and must outlive the bridge's attachment. */
int32_t nogui_ios_a11y_attach(nogui_mobile_bridge *bridge, void *ui_window);
void nogui_ios_a11y_detach(nogui_mobile_bridge *bridge);
int32_t nogui_ios_a11y_update(nogui_mobile_bridge *bridge, const nogui_mobile_tree *update);
/* 1 once VoiceOver has asked the adapter for the tree. */
int32_t nogui_ios_a11y_is_active(const nogui_mobile_bridge *bridge);
int32_t nogui_ios_a11y_set_window_focused(nogui_mobile_bridge *bridge, int32_t focused);
/* Bind an app-owned UITextInput mirror to a live semantic text node. The shim
 * installs a forwarding delegate proxy; the consumer must not also forward the
 * same edit to the core. Published text/selection remain authoritative.
 * The borrowed input must outlive the binding; unbind before destroying it. */
int32_t nogui_ios_a11y_bind_text_input(nogui_mobile_bridge *bridge, void *ui_text_input, uint64_t native_id);
void nogui_ios_a11y_unbind_text_input(nogui_mobile_bridge *bridge);
/* `UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification)`.
 * NOGUI_MOBILE_ERR_UNAVAILABLE when the system declined to post it. */
int32_t nogui_ios_a11y_layout_changed(nogui_mobile_bridge *bridge);

/* Android. The bridge owns a real `AccessibilityNodeProvider`; the Java shim
 * in `NoguiAccessibilityProvider.java` is the object the framework instantiates
 * and every node it hands back is a real `AccessibilityNodeInfo`. */
nogui_mobile_bridge *nogui_android_a11y_new(
    void *user,
    nogui_mobile_action_fn on_action,
    nogui_mobile_dirty_fn on_dirty
);
void nogui_android_a11y_free(nogui_mobile_bridge *bridge);
/* Env is thread-local. Activity is borrowed during this call only: attachment
 * creates its own global references before the caller releases the local. */
int32_t nogui_android_a11y_attach(nogui_mobile_bridge *bridge, void *env, void *activity);
void nogui_android_a11y_detach(nogui_mobile_bridge *bridge);
int32_t nogui_android_a11y_update(nogui_mobile_bridge *bridge, const nogui_mobile_tree *update);
int32_t nogui_android_a11y_is_active(const nogui_mobile_bridge *bridge);
int32_t nogui_android_a11y_set_window_focused(nogui_mobile_bridge *bridge, int32_t focused);
int32_t nogui_android_a11y_layout_changed(nogui_mobile_bridge *bridge);

#ifdef __cplusplus
}
#endif

#endif /* NOGUI_MOBILE_H */
