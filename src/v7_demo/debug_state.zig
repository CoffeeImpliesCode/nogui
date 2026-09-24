//! Demo render toggles, shared between the window and the UI.
//!
//! The window writes this once per frame, before the tree is built, and the
//! UI reads it for the header status line. The UI cannot import the window,
//! so the state needs its own module; it is demo policy, not engine state,
//! and stays out of the public frame engine.

pub const DebugState = struct {
    subpixel: bool = false,
    bgr: bool = false,
    damp: bool = true,
    quad_debug: bool = false,
};

pub var debug_state: DebugState = .{};
