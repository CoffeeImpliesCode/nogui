//! Deterministic behavior tests for W24 inspection, stable ID generation,
//! pick policy, stale handle detection, and bounded collectors.
const std = @import("std");
const widget = @import("widget.zig");
const overlay = @import("overlay.zig");
const focus = @import("focus.zig");
const input = @import("input.zig");
const id_mod = @import("id.zig");
const FrameNodeId = id_mod.FrameNodeId;
const WidgetId = id_mod.WidgetId;
const perf_counters = @import("perf_counters.zig");
const inspection = @import("inspection.zig");

test "api-w24 overlay priority selects the routed target and reports the raw tree hit" {
    const gpa = std.testing.allocator;

    var tree = widget.WidgetTree.init(gpa);
    defer tree.deinit();

    const root_node: FrameNodeId = .root;
    const bg_btn_node: FrameNodeId = @enumFromInt(1);
    const anchor_node: FrameNodeId = @enumFromInt(2);
    const lower_popup_node: FrameNodeId = @enumFromInt(3);
    const higher_popup_node: FrameNodeId = @enumFromInt(4);

    const bg_btn_id: WidgetId = .{ .owner = 10, .slot = 1, .generation = 1 };
    const anchor_id: WidgetId = .{ .owner = 10, .slot = 2, .generation = 1 };
    const lower_popup_id: WidgetId = .{ .owner = 10, .slot = 3, .generation = 1 };
    const higher_popup_id: WidgetId = .{ .owner = 10, .slot = 4, .generation = 1 };

    // Post-order storage, children before parents, and the ROOT CHILDREN in
    // the order the run needs: the background subtree first, so the tree's
    // own walk reaches the control the popups are painted over before it can
    // reach placed content. The overlay frame ranks PLACEMENTS, so the two
    // routings are genuinely different here and a pick can be checked against
    // both instead of against itself.
    // 1. Anchor button inside background
    try tree.nodes.append(gpa, .{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = bg_btn_node,
        .rect = .{ .x = 10, .y = 10, .w = 60, .h = 25 },
    });
    // 2. Background button. Its box stops above the popups' placed rows, so a
    // point low enough to sit in a popup is NOT its box either.
    try tree.nodes.append(gpa, .{
        .id = bg_btn_node,
        .widget_id = bg_btn_id,
        .kind = .{ .button = .{ .label = "Background" } },
        .parent = root_node,
        .rect = .{ .x = 10, .y = 10, .w = 120, .h = 60 },
    });
    // 3. Higher popup (overlay)
    try tree.nodes.append(gpa, .{
        .id = higher_popup_node,
        .widget_id = higher_popup_id,
        .kind = .{ .button = .{ .label = "Higher Popup" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 30 },
    });
    // 4. Lower popup (overlay)
    try tree.nodes.append(gpa, .{
        .id = lower_popup_node,
        .widget_id = lower_popup_id,
        .kind = .{ .button = .{ .label = "Lower Popup" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 70, .h = 40 },
    });

    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();

    // Lower overlay priority 10
    try frame.add(.{
        .anchor = anchor_id,
        .content = lower_popup_id,
        .side = .below,
        .gap = 5,
        .priority = 10,
    });
    // Higher overlay priority 20
    try frame.add(.{
        .anchor = anchor_id,
        .content = higher_popup_id,
        .side = .below,
        .gap = 5,
        .priority = 20,
    });

    const viewport: widget.Rect = .{ .x = 0, .y = 0, .w = 200, .h = 200 };
    try frame.resolve(&tree, viewport);

    const snapshot = try inspection.captureFrame(gpa, .{
        .viewport = viewport,
        .tree = &tree,
        .overlay_frame = &frame,
    });
    var mut_snap = snapshot;
    defer mut_snap.deinit();

    // Placement metadata is node-owned: the tree itself names the band and
    // the (priority, registration) key each popup was assigned, and the
    // snapshot reports that same key per node. The higher priority popup
    // registered second still ranks above the lower one.
    const lower_band = tree.nodeConst(lower_popup_node).?.placement_paint.?;
    const higher_band = tree.nodeConst(higher_popup_node).?.placement_paint.?;
    try std.testing.expect(higher_band.order > lower_band.order);
    try std.testing.expect(higher_band.layer > lower_band.layer);
    try std.testing.expectEqual(
        higher_band.order,
        mut_snap.findByFrameNodeId(higher_popup_node).?.overlay_order.?,
    );
    try std.testing.expectEqual(
        lower_band.order,
        mut_snap.findByFrameNodeId(lower_popup_node).?.overlay_order.?,
    );

    // Both popups resolve to x = 20, y = 50, so a point at (30, 60) overlaps
    // both popups and the background button under them.
    // Placement is ONE geometry: it moved the popups' boxes in this tree, so
    // the tree's own post-order walk at the overlap point still names the
    // background button it is painted over, while the engine's routed answer
    // — the one a press reaches — ranks the placed content first.
    const overlap_pos = [2]f32{ 30, 60 };
    const routed = frame.hitTestTotal(&tree, overlap_pos).?;
    const picked = mut_snap.pickResult(overlap_pos);
    try std.testing.expectEqual(higher_popup_node, picked.node.?);
    try std.testing.expectEqual(routed, picked.node.?);
    try std.testing.expectEqual(bg_btn_node, picked.tree_node.?);
    try std.testing.expectEqual(higher_popup_id.slot, mut_snap.pick(overlap_pos).?.id.slot);
    const live = inspection.pickAt(&tree, &frame, overlap_pos);
    try std.testing.expectEqual(picked.node, live.node);
    try std.testing.expectEqual(picked.tree_node, live.tree_node);

    // The resolved higher popup covers x in [20, 70), the lower one x in
    // [20, 90). A point at (75, 60) is outside the higher popup only, so the
    // routed hit drops to the lower overlay while the raw tree walk still
    // lands on the background button beneath both.
    const lower_only_pos = [2]f32{ 75, 60 };
    const lower_pick = mut_snap.pickResult(lower_only_pos);
    try std.testing.expectEqual(lower_popup_node, lower_pick.node.?);
    try std.testing.expectEqual(bg_btn_node, lower_pick.tree_node.?);
    try std.testing.expectEqual(
        frame.hitTestTotal(&tree, lower_only_pos),
        lower_pick.node,
    );

    // The placement MOVED the content, so the box it was laid out with is
    // empty: the point inside the higher popup's flow position now belongs to
    // the control it is drawn over, and the engine's walk and the snapshot's
    // pick say so together.
    const flow_pos = [2]f32{ 15, 15 };
    try std.testing.expectEqual(bg_btn_node, input.hitTest(&tree, flow_pos).?);
    try std.testing.expectEqual(
        bg_btn_id.slot,
        mut_snap.pick(flow_pos).?.id.slot,
    );

    // Pick outside everything:
    const empty = mut_snap.pickResult(.{ 190, 190 });
    try std.testing.expect(empty.node == null);
    try std.testing.expect(empty.tree_node == null);
    try std.testing.expect(mut_snap.pick(.{ 190, 190 }) == null);
}

test "api-w24: stale handle detection fails on destroyed, recycled, or removed widgets" {
    const gpa = std.testing.allocator;

    const viewport: widget.Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const target_id: WidgetId = .{ .owner = 7, .slot = 5, .generation = 1 };

    // Frame 1: Widget exists with generation 1
    var tree1 = widget.WidgetTree.init(gpa);
    defer tree1.deinit();
    try tree1.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = target_id,
        .kind = .{ .button = .{ .label = "Target Gen 1" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 },
    });

    var snap1 = try inspection.captureFrame(gpa, .{
        .frame_number = 1,
        .viewport = viewport,
        .tree = &tree1,
    });
    defer snap1.deinit();

    const node1 = snap1.findNode(target_id).?;
    const handle1 = node1.handle;
    try std.testing.expectEqual(@as(u32, 1), handle1.generation);

    // Resolving handle1 against frame 1 succeeds.
    const resolved1 = try snap1.resolve(handle1);
    try std.testing.expectEqual(target_id.slot, resolved1.id.slot);

    // Frame 2: Widget slot 5 is recycled with generation 2
    const recycled_id: WidgetId = .{ .owner = 7, .slot = 5, .generation = 2 };
    var tree2 = widget.WidgetTree.init(gpa);
    defer tree2.deinit();
    try tree2.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = recycled_id,
        .kind = .{ .button = .{ .label = "Recycled Gen 2" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 },
    });

    var snap2 = try inspection.captureFrame(gpa, .{
        .frame_number = 2,
        .viewport = viewport,
        .tree = &tree2,
    });
    defer snap2.deinit();

    // Resolving old handle1 against frame 2 MUST fail with StaleHandle!
    try std.testing.expectError(error.StaleHandle, snap2.resolve(handle1));

    // Resolving new handle from snap2 succeeds
    const node2 = snap2.findNode(recycled_id).?;
    const resolved2 = try snap2.resolve(node2.handle);
    try std.testing.expectEqual(@as(u32, 2), resolved2.id.generation);

    // Frame 3: Widget removed entirely from tree
    var tree3 = widget.WidgetTree.init(gpa);
    defer tree3.deinit();
    try tree3.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = .{ .owner = 7, .slot = 99, .generation = 1 },
        .kind = .{ .label = .{ .text = "Other" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 },
    });

    var snap3 = try inspection.captureFrame(gpa, .{
        .frame_number = 3,
        .viewport = viewport,
        .tree = &tree3,
    });
    defer snap3.deinit();

    // Resolving handle1 against frame 3 fails with StaleHandle
    try std.testing.expectError(error.StaleHandle, snap3.resolve(handle1));

    // Handle with completely mismatched owner fails with StaleHandle
    const bogus_handle: inspection.InspectHandle = .{
        .id = .{ .owner = 999, .slot = 5, .generation = 1 },
        .generation = 1,
    };
    try std.testing.expectError(error.StaleHandle, snap1.resolve(bogus_handle));
}

test "api-w24: reordered elements preserve stable identity and update bounds" {
    const gpa = std.testing.allocator;
    const viewport: widget.Rect = .{ .x = 0, .y = 0, .w = 200, .h = 200 };

    const id_a: WidgetId = .{ .owner = 1, .slot = 10, .generation = 1 };
    const id_b: WidgetId = .{ .owner = 1, .slot = 20, .generation = 1 };
    const id_c: WidgetId = .{ .owner = 1, .slot = 30, .generation = 1 };

    // Frame 1: Order is [A, B, C]
    var tree1 = widget.WidgetTree.init(gpa);
    defer tree1.deinit();
    try tree1.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = id_a,
        .kind = .{ .button = .{ .label = "A" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 50, .h = 20 },
    });
    try tree1.nodes.append(gpa, .{
        .id = @enumFromInt(2),
        .widget_id = id_b,
        .kind = .{ .button = .{ .label = "B" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 40, .w = 50, .h = 20 },
    });
    try tree1.nodes.append(gpa, .{
        .id = @enumFromInt(3),
        .widget_id = id_c,
        .kind = .{ .button = .{ .label = "C" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 70, .w = 50, .h = 20 },
    });

    var snap1 = try inspection.captureFrame(gpa, .{
        .frame_number = 1,
        .viewport = viewport,
        .tree = &tree1,
    });
    defer snap1.deinit();

    const handle_a = snap1.findNode(id_a).?.handle;
    const handle_b = snap1.findNode(id_b).?.handle;
    const handle_c = snap1.findNode(id_c).?.handle;

    // Frame 2: Reordered to [C, A, B] with new y positions
    var tree2 = widget.WidgetTree.init(gpa);
    defer tree2.deinit();
    try tree2.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = id_c,
        .kind = .{ .button = .{ .label = "C" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 50, .h = 20 },
    });
    try tree2.nodes.append(gpa, .{
        .id = @enumFromInt(2),
        .widget_id = id_a,
        .kind = .{ .button = .{ .label = "A" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 40, .w = 50, .h = 20 },
    });
    try tree2.nodes.append(gpa, .{
        .id = @enumFromInt(3),
        .widget_id = id_b,
        .kind = .{ .button = .{ .label = "B" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 70, .w = 50, .h = 20 },
    });

    var snap2 = try inspection.captureFrame(gpa, .{
        .frame_number = 2,
        .viewport = viewport,
        .tree = &tree2,
    });
    defer snap2.deinit();

    // Resolving original handles against snap2 succeeds despite reordering!
    const res_a = try snap2.resolve(handle_a);
    const res_b = try snap2.resolve(handle_b);
    const res_c = try snap2.resolve(handle_c);

    // Verify bounds updated to reflect new layout positions
    try std.testing.expectEqual(@as(f32, 40), res_a.layout_bounds.y);
    try std.testing.expectEqual(@as(f32, 70), res_b.layout_bounds.y);
    try std.testing.expectEqual(@as(f32, 10), res_c.layout_bounds.y);
}

test "api-w24: bounded collector enforces capacity, tracks overruns, and keeps chronological order" {
    const gpa = std.testing.allocator;

    var collector = try inspection.BoundedCollector(inspection.TaskRecord).init(gpa, 4);
    defer collector.deinit();

    try std.testing.expectEqual(@as(usize, 4), collector.capacity());
    try std.testing.expectEqual(@as(usize, 0), collector.count);
    try std.testing.expectEqual(@as(u64, 0), collector.overruns);

    // Record 10 items into capacity 4 buffer
    var i: u64 = 1;
    while (i <= 10) : (i += 1) {
        var rec: inspection.TaskRecord = .{
            .task_id = i,
            .priority = .normal,
            .queued_ns = i * 1000,
            .start_ns = i * 1000 + 100,
            .end_ns = i * 1000 + 500,
            .duration_ns = 400,
        };
        rec.setName("worker_task");
        collector.record(rec);
    }

    // Bounded invariants:
    try std.testing.expectEqual(@as(usize, 4), collector.count);
    try std.testing.expectEqual(@as(u64, 6), collector.overruns);
    try std.testing.expectEqual(@as(u64, 10), collector.total_recorded);

    // Chronological order preserved: oldest retained is 7, newest is 10
    try std.testing.expectEqual(@as(u64, 7), collector.get(0).?.task_id);
    try std.testing.expectEqual(@as(u64, 8), collector.get(1).?.task_id);
    try std.testing.expectEqual(@as(u64, 9), collector.get(2).?.task_id);
    try std.testing.expectEqual(@as(u64, 10), collector.get(3).?.task_id);
    try std.testing.expect(collector.get(4) == null);

    try std.testing.expectEqual(@as(u64, 10), collector.latest().?.task_id);

    // Test JSONL output
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try collector.writeJsonl(&out.writer);
    const jsonl = out.written();
    try std.testing.expect(jsonl.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"task_id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"task_id\":10") != null);
}

test "api-w24: disabled collector and sinks perform zero allocations and reject writes" {
    var collector = inspection.BoundedCollector(inspection.FrameRecord).empty;
    try std.testing.expect(!collector.enabled);

    // Recording on disabled collector does not write or crash
    const dummy_rec: inspection.FrameRecord = .{
        .frame_number = 1,
        .timestamp_ns = 100,
    };
    collector.record(dummy_rec);
    try std.testing.expectEqual(@as(usize, 0), collector.count);
    try std.testing.expectEqual(@as(u64, 0), collector.overruns);
    try std.testing.expectEqual(@as(u64, 0), collector.total_recorded);

    // Comptime zero-cost sink invariants:
    const DisabledFrameSink = inspection.CollectorSink(inspection.FrameRecord, false);
    const DisabledTaskSink = inspection.CollectorSink(inspection.TaskRecord, false);
    const DisabledActionSink = inspection.CollectorSink(inspection.ActionRecord, false);

    try std.testing.expectEqual(@as(usize, 0), @sizeOf(DisabledFrameSink));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(DisabledTaskSink));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(DisabledActionSink));

    const sink = DisabledFrameSink.init(null);
    sink.record(dummy_rec);
}

test "api-w24: frame snapshot captures bounds, clipping, focus, capture, and semantics" {
    const gpa = std.testing.allocator;

    var tree = widget.WidgetTree.init(gpa);

    const btn_id: WidgetId = .{ .owner = 1, .slot = 1, .generation = 1 };
    const slider_id: WidgetId = .{ .owner = 1, .slot = 2, .generation = 1 };
    const cb_id: WidgetId = .{ .owner = 1, .slot = 3, .generation = 1 };

    var slider_val: f32 = 75.0;
    var cb_val: bool = true;

    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = btn_id,
        .kind = .{ .button = .{
            .label = "Submit",
            .accessible_label = "Submit Form",
        } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 },
    });

    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(2),
        .widget_id = slider_id,
        .kind = .{ .slider = .{
            .label = "Volume",
            .value = &slider_val,
            .min = 0.0,
            .max = 100.0,
        } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 50, .w = 100, .h = 20 },
    });

    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(3),
        .widget_id = cb_id,
        .kind = .{ .checkbox = .{
            .label = "Accept Terms",
            .value = &cb_val,
        } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 80, .w = 90, .h = 20 },
    });

    var focus_manager: focus.Manager = .{};
    _ = focus_manager.set(&tree, btn_id, null);
    // Two live capture slots mark two different widgets, so the snapshot must
    // carry both flags instead of one caller-supplied id.
    _ = try focus_manager.press(&tree, .{ .mouse = .left }, slider_id);
    _ = try focus_manager.press(&tree, .{ .mouse = .right }, cb_id);

    const viewport: widget.Rect = .{ .x = 0, .y = 0, .w = 300, .h = 300 };

    var snapshot = try inspection.captureFrame(gpa, .{
        .frame_number = 42,
        .timestamp_ns = 123456,
        .viewport = viewport,
        .tree = &tree,
        .focus_manager = &focus_manager,
    });
    defer snapshot.deinit();

    // Now intentionally deinit the original tree to prove snapshot does NOT depend on it!
    tree.deinit();

    // Verify button snapshot
    const btn_snap = snapshot.findNode(btn_id).?;
    try std.testing.expectEqual(inspection.Role.button, btn_snap.semantics.role);
    try std.testing.expectEqualStrings("Submit", btn_snap.semantics.label.?);
    try std.testing.expectEqualStrings("Submit Form", btn_snap.semantics.accessible_label.?);
    try std.testing.expect(btn_snap.focus.is_focused);
    try std.testing.expect(!btn_snap.capture.is_captured);
    try std.testing.expectEqual(@as(f32, 80), btn_snap.layout_bounds.w);

    // Verify slider snapshot
    const slider_snap = snapshot.findNode(slider_id).?;
    try std.testing.expectEqual(inspection.Role.slider, slider_snap.semantics.role);
    try std.testing.expectEqualStrings("Volume", slider_snap.semantics.label.?);
    try std.testing.expectEqual(@as(f32, 75.0), slider_snap.semantics.numeric_value.?);
    try std.testing.expect(slider_snap.capture.is_captured);
    try std.testing.expect(!slider_snap.focus.is_focused);
    try std.testing.expectEqual(@as(u8, 1), slider_snap.capture.pointer_count);

    // Verify checkbox snapshot
    const cb_snap = snapshot.findNode(cb_id).?;
    try std.testing.expectEqual(inspection.Role.checkbox, cb_snap.semantics.role);
    try std.testing.expectEqualStrings("Accept Terms", cb_snap.semantics.label.?);
    try std.testing.expectEqual(true, cb_snap.semantics.is_checked.?);
    try std.testing.expect(cb_snap.capture.is_captured);
    try std.testing.expectEqual(@as(u8, 1), cb_snap.capture.pointer_count);
    try std.testing.expectEqual(@as(u8, 0), btn_snap.capture.pointer_count);
    // A keyed live control is a tab stop; the focus manager, not a caller,
    // decides that.
    try std.testing.expect(btn_snap.focus.can_focus);
    try std.testing.expect(slider_snap.focus.can_focus);
    try std.testing.expect(cb_snap.focus.can_focus);
    try std.testing.expect(btn_snap.focus.contains_focus);
}

test "api-w24: JSON serialization adheres to existing schema without forks" {
    const gpa = std.testing.allocator;

    var counters: perf_counters.Counters = .{};
    counters.add(.measure_requests, 5);
    const snap_counters = try counters.snapshot();

    const frame_rec: inspection.FrameRecord = .{
        .frame_number = 100,
        .timestamp_ns = 5000,
        .cpu_frame_ns = 700,
        .cpu_app_layout_ns = 120,
        .cpu_scene_ns = 80,
        .cpu_record_ns = 40,
        .cpu_submit_present_ns = 60,
        .cpu_compute_ns = 300,
        .gpu_execute_ns = 450,
        .counters = snap_counters,
        .slop_ns = 15,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try frame_rec.writeJson(&out.writer);

    const json = out.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"frame_id\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cpu_app_layout_ns\":120") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gpu_execute_ns\":450") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mechanisms\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"measure_requests\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cpu_frame_ns\":700") != null);

    // Every emitted key parses back as JSON, so the additive key did not
    // disturb the object grammar.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 700), parsed.value.object.get("cpu_frame_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 100), parsed.value.object.get("frame_id").?.integer);

    // Action record JSON serialization
    var act: inspection.ActionRecord = .{
        .target = .{ .owner = 1, .slot = 2, .generation = 3 },
        .start_ns = 100,
        .end_ns = 150,
        .duration_ns = 50,
        .result = .handled,
        .dispatch_depth = 1,
    };
    act.setName("save_document");

    var out_act: std.Io.Writer.Allocating = .init(gpa);
    defer out_act.deinit();
    try act.writeJson(&out_act.writer);

    const act_json = out_act.written();
    try std.testing.expect(std.mem.indexOf(u8, act_json, "\"type\":\"action\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, act_json, "\"name\":\"save_document\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, act_json, "\"result\":\"handled\"") != null);
}

test "api-w24: record names with quotes, backslashes, and control bytes round-trip" {
    const gpa = std.testing.allocator;

    // A double quote, a backslash, a tab, a newline, a NUL byte, and non-ASCII
    // bytes all reach the writer as raw bytes.
    const task_name = "a\"b\\c\td\ne\x00fü";
    const action_name = "{\"weird\":1}[x]\\\x1f";

    var task_collector = try inspection.BoundedCollector(inspection.TaskRecord).init(gpa, 4);
    defer task_collector.deinit();
    var action_collector = try inspection.BoundedCollector(inspection.ActionRecord).init(gpa, 4);
    defer action_collector.deinit();

    var task_rec: inspection.TaskRecord = .{
        .task_id = 1,
        .priority = .normal,
        .queued_ns = 0,
        .start_ns = 0,
        .end_ns = 0,
        .duration_ns = 0,
    };
    task_rec.setName(task_name);
    task_collector.record(task_rec);

    var action_rec: inspection.ActionRecord = .{
        .start_ns = 0,
        .end_ns = 0,
        .duration_ns = 0,
        .result = .handled,
    };
    action_rec.setName(action_name);
    action_collector.record(action_rec);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try task_collector.writeJsonl(&out.writer);
    try action_collector.writeJsonl(&out.writer);

    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Each record must parse on its own, then give back the exact bytes.
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        const record = parsed.value.object;
        const name = record.get("name").?.string;
        if (std.mem.eql(u8, record.get("type").?.string, "task")) {
            try std.testing.expectEqualStrings(task_name, name);
        } else {
            try std.testing.expectEqualStrings(action_name, name);
        }
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "api-w24: snapshot JSON escapes adversarial label bytes" {
    const gpa = std.testing.allocator;

    var tree = widget.WidgetTree.init(gpa);
    defer tree.deinit();

    const wid: WidgetId = .{ .owner = 4, .slot = 1, .generation = 1 };
    const label = "Say \"hi\"\\\n";
    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = wid,
        .kind = .{ .button = .{
            .label = label,
            .accessible_label = "a\"b",
        } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 },
    });

    var snap = try inspection.captureFrame(gpa, .{
        .frame_number = 7,
        .viewport = .{ .w = 100, .h = 100 },
        .tree = &tree,
    });
    defer snap.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try snap.writeJson(&out.writer);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    const nodes = parsed.value.object.get("nodes").?.array;
    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    try std.testing.expectEqual(@as(i64, 7), parsed.value.object.get("frame").?.integer);
    try std.testing.expectEqualStrings(label, nodes.items[0].object.get("label").?.string);
}

test "api-w24: a routed pick names the same node as the engine across a clipped grid" {
    const gpa = std.testing.allocator;

    // A column that clips on x only, with a child that overflows it, plus a
    // sibling underneath: the two cases a wrong clip chain gets wrong.
    var tree = widget.WidgetTree.init(gpa);
    defer tree.deinit();

    const inner: FrameNodeId = @enumFromInt(1);
    const clipped: FrameNodeId = @enumFromInt(2);
    const plain: FrameNodeId = @enumFromInt(3);
    const hidden: FrameNodeId = @enumFromInt(4);

    try tree.nodes.append(gpa, .{
        .id = inner,
        .widget_id = .{ .owner = 2, .slot = 1, .generation = 1 },
        .kind = .{ .label = .{ .text = "inner" } },
        .parent = clipped,
        .rect = .{ .x = 0, .y = 0, .w = 90, .h = 10 },
    });
    try tree.nodes.append(gpa, .{
        .id = clipped,
        .widget_id = .{ .owner = 2, .slot = 2, .generation = 1 },
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 20, .y = 20, .w = 40, .h = 40 },
        .style = .{ .overflow = .{ .width = .scroll, .height = .visible } },
    });
    try tree.nodes.append(gpa, .{
        .id = plain,
        .widget_id = .{ .owner = 2, .slot = 3, .generation = 1 },
        .kind = .{ .label = .{ .text = "plain" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 },
    });
    try tree.nodes.append(gpa, .{
        .id = hidden,
        .widget_id = .{ .owner = 2, .slot = 4, .generation = 1 },
        .kind = .{ .label = .{ .text = "hidden" } },
        .parent = plain,
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .style = .{ .visibility = .hidden },
    });
    try tree.appendChild(clipped, inner);
    try tree.appendChild(plain, hidden);

    var snap = try inspection.captureFrame(gpa, .{
        .viewport = .{ .w = 300, .h = 300 },
        .tree = &tree,
    });
    defer snap.deinit();

    // The clipping column constrains x only, so the y axis stays open: a
    // wrong chain that dropped the axis flags would miss these rows.
    const inner_node = snap.findByFrameNodeId(inner).?;
    try std.testing.expect(inner_node.clip_bounds != null);
    try std.testing.expect(inner_node.clip_axes.x);
    try std.testing.expect(!inner_node.clip_axes.y);
    try std.testing.expectEqual(@as(f32, 20), inner_node.clip_bounds.?.x);
    try std.testing.expectEqual(@as(f32, 60), inner_node.clip_bounds.?.x + inner_node.clip_bounds.?.w);

    // The hidden child is rejected even though its own box contains points,
    // so a point inside it lands on the parent instead.
    try std.testing.expect(!snap.findByFrameNodeId(hidden).?.is_visible);
    try std.testing.expectEqual(plain, input.hitTest(&tree, .{ 4, 4 }).?);
    try std.testing.expectEqual(plain, snap.pickNode(.{ 4, 4 }).?.frame_node_id);

    // Every grid point must produce the engine's own answer, both for the
    // handle and for the node behind it.
    var y: f32 = 0;
    while (y < 100) : (y += 5) {
        var x: f32 = 0;
        while (x < 120) : (x += 5) {
            const pos = [2]f32{ x, y };
            const want = input.hitTest(&tree, pos);
            const got = snap.pickResult(pos);
            try std.testing.expectEqual(want, got.node);
            if (want) |node_id| {
                try std.testing.expectEqual(
                    node_id,
                    snap.pickNode(pos).?.frame_node_id,
                );
            } else {
                try std.testing.expect(snap.pick(pos) == null);
            }
        }
    }

    // A point inside the child's own box but past the column's clip is not
    // the child's, and the snapshot's own clip says the same.
    const outside_clip = [2]f32{ 80, 25 };
    try std.testing.expectEqual(plain, input.hitTest(&tree, outside_clip).?);
    try std.testing.expectEqual(plain, snap.pickNode(outside_clip).?.frame_node_id);
    try std.testing.expect(!widget.pointInClipAxes(
        inner_node.clip_bounds.?,
        inner_node.clip_axes,
        outside_clip,
    ));
}

test "api-w24: a stale handle never resolves to a live node in its slot" {
    const gpa = std.testing.allocator;
    const viewport: widget.Rect = .{ .x = 0, .y = 0, .w = 200, .h = 200 };
    const owner: u64 = 42;
    const slot: u32 = 7;

    // Three live nodes that all report the same owner and slot is impossible
    // through the identity registry, so the handle resolves on the FIRST
    // slot match. A wrong-generation handle must not fall through to the
    // next node that happens to share the slot.
    var tree = widget.WidgetTree.init(gpa);
    defer tree.deinit();
    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = .{ .owner = owner, .slot = slot, .generation = 2 },
        .kind = .{ .button = .{ .label = "second" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
    });
    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(2),
        .widget_id = .{ .owner = owner, .slot = slot, .generation = 1 },
        .kind = .{ .button = .{ .label = "first" } },
        .parent = .root,
        .rect = .{ .x = 0, .y = 20, .w = 10, .h = 10 },
    });

    var snap = try inspection.captureFrame(gpa, .{
        .frame_number = 3,
        .viewport = viewport,
        .tree = &tree,
    });
    defer snap.deinit();

    const live = snap.findByFrameNodeId(@enumFromInt(1)).?;
    try std.testing.expectEqual(@as(u32, 2), live.handle.generation);
    // The live handle resolves to the node it was taken from, not to the
    // other node that shares its slot. The node appended first is snapshot
    // index 0, which is the one whose widget generation is 2.
    try std.testing.expectEqual(live.index, (try snap.resolve(live.handle)).index);
    try std.testing.expectEqual(@as(u32, 0), live.index);

    // A handle that keeps the slot but bumps the generation is refused even
    // though a node with that owner and slot is present.
    const forged: inspection.InspectHandle = .{
        .id = .{ .owner = owner, .slot = slot, .generation = 2 },
        .generation = 9,
    };
    try std.testing.expectError(error.StaleHandle, snap.resolve(forged));

    // The frame stamp is provenance, not identity: a handle taken from an
    // earlier frame still resolves against this frame's node.
    const from_earlier: inspection.InspectHandle = .{
        .id = live.id,
        .generation = 2,
        .frame_number = 1,
    };
    try std.testing.expectEqual(@as(u32, 0), (try snap.resolve(from_earlier)).index);
    try std.testing.expectEqual(@as(u64, 3), (try snap.resolve(from_earlier)).handle.frame_number);
}

test "api-w24: a bounded collector copies at most its retained window in order" {
    const gpa = std.testing.allocator;

    var collector = try inspection.BoundedCollector(inspection.FrameRecord).init(gpa, 3);
    defer collector.deinit();

    // Caller storage smaller than the window: the copy truncates instead of
    // dropping the oldest record, which is what a bounded snapshot means.
    var small: [2]inspection.FrameRecord = undefined;
    try std.testing.expectEqual(@as(usize, 0), collector.copyChronological(&small));

    var index: u64 = 1;
    while (index <= 5) : (index += 1) {
        collector.record(.{
            .frame_number = index,
            .timestamp_ns = index * 10,
            .cpu_frame_ns = index,
        });
    }
    try std.testing.expectEqual(@as(usize, 3), collector.count);
    try std.testing.expectEqual(@as(usize, 2), collector.overruns);
    try std.testing.expectEqual(@as(u64, 5), collector.total_recorded);

    try std.testing.expectEqual(@as(usize, 2), collector.copyChronological(&small));
    try std.testing.expectEqual(@as(u64, 3), small[0].frame_number);
    try std.testing.expectEqual(@as(u64, 4), small[1].frame_number);

    var exact: [3]inspection.FrameRecord = undefined;
    try std.testing.expectEqual(@as(usize, 3), collector.copyChronological(&exact));
    try std.testing.expectEqual(@as(u64, 3), exact[0].frame_number);
    try std.testing.expectEqual(@as(u64, 4), exact[1].frame_number);
    try std.testing.expectEqual(@as(u64, 5), exact[2].frame_number);

    // Records stay monotonic in the window's own order.
    var previous: u64 = 0;
    for (exact) |record| {
        try std.testing.expect(record.frame_number > previous);
        previous = record.frame_number;
    }
}

test "api-w24 retained overlay picks preserve inherited clipping after live placement changes" {
    const gpa = std.testing.allocator;
    var tree = widget.WidgetTree.init(gpa);
    defer tree.deinit();
    const scroller: FrameNodeId = @enumFromInt(4);
    const anchor: FrameNodeId = @enumFromInt(1);
    const popup: FrameNodeId = @enumFromInt(2);
    const anchor_id: WidgetId = .{ .owner = 9, .slot = 1, .generation = 1 };
    const popup_id: WidgetId = .{ .owner = 9, .slot = 2, .generation = 1 };
    try tree.appendNode(.{
        .id = anchor,
        .widget_id = anchor_id,
        .parent = scroller,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .rect = .{ .x = 10, .y = 30, .w = 10, .h = 5 },
    });
    try tree.appendNode(.{
        .id = scroller,
        .parent = .root,
        .kind = .{ .column = .{} },
        .rect = .{ .w = 100, .h = 40 },
        .style = .{ .overflow = .{ .width = .visible, .height = .scroll } },
    });
    try tree.appendNode(.{
        .id = popup,
        .widget_id = popup_id,
        .parent = .root,
        .kind = .{ .button = .{ .label = "Popup" } },
        .rect = .{ .w = 80, .h = 70 },
    });
    try tree.appendChild(scroller, anchor);
    const viewport: widget.Rect = .{ .w = 100, .h = 100 };
    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    var record: overlay.Record = .{
        .anchor = anchor_id,
        .content = popup_id,
        .clip = .inherit,
        .margin = 0,
    };
    frame.beginFrame();
    try frame.add(record);
    try frame.resolve(&tree, viewport);
    var snapshot = try inspection.captureFrame(gpa, .{
        .tree = &tree,
        .overlay_frame = &frame,
        .viewport = viewport,
    });
    defer snapshot.deinit();
    const bounds = widget.visualBorderRect(&tree, popup);
    const clip = snapshot.findByFrameNodeId(popup).?.clip_bounds orelse
        return error.MissingInheritedClip;
    const outside_clip = [2]f32{ bounds.x + 1, clip.y + clip.h + 1 };
    try std.testing.expect(outside_clip[1] < bounds.y + bounds.h);
    try std.testing.expect(frame.hitTest(&tree, outside_clip) == null);
    try std.testing.expect(frame.hitTestTotal(&tree, outside_clip) == null);
    try std.testing.expect(snapshot.pickNode(outside_clip) == null);

    record.clip = .window_escape;
    frame.beginFrame();
    try frame.add(record);
    try frame.resolve(&tree, viewport);
    try std.testing.expectEqual(popup, frame.hitTestTotal(&tree, outside_clip).?);
    try std.testing.expect(snapshot.pickNode(outside_clip) == null);
}

test "api-w24: a published tree keeps its own overlay metadata after the next frame commits" {
    const gpa = std.testing.allocator;
    const viewport: widget.Rect = .{ .w = 200, .h = 200 };
    const anchor_node: FrameNodeId = @enumFromInt(1);
    const popup_node: FrameNodeId = @enumFromInt(2);
    const anchor_id: WidgetId = .{ .owner = 5, .slot = 1, .generation = 1 };
    const popup_id: WidgetId = .{ .owner = 5, .slot = 2, .generation = 1 };

    // Two consecutive frames, each with its own tree and the same anchor and
    // popup identities: the second frame's placement must not describe the
    // first frame's popup.
    var first = widget.WidgetTree.init(gpa);
    defer first.deinit();
    try first.appendNode(.{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 40, .h = 20 },
    });
    try first.appendNode(.{
        .id = popup_node,
        .widget_id = popup_id,
        .kind = .{ .button = .{ .label = "Popup" } },
        .parent = .root,
        .rect = .{ .w = 60, .h = 40 },
    });

    var second = widget.WidgetTree.init(gpa);
    defer second.deinit();
    try second.appendNode(.{
        .id = anchor_node,
        .widget_id = anchor_id,
        .kind = .{ .button = .{ .label = "Anchor" } },
        .parent = .root,
        .rect = .{ .x = 10, .y = 10, .w = 40, .h = 20 },
    });
    try second.appendNode(.{
        .id = popup_node,
        .widget_id = popup_id,
        .kind = .{ .button = .{ .label = "Popup" } },
        .parent = .root,
        .rect = .{ .w = 60, .h = 40 },
    });

    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();

    // Frame 1 places the popup at the lower priority.
    frame.beginFrame();
    try frame.add(.{
        .anchor = anchor_id,
        .content = popup_id,
        .side = .below,
        .gap = 4,
        .priority = 5,
    });
    try frame.resolve(&first, viewport);
    const first_order = first.nodeConst(popup_node).?.placement_paint.?.order;

    // Frame 2 re-registers the same identities at a higher priority into a
    // different tree, so the committed resolution names no tree but this
    // one any more.
    frame.beginFrame();
    try frame.add(.{
        .anchor = anchor_id,
        .content = popup_id,
        .side = .below,
        .gap = 4,
        .priority = 40,
    });
    try frame.resolve(&second, viewport);
    const second_order = second.nodeConst(popup_node).?.placement_paint.?.order;
    try std.testing.expect(second_order > first_order);

    // The first tree still answers for ITS popup: the band it published
    // travels with its nodes, so a snapshot captured now reports the popup
    // this frame placed and not the one the next frame placed.
    var previous = try inspection.captureFrame(gpa, .{
        .frame_number = 1,
        .viewport = viewport,
        .tree = &first,
    });
    defer previous.deinit();
    const previous_node = previous.findByFrameNodeId(popup_node).?;
    try std.testing.expect(previous_node.is_overlay);
    try std.testing.expectEqual(first_order, previous_node.overlay_order.?);

    // The order is a paint position, so the retained snapshot still routes
    // inside the box its own placement moved the popup to.
    const placed = widget.visualBorderRect(&first, popup_node);
    try std.testing.expectEqual(
        popup_node,
        previous.pickNode(.{ placed.x + 1, placed.y + 1 }).?.frame_node_id,
    );

    // Handing the snapshot the very frame that no longer resolves this tree
    // changes nothing: the answer is the node's own metadata, so the frame
    // can neither answer for it nor contradict it.
    var with_frame = try inspection.captureFrame(gpa, .{
        .frame_number = 1,
        .viewport = viewport,
        .tree = &first,
        .overlay_frame = &frame,
    });
    defer with_frame.deinit();
    const with_frame_node = with_frame.findByFrameNodeId(popup_node).?;
    try std.testing.expect(with_frame_node.is_overlay);
    try std.testing.expectEqual(first_order, with_frame_node.overlay_order.?);

    // The tree the frame actually resolved reports its own, newer, popup.
    var current = try inspection.captureFrame(gpa, .{
        .frame_number = 2,
        .viewport = viewport,
        .tree = &second,
        .overlay_frame = &frame,
    });
    defer current.deinit();
    const current_node = current.findByFrameNodeId(popup_node).?;
    try std.testing.expect(current_node.is_overlay);
    try std.testing.expectEqual(second_order, current_node.overlay_order.?);
}
