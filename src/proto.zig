//! nogui prototype — exploratory API design for the UI layer.
//!
//! PROTOTYPE — throwaway design exploration. The widget tree type,
//! two-phase layout engine, and carrier abstractions (Context,
//! Window, DrawCtx) are being validated here before folding into
//! the real root.zig.
//!
//! To run: zig build run

pub const Context = @import("proto/context.zig").Context;
pub const Window = @import("proto/window.zig").Window;
pub const DrawCtx = @import("proto/drawctx.zig").DrawCtx;
pub const Widget = @import("proto/widget.zig").Widget;
pub const Sizing = @import("proto/widget.zig").Sizing;
pub const SizingAxis = @import("proto/widget.zig").SizingAxis;
pub const Size = @import("proto/widget.zig").Size;
pub const Rect = @import("proto/widget.zig").Rect;
pub const Direction = @import("proto/widget.zig").Direction;
pub const GlyphSweeper = @import("proto/sweeper.zig").GlyphSweeper;
pub const Curve = @import("proto/sweeper.zig").Curve;

test {
    @import("std").testing.refAllDecls(@This());
}
