//! The one platform adapter behind the shared C ABI.
//!
//! `cfg` picks exactly one of these three, so a host links one archive and
//! every target serves the same `nogui_accesskit_bridge_*` symbols. The split
//! is drawn where the platforms really differ, which is the adapter itself and
//! nothing else: the records, the discriminants, the marshalling, the gate and
//! the argument handling of the six common entry points all live in the crate
//! root, because one header describes them and a host compiles against that
//! header on every target.
//!
//! Each module answers the same five questions, and those answers are the
//! whole of what differs:
//!
//!   * `new`. AT-SPI attaches itself to a D-Bus connection in its
//!     constructor and is live on return. AX and UI Automation are built
//!     around one window, which the host has not created yet, so they return
//!     an empty adapter and the host attaches one afterwards.
//!   * `set_window_focused`. Forwarded everywhere but Windows, which learns
//!     the focus state from the window messages its own subclass receives.
//!   * `set_window_bounds`. Forwarded only on AT-SPI. The other two derive the
//!     window's rectangle themselves, so nothing is invented for them.
//!   * `update`. All three queue the events a tree update produces and hand
//!     them back for the bridge to raise, and all three answer `None` while no
//!     screen reader is attached. What differs is what an unattached handle
//!     says, and the module that answers it says why.
//!   * the deactivation handler. Only AT-SPI has a signal that a screen
//!     reader went away, so only AT-SPI is given the callback.
//!
//! The `cfg` arms here are the same expressions as the `[target.'cfg(..)']`
//! tables in `Cargo.toml`. They have to match: a dependency that is not there
//! cannot be named, and a table with no arm would be dead weight in the lock
//! file and nothing else.

#[cfg(all(unix, not(target_os = "macos")))]
mod unix;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(windows)]
mod windows;

#[cfg(all(unix, not(target_os = "macos")))]
pub(crate) use unix::{new, set_window_bounds, set_window_focused, update, Adapter};
#[cfg(target_os = "macos")]
pub(crate) use macos::{new, set_window_bounds, set_window_focused, update, Adapter};
#[cfg(windows)]
pub(crate) use windows::{new, set_window_bounds, set_window_focused, update, Adapter};

/// Fail loudly on a target no adapter serves, rather than exporting the C ABI
/// and quietly serving nobody. A host that compiled and linked but could never
/// see a tree is exactly the failure this exists to prevent.
#[cfg(not(any(
    all(unix, not(target_os = "macos")),
    target_os = "macos",
    windows,
)))]
compile_error!(
    "nogui_accesskit_bridge serves the non-macOS unixes through AT-SPI, macOS \
     through AX and Windows through UI Automation. This target has none of \
     them: add a module under src/platform and the matching [target.'cfg(..)'] \
     table in Cargo.toml, or the host will link an archive that cannot publish \
     a tree."
);
