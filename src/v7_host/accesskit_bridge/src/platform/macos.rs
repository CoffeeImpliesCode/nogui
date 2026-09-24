//! The AX adapter: `accesskit_macos`, for macOS.
//!
//! Two facts about this platform shape the whole module.
//!
//! FIRST, THE ADAPTER IS BUILT AROUND A WINDOW. `SubclassingAdapter` is
//! constructed from the content view of a real `NSWindow` and dynamically
//! subclasses it (`accesskit_macos-0.27.0/src/subclass.rs`), so the bridge
//! exists before the adapter does and the host attaches one through
//! `nogui_accesskit_bridge_set_view`. Every entry point below is written to be
//! meaningful before one is attached, and says so instead of reporting a host
//! mistake where there is none.
//!
//! SECOND, `SubclassingAdapter` IS NEITHER `Send` NOR `SYNC`, and everything it
//! touches is AppKit. It is built from a main-thread marker internally, its
//! state is a `RefCell` that the accessibility system and the host would both
//! borrow, and its handlers are documented to run on the main thread. So every
//! entry point that mutates the adapter REFUSES a call that is not on the main
//! thread, which is the mistake the refusal names. The status read is not one
//! of them: it touches no adapter and answers from a lock the handlers write
//! under, so it is safe from any thread.

use crate::{
    contained, ActionHandlerImpl, ActivationHandlerImpl, Callbacks, DeactivationFn,
    NoguiAccesskitBridge,
};
use accesskit::{Rect, TreeUpdate};
use accesskit_macos::SubclassingAdapter;
use objc2_foundation::MainThreadMarker;
use std::ffi::{c_char, c_void, CStr};
use std::sync::Arc;

/// The adapter, empty until the host attaches a view.
///
/// Not a wrapper over the platform type for show: the `Option` is what lets a
/// handle exist before it has a window, and that is a real state the shared ABI
/// has to answer for.
pub(crate) struct Adapter(Option<SubclassingAdapter>);

pub(crate) fn new(
    _callbacks: &Arc<Callbacks>,
    _on_deactivate: Option<DeactivationFn>,
) -> Adapter {
    // Neither handler is built here. AX has no public signal that a screen
    // reader detached, so there is no deactivation handler at all, and the two
    // handlers it does take are built at attach time because that is where
    // AccessKit wants them by value.
    Adapter(None)
}

/// Attach the platform adapter to an `NSWindow`.
///
/// `view_is_focused` is the window's key state at the moment of attachment, and
/// it is applied rather than accepted and ignored. That is not cosmetic:
/// `SubclassingAdapter::for_window` constructs the platform adapter with
/// `Adapter::new(view, false, ..)` (`subclass.rs:157`), so the adapter's own
/// view-focus state starts out hardcoded to `false`, and the placeholder to
/// active transition builds the real tree from it
/// (`Tree::new(update_factory(), *is_view_focused)`, `adapter.rs:125`). A
/// window that is already key when its view is attached would otherwise publish
/// a tree the platform believes is unfocused until the host happened to publish
/// again.
///
/// # Safety
///
/// `ns_window` must be a valid, unreleased pointer to an `NSWindow` whose
/// content view does not already carry an AccessKit subclass.
#[no_mangle]
pub unsafe extern "C" fn nogui_accesskit_bridge_set_view(
    bridge: *mut NoguiAccesskitBridge,
    ns_window: *mut c_void,
    view_is_focused: bool,
) -> bool {
    contained(false, || {
        if bridge.is_null() || ns_window.is_null() {
            return false;
        }
        if MainThreadMarker::new().is_none() {
            // The adapter is built from a main-thread marker internally, so
            // calling this anywhere else would panic there. Refusing here
            // names the actual mistake.
            return false;
        }
        // SAFETY: non-null, and the caller owns the handle for the call.
        let target = unsafe { &mut *bridge };
        if target.adapter.0.is_some() {
            // A second window on one bridge would leave the first view
            // subclassed with no adapter behind it.
            return false;
        }
        let callbacks = Arc::clone(&target.callbacks);
        let adapter = unsafe {
            SubclassingAdapter::for_window(
                ns_window,
                ActivationHandlerImpl(Arc::clone(&callbacks)),
                ActionHandlerImpl(callbacks),
            )
        };
        if let Some(events) = adapter.update_view_focus_state(view_is_focused) {
            events.raise();
        }
        target.adapter = Adapter(Some(adapter));
        true
    })
}

/// Add the focus forwarder AccessKit needs for a windowing library that puts
/// keyboard focus on the window rather than its content view.
///
/// SDL declares its own window class and calls this once for it, so the
/// forwarder is installed before any window exists and the process keeps it for
/// its lifetime: the helper cannot be undone, which is why the archive is
/// linked statically and stays loaded.
#[no_mangle]
pub unsafe extern "C" fn nogui_accesskit_bridge_add_focus_forwarder(
    class_name: *const c_char,
) -> bool {
    contained(false, || {
        if class_name.is_null() {
            return false;
        }
        if MainThreadMarker::new().is_none() {
            return false;
        }
        let name = match unsafe { CStr::from_ptr(class_name) }.to_str() {
            Ok(value) => value,
            Err(_) => return false,
        };
        // SAFETY: the caller promises the class exists and is an `NSWindow`
        // subclass. A class that does not exist makes the helper panic
        // (`AnyClass::get(class_name).unwrap()`, `patch.rs:40`), and
        // `contained` turns that into the same `false` as a bad argument.
        unsafe { accesskit_macos::add_focus_forwarder_to_window_class(name) };
        true
    })
}

pub(crate) fn set_window_focused(adapter: &mut Adapter, focused: bool) {
    if MainThreadMarker::new().is_none() {
        // Sending a focus change into AppKit from another thread is a data race
        // on the adapter's `RefCell` and an Objective-C message from a thread
        // that has no business sending one. Refusing names it.
        return;
    }
    if let Some(adapter) = adapter.0.as_mut() {
        if let Some(events) = adapter.update_view_focus_state(focused) {
            events.raise();
        }
    }
}

/// A documented no-op, because the AX adapter already has this.
///
/// `accesskit_macos` converts every node rectangle to screen coordinates from
/// the view it was given, dividing by the window's backing scale factor
/// (`accesskit_macos-0.27.0/src/util.rs:62`), and the host publishes physical
/// pixels with that same factor applied. So there is no window rectangle for
/// the host to push, and no substitute is invented for the two it is handed.
pub(crate) fn set_window_bounds(_adapter: &mut Adapter, _outer: Rect, _inner: Rect) {
}

pub(crate) fn update(
    adapter: &mut Adapter,
    callbacks: &Callbacks,
    update: crate::Submission,
) -> bool {
    if MainThreadMarker::new().is_none() {
        // Refused, and not the same answer as "no view yet": this one is a
        // caller mistake on a thread that must not touch the adapter.
        return false;
    }
    let Some(adapter) = adapter.0.as_mut() else {
        // No view yet, so there is no platform tree to update. The host
        // publishes again after attaching, and that update is the first one a
        // screen reader sees; refusing here would report a host mistake where
        // there is none.
        return true;
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

    /// A tree update from a thread that is not the main one is refused.
    ///
    /// The call is made from a thread this test spawns, not from the test's
    /// own: `cargo test` may run a test on the main thread, and the point is
    /// the worker. A `true` here would mean a host could mutate the AX adapter
    /// from a background task, which is a `RefCell` borrow race and an
    /// Objective-C message from a thread that has no business sending one.
    #[test]
    fn a_worker_thread_cannot_publish_a_tree() {
        let accepted = std::thread::spawn(|| {
            let update = tree_update();
            // SAFETY: the handle is used only through the entry points below
            // and is freed exactly once.
            let bridge = unsafe {
                nogui_accesskit_bridge_new(std::ptr::null_mut(), None, None, None)
            };
            assert!(!bridge.is_null(), "the bridge refused to be created");
            let accepted = unsafe {
                nogui_accesskit_bridge_update(
                    bridge,
                    &update,
                    (&update as *const NoguiTreeUpdate).cast_mut().cast(),
                    Some(crate::unchanged_full_tree),
                )
            };
            // SAFETY: the handle came from `nogui_accesskit_bridge_new` and is
            // consumed exactly once.
            unsafe { nogui_accesskit_bridge_free(bridge) };
            accepted
        })
        .join()
        .expect("the worker thread panicked");
        assert!(!accepted, "a worker thread was allowed to publish a tree");
    }

    /// The status read touches no adapter, so it answers from any thread. A
    /// bridge with no view has published nothing, which is what it says.
    #[test]
    fn a_bridge_with_no_view_has_published_nothing() {
        // SAFETY: the handle is read through one entry point and freed exactly
        // once, and no callback is registered.
        let bridge = unsafe {
            nogui_accesskit_bridge_new(std::ptr::null_mut(), None, None, None)
        };
        assert!(!bridge.is_null(), "the bridge refused to be created");
        // SAFETY: the handle is live for the call.
        assert!(!unsafe { nogui_accesskit_bridge_is_active(bridge) });
        // SAFETY: the handle came from `nogui_accesskit_bridge_new` and is
        // consumed exactly once.
        unsafe { nogui_accesskit_bridge_free(bridge) };
    }

    /// A null window, a null class name and a null handle are all refused
    /// before the platform is touched.
    #[test]
    fn a_null_argument_is_refused() {
        // SAFETY: every call below is passed a null pointer, which each entry
        // point checks before it dereferences anything.
        unsafe {
            assert!(!nogui_accesskit_bridge_set_view(
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                false
            ));
            assert!(!nogui_accesskit_bridge_add_focus_forwarder(std::ptr::null()));
            assert!(!nogui_accesskit_bridge_is_active(std::ptr::null()));
            nogui_accesskit_bridge_free(std::ptr::null_mut());
        }
    }
}
