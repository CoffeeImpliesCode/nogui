//! The barrier that makes `nogui_accesskit_bridge_free` a real cutover.
//!
//! AccessKit cannot be shut down on any of the three platforms, so dropping an
//! adapter is a request and not a barrier. Each pinned crate shows it, and
//! each shows it differently.
//!
//! AT-SPI (`accesskit_unix 0.23.0`) exports nothing but the adapter.
//! `src/lib.rs:27` is the whole public surface, `pub use adapter::Adapter;`.
//! There is no `shutdown`, no `join`, no handle of any kind. `Drop for Adapter`
//! only enqueues work, and does not wait for it:
//!
//! ```text
//! accesskit_unix-0.23.0/src/adapter.rs:240
//! impl Drop for Adapter {
//!     fn drop(&mut self) {
//!         self.send_message(Message::RemoveAdapter { id: self.id });
//!     }
//! }
//! ```
//!
//! `send_message` is a non-blocking `try_send` onto an unbounded channel
//! (`adapter.rs:159`). The task that would drain that channel is a detached
//! `thread::spawn` created inside a `OnceLock` (`context.rs:49`); its handle is
//! dropped on the floor, and it runs a `loop { select! { .. } }` with no exit
//! arm (`context.rs:197`), so it is not merely unjoined, it never ends. Worse,
//! the AT-SPI interfaces are served on the zbus connection's object server
//! (`src/atspi/bus.rs:180`), which dispatches each incoming method call as its
//! own task on that same executor. A screen reader's action call is therefore a
//! detached task that can be neither cancelled nor awaited, and the crate
//! exposes no handle that could.
//!
//! AX (`accesskit_macos 0.27.0`) exports `Adapter`, `QueuedEvents`,
//! `SubclassingAdapter` and `add_focus_forwarder_to_window_class`, and no
//! handle. `Drop for SubclassingAdapter` restores the view's class and clears
//! the associated object (`subclass.rs:259`) and returns. The object it
//! installed holds the action handler in an `Rc`, and the accessibility system
//! keeps calling into that object for as long as the view is in a window, which
//! outlives the bridge whenever the host drops its adapter first.
//!
//! UI Automation (`accesskit_windows 0.35.0`) exports `Adapter`, `QueuedEvents`
//! and `SubclassingAdapter`, and again no handle.
//! `Drop for SubclassingAdapter` restores the previous window procedure and
//! removes the window property:
//!
//! ```text
//! accesskit_windows-0.35.0/src/subclass.rs:200
//! impl Drop for SubclassingAdapter {
//!     fn drop(&mut self) {
//!         self.0.uninstall();
//!     }
//! }
//! ```
//!
//! `uninstall` (`subclass.rs:126`) calls `SetWindowLongPtrW` and returns. It
//! does not wait for a screen reader worker already inside the action handler,
//! and no API in the crate would let it. It can also panic, which is why the
//! drop runs inside the same panic containment as the rest of the teardown.
//!
//! So after `free` returns, AccessKit can still reach the handler objects and
//! call into a host pointer the caller is about to poison. The only ordering
//! the bridge can enforce is one it owns, and that is this gate.

use std::sync::{Mutex, MutexGuard};

/// A one-way latch that orders host callbacks against teardown.
///
/// A handler holds it for the whole of the host callback. Teardown closes it
/// and takes it, which does both halves of the job at once: it stops the next
/// handler from starting, and it blocks until the one already inside the host
/// has returned.
///
/// [`Gate::enter`] is deliberately not reentrant, and that puts a real
/// requirement on the host: a callback must not call `free`, or any other
/// entry point that takes the gate, on its own thread. It would wait on a
/// latch its own thread holds, and on macOS that is not a theoretical hazard
/// but the ordinary path: AccessKit documents that the action handler always
/// runs on the main thread (`accesskit_macos-0.27.0/src/subclass.rs:129`), and
/// a host that acts on an ordinary VoiceOver Close or Delete by destroying the
/// window would be freeing the bridge from inside its own callback.
///
/// The Zig host satisfies this: its callbacks only enqueue a request or set a
/// flag and return (`AdapterCallbacks` in `src/v7_host/accessibility.zig`), and it frees the
/// bridge from its own teardown, never from a callback.
pub(crate) struct Gate {
    closed: Mutex<bool>,
}

impl Gate {
    pub(crate) fn new() -> Self {
        Gate {
            closed: Mutex::new(false),
        }
    }

    /// Run `body` unless teardown has already closed the gate.
    ///
    /// The latch is held across the whole of `body`, so a teardown racing this
    /// call blocks until the host pointer has no reader left. Returns `None`
    /// when the gate is already closed, which is the common case after free:
    /// AccessKit still owns the handler objects and may call them.
    pub(crate) fn enter<T>(&self, body: impl FnOnce() -> T) -> Option<T> {
        let closed = lock(&self.closed);
        if *closed {
            return None;
        }
        Some(body())
    }

    /// Close the gate and wait for the in-flight handler, if any, to return.
    ///
    /// This cannot deadlock for any caller that is not a host callback on its
    /// own thread, and the two facts that make it true are both about the
    /// order. It takes one lock, the gate, and it takes it last. A handler
    /// takes the gate first and then only locks that belong to itself: its own
    /// `active` flag, which `set_active` drops again before the host callback
    /// runs, and the host's own lock inside that callback. Nothing reached from
    /// the gate is ever held while waiting for the gate.
    ///
    /// The one caller that WOULD deadlock is a host callback, because the gate
    /// is not reentrant: it already holds this lock on this thread. That case
    /// is stated on [`Gate`] and in the header, and it is why a host callback
    /// may only enqueue or set a flag. The one other thing that would block is
    /// a host callback that never returns, and that is the host's contract,
    /// not this crate's.
    pub(crate) fn close(&self) {
        *lock(&self.closed) = true;
    }

    /// Whether teardown has closed the gate. Test-only introspection.
    #[cfg(test)]
    pub(crate) fn is_closed(&self) -> bool {
        *lock(&self.closed)
    }
}

/// Lock without failing on a poisoned mutex.
///
/// A host callback runs in an `extern "C"` frame, so it cannot unwind through
/// this lock. Recovering the value anyway is the cheap half of being right: a
/// poisoned `Gate` still says the true thing about whether teardown has run,
/// and a poisoned `active` flag still says the true thing about whether the
/// platform is up. Propagating the poison instead would turn one caught panic
/// into a permanently broken bridge.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A stand-in for the Zig `Adapter` and its three callbacks, shared by the gate
/// tests here and the live-adapter test in `platform::unix`.
///
/// The bridge only ever sees the host's address, exactly as it sees the real
/// one's. The `Arc` is the owner, and it is dropped by a test only after the
/// gate has closed, which is the last moment a callback can still reach the
/// host, so no test leaks an allocation to get a stable address.
#[cfg(test)]
pub(crate) mod host {
    use super::lock;
    use crate::{Action, ActionRequest, Callbacks, NodeId, NoguiRequest, TreeId};
    use std::ffi::c_void;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::mpsc::{self, Receiver, SyncSender};
    use std::sync::Arc;

    pub(crate) struct Host {
        /// Cleared the instant teardown returns, mirroring the Zig order:
        /// free first, then `self.* = undefined`.
        alive: AtomicBool,
        /// Callbacks that entered the host after it was cleared.
        late: AtomicUsize,
        /// Callbacks that entered the host while it was live.
        seen: AtomicUsize,
        /// Announces that a callback is parked inside the host.
        entered: SyncSender<()>,
        /// Lets the test let that callback out again.
        release: Mutex<Receiver<()>>,
        /// Whether the next callback should park.
        park: AtomicBool,
    }

    impl Host {
        pub(crate) fn new() -> (Arc<Host>, Receiver<()>, mpsc::Sender<()>) {
            let (entered_tx, entered_rx) = mpsc::sync_channel(1);
            let (release_tx, release_rx) = mpsc::channel();
            let host = Arc::new(Host {
                alive: AtomicBool::new(true),
                late: AtomicUsize::new(0),
                seen: AtomicUsize::new(0),
                entered: entered_tx,
                release: Mutex::new(release_rx),
                park: AtomicBool::new(false),
            });
            (host, entered_rx, release_tx)
        }

        /// The address the bridge would hold.
        pub(crate) fn user(host: &Arc<Host>) -> *mut c_void {
            Arc::as_ptr(host) as *mut Host as *mut c_void
        }

        /// What the Zig host does the moment `nogui_accesskit_bridge_free`
        /// returns.
        pub(crate) fn poison(host: &Arc<Host>) {
            host.alive.store(false, Ordering::SeqCst);
        }

        pub(crate) fn revive(host: &Arc<Host>) {
            host.alive.store(true, Ordering::SeqCst);
        }

        pub(crate) fn park_next_callback(&self) {
            self.park.store(true, Ordering::SeqCst);
        }

        pub(crate) fn late(&self) -> usize {
            self.late.load(Ordering::SeqCst)
        }

        pub(crate) fn seen(&self) -> usize {
            self.seen.load(Ordering::SeqCst)
        }
    }

    /// Every `extern "C"` entry into the test host goes through here.
    ///
    /// # Safety
    ///
    /// `user` must be `Host::user` of an `Arc<Host>` that is still alive.
    unsafe fn enter_host(user: *mut c_void) {
        let host = unsafe { &*user.cast::<Host>() };
        if !host.alive.load(Ordering::SeqCst) {
            host.late.fetch_add(1, Ordering::SeqCst);
            return;
        }
        host.seen.fetch_add(1, Ordering::SeqCst);
        if host.park.swap(false, Ordering::SeqCst) {
            let _ = host.entered.try_send(());
            let _ = lock(&host.release).recv();
        }
    }

    pub(crate) unsafe extern "C" fn on_activate(user: *mut c_void) {
        unsafe { enter_host(user) };
    }

    pub(crate) unsafe extern "C" fn on_deactivate(user: *mut c_void) {
        unsafe { enter_host(user) };
    }

    /// Answers 1, so a live host stands in for a ring that accepted the
    /// request. What it does not stand in for is the model having changed,
    /// which is the whole point of the queue-acceptance contract.
    ///
    /// # Safety
    ///
    /// `user` must be `Host::user` of an `Arc<Host>` that is still alive.
    pub(crate) unsafe extern "C" fn on_action(
        user: *mut c_void,
        _request: *const NoguiRequest,
    ) -> u8 {
        unsafe { enter_host(user) };
        1
    }

    /// The two handler objects every platform has, bound to `host`.
    pub(crate) fn callbacks(host: &Arc<Host>) -> Arc<Callbacks> {
        Arc::new(Callbacks::new(
            Host::user(host),
            Some(on_action),
            Some(on_activate),
        ))
    }

    pub(crate) fn action_request() -> ActionRequest {
        ActionRequest {
            action: Action::Click,
            target_tree: TreeId::ROOT,
            target_node: NodeId(1),
            data: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::host::*;
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::mpsc;
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    /// A handler already inside the host must be waited for.
    ///
    /// This is the use-after-free in miniature. A callback is parked inside
    /// the host, teardown runs, and the host is cleared. The gate has to hold
    /// teardown until the parked callback leaves, so the clear can never land
    /// under a running handler. Without a gate, teardown returns at once and
    /// the wait below completes immediately.
    #[test]
    fn teardown_waits_for_the_handler_already_inside_the_host() {
        let (host, entered, release) = Host::new();
        host.park_next_callback();
        let callbacks = callbacks(&host);

        // Every thread keeps its own `Arc<Host>`. The bridge holds only a raw
        // pointer, so a thread parked inside the host is what keeps the host
        // alive. Without that, a failing run frees the host under a running
        // callback and turns a clean failure into a crash.
        let parked = {
            let host = Arc::clone(&host);
            let callbacks = Arc::clone(&callbacks);
            thread::spawn(move || {
                let _host = host;
                callbacks.activate()
            })
        };
        entered
            .recv_timeout(Duration::from_secs(5))
            .expect("the activation callback never reached the host");

        let (done_tx, done_rx) = mpsc::channel();
        let teardown = {
            let host = Arc::clone(&host);
            let callbacks = Arc::clone(&callbacks);
            thread::spawn(move || {
                callbacks.close();
                Host::poison(&host);
                let _ = done_tx.send(());
            })
        };

        // Teardown must still be waiting. Recorded rather than asserted, so
        // the handler is always let out and both threads joined before any
        // failure is reported.
        let observed = done_rx.recv_timeout(Duration::from_millis(400));
        let _ = release.send(());
        parked.join().expect("activation panicked");
        teardown.join().expect("teardown panicked");

        assert_eq!(
            observed,
            Err(mpsc::RecvTimeoutError::Timeout),
            "teardown returned while a handler was still inside the host callback"
        );
        assert_eq!(host.late(), 0, "a callback ran under a cleared host");
    }

    /// Once teardown has closed the gate, no handler reaches the host again.
    ///
    /// The hammering threads stand in for the AccessKit handler objects, which
    /// keep calling after free because AccessKit cannot be stopped. Any of
    /// them arriving after the clear is the use-after-free. Windows and macOS
    /// have two handler objects and AT-SPI has three; the third AT-SPI path is
    /// the deactivation handler, which is tested with the AT-SPI adapter in
    /// `platform::unix`.
    #[test]
    fn no_handler_reaches_the_host_once_teardown_has_closed_the_gate() {
        let (host, _entered, _release) = Host::new();
        let callbacks = callbacks(&host);
        let stop = Arc::new(AtomicBool::new(false));

        let hammerers: Vec<_> = (0..2)
            .map(|index| {
                let host = Arc::clone(&host);
                let callbacks = Arc::clone(&callbacks);
                let stop = Arc::clone(&stop);
                thread::spawn(move || {
                    let _host = host;
                    while !stop.load(Ordering::SeqCst) {
                        if index == 0 {
                            callbacks.activate();
                        } else {
                            callbacks.action(action_request());
                        }
                    }
                })
            })
            .collect();

        // Let them run long enough that the arm is not vacuous.
        thread::sleep(Duration::from_millis(200));
        callbacks.close();
        Host::poison(&host);
        thread::sleep(Duration::from_millis(200));
        stop.store(true, Ordering::SeqCst);
        for hammerer in hammerers {
            hammerer.join().expect("a handler panicked");
        }

        assert!(host.seen() > 0, "no handler ran at all, so this proved nothing");
        assert_eq!(
            host.late(),
            0,
            "a handler entered the host after teardown returned"
        );
    }

    /// A closed gate is a latch and not a queue: closing twice is free, and a
    /// second close does not reopen anything.
    #[test]
    fn closing_twice_stays_closed() {
        let gate = Gate::new();
        assert!(!gate.is_closed());
        gate.close();
        gate.close();
        assert!(gate.is_closed());
        assert_eq!(gate.enter(|| 1), None);
    }

    /// Only one host callback runs at a time.
    ///
    /// The latch is held across the body, so the bridge admits one handler at
    /// a time even though AccessKit runs the activation handler and the action
    /// handler on different threads. The Zig host takes its own mutex inside
    /// the callback, and holding the latch across that call is what keeps the
    /// two locks in a single order instead of two.
    #[test]
    fn the_gate_admits_one_handler_at_a_time() {
        const CALLERS: usize = 4;
        const ROUNDS: usize = 2_000;
        let gate = Arc::new(Gate::new());
        let inside = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let ran = Arc::new(AtomicUsize::new(0));

        let callers: Vec<_> = (0..CALLERS)
            .map(|_| {
                let gate = Arc::clone(&gate);
                let inside = Arc::clone(&inside);
                let peak = Arc::clone(&peak);
                let ran = Arc::clone(&ran);
                thread::spawn(move || {
                    for _ in 0..ROUNDS {
                        if gate
                            .enter(|| {
                                let now = inside.fetch_add(1, Ordering::SeqCst) + 1;
                                peak.fetch_max(now, Ordering::SeqCst);
                                thread::yield_now();
                                inside.fetch_sub(1, Ordering::SeqCst);
                            })
                            .is_some()
                        {
                            ran.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                })
            })
            .collect();
        for caller in callers {
            caller.join().expect("a caller panicked");
        }

        assert_eq!(ran.load(Ordering::SeqCst), CALLERS * ROUNDS);
        assert_eq!(
            peak.load(Ordering::SeqCst),
            1,
            "two host callbacks were inside the host at once"
        );
    }
}
