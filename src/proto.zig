//! nogui prototype — exploratory API design for the UI layer.
//!
//! PROTOTYPE — throwaway design exploration. The widget tree type,
//! two-phase layout engine, and carrier abstractions (Context,
//! Window, DrawCtx) are being validated here before folding into
//! the real root.zig.
//!
//! To run: zig build run

const std = @import("std");

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

// ─── Event system ─────────────────────────────────────
pub const Event = @import("proto/event.zig").Event;
pub const InputState = @import("proto/context.zig").InputState;
pub const InteractionState = @import("proto/widget.zig").InteractionState;
pub const Key = @import("proto/widget.zig").Key;
pub const KeyMods = @import("proto/widget.zig").KeyMods;
pub const MouseButton = @import("proto/widget.zig").MouseButton;
pub const hitTest = @import("proto/event.zig").hitTest;
pub const dispatchEvents = @import("proto/event.zig").dispatchEvents;
pub const isHot = @import("proto/event.zig").isHot;
pub const isActive = @import("proto/event.zig").isActive;
pub const isFocused = @import("proto/event.zig").isFocused;
pub const wasClicked = @import("proto/event.zig").wasClicked;

test {
    _ = @import("proto/widget.zig");
    _ = @import("proto/sweeper.zig");
    @import("std").testing.refAllDecls(@This());
}

test {
    _ = @import("proto/layout.zig");
}

test {
    _ = @import("proto/headless.zig");
    _ = @import("proto/app.zig");
    _ = @import("proto/cmd.zig");
    _ = @import("proto/frame_pacer.zig");
    _ = @import("proto/thread_pool.zig");
    _ = @import("proto/bg_task.zig");
    _ = @import("proto/comp_queue.zig");
    _ = @import("proto/component.zig");
}

test {
    std.testing.refAllDecls(@import("app_framework.zig"));
    std.testing.refAllDecls(@import("proto/headless.zig"));
}
