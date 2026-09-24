//! Renderer external consumer of the `nogui` package.
//!
//! Lowers paint records to scene records on the CPU through `v7_render`.
//! No window is opened and no GPU is initialised, so this runs on a machine
//! with no display, no Vulkan loader and no driver.
const std = @import("std");
const nogui = @import("nogui");
const render = @import("v7_render");

const paint = nogui.paint;

/// Material slots and scene slots the lowering stage is allowed to fill.
const budget = struct {
    const material_first: u32 = 1;
    const material_end: u32 = 5;
    const rect_scratch: usize = 4;
    const curve_scratch: usize = 4;
};

fn oklabOf(record: *const paint.PaintRecord) [4]f32 {
    const solid = record.shape.rect.fill.?.solid;
    return .{ solid.l, solid.a, solid.b, solid.alpha };
}

fn assertColor(got: [4]f32, want: [4]f32) !void {
    for (got, want) |g, w| {
        if (@abs(g - w) > 1e-6) return error.ColorMismatch;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var list = paint.PaintList.init(gpa, &.{}, 2);
    defer list.deinit();

    // A flat solid fill needs no material slot; the bordered one does.
    try list.addRect(.{
        .bounds = .{ .x = 4, .y = 6, .w = 40, .h = 20 },
        .fill = .{ .solid = .{ .srgb = .{ .r = 1, .g = 0, .b = 0 } } },
    });
    try list.addRect(.{
        .bounds = .{ .x = 10, .y = 30, .w = 60, .h = 24 },
        .fill = .{ .solid = .{ .srgb = .{ .r = 0, .g = 0, .b = 1 } } },
        .borders = .{
            .{ .width = 2, .style = .solid, .color = .{ .srgb = .{ .r = 0, .g = 1, .b = 0 } } },
            .{ .width = 0, .style = .none },
            .{ .width = 0, .style = .none },
            .{ .width = 0, .style = .none },
        },
    });
    if (list.records.items.len != 2) return error.UnexpectedRecordCount;

    var rects: [budget.rect_scratch]render.SceneRect = undefined;
    var curves: [budget.curve_scratch]nogui.path.Quadratic = undefined;
    var materials: [budget.material_end - budget.material_first]render.PaintMaterial = undefined;

    const lowered: render.Lowered = try render.lowerPaint(
        &.{},
        list.records.items,
        &rects,
        &curves,
        &materials,
        .{ .first = budget.material_first, .end = budget.material_end },
    );

    // Flat fill: one scene rect that samples the identity tint. The bordered
    // fill: a fill rect plus a border rect, each with its own material slot.
    if (lowered.rects.len != 3) {
        std.debug.print("scene rect count {d}, expected 3\n", .{lowered.rects.len});
        return error.UnexpectedSceneRectCount;
    }
    if (lowered.materials.len != 2) {
        std.debug.print("material count {d}, expected 2\n", .{lowered.materials.len});
        return error.UnexpectedMaterialCount;
    }
    for (lowered.materials) |material| {
        if (material.material.type != render.type_paint_rect) return error.UnexpectedMaterialType;
        if (material.curve_count != 0) return error.RectMaterialClaimedCurves;
    }

    // The flat fill must not consume a material slot; the two primed rects
    // must take consecutive slots starting at the requested range.
    if (lowered.rects[0].material_index != 0) return error.FlatFillAllocatedMaterial;
    if (lowered.rects[1].material_index != budget.material_first) {
        return error.FillDidNotTakeFirstMaterial;
    }
    if (lowered.rects[2].material_index != budget.material_first + 1) {
        return error.BorderDidNotTakeNextMaterial;
    }
    if (lowered.materials[0].extra.border_width[0] != 2 or
        lowered.materials[0].extra.border_styles[0] != @intFromEnum(paint.BorderStyle.solid))
    {
        return error.MaterialLostBorderWidth;
    }

    // Colour must survive lowering: red fill, blue fill, green border.
    const first_fill = oklabOf(&list.records.items[0]);
    const second_fill = oklabOf(&list.records.items[1]);
    const border = list.records.items[1].shape.rect.borders[0].color;
    // Red and green lean towards +b in Oklab, blue towards -b; a green that
    // silently became black would still pass a plain alpha check.
    if (!(first_fill[0] > 0) or !(first_fill[2] > 0)) return error.FirstFillNotRed;
    if (!(second_fill[0] > 0) or !(second_fill[2] < 0)) return error.SecondFillNotBlue;
    if (!(border.l > 0) or !(border.b > 0)) return error.BorderNotGreen;
    assertColor(lowered.rects[0].color, first_fill) catch return error.LoweringLostFirstFillColor;
    assertColor(lowered.rects[1].color, second_fill) catch return error.LoweringLostSecondFillColor;
    assertColor(lowered.rects[2].color, .{
        border.l,
        border.a,
        border.b,
        border.alpha,
    }) catch return error.LoweringLostBorderColor;

    const line = try std.fmt.allocPrint(gpa, "renderer: OK rects={d} materials={d}\n", .{
        lowered.rects.len,
        lowered.materials.len,
    });
    defer gpa.free(line);
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
