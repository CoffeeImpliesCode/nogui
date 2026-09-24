//! Mobile window lifecycle and native semantics. SDL owns the window.
//! UIKit uses logical points. Android uses physical window pixels.
//! Call Observer.pump for raw observation and normal Application dispatch.
//! Shut down the observer before the borrowed window closes.
pub const native = @import("native.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const sdl_mobile = @import("sdl_mobile.zig");
pub const accessibility = @import("accessibility.zig");

test {
    _ = @import("lifecycle.zig");
    _ = @import("sdl_mobile.zig");
    _ = @import("accessibility.zig");
}
