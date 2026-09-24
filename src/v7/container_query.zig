//! Width-dependent children built after the query has a measured content box.
const widget = @import("widget.zig");
const DrawCtx = @import("drawctx.zig").DrawCtx;
const element = @import("element.zig");
const FrameNodeId = @import("id.zig").FrameNodeId;
const default_style: widget.Style = .{};

/// Size and placement belong to the query, not to the selected children.
/// An automatic width uses the available width. An automatic height is zero.
/// Give the query an explicit height when it must display children in flow.
pub const Options = struct {
    width: widget.Dimension = .auto,
    height: widget.Dimension = .{ .length = 0 },
    min_width: widget.Dimension = .{ .length = 0 },
    max_width: widget.Dimension = .auto,
    min_height: widget.Dimension = .{ .length = 0 },
    max_height: widget.Dimension = .auto,
    display: widget.Display = .flex,
    position: widget.Position = .relative,
    grow: f32 = 0,
    shrink: f32 = 1,
    flex_basis: widget.Dimension = .auto,
    box_sizing: widget.BoxSizing = .content_box,
    margin_inset: widget.Insets = default_style.margin_inset,
    border_inset: widget.LengthPercentageRect = default_style.border_inset,
    padding_inset: widget.LengthPercentageRect = default_style.padding_inset,
};

fn Payload(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T,

        pub fn measure(_: *const Self, input: element.MeasureInput) element.Error!widget.Size {
            return .{
                .width = input.known_dimensions.width orelse switch (input.available_space.width) {
                    .definite => |available| available,
                    .min_content, .max_content => 0,
                },
                .height = input.known_dimensions.height orelse 0,
            };
        }

        pub fn buildLate(self: *const Self, size: widget.Size, ctx: *DrawCtx) anyerror!void {
            try T.build(&self.value, size, ctx);
        }
    };
}

/// `T.build(self: *const T, size: widget.Size, ctx: *DrawCtx)` builds one
/// selected branch. `size` is the laid-out content size, not an estimate from
/// draw time. The returned node ID belongs to this frame only.
///
/// The value is copied into the frame arena. Referenced data must remain valid
/// through this frame and the previous-frame comparison.
pub fn query(comptime T: type, ctx: *DrawCtx, value: T, options: Options) !FrameNodeId {
    if (@typeInfo(T) != .@"struct") @compileError("query payload must be a struct");
    if (!@hasDecl(T, "build")) @compileError("query payload must declare build");
    const id = try ctx.elementContainer(Payload(T), .{ .value = value }, .{
        .late_scope = element.LateScope.query,
        .width = options.width,
        .height = options.height,
        .min_width = options.min_width,
        .max_width = options.max_width,
        .min_height = options.min_height,
        .max_height = options.max_height,
        .display = options.display,
        .position = options.position,
        .grow = options.grow,
        .shrink = options.shrink,
        .flex_basis = options.flex_basis,
        .box_sizing = options.box_sizing,
        .margin_inset = options.margin_inset,
        .border_inset = options.border_inset,
        .padding_inset = options.padding_inset,
    });
    ctx.pop();
    return id;
}
