//! The AT-SPI adapter: `accesskit_unix`, for every Unix that is not macOS.
//!
//! This is the only one of the three that is live the moment
//! `nogui_accesskit_bridge_new` returns, because `Adapter::new` connects to the
//! accessibility bus itself (`accesskit_unix-0.23.0/src/lib.rs:27` exports the
//! adapter and nothing else). It is also the only one of the three that takes a
//! deactivation handler, because AT-SPI is the only one of the three that
//! reports a screen reader going away. Those two facts are the reason this
//! module exists; the rest of it is the common ABI over a live adapter.

use crate::{ActionHandlerImpl, ActivationHandlerImpl, Callbacks, DeactivationFn, Submission};
use accesskit::{DeactivationHandler, Rect};
use accesskit_atspi_common::EditableTextHandlerNoMut;
use std::sync::Arc;

/// The adapter, and not an `Option` of one: there is nothing to attach later.
pub(crate) type Adapter = accesskit_unix::Adapter;

/// The screen reader went away. AT-SPI says so, and it is the only one of the
/// three platforms that does.
///
/// The callback lives here rather than in `Callbacks` because this is the only
/// module that can invoke it, so on the other two targets there is no stored
/// function pointer that the platform can never call.
struct DeactivationHandlerImpl {
    callbacks: Arc<Callbacks>,
    on_deactivate: Option<DeactivationFn>,
}

impl DeactivationHandler for DeactivationHandlerImpl {
    fn deactivate_accessibility(&mut self) {
        let Some(callback) = self.on_deactivate else {
            return;
        };
        let callbacks = Arc::clone(&self.callbacks);
        callbacks.gate.enter(|| {
            callbacks.set_active(false);
            // SAFETY: the gate is open, so teardown has not run and the host
            // is still the caller's live object.
            unsafe { callback(callbacks.host()) };
        });
    }
}

pub(crate) fn new(
    callbacks: &Arc<Callbacks>,
    on_deactivate: Option<DeactivationFn>,
) -> Adapter {
    // The existing `Arc` is cloned and unsized, never reallocated: the handler
    // for the standard `EditableText` range methods IS the bridge's own
    // `Callbacks`. `Some` is not a promise the host will apply the edit; the
    // answer the provider gets back is the host queue's.
    let editable_text_handler: Arc<dyn EditableTextHandlerNoMut + Send + Sync> =
        callbacks.clone();
    accesskit_unix::Adapter::new(
        ActivationHandlerImpl(Arc::clone(callbacks)),
        ActionHandlerImpl(Arc::clone(callbacks)),
        DeactivationHandlerImpl {
            callbacks: Arc::clone(callbacks),
            on_deactivate,
        },
        Some(editable_text_handler),
    )
}

pub(crate) fn set_window_focused(adapter: &mut Adapter, focused: bool) {
    adapter.update_window_focus_state(focused);
}

pub(crate) fn set_window_bounds(adapter: &mut Adapter, outer: Rect, inner: Rect) {
    adapter.set_root_window_bounds(outer, inner);
}

/// `update_if_active` returns nothing on this adapter: the AT-SPI event loop is
/// still running and raises what it was given. Inactive is its own answer and
/// not a failure, so this is `true` either way.
pub(crate) fn update(adapter: &mut Adapter, callbacks: &Callbacks, update: Submission) -> bool {
    adapter.update_if_active(move || update.convert(callbacks));
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::teardown::host::{on_action, on_activate, on_deactivate, Host};
    use crate::{
        nogui_accesskit_bridge_free, nogui_accesskit_bridge_is_active,
        nogui_accesskit_bridge_new, Callbacks,
    };
    use std::ffi::c_void;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    /// Counts through the host pointer the bridge hands back, so the test needs
    /// no static and no second allocation.
    ///
    /// # Safety
    ///
    /// `user` must be a live `*mut AtomicUsize`.
    unsafe extern "C" fn count(user: *mut c_void) {
        // SAFETY: the test passes the pointer of an `Arc` it keeps alive for
        // the whole callback.
        unsafe { (*user.cast::<AtomicUsize>()).fetch_add(1, Ordering::SeqCst) };
    }

    /// A deactivation clears the flag and reaches the host, and it is the only
    /// platform that can do either.
    ///
    /// The flag is what `nogui_accesskit_bridge_is_active` answers from, so a
    /// deactivation that did not clear it would leave a host reporting itself
    /// connected to a screen reader that has gone.
    #[test]
    fn a_deactivation_clears_the_flag_and_reaches_the_host() {
        let seen = Arc::new(AtomicUsize::new(0));
        // SAFETY: the pointer below is the address of an `Arc` this test keeps
        // alive for the whole call, and `count` only increments through it.
        let callbacks = Arc::new(Callbacks::new(
            Arc::as_ptr(&seen).cast_mut().cast::<c_void>(),
            None,
            None,
        ));
        callbacks.set_active(true);
        assert!(callbacks.is_active());
        let mut handler = DeactivationHandlerImpl {
            callbacks: Arc::clone(&callbacks),
            on_deactivate: Some(count),
        };
        handler.deactivate_accessibility();
        assert_eq!(seen.load(Ordering::SeqCst), 1);
        assert!(
            !callbacks.is_active(),
            "a deactivation left the bridge reporting itself active"
        );
    }

    /// The real entry points, a real AT-SPI adapter, and a real host.
    ///
    /// Each round builds a bridge and tears it straight down, which is what
    /// the Zig suite does and what the reported crash looked like: a screen
    /// reader connects, AccessKit activates the adapter, and the test finishes
    /// and frees while that activation is still in flight. Without the gate
    /// the activation lands on a host that `free` has already released.
    ///
    /// AccessKit only calls the handlers when a screen reader is attached, so
    /// the strong arm runs only then. Where there is no screen reader this
    /// checks the weaker fact that free on a live adapter is clean, and says
    /// so out loud rather than passing in silence. Set
    /// `NOGUI_ACCESSKIT_REQUIRE_SCREEN_READER=1` to make a missing screen
    /// reader a failure instead of a note.
    #[test]
    fn freeing_a_live_bridge_reaches_no_late_callback() {
        const ROUNDS: usize = 64;
        let (host, _entered, _release) = Host::new();
        let mut attached = false;
        let mut late = 0;

        for round in 0..ROUNDS {
            // SAFETY: the handle is used only through the three callbacks
            // below, and `host` outlives every bridge.
            let bridge = unsafe {
                nogui_accesskit_bridge_new(
                    Host::user(&host),
                    Some(on_action),
                    Some(on_activate),
                    Some(on_deactivate),
                )
            };
            assert!(!bridge.is_null(), "the bridge refused to be created");

            // The first round waits for the event loop to reach the AT-SPI bus
            // and react to the screen reader. The rest run hot, so teardown
            // lands on adapters that are still being activated.
            if round == 0 {
                let deadline = Instant::now() + Duration::from_secs(5);
                // SAFETY: the handle is live for the whole loop.
                while !unsafe { nogui_accesskit_bridge_is_active(bridge) }
                    && Instant::now() < deadline
                {
                    thread::sleep(Duration::from_millis(20));
                }
            }
            // SAFETY: as above.
            if unsafe { nogui_accesskit_bridge_is_active(bridge) } {
                attached = true;
            }

            // SAFETY: the handle came from `nogui_accesskit_bridge_new` and is
            // consumed exactly once.
            unsafe { nogui_accesskit_bridge_free(bridge) };
            Host::poison(&host);

            // The AccessKit event loop outlives the bridge and cannot be
            // stopped, so give it room to try to call back on a dead host.
            thread::sleep(Duration::from_millis(15));
            late = host.late();
            if late > 0 {
                break;
            }
            Host::revive(&host);
        }

        // The last bridge is already freed, so nothing can reach the host now.
        thread::sleep(Duration::from_millis(250));
        late = late.max(host.late());
        assert_eq!(
            late,
            0,
            "a callback ran after nogui_accesskit_bridge_free returned"
        );

        if attached {
            assert!(
                host.seen() > 0,
                "a screen reader is attached but no callback ever ran"
            );
        } else {
            assert_eq!(
                host.seen(),
                0,
                "callbacks ran with no screen reader attached, so the test setup is wrong"
            );
            assert!(
                std::env::var_os("NOGUI_ACCESSKIT_REQUIRE_SCREEN_READER").is_none(),
                "no screen reader is attached, so the real AccessKit callback path \
                 was not exercised by this test"
            );
            eprintln!(
                "note: no screen reader is attached (org.a11y.Status \
                 ScreenReaderEnabled is false, or there is no AT-SPI bus), so the \
                 real AccessKit callback path was NOT exercised. Set the property to \
                 true, or set NOGUI_ACCESSKIT_REQUIRE_SCREEN_READER=1 to make that a \
                 failure."
            );
        }
    }
}
