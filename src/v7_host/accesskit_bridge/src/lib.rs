//! Narrow, panic-contained C ABI bridge from nogui to AccessKit.
//!
//! ONE crate, ONE archive, THREE platform adapters. The record layouts, the
//! action discriminants, the tree-update shape, the gate and the six common
//! entry points are written once, here, because
//! `include/nogui_accesskit_bridge.h` describes them once and a host compiles
//! against that header on every target. `platform` holds the three adapters
//! that differ, and `cfg` picks exactly one of them; a target with none is a
//! compile error rather than a bridge that exports the ABI and serves nobody.
//!
//! The platforms genuinely differ, and each difference is a fact about the
//! platform rather than a choice made here:
//!
//!   * THE ADAPTER NEEDS A WINDOW ON macOS AND WINDOWS. `accesskit_macos`
//!     builds its adapter around the content view of an `NSWindow` and
//!     `accesskit_windows` around one `HWND`, so both are attached after
//!     construction, by `nogui_accesskit_bridge_set_view` and
//!     `nogui_accesskit_bridge_windows_attach`. `accesskit_unix` attaches
//!     itself to a D-Bus connection in its constructor, so on that target
//!     `new` returns a handle that can already serve a tree.
//!   * ONLY AT-SPI REPORTS A SCREEN READER GOING AWAY. So only
//!     `accesskit_unix` takes a deactivation handler and only there does
//!     `nogui_accesskit_bridge_is_active` ever go back to false. On the other
//!     two it latches, which is stated in the header rather than hidden.
//!   * WINDOW BOUNDS ARE AN X11 FACT. A Wayland client cannot learn its
//!     toplevel position, AT-SPI wants the outer and client rectangles, and
//!     the AX and UI Automation adapters derive the window's own rectangle
//!     from the view and the window procedure respectively. So the bounds
//!     entry point forwards on AT-SPI and is a documented no-op elsewhere.
//!
//! Rules, in both directions:
//!   * Everything C passes in is BORROWED for the duration of the call. The
//!     bridge copies what it keeps, so no C pointer outlives the call.
//!   * Everything the bridge passes out is owned by the bridge and freed with
//!     it. No Rust object, allocation or `Box` is ever visible to C.
//!   * Every `extern "C"` entry point catches panics, so a Rust failure
//!     becomes a null handle or a `false` result instead of unwinding into a
//!     foreign frame.
//!   * `nogui_accesskit_bridge_free` is a barrier and not a request. AccessKit
//!     cannot be shut down, so it keeps the handler objects and can still call
//!     them after `free` returns. Every callback therefore takes a gate that
//!     `free` closes, which stops the next callback and waits out the one
//!     already running. The caller may destroy the host the moment `free`
//!     returns. See `teardown` for what AccessKit offers and what it does not.
//!   * A host callback therefore MUST NOT call `nogui_accesskit_bridge_free`,
//!     or any other entry point that takes the gate, on the same thread. The
//!     gate is not reentrant and a host that frees itself from inside its own
//!     callback deadlocks on it. The Zig host satisfies this: its callbacks
//!     only enqueue a request or set a flag
//!     (`AdapterCallbacks` in `src/v7_host/accessibility.zig`).
//!
//! Every initial-tree request requires a complete declaration. The bridge
//! answers `request_initial_tree` with `None`, so the SDK initializes from its
//! next update factory. That factory selects the host's full-tree supplier
//! under the SDK's activation lock, including requests arriving after the host
//! prepared a delta. The supplier reserves nothing and makes no native calls.
//! Rust marshalling runs afterward, on the publisher thread under that lock.
//! Ordinary frames still convert only their delta. No second node cache or
//! stale full-tree fallback is kept.

#![deny(unsafe_op_in_unsafe_fn)]

use accesskit::{
    Action, ActionData, ActionHandler, ActionRequest, ActivationHandler, CustomAction, Node,
    NodeId, Rect, Role, TextPosition, TextSelection, Toggled, TreeId, TreeInfo, TreeUpdate,
};
#[cfg(all(unix, not(target_os = "macos")))]
use accesskit_atspi_common::{EditableTextHandlerNoMut, EditableTextRequest};
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, MutexGuard};

mod platform;
mod teardown;

use teardown::Gate;

// --- C ABI types. These mirror include/nogui_accesskit_bridge.h exactly. ---

#[repr(C)]
pub struct NoguiRect {
    pub x0: f64,
    pub y0: f64,
    pub x1: f64,
    pub y1: f64,
}

#[repr(C)]
pub struct NoguiNode {
    pub id: u64,
    pub role: u8,
    pub flags: u32,
    pub actions: u32,
    pub bounds: NoguiRect,
    pub label: *const u8,
    pub label_len: usize,
    pub description: *const u8,
    pub description_len: usize,
    pub value: *const u8,
    pub value_len: usize,
    pub shortcut: *const u8,
    pub shortcut_len: usize,
    pub placeholder: *const u8,
    pub placeholder_len: usize,
    pub numeric_value: f64,
    pub has_numeric_value: bool,
    pub min_numeric_value: f64,
    pub has_min_numeric_value: bool,
    pub max_numeric_value: f64,
    pub has_max_numeric_value: bool,
    pub numeric_step: f64,
    pub has_numeric_step: bool,
    pub text_cursor: usize,
    pub text_selection_anchor: usize,
    pub text_selection_focus: usize,
    pub has_text_selection: bool,
    pub character_lengths: *const u8,
    pub character_lengths_len: usize,
    pub character_positions: *const f32,
    pub character_positions_len: usize,
    pub character_widths: *const f32,
    pub character_widths_len: usize,
    pub children: *const u64,
    pub children_len: usize,
    pub active_descendant: u64,
    pub controls: *const u64,
    pub controls_len: usize,
    pub described_by: *const u64,
    pub described_by_len: usize,
    pub labelled_by: *const u64,
    pub labelled_by_len: usize,
    pub flow_to: *const u64,
    pub flow_to_len: usize,
    pub member_of: u64,
    pub row_count_set_size: u64,
    pub row_index_position: usize,
    pub has_row_index_position: bool,
    /// The node the selection's character indices are positions in, or 0
    /// for the node itself. See `nogui_accesskit_node` in the header.
    pub text_selection_owner: u64,
    /// The named actions this node publishes, in the order a screen reader
    /// offers them. The host publishes none on a hidden or disabled node. See
    /// `nogui_accesskit_node` in the header.
    pub custom_actions: *const NoguiCustomAction,
    pub custom_actions_len: usize,
}

/// One named action. The name bytes are borrowed UTF-8 for the duration of
/// the update call; `accesskit::CustomAction` owns the copy that outlives it.
#[repr(C)]
pub struct NoguiCustomAction {
    pub id: i32,
    pub name: *const u8,
    pub name_len: usize,
}

#[repr(C)]
pub struct NoguiTreeUpdate {
    pub root: u64,
    pub has_tree_init: bool,
    pub toolkit_name: *const u8,
    pub toolkit_name_len: usize,
    pub toolkit_version: *const u8,
    pub toolkit_version_len: usize,
    pub focus: u64,
    pub nodes: *const NoguiNode,
    pub nodes_len: usize,
}

#[repr(C)]
pub struct NoguiRequest {
    pub action: u8,
    pub target: u64,
    pub data: u8,
    pub value: *const u8,
    pub value_len: usize,
    pub numeric_value: f64,
    pub custom_action: i32,
    pub anchor_node: u64,
    pub anchor_index: usize,
    pub focus_node: u64,
    pub focus_index: usize,
}

/// Returns the host queue's acceptance: 1 accepted for asynchronous dispatch,
/// 0 refused. Never proof the model changed; the host applies the request
/// later, on its own thread.
pub type ActionFn =
    unsafe extern "C" fn(user: *mut std::ffi::c_void, request: *const NoguiRequest) -> u8;
pub type ActivationFn = unsafe extern "C" fn(user: *mut std::ffi::c_void);
pub type DeactivationFn = unsafe extern "C" fn(user: *mut std::ffi::c_void);

const NOGUI_ACTION_DATA_NONE: u8 = 0;
const NOGUI_ACTION_DATA_CUSTOM_ACTION: u8 = 1;
const NOGUI_ACTION_DATA_VALUE: u8 = 2;
const NOGUI_ACTION_DATA_NUMERIC_VALUE: u8 = 3;
const NOGUI_ACTION_DATA_SCROLL_TO_POINT: u8 = 6;
const NOGUI_ACTION_DATA_SET_SCROLL_OFFSET: u8 = 7;
const NOGUI_ACTION_DATA_TEXT_SELECTION: u8 = 8;
const NOGUI_ACTION_DATA_TEXT_RANGE: u8 = 9;
const NOGUI_ACTION_REPLACE_SELECTED_TEXT: u8 = 10;

const FLAG_HIDDEN: u32 = 1 << 0;
const FLAG_DISABLED: u32 = 1 << 1;

/// The one bit of the node state mask that AccessKit gives no node-level
/// meaning to, and it is here because the host emits it, not because the
/// bridge can act on it.
///
/// `accesskit 0.25.0` gives `Node` no `Focused` property at all, and carries
/// focus on the tree instead: `TreeUpdate::focus` (`src/lib.rs:3256`). So this
/// bit is read from the record and deliberately not turned into a node state,
/// and `nogui_accesskit_tree_update::focus` is what reaches the platform. It
/// stays in the bit layout because the host publishes a widget's whole state
/// mask in one field.
const FLAG_FOCUSED: u32 = 1 << 2;
const FLAG_SELECTED: u32 = 1 << 3;
const FLAG_EXPANDED: u32 = 1 << 4;
const FLAG_COLLAPSED: u32 = 1 << 5;
const FLAG_REQUIRED: u32 = 1 << 6;
const FLAG_INVALID: u32 = 1 << 7;
const FLAG_MODAL: u32 = 1 << 8;
const FLAG_MULTISELECTABLE: u32 = 1 << 9;
const FLAG_READ_ONLY: u32 = 1 << 10;
const FLAG_BUSY: u32 = 1 << 11;
const FLAG_LIVE_REGION: u32 = 1 << 12;
const FLAG_TOGGLED_ON: u32 = 1 << 13;
const FLAG_TOGGLED_OFF: u32 = 1 << 14;
const FLAG_TOGGLED_MIXED: u32 = 1 << 15;
const FLAG_SELECTABLE: u32 = 1 << 16;

fn role_of(value: u8) -> Role {
    match value {
        1 => Role::TextRun,
        3 => Role::Label,
        4 => Role::Image,
        7 => Role::ListItem,
        14 => Role::GenericContainer,
        15 => Role::CheckBox,
        16 => Role::RadioButton,
        17 => Role::TextInput,
        18 => Role::Button,
        24 => Role::List,
        29 => Role::Switch,
        31 => Role::MultilineTextInput,
        32 => Role::SearchInput,
        66 => Role::Dialog,
        78 => Role::Group,
        87 => Role::ListBox,
        101 => Role::ProgressIndicator,
        102 => Role::RadioGroup,
        108 => Role::ScrollView,
        113 => Role::Slider,
        114 => Role::SpinButton,
        120 => Role::Tab,
        121 => Role::TabList,
        122 => Role::TabPanel,
        127 => Role::Toolbar,
        128 => Role::Tooltip,
        133 => Role::Window,
        _ => Role::Unknown,
    }
}

fn action_of(value: u8) -> Option<Action> {
    match value {
        0 => Some(Action::Click),
        1 => Some(Action::Focus),
        2 => Some(Action::Blur),
        3 => Some(Action::Collapse),
        4 => Some(Action::Expand),
        5 => Some(Action::CustomAction),
        6 => Some(Action::Decrement),
        7 => Some(Action::Increment),
        10 => Some(Action::ReplaceSelectedText),
        11 => Some(Action::ScrollDown),
        14 => Some(Action::ScrollUp),
        15 => Some(Action::ScrollIntoView),
        18 => Some(Action::SetTextSelection),
        20 => Some(Action::SetValue),
        _ => None,
    }
}

/// Borrow `len` bytes at `ptr` as UTF-8. Invalid UTF-8 is dropped rather than
/// replaced: a screen reader must never announce a mangled name.
unsafe fn borrow_str<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    if ptr.is_null() || len == 0 {
        return None;
    }
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(ptr, len) }).ok()
}

/// Borrow `len` bytes at `ptr` as a VALUE, where an empty value and an absent
/// one are different values.
///
/// `accesskit_consumer` unwraps the value of the run that carries a text
/// field's characters rather than reading an optional, so a host that cleared
/// a field and published the empty string has to have that reach AccessKit as
/// `Some("")`. The pointer carries the difference: null for a node with no
/// value, non-null for one that has a value, and only the length separates an
/// empty value from characters. `borrow_str` reads every empty string as
/// absent, which is right for a label and wrong here.
unsafe fn borrow_value_str<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    if len == 0 {
        return Some("");
    }
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(ptr, len) }).ok()
}

unsafe fn borrow_ids<'a>(ptr: *const u64, len: usize) -> Option<&'a [u64]> {
    if ptr.is_null() || len == 0 {
        return None;
    }
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// Translate the named actions a node published into the SDK's own records.
///
/// The ids cross the boundary unchanged, because the request that comes back
/// carries the same signed id, and every name is COPIED into an owned `String`
/// so no C pointer outlives the call. Empty names remain distinct descriptors,
/// with their signed ids and positions unchanged.
unsafe fn custom_actions_of(ptr: *const NoguiCustomAction, len: usize) -> Vec<CustomAction> {
    if ptr.is_null() || len == 0 {
        return Vec::new();
    }
    let borrowed = unsafe { std::slice::from_raw_parts(ptr, len) };
    let mut out = Vec::with_capacity(borrowed.len());
    for entry in borrowed {
        let name = unsafe { borrow_str(entry.name, entry.name_len) }.unwrap_or("");
        out.push(CustomAction {
            id: entry.id,
            description: name.to_owned(),
        });
    }
    out
}

unsafe fn node_from_c(source: &NoguiNode) -> (NodeId, Node) {
    let mut node = Node::new(role_of(source.role));
    node.set_bounds(Rect {
        x0: source.bounds.x0,
        y0: source.bounds.y0,
        x1: source.bounds.x1,
        y1: source.bounds.y1,
    });
    if let Some(text) = unsafe { borrow_str(source.label, source.label_len) } {
        node.set_label(text);
    }
    if let Some(text) = unsafe { borrow_str(source.description, source.description_len) } {
        node.set_description(text);
    }
    if let Some(text) = unsafe { borrow_value_str(source.value, source.value_len) } {
        node.set_value(text);
    }
    if let Some(text) = unsafe { borrow_str(source.shortcut, source.shortcut_len) } {
        node.set_keyboard_shortcut(text);
    }
    if let Some(text) = unsafe { borrow_str(source.placeholder, source.placeholder_len) } {
        node.set_placeholder(text);
    }
    if source.has_numeric_value {
        node.set_numeric_value(source.numeric_value);
    }
    if source.has_min_numeric_value {
        node.set_min_numeric_value(source.min_numeric_value);
    }
    if source.has_max_numeric_value {
        node.set_max_numeric_value(source.max_numeric_value);
    }
    if source.has_numeric_step {
        node.set_numeric_value_step(source.numeric_step);
    }

    let flags = source.flags;
    if flags & FLAG_HIDDEN != 0 {
        node.set_hidden();
    }
    if flags & FLAG_DISABLED != 0 {
        node.set_disabled();
    }
    if flags & FLAG_FOCUSED != 0 {
        // AccessKit carries focus through the tree update, not a node flag.
    }
    if flags & (FLAG_SELECTED | FLAG_SELECTABLE) != 0 {
        node.set_selected(flags & FLAG_SELECTED != 0);
    }
    if flags & FLAG_EXPANDED != 0 {
        node.set_expanded(true);
    }
    if flags & FLAG_COLLAPSED != 0 {
        node.set_expanded(false);
    }
    if flags & FLAG_REQUIRED != 0 {
        node.set_required();
    }
    if flags & FLAG_INVALID != 0 {
        node.set_invalid(accesskit::Invalid::True);
    }
    if flags & FLAG_MODAL != 0 {
        node.set_modal();
    }
    if flags & FLAG_MULTISELECTABLE != 0 {
        node.set_multiselectable();
    }
    if flags & FLAG_READ_ONLY != 0 {
        node.set_read_only();
    }
    if flags & FLAG_BUSY != 0 {
        node.set_busy();
    }
    if flags & FLAG_LIVE_REGION != 0 {
        node.set_live(accesskit::Live::Polite);
    }
    if flags & FLAG_TOGGLED_ON != 0 {
        node.set_toggled(Toggled::True);
    } else if flags & FLAG_TOGGLED_OFF != 0 {
        node.set_toggled(Toggled::False);
    } else if flags & FLAG_TOGGLED_MIXED != 0 {
        node.set_toggled(Toggled::Mixed);
    }

    for bit in 0..22u8 {
        if source.actions & (1u32 << bit) == 0 {
            continue;
        }
        if let Some(action) = action_of(bit) {
            node.add_action(action);
        }
    }

    // The named actions carry their own ids, so the request that performs one
    // names the descriptor directly. A node that published none leaves the
    // property unset rather than set to an empty list: AccessKit reads both as
    // "no named actions", and not calling the setter allocates nothing.
    let named = unsafe { custom_actions_of(source.custom_actions, source.custom_actions_len) };
    if !named.is_empty() {
        node.set_custom_actions(named);
    }

    if let Some(ids) = unsafe { borrow_ids(source.children, source.children_len) } {
        node.set_children(ids.iter().map(|id| NodeId(*id)).collect::<Vec<_>>());
    }
    if source.active_descendant != 0 {
        node.set_active_descendant(NodeId(source.active_descendant));
    }
    if let Some(ids) = unsafe { borrow_ids(source.controls, source.controls_len) } {
        node.set_controls(ids.iter().map(|id| NodeId(*id)).collect::<Vec<_>>());
    }
    if let Some(ids) = unsafe { borrow_ids(source.described_by, source.described_by_len) } {
        node.set_described_by(ids.iter().map(|id| NodeId(*id)).collect::<Vec<_>>());
    }
    if let Some(ids) = unsafe { borrow_ids(source.labelled_by, source.labelled_by_len) } {
        node.set_labelled_by(ids.iter().map(|id| NodeId(*id)).collect::<Vec<_>>());
    }
    if let Some(ids) = unsafe { borrow_ids(source.flow_to, source.flow_to_len) } {
        node.set_flow_to(ids.iter().map(|id| NodeId(*id)).collect::<Vec<_>>());
    }
    if source.member_of != 0 {
        node.set_member_of(NodeId(source.member_of));
    }
    if source.has_row_index_position {
        node.set_position_in_set(source.row_index_position);
        node.set_size_of_set(source.row_count_set_size as usize);
    }

    if source.has_text_selection {
        // The selection's endpoints name the node whose characters they are
        // positions in, which for a text field is the run it published. The
        // platform reads the caret back through this same node, so its
        // indices stay in the units they were measured in.
        let owner = if source.text_selection_owner == 0 {
            NodeId(source.id)
        } else {
            NodeId(source.text_selection_owner)
        };
        node.set_text_selection(TextSelection {
            anchor: TextPosition {
                node: owner,
                character_index: source.text_selection_anchor,
            },
            focus: TextPosition {
                node: owner,
                character_index: source.text_selection_focus,
            },
        });
    }
    if !source.character_lengths.is_null() && source.character_lengths_len > 0 {
        let slice = unsafe { std::slice::from_raw_parts(source.character_lengths, source.character_lengths_len) };
        node.set_character_lengths(slice.to_vec().into_boxed_slice());
    }
    if !source.character_positions.is_null() && source.character_positions_len > 0 {
        let slice = unsafe { std::slice::from_raw_parts(source.character_positions, source.character_positions_len) };
        node.set_character_positions(slice.to_vec().into_boxed_slice());
    }
    if !source.character_widths.is_null() && source.character_widths_len > 0 {
        let slice = unsafe { std::slice::from_raw_parts(source.character_widths, source.character_widths_len) };
        node.set_character_widths(slice.to_vec().into_boxed_slice());
    }

    (NodeId(source.id), node)
}

unsafe fn tree_update_from_c(source: &NoguiTreeUpdate) -> TreeUpdate {
    let mut nodes = Vec::with_capacity(source.nodes_len);
    if !source.nodes.is_null() && source.nodes_len > 0 {
        let slice = unsafe { std::slice::from_raw_parts(source.nodes, source.nodes_len) };
        for node in slice {
            nodes.push(unsafe { node_from_c(node) });
        }
    }
    let tree = if source.has_tree_init {
        let mut tree = TreeInfo::new(NodeId(source.root));
        if let Some(name) = unsafe { borrow_str(source.toolkit_name, source.toolkit_name_len) } {
            tree.toolkit_name = Some(name.to_owned());
        }
        if let Some(version) = unsafe { borrow_str(source.toolkit_version, source.toolkit_version_len) } {
            tree.toolkit_version = Some(version.to_owned());
        }
        Some(tree)
    } else {
        None
    };
    TreeUpdate {
        nodes,
        tree,
        tree_id: TreeId::ROOT,
        focus: NodeId(source.focus),
    }
}

// --- adapter state ----------------------------------------------------------

/// The host-facing half of the bridge, shared by the AccessKit handler objects
/// and by the opaque C handle.
///
/// One shared `Arc` and not one copy per handler, because the gate has to be
/// one latch. AccessKit owns the handler objects past the end of
/// `nogui_accesskit_bridge_free` and can call them until its own unstopped
/// event loop drops them, so a flag only the bridge read would prove nothing.
///
/// The deactivation callback is NOT stored here. Only the AT-SPI adapter can
/// invoke one, so the AT-SPI handler object owns it, and a target with no
/// deactivation signal has nothing here it could never call.
struct Callbacks {
    /// The host pointer, borrowed for the whole of a callback. Stored as a
    /// `usize` so this struct is `Send + Sync` on its own account: the gate
    /// orders every read of it against teardown, so none is left to justify
    /// with an `unsafe impl`.
    user: usize,
    on_action: Option<ActionFn>,
    on_activate: Option<ActivationFn>,
    /// Consumed only by the SDK's update factory, under its activation lock.
    initial_tree_requested: Mutex<bool>,
    /// Whether the platform is up, as last reported by AccessKit. Read by
    /// `nogui_accesskit_bridge_is_active`, never by the handlers themselves.
    ///
    /// One `Mutex<bool>` on every target, not an atomic on two of them. It is
    /// read once per host frame and written once per activation, and a
    /// platform-dependent field type would be an accidental difference with
    /// nothing behind it. It latches where nothing ever clears it: the two
    /// adapters that take no deactivation handler have no way to report a
    /// screen reader leaving, and the header says so rather than pretending.
    active: Mutex<bool>,
    /// Held for the whole of a host callback, and closed by teardown.
    gate: Gate,
}

impl Callbacks {
    fn new(
        user: *mut c_void,
        on_action: Option<ActionFn>,
        on_activate: Option<ActivationFn>,
    ) -> Self {
        Callbacks {
            user: user as usize,
            on_action,
            on_activate,
            active: Mutex::new(false),
            initial_tree_requested: Mutex::new(false),
            gate: Gate::new(),
        }
    }

    fn host(&self) -> *mut c_void {
        self.user as *mut c_void
    }

    fn is_active(&self) -> bool {
        *locked(&self.active)
    }

    /// Record a platform state transition. Both transitions are platform facts,
    /// so which of them any target can report is decided in `platform` and
    /// this is the one place the flag is written.
    fn set_active(&self, active: bool) {
        *locked(&self.active) = active;
    }

    /// A screen reader asked for the tree.
    ///
    /// The thread is the platform's: on AT-SPI the event loop, which still
    /// holds its own adapter-state lock across this call; on macOS inside the
    /// accessibility call itself, on the main thread; on Windows in the
    /// subclassed window procedure, on the thread that owns the window.
    fn activate(&self) {
        self.gate.enter(|| {
            // The guard is dropped by the end of the statement, so the host is
            // free to ask `is_active` from inside its own callback.
            self.set_active(true);
            *locked(&self.initial_tree_requested) = true;
            if let Some(callback) = self.on_activate {
                // SAFETY: the gate is open, so teardown has not run and the
                // host is still the caller's live object.
                unsafe { callback(self.host()) };
            }
        });
    }

    /// A screen reader asked for an action.
    ///
    /// Returns the host queue's answer, so the provider learns that a request
    /// the ring refused was refused instead of being told nothing.
    ///
    /// The thread is the platform's, and is not always the one that asked for
    /// the tree: on AT-SPI it is a detached zbus dispatcher task that nothing
    /// can cancel or wait for, on macOS the main thread inside an
    /// accessibility call, and on Windows a thread of AccessKit's own
    /// choosing. So the gate, not the caller, is the only thing standing
    /// between this and a freed host.
    fn action(&self, request: ActionRequest) -> bool {
        let Some(callback) = self.on_action else {
            return false;
        };
        let mut out = NoguiRequest {
            action: request.action as u8,
            target: request.target_node.0,
            data: NOGUI_ACTION_DATA_NONE,
            value: std::ptr::null(),
            value_len: 0,
            numeric_value: 0.0,
            custom_action: 0,
            anchor_node: 0,
            anchor_index: 0,
            focus_node: 0,
            focus_index: 0,
        };
        // The request owns borrowed strings until the host callback returns.
        match request.data.as_ref() {
            None => {}
            Some(ActionData::CustomAction(id)) => {
                out.data = NOGUI_ACTION_DATA_CUSTOM_ACTION;
                out.custom_action = *id;
            }
            Some(ActionData::Value(text)) => {
                out.data = NOGUI_ACTION_DATA_VALUE;
                out.value = text.as_ptr();
                out.value_len = text.len();
            }
            Some(ActionData::NumericValue(number)) => {
                out.data = NOGUI_ACTION_DATA_NUMERIC_VALUE;
                out.numeric_value = *number;
            }
            Some(ActionData::ScrollToPoint(point)) => {
                out.data = NOGUI_ACTION_DATA_SCROLL_TO_POINT;
                out.numeric_value = point.x;
                out.anchor_index = point.y as usize;
            }
            Some(ActionData::SetScrollOffset(point)) => {
                out.data = NOGUI_ACTION_DATA_SET_SCROLL_OFFSET;
                out.numeric_value = point.x;
                out.anchor_index = point.y as usize;
            }
            Some(ActionData::SetTextSelection(selection)) => {
                out.data = NOGUI_ACTION_DATA_TEXT_SELECTION;
                out.anchor_node = selection.anchor.node.0;
                out.anchor_index = selection.anchor.character_index;
                out.focus_node = selection.focus.node.0;
                out.focus_index = selection.focus.character_index;
            }
            // ScrollUnit, ScrollHint and anything newer carry no payload the
            // host can act on; the action itself is still forwarded.
            Some(_) => {}
        }
        match self.gate.enter(|| {
            // SAFETY: the gate is open, so teardown has not run and the host
            // is still the caller's live object. `out` outlives the call.
            unsafe { callback(self.host(), &out) }
        }) {
            Some(accepted) => accepted != 0,
            None => false,
        }
    }

    /// One positioned range edit over a text owner, from the standard
    /// `org.a11y.atspi.EditableText` methods.
    ///
    /// `action` is always `NOGUI_ACTION_REPLACE_SELECTED_TEXT` and `data` is
    /// always `NOGUI_ACTION_DATA_TEXT_RANGE`, which is what makes the payload
    /// unambiguous on the wire: there is one request shape, and it is the one
    /// the host decodes. Both endpoint node ids name the same text owner,
    /// because one owner holds the characters being edited.
    ///
    /// `start` and `end` are LIVE Unicode-scalar indices. Nothing here
    /// validates them against the published character table: that table is a
    /// frozen snapshot, and the live model value is what the host resolves
    /// them against. An index past the live end is therefore a host-side
    /// refusal at dispatch, which this layer cannot observe.
    ///
    /// `target_tree` is dropped here exactly as `Callbacks::action` drops it:
    /// the C record has no field for it, and the host's node ids are already
    /// scoped to its own single tree.
    #[cfg(all(unix, not(target_os = "macos")))]
    fn editable_text(&self, request: EditableTextRequest<'_>) -> bool {
        let Some(callback) = self.on_action else {
            return false;
        };
        let out = NoguiRequest {
            action: NOGUI_ACTION_REPLACE_SELECTED_TEXT,
            target: request.target_node.0,
            data: NOGUI_ACTION_DATA_TEXT_RANGE,
            value: request.replacement.as_ptr(),
            value_len: request.replacement.len(),
            numeric_value: 0.0,
            custom_action: 0,
            anchor_node: request.target_node.0,
            anchor_index: request.start,
            focus_node: request.target_node.0,
            focus_index: request.end,
        };
        match self.gate.enter(|| {
            // SAFETY: as in `action`. The replacement is borrowed from the
            // provider's own frame and `out` does not outlive this call.
            unsafe { callback(self.host(), &out) }
        }) {
            Some(accepted) => accepted != 0,
            None => false,
        }
    }

    /// Stop accepting host callbacks and wait out the one in flight.
    fn close(&self) {
        self.gate.close();
    }
}

/// AccessKit invokes the activation handler from whichever of its own
/// contexts owns the tree, and the action handler from a thread that may be
/// none of them. `Arc<Callbacks>` is `Send` because `Callbacks` is
/// `Send + Sync`, so nothing here needs an `unsafe impl`.
struct ActivationHandlerImpl(Arc<Callbacks>);

impl ActivationHandler for ActivationHandlerImpl {
    fn request_initial_tree(&mut self) -> Option<TreeUpdate> {
        // The host owns the committed tree and republishes on its own frame.
        // Returning None asks the adapter to install its placeholder, and the
        // first real update has to be a full tree: all three adapters say so
        // on `update_if_active`, and the host answers with
        // `nogui_accesskit_tree_update::has_tree_init`.
        //
        // `activate` runs BEFORE the adapter reaches its pending state, so a
        // host that decides from `nogui_accesskit_bridge_is_active` cannot
        // order itself against this: the flag is already true by the time the
        // platform is waiting for a tree, and it was just as true last time
        // one was requested. The callback is the only signal that says WHICH
        // request this is.
        self.0.activate();
        None
    }
}

struct ActionHandlerImpl(Arc<Callbacks>);

impl ActionHandler for ActionHandlerImpl {
    fn do_action(&mut self, request: ActionRequest) {
        // `accesskit::ActionHandler::do_action` returns nothing, so a host's
        // queue answer has nowhere to go on this path. The typed
        // `EditableTextHandlerNoMut` path below is the one that carries it.
        let _ = self.0.action(request);
    }
}

/// `Callbacks` is its own handler for the standard AT-SPI positioned range
/// methods, rather than a wrapper around one. The bridge already holds it in an
/// `Arc` and this trait takes `&self`, so a tuple struct would add an
/// allocation and a hop to say nothing.
#[cfg(all(unix, not(target_os = "macos")))]
impl EditableTextHandlerNoMut for Callbacks {
    fn do_editable_text(&self, request: EditableTextRequest<'_>) -> bool {
        self.editable_text(request)
    }
}

/// Lock without failing on a poisoned mutex. See `teardown::lock`.
fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The opaque C handle. Every field is private to this crate; C only ever
/// holds the pointer.
///
/// The adapter is `platform::Adapter`, which is a live adapter on AT-SPI and
/// an `Option` on the other two because those need a window that arrives
/// later. A handle with no window is valid, inert, and says so.
pub struct NoguiAccesskitBridge {
    adapter: platform::Adapter,
    callbacks: Arc<Callbacks>,
}

/// Run `body` with a caught panic, so a Rust failure becomes `fallback` at the
/// boundary instead of unwinding into a C frame that cannot catch it.
fn contained<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

/// Create the bridge, and the platform adapter where the platform has one
/// without a window. Returns null when the handle cannot be created,
/// including when a Rust panic is caught at the boundary.
///
/// `on_deactivate` is only ever called where the platform reports a screen
/// reader going away, which today means AT-SPI. See `platform::unix`; the
/// other two adapters have no such signal, so they accept the argument and
/// drop it rather than store a callback the platform cannot invoke.
#[no_mangle]
pub unsafe extern "C" fn nogui_accesskit_bridge_new(
    user: *mut c_void,
    on_action: Option<ActionFn>,
    on_activate: Option<ActivationFn>,
    on_deactivate: Option<DeactivationFn>,
) -> *mut NoguiAccesskitBridge {
    contained(std::ptr::null_mut(), || {
        let callbacks = Arc::new(Callbacks::new(user, on_action, on_activate));
        let adapter = platform::new(&callbacks, on_deactivate);
        Box::into_raw(Box::new(NoguiAccesskitBridge { adapter, callbacks }))
    })
}

/// Tear the bridge down. On return, no host callback is running and none can
/// start, so the caller owns `user` outright and may destroy it.
///
/// The gate is closed before the box is dropped, and that order is the whole
/// fix. Dropping an adapter never waits for anything: on AT-SPI it only
/// enqueues `RemoveAdapter` on a channel a detached thread drains whenever it
/// gets to it (`accesskit_unix-0.23.0/src/adapter.rs:240`) while a screen
/// reader may already have a D-Bus dispatcher calling the action handler, and
/// on macOS and Windows it restores the view's class or the window procedure
/// and returns. The gate outlives the box because AccessKit holds clones of
/// the shared state, so closing it is the part that outlives the teardown.
///
/// This is a barrier, and a barrier cannot be called from inside a host
/// callback on the same thread: the gate is not reentrant. The Zig host frees
/// the bridge from its own teardown, never from a callback.
#[no_mangle]
pub unsafe extern "C" fn nogui_accesskit_bridge_free(bridge: *mut NoguiAccesskitBridge) {
    let _ = contained((), || {
        if bridge.is_null() {
            return;
        }
        // SAFETY: non-null, and the caller owns the handle until this returns.
        // Taking the box before closing is what orders the two: the gate is
        // closed first and the adapter is dropped second, so the callback
        // that is in flight has returned before the platform is unwound.
        let target = unsafe { Box::from_raw(bridge) };
        target.callbacks.close();
        drop(target);
    });
}

/// True once a screen reader has asked the adapter for the tree.
///
/// Deliberately not gated. This is a status query from the thread that will
/// call `free`, and blocking it behind an in-flight host callback would be a
/// lock cycle waiting to happen. The flag it reads is written only under its
/// own mutex. It latches where nothing ever clears it, which is every target
/// but AT-SPI.
#[no_mangle]
pub unsafe extern "C" fn nogui_accesskit_bridge_is_active(
    bridge: *const NoguiAccesskitBridge,
) -> bool {
    contained(false, || {
        if bridge.is_null() {
            return false;
        }
        // SAFETY: non-null, and the caller owns the handle for the call.
        let bridge = unsafe { &*bridge };
        bridge.callbacks.is_active()
    })
}

/// Tell the platform whether the window itself has keyboard focus.
///
/// Forwarded where the platform cannot learn it for itself, which is every
/// target but Windows: the Windows adapter already receives `WM_SETFOCUS`,
/// `WM_KILLFOCUS`, `WM_ENTERMENULOOP`, `WM_EXITMENULOOP`, `WM_ENTERSIZEMOVE`
/// and `WM_EXITSIZEMOVE` in the window procedure its own subclass installs,
/// so a second copy of the same fact from the host would be one nothing reads.
#[no_mangle]
pub unsafe extern "C" fn nogui_accesskit_bridge_set_window_focused(
    bridge: *mut NoguiAccesskitBridge,
    focused: bool,
) {
    let _ = contained((), || {
        if bridge.is_null() {
            return;
        }
        // SAFETY: non-null, and the caller owns the handle for the call.
        platform::set_window_focused(unsafe { &mut (*bridge).adapter }, focused);
    });
}

/// Publish the window's outer and client rectangles.
///
/// An X11 fact, forwarded only on AT-SPI: a Wayland client cannot learn its
/// toplevel position and has to publish it. The AX adapter converts every node
/// rectangle to screen coordinates from the view and the window's backing
/// scale factor, and the UI Automation adapter reads the client rectangle in
/// the window procedure, so neither has a window rectangle to be told. Neither
/// is given a made-up one.
#[no_mangle]
pub unsafe extern "C" fn nogui_accesskit_bridge_set_window_bounds(
    bridge: *mut NoguiAccesskitBridge,
    outer: NoguiRect,
    inner: NoguiRect,
) {
    let _ = contained((), || {
        if bridge.is_null() {
            return;
        }
        // SAFETY: non-null, and the caller owns the handle for the call.
        platform::set_window_bounds(
            unsafe { &mut (*bridge).adapter },
            rect_of(outer),
            rect_of(inner),
        );
    });
}

/// A rectangle as AccessKit spells one: the same four `f64`s in the same
/// order, under the name the crate's own API uses.
fn rect_of(source: NoguiRect) -> Rect {
    Rect {
        x0: source.x0,
        y0: source.y0,
        x1: source.x1,
        y1: source.y1,
    }
}

/// A borrowed update and an allocation-free supplier for a complete view of
/// the same snapshot. Selection happens inside the SDK's update factory, not
/// before the SDK observes its Pending state.
pub(crate) struct Submission {
    source: *const NoguiTreeUpdate,
    context: *mut c_void,
    full_tree: unsafe extern "C" fn(*mut c_void) -> *const NoguiTreeUpdate,
}

impl Submission {
    fn convert(self, callbacks: &Callbacks) -> TreeUpdate {
        let requested = std::mem::take(&mut *locked(&callbacks.initial_tree_requested));
        let source = if requested {
            // SAFETY: the host keeps this call-local context live, and the
            // supplier returns a full view whose storage lasts through update.
            unsafe { (self.full_tree)(self.context) }
        } else {
            self.source
        };
        // Do not borrow the source record before invoking its supplier: the
        // supplier may replace that very record and refill its backing arrays.
        // SAFETY: the record and every array stay live through this conversion.
        unsafe { tree_update_from_c(&*source) }
    }
}

#[cfg(all(test, any(target_os = "macos", windows)))]
pub(crate) unsafe extern "C" fn unchanged_full_tree(
    context: *mut c_void,
) -> *const NoguiTreeUpdate {
    context.cast()
}

/// Apply one tree update. Returns false only when the platform refused it.
#[no_mangle]
pub unsafe extern "C" fn nogui_accesskit_bridge_update(
    bridge: *mut NoguiAccesskitBridge,
    update: *const NoguiTreeUpdate,
    context: *mut c_void,
    full_tree: Option<unsafe extern "C" fn(*mut c_void) -> *const NoguiTreeUpdate>,
) -> bool {
    contained(false, || {
        if bridge.is_null() || update.is_null() {
            return false;
        }
        let Some(full_tree) = full_tree else {
            return false;
        };
        // SAFETY: the caller owns the handle, record and supplier context until
        // this synchronous update returns. The SDK invokes conversion only
        // after taking the same lock it holds across request_initial_tree.
        let source = update;
        let bridge = unsafe { &mut *bridge };
        platform::update(
            &mut bridge.adapter,
            &bridge.callbacks,
            Submission { source, context, full_tree },
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(id: u64, role: u8) -> NoguiNode {
        NoguiNode {
            id,
            role,
            flags: 0,
            actions: 0,
            bounds: NoguiRect {
                x0: 1.0,
                y0: 2.0,
                x1: 3.0,
                y1: 4.0,
            },
            label: std::ptr::null(),
            label_len: 0,
            description: std::ptr::null(),
            description_len: 0,
            value: std::ptr::null(),
            value_len: 0,
            shortcut: std::ptr::null(),
            shortcut_len: 0,
            placeholder: std::ptr::null(),
            placeholder_len: 0,
            numeric_value: 0.0,
            has_numeric_value: false,
            min_numeric_value: 0.0,
            has_min_numeric_value: false,
            max_numeric_value: 0.0,
            has_max_numeric_value: false,
            numeric_step: 0.0,
            has_numeric_step: false,
            text_cursor: 0,
            text_selection_anchor: 0,
            text_selection_focus: 0,
            has_text_selection: false,
            character_lengths: std::ptr::null(),
            character_lengths_len: 0,
            character_positions: std::ptr::null(),
            character_positions_len: 0,
            character_widths: std::ptr::null(),
            character_widths_len: 0,
            children: std::ptr::null(),
            children_len: 0,
            active_descendant: 0,
            controls: std::ptr::null(),
            controls_len: 0,
            described_by: std::ptr::null(),
            described_by_len: 0,
            labelled_by: std::ptr::null(),
            labelled_by_len: 0,
            flow_to: std::ptr::null(),
            flow_to_len: 0,
            member_of: 0,
            row_count_set_size: 0,
            row_index_position: 0,
            has_row_index_position: false,
            text_selection_owner: 0,
            custom_actions: std::ptr::null(),
            custom_actions_len: 0,
        }
    }

    #[test]
    fn role_mapping_is_exact_for_emitted_roles() {
        assert_eq!(role_of(18), Role::Button);
        assert_eq!(role_of(113), Role::Slider);
        assert_eq!(role_of(29), Role::Switch);
        assert_eq!(role_of(101), Role::ProgressIndicator);
        // An unknown code degrades instead of guessing a control.
        assert_eq!(role_of(200), Role::Unknown);
    }

    #[test]
    fn action_mapping_is_exact_for_emitted_actions() {
        assert_eq!(action_of(0), Some(Action::Click));
        assert_eq!(action_of(20), Some(Action::SetValue));
        assert_eq!(action_of(99), None);
        // A positioned edit is carried on the same discriminant an ordinary
        // selected-text replacement uses, so the host reads one action for
        // both and tells them apart by `data`.
        assert_eq!(Action::ReplaceSelectedText as u8, NOGUI_ACTION_REPLACE_SELECTED_TEXT);
    }

    #[test]
    fn unselected_selectable_row_retains_a_false_selection_state() {
        let mut source = node(7, 7); // ListItem
        source.flags = FLAG_SELECTABLE;
        source.actions = 1; // Click
        let (_, row) = unsafe { node_from_c(&source) };
        assert_eq!(row.is_selected(), Some(false));
        assert!(row.supports_action(Action::Click));

        source.flags |= FLAG_SELECTED;
        let (_, row) = unsafe { node_from_c(&source) };
        assert_eq!(row.is_selected(), Some(true));

        source.flags = 0;
        source.actions = 0;
        let (_, row) = unsafe { node_from_c(&source) };
        assert_eq!(row.is_selected(), None);
    }

    #[test]
    fn borrowed_node_becomes_an_accesskit_node() {
        let label = b"Save";
        let mut source = node(7, 18);
        source.label = label.as_ptr();
        source.label_len = label.len();
        source.actions = 1; // Click
        let (id, node) = unsafe { node_from_c(&source) };
        assert_eq!(id, NodeId(7));
        assert_eq!(node.role(), Role::Button);
        assert_eq!(node.label(), Some("Save"));
        assert!(node.supports_action(Action::Click));
        assert!(!node.supports_action(Action::SetValue));
        assert_eq!(node.bounds(), Some(Rect { x0: 1.0, y0: 2.0, x1: 3.0, y1: 4.0 }));
    }

    /// The focused bit is read and deliberately not turned into a node state.
    ///
    /// `accesskit 0.25.0` gives `Node` no `Focused` property, so there is nothing
    /// to set: focus is a property of the tree and travels as
    /// `TreeUpdate::focus`. Pinned here so the bit cannot be quietly
    /// "corrected" into a state the pinned crate cannot express, and so the
    /// header's promise that `focus` is what reaches the platform stays true.
    #[test]
    fn focus_travels_in_the_update_and_not_in_the_node_flag() {
        let mut flagged = node(7, 18);
        flagged.flags = FLAG_FOCUSED;
        let unflagged = node(7, 18);
        let (_, with_bit) = unsafe { node_from_c(&flagged) };
        let (_, without_bit) = unsafe { node_from_c(&unflagged) };
        assert_eq!(with_bit, without_bit);

        // The same record, published, carries the focus where AccessKit reads
        // it.
        let update = NoguiTreeUpdate {
            root: 7,
            has_tree_init: true,
            toolkit_name: std::ptr::null(),
            toolkit_name_len: 0,
            toolkit_version: std::ptr::null(),
            toolkit_version_len: 0,
            focus: 7,
            nodes: std::ptr::null(),
            nodes_len: 0,
        };
        let converted = unsafe { tree_update_from_c(&update) };
        assert_eq!(converted.focus, NodeId(7));
    }

    #[test]
    fn invalid_utf8_is_dropped_rather_than_mangled() {
        let raw = [0xffu8, 0xfe];
        let mut source = node(1, 3);
        source.label = raw.as_ptr();
        source.label_len = raw.len();
        let (_, node) = unsafe { node_from_c(&source) };
        assert_eq!(node.label(), None);

        // The value is a different field with its own rule, and an undecodable
        // value is dropped rather than shortened to the empty one: an empty
        // value is announced, and a broken one must not be.
        source.label = std::ptr::null();
        source.label_len = 0;
        source.value = raw.as_ptr();
        source.value_len = raw.len();
        let (_, node) = unsafe { node_from_c(&source) };
        assert_eq!(node.value(), None);
    }

    /// An EMPTY value the host published is a value; an absent one is not.
    ///
    /// `accesskit_consumer` reads a text run's characters through
    /// `node.data().value().unwrap()` (`accesskit_consumer-0.39.0/src/text.rs`
    /// `:696`, `:1574`), so a run published as an empty string has to reach
    /// AccessKit as `Some("")`. Only the pointer says which of the two a host
    /// published: null for absent, non-null at length zero for empty.
    #[test]
    fn an_empty_published_value_reaches_accesskit_as_an_empty_value() {
        let empty = b"";
        let mut cleared = node(9, 1); // TextRun
        cleared.value = empty.as_ptr();
        cleared.value_len = 0;
        let (_, run) = unsafe { node_from_c(&cleared) };
        assert_eq!(run.value(), Some(""));

        let (_, button) = unsafe { node_from_c(&node(7, 18)) };
        assert_eq!(button.value(), None);
    }

    /// A number is a value the platform reads as a NUMBER, and it carries no
    /// value bytes at all, so the third thing a pointer can say is "absent".
    /// A slider that grew an empty string here would announce an empty value
    /// where its position is.
    #[test]
    fn a_numeric_value_is_carried_by_the_number_and_by_no_value_bytes() {
        let mut slider = node(5, 113);
        slider.numeric_value = 0.5;
        slider.has_numeric_value = true;
        slider.min_numeric_value = 0.0;
        slider.has_min_numeric_value = true;
        slider.max_numeric_value = 1.0;
        slider.has_max_numeric_value = true;
        slider.numeric_step = 0.05;
        slider.has_numeric_step = true;
        let (_, converted) = unsafe { node_from_c(&slider) };
        assert_eq!(converted.value(), None);
        assert_eq!(converted.numeric_value(), Some(0.5));
        assert_eq!(converted.min_numeric_value(), Some(0.0));
        assert_eq!(converted.max_numeric_value(), Some(1.0));
        assert_eq!(converted.numeric_value_step(), Some(0.05));
    }

    /// The characters a field holds reach AccessKit as themselves. The length
    /// the host published is in bytes and the value it names is in
    /// characters, so a multi-byte value is the case where a wrong conversion
    /// would be a value no user ever typed.
    #[test]
    fn a_full_unicode_value_reaches_accesskit_unchanged() {
        let typed = "Grüße ✓€€";
        let mut run = node(9, 1); // TextRun
        run.value = typed.as_ptr();
        run.value_len = typed.len();
        let (_, converted) = unsafe { node_from_c(&run) };
        assert_eq!(converted.value(), Some(typed));
        assert_eq!(converted.value().map(str::len), Some(typed.len()));
    }

    /// A text field's published selection must name the RUN it belongs to.
    ///
    /// `accesskit_consumer` resolves a selection's `TextPosition` against the
    /// node that carries the characters, and its text interface is offered
    /// only when a text input has a `Role::TextRun` child. Pointing the
    /// selection at the field itself would leave the caret in a node the
    /// platform never asks about, so the owner the host published has to
    /// reach AccessKit as the node both endpoints name.
    #[test]
    fn a_published_selection_names_the_run_that_carries_its_characters() {
        let mut field = node(7, 17); // TextInput
        field.has_text_selection = true;
        field.text_selection_anchor = 2;
        field.text_selection_focus = 5;
        field.text_selection_owner = 9;

        let (_, converted) = unsafe { node_from_c(&field) };
        let selection = converted.text_selection().expect("selection");
        assert_eq!(selection.anchor.node, NodeId(9));
        assert_eq!(selection.focus.node, NodeId(9));
        assert_eq!(selection.anchor.character_index, 2);
        assert_eq!(selection.focus.character_index, 5);

        // A host that publishes no run keeps the older meaning: the node's
        // own characters.
        let mut self_owned = node(7, 17);
        self_owned.has_text_selection = true;
        self_owned.text_selection_anchor = 1;
        self_owned.text_selection_focus = 1;
        let (_, node) = unsafe { node_from_c(&self_owned) };
        let selection = node.text_selection().expect("selection");
        assert_eq!(selection.anchor.node, NodeId(7));
        assert_eq!(selection.focus.node, NodeId(7));
    }

    #[test]
    fn tree_update_keeps_root_focus_and_relations() {
        let children = [2u64, 3u64];
        let mut child = node(2, 18);
        child.children = children.as_ptr();
        child.children_len = children.len();
        let mut root = node(1, 133);
        root.children = children.as_ptr();
        root.children_len = children.len();
        root.active_descendant = 2;
        let nodes = [root, child];
        let update = NoguiTreeUpdate {
            root: 1,
            has_tree_init: true,
            toolkit_name: b"nogui".as_ptr(),
            toolkit_name_len: 5,
            toolkit_version: std::ptr::null(),
            toolkit_version_len: 0,
            focus: 2,
            nodes: nodes.as_ptr(),
            nodes_len: nodes.len(),
        };
        let converted = unsafe { tree_update_from_c(&update) };
        assert_eq!(converted.nodes.len(), 2);
        assert_eq!(converted.focus, NodeId(2));
        let tree = converted.tree.expect("tree init requested");
        assert_eq!(tree.root, NodeId(1));
        assert_eq!(tree.toolkit_name.as_deref(), Some("nogui"));
        let (_, root) = &converted.nodes[0];
        assert_eq!(root.active_descendant(), Some(NodeId(2)));
        assert_eq!(root.children(), &[NodeId(2), NodeId(3)]);
    }

    struct FullSupply {
        tree: NoguiTreeUpdate,
        calls: usize,
    }

    unsafe extern "C" fn supply_full_tree(context: *mut c_void) -> *const NoguiTreeUpdate {
        // SAFETY: each submission below borrows its live local FullSupply.
        let supply = unsafe { &mut *context.cast::<FullSupply>() };
        supply.calls += 1;
        &supply.tree
    }

    /// A request arriving after delta preparation must initialize from the
    /// current complete hierarchy, including unchanged siblings. Later frames
    /// remain diffs until another request, not full-tree retransmissions.
    #[test]
    fn activation_after_delta_preparation_declares_the_current_hierarchy() {
        let children = [2u64, 3];
        let mut root = node(1, 133);
        root.children = children.as_ptr();
        root.children_len = children.len();
        let mut changed = node(2, 18);
        changed.label = b"Changed".as_ptr();
        changed.label_len = 7;
        let nodes = [root, changed, node(3, 18)];
        let mut supply = FullSupply {
            tree: NoguiTreeUpdate {
                root: 1,
                has_tree_init: true,
                toolkit_name: std::ptr::null(),
                toolkit_name_len: 0,
                toolkit_version: std::ptr::null(),
                toolkit_version_len: 0,
                focus: 2,
                nodes: nodes.as_ptr(),
                nodes_len: nodes.len(),
            },
            calls: 0,
        };
        let delta = NoguiTreeUpdate {
            root: 1,
            has_tree_init: false,
            toolkit_name: std::ptr::null(),
            toolkit_name_len: 0,
            toolkit_version: std::ptr::null(),
            toolkit_version_len: 0,
            focus: 2,
            nodes: &nodes[1],
            nodes_len: 1,
        };
        let callbacks = Arc::new(Callbacks::new(std::ptr::null_mut(), None, None));
        let prepared = Submission {
            source: &delta,
            context: (&mut supply as *mut FullSupply).cast(),
            full_tree: supply_full_tree,
        };
        assert!(ActivationHandlerImpl(Arc::clone(&callbacks))
            .request_initial_tree()
            .is_none());
        let initial = prepared.convert(&callbacks);
        assert_eq!(initial.tree.as_ref().unwrap().root, NodeId(1));
        assert_eq!(initial.nodes.len(), 3);
        for ((id, _), expected) in initial.nodes.iter().zip([1, 2, 3]) {
            assert_eq!(id.0, expected);
        }
        assert_eq!(initial.nodes[0].1.children(), &[NodeId(2), NodeId(3)]);
        assert_eq!(initial.nodes[1].1.label(), Some("Changed"));
        assert_eq!(initial.focus, NodeId(2));
        assert_eq!(supply.calls, 1);
        let quiet = Submission {
            source: &delta,
            context: (&mut supply as *mut FullSupply).cast(),
            full_tree: supply_full_tree,
        }
        .convert(&callbacks);
        assert!(quiet.tree.is_none());
        assert_eq!(quiet.nodes.len(), 1);
        assert_eq!(quiet.nodes[0].0, NodeId(2));
        assert_eq!(supply.calls, 1);
        callbacks.activate();
        let again = Submission {
            source: &delta,
            context: (&mut supply as *mut FullSupply).cast(),
            full_tree: supply_full_tree,
        }
        .convert(&callbacks);
        assert!(again.tree.is_some());
        assert_eq!(again.nodes.len(), 3);
        assert_eq!(supply.calls, 2);
    }

    #[test]
    fn a_null_bridge_is_inert_instead_of_fatal() {
        assert!(!unsafe { nogui_accesskit_bridge_is_active(std::ptr::null()) });
        unsafe { nogui_accesskit_bridge_free(std::ptr::null_mut()) };
        unsafe { nogui_accesskit_bridge_set_window_focused(std::ptr::null_mut(), true) };
        unsafe {
            nogui_accesskit_bridge_set_window_bounds(
                std::ptr::null_mut(),
                rect(),
                rect(),
            )
        };
        assert!(!unsafe {
            nogui_accesskit_bridge_update(
                std::ptr::null_mut(), std::ptr::null(), std::ptr::null_mut(), None,
            )
        });
    }

    fn rect() -> NoguiRect {
        NoguiRect {
            x0: 0.0,
            y0: 0.0,
            x1: 0.0,
            y1: 0.0,
        }
    }

    /// A borrowed slice is read once, at the boundary, and the accesskit value
    /// owns what it kept.
    ///
    /// This is the half of the ownership contract that C cannot check: the
    /// record is borrowed for the call, so the converted node has to hold its
    /// own copy of the label. If it borrowed instead, the next frame's buffer
    /// would silently rewrite the previous frame's announced name.
    #[test]
    fn a_borrowed_label_is_copied_not_aliased() {
        let mut source = node(7, 18);
        let mut label = b"Save".to_vec();
        source.label = label.as_ptr();
        source.label_len = label.len();
        let (_, converted) = unsafe { node_from_c(&source) };
        // Overwrite the buffer the record pointed at.
        label.fill(b'X');
        label.shrink_to_fit();
        assert_eq!(converted.label(), Some("Save"));
    }

    /// What the host queue did with the request, counted through the host
    /// pointer the bridge hands back. A C callback cannot be a closure, so the
    /// count is written through that pointer instead.
    #[derive(Default)]
    struct Ring {
        calls: usize,
    }

    /// A ring that accepted the request.
    ///
    /// # Safety
    ///
    /// `user` must be a live `*mut Ring` the test keeps alive for the call.
    unsafe extern "C" fn accept(user: *mut c_void, _request: *const NoguiRequest) -> u8 {
        // SAFETY: the test owns the `Ring` for the whole call and the bridge
        // hands the same pointer back.
        unsafe { &mut *user.cast::<Ring>() }.calls += 1;
        1
    }

    /// A host that installed no action callback has no queue to accept into,
    /// and the bridge says so rather than reporting a delivery nobody made.
    #[test]
    fn a_bridge_with_no_action_callback_refuses_every_request() {
        let callbacks = Callbacks::new(std::ptr::null_mut(), None, None);
        assert!(!callbacks.action(ActionRequest {
            action: Action::Click,
            target_tree: TreeId::ROOT,
            target_node: NodeId(7),
            data: None,
        }));
    }

    /// Teardown closes the gate, so a positioned edit arriving afterwards is
    /// refused rather than dispatched into a host the caller has released.
    #[cfg(all(unix, not(target_os = "macos")))]
    #[test]
    fn a_closed_gate_refuses_a_positioned_edit() {
        let mut ring = Ring::default();
        let callbacks = Arc::new(Callbacks::new(
            (&mut ring as *mut Ring).cast(),
            Some(accept),
            None,
        ));
        callbacks.close();
        assert!(!callbacks.do_editable_text(range(0, 1, "x")));
        assert_eq!(ring.calls, 0);
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    fn range(start: usize, end: usize, replacement: &'static str) -> EditableTextRequest<'static> {
        EditableTextRequest {
            target_tree: TreeId::ROOT,
            target_node: NodeId(7),
            start,
            end,
            replacement,
        }
    }
}
