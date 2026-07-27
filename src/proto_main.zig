//! Prototype main — demonstrates the nogui API.
//!
//! PROTOTYPE — throwaway design exploration. Validates the
//! Context/Window/DrawCtx/Gui abstraction and the two-phase
//! layout engine before folding into src/root.zig.
//!
//! Run with: zig build proto

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const proto = @import("proto");
const c = @cImport({
    @cDefine("FT2_BUILD_LIBRARY", "1");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
    @cInclude("freetype/ftglyph.h");
});

var exts_global: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_global;
}

/// Extract glyph curves for a specific character using FreeType.
fn extractCharCurves(alloc: std.mem.Allocator, face: c.FT_Face, ch: u21) ![]proto.Curve {
    const idx = c.FT_Get_Char_Index(face, @intCast(ch));
    if (idx == 0) return error.GlyphNotFound;
    if (c.FT_Load_Glyph(face, idx, c.FT_LOAD_NO_BITMAP) != 0) return error.GlyphLoadFailed;
    const outline = &face.*.glyph.*.outline;

    var buf: [4096]proto.Curve = undefined;
    var count: u32 = 0;
    var first_x: f32 = 0;
    var first_y: f32 = 0;
    var last_x: f32 = 0;
    var last_y: f32 = 0;

    const Ctx = struct {
        curves: *[4096]proto.Curve,
        count: *u32,
        first_x: *f32,
        first_y: *f32,
        last_x: *f32,
        last_y: *f32,
    };

    var ctx = Ctx{
        .curves = &buf,
        .count = &count,
        .first_x = &first_x,
        .first_y = &first_y,
        .last_x = &last_x,
        .last_y = &last_y,
    };

    const funcs = c.FT_Outline_Funcs{
        .move_to = struct {
            fn cb(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
                const p: *Ctx = @ptrCast(@alignCast(user));
                p.first_x.* = @as(f32, @floatFromInt(to.*.x)) / 64;
                p.first_y.* = @as(f32, @floatFromInt(to.*.y)) / 64;
                p.last_x.* = p.first_x.*;
                p.last_y.* = p.first_y.*;
                return 0;
            }
        }.cb,
        .line_to = struct {
            fn cb(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
                const p: *Ctx = @ptrCast(@alignCast(user));
                const tx = @as(f32, @floatFromInt(to.*.x)) / 64;
                const ty = @as(f32, @floatFromInt(to.*.y)) / 64;
                if (p.count.* < 4096) {
                    p.curves[p.count.*] = .{ .p0x = p.last_x.*, .p0y = p.last_y.*, .p1x = (p.last_x.* + tx) * 0.5, .p1y = (p.last_y.* + ty) * 0.5, .p2x = tx, .p2y = ty };
                    p.count.* += 1;
                }
                p.last_x.* = tx;
                p.last_y.* = ty;
                return 0;
            }
        }.cb,
        .conic_to = struct {
            fn cb(control: [*c]const c.FT_Vector, to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
                const p: *Ctx = @ptrCast(@alignCast(user));
                const cx = @as(f32, @floatFromInt(control.*.x)) / 64;
                const cy = @as(f32, @floatFromInt(control.*.y)) / 64;
                const tx = @as(f32, @floatFromInt(to.*.x)) / 64;
                const ty = @as(f32, @floatFromInt(to.*.y)) / 64;
                if (p.count.* < 4096) {
                    p.curves[p.count.*] = .{ .p0x = p.last_x.*, .p0y = p.last_y.*, .p1x = cx, .p1y = cy, .p2x = tx, .p2y = ty };
                    p.count.* += 1;
                }
                p.last_x.* = tx;
                p.last_y.* = ty;
                return 0;
            }
        }.cb,
        .cubic_to = struct {
            fn cb(c1: [*c]const c.FT_Vector, c2: [*c]const c.FT_Vector, to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
                const p: *Ctx = @ptrCast(@alignCast(user));
                const c1x = @as(f32, @floatFromInt(c1.*.x)) / 64;
                const c1y = @as(f32, @floatFromInt(c1.*.y)) / 64;
                const c2x = @as(f32, @floatFromInt(c2.*.x)) / 64;
                const c2y = @as(f32, @floatFromInt(c2.*.y)) / 64;
                const tx = @as(f32, @floatFromInt(to.*.x)) / 64;
                const ty = @as(f32, @floatFromInt(to.*.y)) / 64;
                if (p.count.* + 1 < 4096) {
                    const t: f32 = 0.5;
                    const mt = 1 - t;
                    const b0x = mt * p.last_x.* + t * c1x;
                    const b0y = mt * p.last_y.* + t * c1y;
                    const b1x = mt * c1x + t * c2x;
                    const b1y = mt * c1y + t * c2y;
                    const b2x = mt * c2x + t * tx;
                    const b2y = mt * c2y + t * ty;
                    const cx1 = mt * b0x + t * b1x;
                    const cy1 = mt * b0y + t * b1y;
                    const cx2 = mt * b1x + t * b2x;
                    const cy2 = mt * b1y + t * b2y;
                    const dx = mt * cx1 + t * cx2;
                    const dy = mt * cy1 + t * cy2;
                    p.curves[p.count.*] = .{ .p0x = p.last_x.*, .p0y = p.last_y.*, .p1x = b0x, .p1y = b0y, .p2x = dx, .p2y = dy };
                    p.count.* += 1;
                    p.curves[p.count.*] = .{ .p0x = dx, .p0y = dy, .p1x = cx2, .p1y = cy2, .p2x = tx, .p2y = ty };
                    p.count.* += 1;
                }
                p.last_x.* = tx;
                p.last_y.* = ty;
                return 0;
            }
        }.cb,
        .shift = 0,
        .delta = 0,
    };
    if (c.FT_Outline_Decompose(outline, &funcs, &ctx) != 0) return error.OutlineDecomposeFailed;

    const result = try alloc.dupe(proto.Curve, buf[0..count]);
    return result; // caller prints glyph info
}

// ─── Main ────────────────────────────────────────────
// The only thing the user writes: a struct with `draw()`.

const MyGui = struct {
    counter: i32 = 0,
    volume: f32 = 0.5,
    time_sec: f32 = 0,

    pub fn draw(self: *@This(), ctx: *proto.DrawCtx) !*proto.Widget {
        self.time_sec += 1.0 / 60.0;
        self.volume = @sin(self.time_sec * 0.5) * 0.5 + 0.5;

        const btn_blue = [4]f32{ 0.807668, -0.021430, -0.067556, 1.0 };
        const bg_dark = [4]f32{ 0.516395, 0.0, 0.0, 1.0 };

        const children = try ctx.allocator.alloc(*proto.Widget, 12);
        children[0] = try ctx.tempLabel("nogui prototype v0.1", .{ .sizing = .{ .x = .fit, .y = .fit } });
        children[1] = try ctx.tempButton("Click me!", .{ .sizing = .{ .x = .fit, .y = .fit }, .color = btn_blue, .corner_radius = 4 });
        children[2] = try ctx.tempSlider("Volume", &self.volume, 0, 1, .{ .sizing = .{ .x = .grow, .y = .fit }, .color = .{ 0.599211, -0.044541, 0.031354, 1.0 }, .corner_radius = 3 });

        const row_children = try ctx.allocator.alloc(*proto.Widget, 2);
        row_children[0] = try ctx.tempLabel("Counter:", .{});
        const counter_str = try std.fmt.allocPrint(ctx.allocator, "{}", .{self.counter});
        row_children[1] = try ctx.tempLabel(counter_str, .{});
        children[3] = try ctx.tempRow(row_children, .{ .padding = 4, .gap = 8, .sizing = .{ .x = .grow, .y = .fit } });

        children[4] = try ctx.tempButton("Quit", .{ .sizing = .{ .x = .fit, .y = .fit }, .color = btn_blue, .corner_radius = 4 });

        children[5] = try ctx.tempLabel("The quick brown fox jumps over the lazy dog.", .{ .sizing = .{ .x = .grow, .y = .fit } });
        children[6] = try ctx.tempLabel("ABCDEFGHIJKLMNOPQRSTUVWXYZ", .{ .sizing = .{ .x = .fit, .y = .fit } });
        children[7] = try ctx.tempLabel("abcdefghijklmnopqrstuvwxyz 0123456789", .{ .sizing = .{ .x = .fit, .y = .fit } });

        // Small font edge cases
        children[8] = try ctx.tempLabel("The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.", .{ .sizing = .{ .x = .grow, .y = .fit } });
        children[9] = try ctx.tempLabel("iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii", .{ .sizing = .{ .x = .fit, .y = .fit } });
        children[10] = try ctx.tempLabel("gggggggggggggggggggggggggggggggggggggggggggggggggg", .{ .sizing = .{ .x = .fit, .y = .fit } });
        children[11] = try ctx.tempLabel("MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM", .{ .sizing = .{ .x = .fit, .y = .fit } });

        return try ctx.tempColumn(children, .{ .padding = 16, .gap = 8, .sizing = .{
            .x = .grow,
            .y = .grow,
        }, .color = bg_dark, .corner_radius = 8 });
    }
};

// ─── Main ────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    // Vulkan loader via SDL3
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();

    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    exts_global = try init.arena.allocator().dupe([*:0]const u8, sdl_exts);

    // ─── Bootstrap ──────────────────────────────────

    const gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = "nogui",
        .validation = true,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
    });

    var ctx = proto.Context.init(gpa, gpu);
    defer ctx.deinit();

    // Load 9-slice quad shaders
    const vert_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "shaders/quad_vert.spv", gpa, .unlimited);
    defer gpa.free(vert_bytes);
    const frag_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "shaders/quad_frag.spv", gpa, .unlimited);
    defer gpa.free(frag_bytes);
    const vert_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, vert_bytes));
    const frag_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, frag_bytes));

    // Load blit shaders (fullscreen vertex + Oklab→sRGB fragment)
    const blit_vert_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "shaders/fullscreen_vert.spv", gpa, .unlimited);
    defer gpa.free(blit_vert_bytes);
    const blit_frag_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "shaders/blit_oklab.spv", gpa, .unlimited);
    defer gpa.free(blit_frag_bytes);
    const blit_vert_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, blit_vert_bytes));
    const blit_frag_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, blit_frag_bytes));

    // ─── Init FreeType ─────────────────────────────────
    var ft_lib: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_lib) != 0) @panic("FT init");
    defer _ = c.FT_Done_FreeType(ft_lib);

    const font_data = @embedFile("InterVariable.ttf");
    var face: c.FT_Face = undefined;
    std.debug.assert(font_data.len <= std.math.maxInt(u32));
    if (c.FT_New_Memory_Face(ft_lib, font_data.ptr, @as(c.FT_Long, @intCast(font_data.len)), 0, &face) != 0) @panic("FT face");
    defer _ = c.FT_Done_Face(face);
    if (c.FT_Set_Pixel_Sizes(face, 0, 480) != 0) @panic("FT_Set_Pixel_Sizes failed");

    // Extract glyph 'A' curves — renders as background sweep
    const a_curves = try extractCharCurves(gpa, face, 'A');
    defer gpa.free(a_curves);
    std.debug.print("Glyph 'A': {d} curves\n", .{a_curves.len});

    var win = try proto.Window.init(&ctx, "nogui prototype", 800, 600, vert_spv, frag_spv, blit_vert_spv, blit_frag_spv);
    defer win.deinit();

    // Create 'A' sweeper (background glyph)
    var a_sweeper = try proto.GlyphSweeper.init(&ctx.gpu, a_curves);
    defer a_sweeper.deinit();
    win.sweeper = &a_sweeper;

    // Extract label glyphs
    if (c.FT_Set_Pixel_Sizes(face, 0, 12) != 0) @panic("FT_Set_Pixel_Sizes failed");
    // Build string containing all unique chars from test texts
    const label_chars = "nogui prototype v0.1Click me!VolumeCounter:0QuitThe quick brown fox jumps over the lazy dog.ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    var seen: [256]bool = .{false} ** 256;
    var unique_count: usize = 0;
    for (label_chars) |ch| {
        if (!seen[ch]) {
            seen[ch] = true;
            unique_count += 1;
        }
    }
    @memset(&seen, false);

    const sweeper_arr = try gpa.alloc(proto.GlyphSweeper, unique_count);
    var si: usize = 0;
    defer {
        for (sweeper_arr[0..si]) |*s| s.deinit();
        gpa.free(sweeper_arr);
    }
    for (label_chars) |ch| {
        if (seen[ch]) continue;
        seen[ch] = true;
        const curves = try extractCharCurves(gpa, face, ch);
        defer gpa.free(curves);
        sweeper_arr[si] = try proto.GlyphSweeper.init(&ctx.gpu, curves);

        _ = c.FT_Load_Glyph(face, c.FT_Get_Char_Index(face, ch), c.FT_LOAD_NO_BITMAP);
        const m = face.*.glyph.*.metrics;
        const advance = @as(f32, @floatFromInt(m.horiAdvance)) / 64.0;
        const bx = @as(f32, @floatFromInt(m.horiBearingX)) / 64.0;
        const by = @as(f32, @floatFromInt(m.horiBearingY)) / 64.0;
        const gw = @as(f32, @floatFromInt(m.width)) / 64.0;
        const gh = @as(f32, @floatFromInt(m.height)) / 64.0;
        win.addGlyph(ch, &sweeper_arr[si], advance, bx, by, gw, gh);
        std.debug.print("Glyph '{c}': {d} curves, adv={d:.1} bx={d:.1} by={d:.1}\n", .{ ch, curves.len, advance, bx, by });
        si += 1;
    }
    if (c.FT_Set_Pixel_Sizes(face, 0, 480) != 0) @panic("FT_Set_Pixel_Sizes failed");

    var gui = MyGui{};
    try win.run(&gui);
}
