/*
 * The owned C ABI for the nogui AccessKit bridge, for every target.
 *
 * This is the ONLY header for this bridge. One crate, one archive, one set of
 * symbols, and a host compiles against this file whatever it is building for,
 * so the macOS and Windows extensions below are declared here beside the six
 * shared entry points rather than in per-platform headers that a build system
 * has to choose between.
 *
 * The header is deliberately narrow: it carries only the roles the nogui core
 * publishes and the action payloads the bridge marshals. Every pointer here is
 * borrowed for the duration of the call; no Rust allocation, string or object
 * ever crosses this boundary, and nothing in it is freed by C.
 *
 * Three things the platforms genuinely do differently are stated here rather
 * than hidden behind a value. None of them changes a signature.
 *
 *   * THE ADAPTER IS ATTACHED AFTER CONSTRUCTION on macOS and Windows, by
 *     `nogui_accesskit_bridge_set_view` and
 *     `nogui_accesskit_bridge_windows_attach`. AT-SPI attaches itself to a
 *     D-Bus connection in its constructor, so a handle from
 *     `nogui_accesskit_bridge_new` can already serve a tree there. A handle
 *     with no window is valid and inert, and every entry point says so.
 *   * `on_deactivate` IS ONLY EVER CALLED ON AT-SPI. It is the only one of the
 *     three platforms that reports a screen reader going away, so
 *     `nogui_accesskit_bridge_is_active` latches on macOS and Windows and only
 *     ever goes back to `false` on AT-SPI.
 *   * `nogui_accesskit_bridge_set_window_focused` and
 *     `nogui_accesskit_bridge_set_window_bounds` are forwarded on some targets
 *     and not others, for the reasons given on each.
 *
 * Two rules a host has to keep, both because AccessKit cannot be shut down:
 *
 *   * A callback must not call `nogui_accesskit_bridge_free` on its own thread.
 *     `free` waits out the callback already running, and the wait is a
 *     non-reentrant lock, so a host that freed itself from inside its own
 *     callback would hang there. A callback may enqueue, set a flag and
 *     return; the Zig host does exactly that. Free from the host's own
 *     teardown, on a different turn of the event loop.
 *   * The first update the platform ACCEPTS after it asks for the initial tree
 *     must be a FULL tree, so `has_tree_init` must be set on it. The bridge
 *     answers `request_initial_tree` with nothing, which makes the platform
 *     adapter install a placeholder and build the tree it serves out of the
 *     next update, which therefore has to carry the whole tree. Every request
 *     counts, not only the first: a reader that leaves and comes back asks
 *     again and finds nothing waiting for it, while the active flag reports
 *     the first attach and a later one identically, so a host cannot tell
 *     them apart by watching it.
 */
#ifndef NOGUI_ACCESSKIT_BRIDGE_H
#define NOGUI_ACCESSKIT_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif


/* AccessKit role discriminants. Only the roles the nogui core emits appear
 * here; an unknown value degrades to ROLE_UNKNOWN rather than guessing. */
typedef enum nogui_accesskit_role {
    NOGUI_ROLE_UNKNOWN = 0,
    NOGUI_ROLE_TEXT_RUN = 1,
    NOGUI_ROLE_LABEL = 3,
    NOGUI_ROLE_IMAGE = 4,
    NOGUI_ROLE_LIST_ITEM = 7,
    NOGUI_ROLE_GENERIC_CONTAINER = 14,
    NOGUI_ROLE_CHECK_BOX = 15,
    NOGUI_ROLE_RADIO_BUTTON = 16,
    NOGUI_ROLE_TEXT_INPUT = 17,
    NOGUI_ROLE_BUTTON = 18,
    NOGUI_ROLE_LIST = 24,
    NOGUI_ROLE_SWITCH = 29,
    NOGUI_ROLE_MULTILINE_TEXT_INPUT = 31,
    NOGUI_ROLE_SEARCH_INPUT = 32,
    NOGUI_ROLE_DIALOG = 66,
    NOGUI_ROLE_GROUP = 78,
    NOGUI_ROLE_LIST_BOX = 87,
    NOGUI_ROLE_PROGRESS_INDICATOR = 101,
    NOGUI_ROLE_RADIO_GROUP = 102,
    NOGUI_ROLE_SCROLL_VIEW = 108,
    NOGUI_ROLE_SLIDER = 113,
    NOGUI_ROLE_SPIN_BUTTON = 114,
    NOGUI_ROLE_TAB = 120,
    NOGUI_ROLE_TAB_LIST = 121,
    NOGUI_ROLE_TAB_PANEL = 122,
    NOGUI_ROLE_TOOLBAR = 127,
    NOGUI_ROLE_TOOLTIP = 128,
    NOGUI_ROLE_WINDOW = 133
} nogui_accesskit_role;

/* AccessKit action discriminants. */
typedef enum nogui_accesskit_action {
    NOGUI_ACTION_CLICK = 0,
    NOGUI_ACTION_FOCUS = 1,
    NOGUI_ACTION_BLUR = 2,
    NOGUI_ACTION_COLLAPSE = 3,
    NOGUI_ACTION_EXPAND = 4,
    NOGUI_ACTION_CUSTOM_ACTION = 5,
    NOGUI_ACTION_DECREMENT = 6,
    NOGUI_ACTION_INCREMENT = 7,
    NOGUI_ACTION_REPLACE_SELECTED_TEXT = 10,
    NOGUI_ACTION_SCROLL_DOWN = 11,
    NOGUI_ACTION_SCROLL_UP = 14,
    NOGUI_ACTION_SCROLL_INTO_VIEW = 15,
    NOGUI_ACTION_SET_TEXT_SELECTION = 18,
    NOGUI_ACTION_SET_VALUE = 20
} nogui_accesskit_action;

/* Node state flags.
 *
 * `NOGUI_FLAG_FOCUSED` is ADVISORY and is the one bit here that becomes no
 * node state. AccessKit 0.25.0 has no focused flag on a node: focus belongs to
 * the tree and travels in `nogui_accesskit_tree_update::focus`, which is what
 * reaches the platform. The bit stays in the layout because a host publishes a
 * widget's whole state mask in one field. */
enum {
    NOGUI_FLAG_HIDDEN = 1u << 0,
    NOGUI_FLAG_DISABLED = 1u << 1,
    NOGUI_FLAG_FOCUSED = 1u << 2,
    NOGUI_FLAG_SELECTED = 1u << 3,
    NOGUI_FLAG_EXPANDED = 1u << 4,
    NOGUI_FLAG_COLLAPSED = 1u << 5,
    NOGUI_FLAG_REQUIRED = 1u << 6,
    NOGUI_FLAG_INVALID = 1u << 7,
    NOGUI_FLAG_MODAL = 1u << 8,
    NOGUI_FLAG_MULTISELECTABLE = 1u << 9,
    NOGUI_FLAG_READ_ONLY = 1u << 10,
    NOGUI_FLAG_BUSY = 1u << 11,
    NOGUI_FLAG_LIVE_REGION = 1u << 12,
    NOGUI_FLAG_TOGGLED_ON = 1u << 13,
    NOGUI_FLAG_TOGGLED_OFF = 1u << 14,
    NOGUI_FLAG_TOGGLED_MIXED = 1u << 15,
    /* Selection capability is distinct from the current selected value.
     * A selectable row emits selected=false even when not selected. */
    NOGUI_FLAG_SELECTABLE = 1u << 16
};

/* Supported-action bitmask; bit N is NOGUI_ACTION_* == N. */
typedef uint32_t nogui_accesskit_action_set;

/* Action payload discriminants. */
typedef enum nogui_accesskit_action_data {
    NOGUI_ACTION_DATA_NONE = 0,
    NOGUI_ACTION_DATA_CUSTOM_ACTION = 1,
    NOGUI_ACTION_DATA_VALUE = 2,
    NOGUI_ACTION_DATA_NUMERIC_VALUE = 3,
    NOGUI_ACTION_DATA_SCROLL_TO_POINT = 6,
    NOGUI_ACTION_DATA_SET_SCROLL_OFFSET = 7,
    NOGUI_ACTION_DATA_TEXT_SELECTION = 8,
    /* One positioned range edit over a text owner. `value`/`value_len` carry
     * the replacement UTF-8 bytes, `anchor_index` is the inclusive LIVE
     * Unicode-scalar start and `focus_index` the exclusive end. `anchor_node`
     * and `focus_node` both name that same text owner, which is also
     * `target`. The indices are resolved against the host's LIVE model value,
     * never against the published `character_lengths` table. */
    NOGUI_ACTION_DATA_TEXT_RANGE = 9
} nogui_accesskit_action_data;

/* Logical pixels. The host adapter converts to physical pixels before
 * calling, so the bridge stays free of scale and origin policy. */
typedef struct nogui_accesskit_rect {
    double x0;
    double y0;
    double x1;
    double y1;
} nogui_accesskit_rect;

/* A named action. The name bytes are borrowed UTF-8 for the update call;
 * the SDK owns its copy. The action request returns this exact signed id. */
typedef struct nogui_accesskit_custom_action {
    int32_t id;
    const char* name;
    size_t name_len;
} nogui_accesskit_custom_action;

/* One borrowed node. Slices are valid only for the duration of the
 * accesskit_adapter_update call that receives them. */
typedef struct nogui_accesskit_node {
    uint64_t id;
    uint8_t role;
    uint32_t flags;
    nogui_accesskit_action_set actions;
    nogui_accesskit_rect bounds;
    const char* label;
    size_t label_len;
    const char* description;
    size_t description_len;
    /* NULL means no text value. Non-NULL with value_len == 0 means empty text.
     * Numeric values use numeric_value and has_numeric_value, not this slice. */
    const char* value;
    size_t value_len;
    const char* shortcut;
    size_t shortcut_len;
    const char* placeholder;
    size_t placeholder_len;
    double numeric_value;
    bool has_numeric_value;
    double min_numeric_value;
    bool has_min_numeric_value;
    double max_numeric_value;
    bool has_max_numeric_value;
    double numeric_step;
    bool has_numeric_step;
    size_t text_cursor;
    size_t text_selection_anchor;
    size_t text_selection_focus;
    bool has_text_selection;
    const uint8_t* character_lengths;
    size_t character_lengths_len;
    const float* character_positions;
    size_t character_positions_len;
    const float* character_widths;
    size_t character_widths_len;
    const uint64_t* children;
    size_t children_len;
    uint64_t active_descendant;
    const uint64_t* controls;
    size_t controls_len;
    const uint64_t* described_by;
    size_t described_by_len;
    const uint64_t* labelled_by;
    size_t labelled_by_len;
    const uint64_t* flow_to;
    size_t flow_to_len;
    uint64_t member_of;
    uint64_t row_count_set_size;
    size_t row_index_position;
    bool has_row_index_position;
    /* The node whose characters `text_cursor`, `text_selection_anchor` and
     * `text_selection_focus` are positions in, or 0 for the node itself.
     *
     * A text field's selection lives in the run it published, which is the
     * node the platform addresses offsets in. Naming that node keeps the
     * published selection in the same units as the character tables, so a
     * screen reader that reads the caret back and then sends a new one is
     * talking about the very characters it read.
     */
    uint64_t text_selection_owner;
    /* Hidden and disabled nodes carry no named actions. */
    const nogui_accesskit_custom_action* custom_actions;
    size_t custom_actions_len;
} nogui_accesskit_node;

/* One borrowed tree update.
 *
 * `has_tree_init` must be set on the first update and on any update that
 * re-declares the tree, INCLUDING the first update the platform accepts after
 * it asks for the initial tree: the bridge answers that request with nothing,
 * which makes the adapter install a placeholder and build the tree it serves
 * out of the next update. EVERY request needs one, not only the first, and
 * `nogui_accesskit_bridge_is_active` reports the first attach and a later one
 * identically, so it is not what decides.
 *
 * `focus` is the tree's focused node and is the only thing that reaches the
 * platform as focus; see `NOGUI_FLAG_FOCUSED`. */
typedef struct nogui_accesskit_tree_update {
    uint64_t root;
    bool has_tree_init;
    const char* toolkit_name;
    size_t toolkit_name_len;
    const char* toolkit_version;
    size_t toolkit_version_len;
    uint64_t focus;
    const nogui_accesskit_node* nodes;
    size_t nodes_len;
} nogui_accesskit_tree_update;

/* One owned request handed to the host. The payload slices are valid only
 * for the duration of the callback. */
typedef struct nogui_accesskit_request {
    uint8_t action;
    uint64_t target;
    uint8_t data;
    const char* value;
    size_t value_len;
    double numeric_value;
    int32_t custom_action;
    uint64_t anchor_node;
    size_t anchor_index;
    uint64_t focus_node;
    size_t focus_index;
} nogui_accesskit_request;

/* Return non-zero (1) when the host queue ACCEPTED the request for
 * asynchronous dispatch, and 0 when it refused it (full ring, oversize
 * payload, or a record it will not decode). Acceptance is queue acceptance
 * and never proof the model changed: the host applies the edit later, on its
 * own thread, and the caller must read the value back to know that.
 *
 * `uint8_t` and not a C `bool`, so the value is one explicit stable ABI
 * number on the Zig side with no representation assumption. */
typedef uint8_t (*nogui_accesskit_action_fn)(void* user, const nogui_accesskit_request* request);
typedef void (*nogui_accesskit_activation_fn)(void* user);
typedef void (*nogui_accesskit_deactivation_fn)(void* user);
/* Called synchronously by update, on its caller's thread, under the SDK's
 * activation lock. Return a non-null pointer to a full view of the SAME
 * snapshot, valid through update's return. Preflight storage: this cannot fail, allocate
 * or call any native adapter entry point. */
typedef const nogui_accesskit_tree_update*
    (*nogui_accesskit_full_tree_fn)(void* context);

typedef struct nogui_accesskit_bridge nogui_accesskit_bridge;

/* Every entry point is panic-contained: a Rust panic returns a null handle or
 * a false result instead of unwinding into C.
 *
 * `on_deactivate` is only ever called on AT-SPI, the one platform that
 * reports a screen reader going away. On macOS and Windows it is accepted and
 * dropped rather than stored, because a callback the platform can never
 * invoke is a claim it cannot back.
 *
 * Returns null only when a Rust panic is caught at the boundary, so a null
 * handle means the bridge is unavailable and every call on it is a no-op. */
nogui_accesskit_bridge* nogui_accesskit_bridge_new(
    void* user,
    nogui_accesskit_action_fn on_action,
    nogui_accesskit_activation_fn on_activate,
    nogui_accesskit_deactivation_fn on_deactivate
);

/* Tear the bridge down. On return no host callback is running and none can
 * start, so the caller owns `user` outright and may destroy it.
 *
 * This is a barrier, and a barrier must not be called from inside a host
 * callback on the same thread. */
void nogui_accesskit_bridge_free(nogui_accesskit_bridge* bridge);

/* True once a screen reader has asked the adapter for the tree.
 *
 * On AT-SPI this goes back to `false` when a screen reader detaches. On macOS
 * and Windows it latches once set, because neither platform reports a screen
 * reader leaving; the host's own activation callback is the authoritative
 * signal there, and this answers "has anything ever been published". */
bool nogui_accesskit_bridge_is_active(const nogui_accesskit_bridge* bridge);

/* Tell the platform whether the window itself has keyboard focus.
 *
 * Forwarded on AT-SPI and macOS. Accepted and NOT forwarded on Windows: the
 * Windows adapter already receives `WM_SETFOCUS`, `WM_KILLFOCUS`,
 * `WM_ENTERMENULOOP`, `WM_EXITMENULOOP`, `WM_ENTERSIZEMOVE` and
 * `WM_EXITSIZEMOVE` in the window procedure its own subclass installs, so the
 * window's focus state is already the platform's. No second copy is kept.
 *
 * On macOS this must be called on the main thread, like every other entry
 * point that touches the adapter; off the main thread it does nothing. */
void nogui_accesskit_bridge_set_window_focused(
    nogui_accesskit_bridge* bridge,
    bool focused
);

/* Publish the window's outer and client rectangles.
 *
 * An X11 fact, and only an X11 fact. A Wayland client cannot learn its toplevel
 * position and has to publish it, and AT-SPI wants both rectangles. On macOS
 * the adapter converts every node rectangle to screen coordinates from the
 * content view and the window's backing scale factor, and on Windows it reads
 * the client rectangle in the window procedure, so on both the call is
 * accepted and does nothing. No rectangle is invented for the two it is
 * handed. */
void nogui_accesskit_bridge_set_window_bounds(
    nogui_accesskit_bridge* bridge,
    nogui_accesskit_rect outer,
    nogui_accesskit_rect inner
);

/* Apply one tree update. Returns false only when the platform refused it.
 *
 * An update with no window attached is accepted and does nothing on macOS,
 * because the host publishes again once the view is attached and that update
 * is the first one a screen reader can see. On Windows it is REFUSED, because
 * a handle with no window has nothing to publish to and saying otherwise
 * would be a claim the caller cannot check. On AT-SPI there is always a window
 * and the call is always accepted; "no screen reader is attached" is the
 * platform's own answer and not a failure.
 *
 * The required supplier handles an activation arriving after the host prepared
 * an incremental record. The bridge calls it when the SDK requests a full
 * declaration, even if the prepared record is already full. No pointer is retained.
 *
 * On macOS this must be called on the main thread. */
bool nogui_accesskit_bridge_update(
    nogui_accesskit_bridge* bridge,
    const nogui_accesskit_tree_update* update,
    void* context,
    nogui_accesskit_full_tree_fn full_tree
);

/* macOS only. Attach the adapter to an `NSWindow`, borrowed for the call.
 *
 * `ns_window` is the `NSWindow` SDL published for the window. Its content view
 * must not already carry an AccessKit subclass, and calling this twice for one
 * bridge is refused rather than leaving the first view subclassed with no
 * adapter behind it. Returns false for a null argument, for a handle that
 * already has a view, when the thread is not the main one, and when the
 * platform refused the window.
 *
 * `view_is_focused` is the window's key state at the moment of attachment, and
 * it is APPLIED. The adapter starts out with its own view-focus state
 * hardcoded to false, and the first real tree is built from it, so a window
 * that is already key would otherwise publish a tree the platform believes is
 * unfocused until the host happened to publish again.
 *
 * Must be called on the main thread. A bridge with no view accepts updates and
 * reports itself inactive. */
bool nogui_accesskit_bridge_set_view(
    nogui_accesskit_bridge* bridge,
    void* ns_window,
    bool view_is_focused
);

/* macOS only. Add the `accessibilityFocusedUIElement` forwarder to an
 * `NSWindow` subclass, named by its Objective-C class name. SDL declares its
 * window class as `SDL3Window`. The class must still exist, and the caller
 * must be on the main thread. Returns false when the class name is null or not
 * valid UTF-8, when the thread is not the main one, and when the class does not
 * exist. The modification cannot be undone, so call it once at startup. */
bool nogui_accesskit_bridge_add_focus_forwarder(const char* class_name);

/* Windows only. Attach the adapter to the window SDL owns.
 *
 * `hwnd` is the `HWND` SDL published for the window, borrowed for the call.
 * Returns false when the handle is null, when an adapter is already attached,
 * or when the platform refused it, including when a Rust panic is caught at the
 * boundary.
 *
 * Call it on the thread that owns the window, and before the window is shown
 * for the first time: the adapter subclasses the window procedure to receive
 * `WM_GETOBJECT`, and it refuses a window that is already visible. */
bool nogui_accesskit_bridge_windows_attach(
    nogui_accesskit_bridge* bridge,
    void* hwnd
);

#ifdef __cplusplus
}
#endif

#endif /* NOGUI_ACCESSKIT_BRIDGE_H */
