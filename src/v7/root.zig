//! v7 prototype module root — DrawCtx + components (headless-first).
//! See notes/v7-prototype-spec.md.
const std = @import("std");

pub const Id = @import("id.zig").Id;
pub const Rect = @import("widget.zig").Rect;
pub const Size = @import("widget.zig").Size;
pub const FlexChild = @import("widget.zig").FlexChild;
pub const WidgetKind = @import("widget.zig").WidgetKind;
pub const WidgetNode = @import("widget.zig").WidgetNode;
pub const WidgetTree = @import("widget.zig").WidgetTree;
pub const wrap = @import("callback.zig").wrap;
pub const DrawCtx = @import("drawctx.zig").DrawCtx;
pub const ComponentVTable = @import("component.zig").ComponentVTable;
pub const Component = @import("component.zig").Component;
pub const Direction = @import("flex.zig").Direction;
pub const Justify = @import("flex.zig").Justify;
pub const Align = @import("flex.zig").Align;
pub const FlexStyle = @import("flex.zig").FlexStyle;
pub const Event = @import("event.zig").Event;
pub const dispatchClick = @import("event.zig").dispatchClick;
pub const FrameOutput = @import("headless.zig").FrameOutput;
pub const treeToJson = @import("headless.zig").treeToJson;
pub const App = @import("app.zig").App;

test {
    std.testing.refAllDecls(@This());
}
