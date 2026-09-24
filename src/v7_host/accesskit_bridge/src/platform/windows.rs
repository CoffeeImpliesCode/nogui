//! The UI Automation adapter: `accesskit_windows`, for Windows.
//!
//! Three facts about this platform shape the module.
//!
//! FIRST, THE ADAPTER IS BUILT AROUND A WINDOW. `SubclassingAdapter::new` takes
//! the window's `HWND` and installs a window procedure that receives
//! `WM_GETOBJECT`, so the shared `nogui_accesskit_bridge_new` signature has
//! nowhere to put one. So `new` builds the host side only and
//! `nogui_accesskit_bridge_windows_attach` binds the adapter afterwards, on
//! the thread that owns the window and before the window is first shown. Until
//! that call the handle is valid and inert.
//!
//! SECOND, UI AUTOMATION HAS NO DEACTIVATION EVENT. `accesskit_windows` takes
//! no `DeactivationHandler`, so `on_deactivate` is accepted and dropped rather
//! than stored: a callback the platform can never invoke is a claim it cannot
//! back. That also means `nogui_accesskit_bridge_is_active` latches here, the
//! same as on macOS, and the header says so.
//!
//! THIRD, THE ADAPTER LEARNS THE FOCUS STATE FOR ITSELF. Its window procedure
//! turns `WM_SETFOCUS`, `WM_EXITMENULOOP` and `WM_EXITSIZEMOVE` into
//! `update_window_focus_state(true)` and `WM_KILLFOCUS`, `WM_ENTERMENULOOP` and
//! `WM_ENTERSIZEMOVE` into `update_window_focus_state(false)`
//! (`accesskit_windows-0.35.0/src/subclass.rs:62`). So the shared focus entry
//! point is accepted and not forwarded: a second copy of a fact the platform
//! already holds would be a value nothing reads.

use crate::{
    contained, ActionHandlerImpl, ActivationHandlerImpl, Callbacks, DeactivationFn,
    NoguiAccesskitBridge,
};
use accesskit::{Rect, TreeUpdate};
use accesskit_windows::{HWND, SubclassingAdapter};
use std::ffi::c_void;
use std::sync::Arc;

/// The adapter, empty until the host attaches a window.
pub(crate) struct Adapter(Option<SubclassingAdapter>);

pub(crate) fn new(
    _callbacks: &Arc<Callbacks>,
    _on_deactivate: Option<DeactivationFn>,
) -> Adapter {
    // The two handlers are built at attach time, because that is where
    // `SubclassingAdapter::new` takes them by value, and there is no
    // deactivation handler on this platform at all.
    Adapter(None)
}

/// Bind the platform adapter to the window SDL owns.
///
/// The adapter subclasses the window procedure, so this must run on the thread
/// that owns the window and before the window is shown for the first time:
/// `SubclassingAdapter::new` panics on a window that is already visible
/// (`accesskit_windows-0.35.0/src/subclass.rs:168`), that panic is contained,
/// and it is reported as a failed attach.
///
/// Returns false for a null handle, a null window, or a handle that already
/// carries an adapter, and false when the platform refused it. A handle left
/// unattached stays inert, which is not the same as a live adapter that has no
/// screen reader: neither can serve a tree, and neither says otherwise.
#[no_mangle]
pub unsafe extern "C" fn nogui_accesskit_bridge_windows_attach(
    bridge: *mut NoguiAccesskitBridge,
    hwnd: *mut c_void,
) -> bool {
    contained(false, || {
        if bridge.is_null() || hwnd.is_null() {
            return false;
        }
        // SAFETY: non-null, and the caller owns the handle for the call.
        let target = unsafe { &mut *bridge };
        if target.adapter.0.is_some() {
            return false;
        }
        let callbacks = Arc::clone(&target.callbacks);
        let adapter = SubclassingAdapter::new(
            HWND(hwnd),
            ActivationHandlerImpl(Arc::clone(&callbacks)),
            ActionHandlerImpl(callbacks),
        );
        target.adapter = Adapter(Some(adapter));
        true
    })
}

/// A documented no-op, because the window procedure already has this fact.
///
/// The window's own focus state is the platform's, learned from the messages
/// the subclass receives. Nothing is recorded here either: a second copy of a
/// fact nothing reads is worse than none.
pub(crate) fn set_window_focused(_adapter: &mut Adapter, _focused: bool) {
}

/// A documented no-op, because the window procedure already has this.
///
/// There is no X11 outer-frame and client-area split on Windows. The adapter
/// derives the root window size from the client rectangle the window procedure
/// is given, so no rectangle is invented for the two this is handed.
pub(crate) fn set_window_bounds(_adapter: &mut Adapter, _outer: Rect, _inner: Rect) {
}

pub(crate) fn update(
    adapter: &mut Adapter,
    callbacks: &Callbacks,
    update: crate::Submission,
) -> bool {
    let Some(adapter) = adapter.0.as_mut() else {
        // An unattached handle has no platform to publish to, and saying it
        // accepted the update would be a claim the caller cannot check. This is
        // deliberately a different answer from macOS, where the host is
        // expected to publish before the window is attached.
        return false;
    };
    let events = adapter.update_if_active(move || update.convert(callbacks));
    if events.is_some() {
        // The adapter queues the events a tree update produces instead of
        // raising them, so they are raised here. Dropping them would leave the
        // screen reader waiting for an announcement. A raised update is also
        // the only evidence of a screen reader on this platform, because
        // nothing here ever reports one leaving.
        callbacks.set_active(true);
        events.raise();
    }
    // Inactive means no screen reader has asked for the tree, which is the
    // adapter's own answer and not a failure.
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        nogui_accesskit_bridge_free, nogui_accesskit_bridge_is_active,
        nogui_accesskit_bridge_new, nogui_accesskit_bridge_update, NoguiTreeUpdate,
    };

    fn tree_update() -> NoguiTreeUpdate {
        NoguiTreeUpdate {
            root: 1,
            has_tree_init: true,
            toolkit_name: std::ptr::null(),
            toolkit_name_len: 0,
            toolkit_version: std::ptr::null(),
            toolkit_version_len: 0,
            focus: 1,
            nodes: std::ptr::null(),
            nodes_len: 0,
        }
    }

    /// An unattached handle refuses a tree update instead of reporting it
    /// sent.
    ///
    /// This is the one answer that differs from macOS on purpose. A host that
    /// publishes before `nogui_accesskit_bridge_windows_attach` has nothing to
    /// publish to, and saying it succeeded would be a claim it cannot check.
    #[test]
    fn an_unattached_bridge_publishes_nothing() {
        // SAFETY: the handle is used only through the entry points below and is
        // freed exactly once.
        let bridge =
            unsafe { nogui_accesskit_bridge_new(std::ptr::null_mut(), None, None, None) };
        assert!(!bridge.is_null(), "the bridge refused to be created");
        // There is no adapter yet, so the platform cannot have a tree.
        // SAFETY: the handle is live for the call.
        assert!(!unsafe { nogui_accesskit_bridge_is_active(bridge) });
        let update = tree_update();
        // SAFETY: the handle is live for the call and the record outlives it.
        assert!(!unsafe {
            nogui_accesskit_bridge_update(
                bridge,
                &update,
                (&update as *const NoguiTreeUpdate).cast_mut().cast(),
                Some(crate::unchanged_full_tree),
            )
        });
        // A refused attach leaves the handle inert rather than half attached.
        // SAFETY: a null window is checked before it is used.
        assert!(!unsafe {
            nogui_accesskit_bridge_windows_attach(bridge, std::ptr::null_mut())
        });
        // SAFETY: the handle came from `nogui_accesskit_bridge_new` and is
        // consumed exactly once.
        unsafe { nogui_accesskit_bridge_free(bridge) };
    }

    /// Every entry point refuses a null handle rather than dereferencing it.
    #[test]
    fn a_null_handle_is_refused() {
        // SAFETY: every call below is passed a null pointer, which each entry
        // point checks before it dereferences anything.
        unsafe {
            assert!(!nogui_accesskit_bridge_windows_attach(
                std::ptr::null_mut(),
                std::ptr::null_mut()
            ));
            assert!(!nogui_accesskit_bridge_is_active(std::ptr::null()));
            assert!(!nogui_accesskit_bridge_update(
                std::ptr::null_mut(),
                std::ptr::null(), std::ptr::null_mut(), None,
            ));
            nogui_accesskit_bridge_free(std::ptr::null_mut());
        }
    }
}
