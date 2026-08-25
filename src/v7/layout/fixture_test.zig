const std = @import("std");
const fixture = @import("fixture.zig");

test "diagnose detailed remaining issues" {
    const allocator = std.testing.allocator;
    var io_impl = std.Io.Threaded.init(allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    const raw_cases = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "~/.cache/taffy-v0.13.0-normalized/normalized/cases.json",
        allocator,
        .unlimited,
    );
    defer allocator.free(raw_cases);

    var parsed_corpus = try std.json.parseFromSlice(
        fixture.Corpus,
        allocator,
        raw_cases,
        .{ .ignore_unknown_fields = false },
    );
    defer parsed_corpus.deinit();

    var fail_counts = std.StringHashMap(usize).init(allocator);
    defer fail_counts.deinit();
    var unsup_counts = std.StringHashMap(usize).init(allocator);
    defer unsup_counts.deinit();
    var cat_counts = std.StringHashMap(usize).init(allocator);
    defer cat_counts.deinit();

    for (parsed_corpus.value.cases) |case| {
        const slash = std.mem.indexOfScalar(u8, case.id, '/') orelse case.id.len;
        const category = case.id[0..slash];

        const res = fixture.runCase(allocator, case) catch |err| {
            if (err == error.Unsupported) {
                for (case.nodes) |node| {
                    if (node.attributes) |attrs| {
                        if (attrs == .object) {
                            var it = attrs.object.iterator();
                            while (it.next()) |entry| {
                                const val = if (entry.value_ptr.* == .string) entry.value_ptr.string else "";
                                const key = entry.key_ptr.*;
                                if (std.mem.indexOf(u8, val, "min-content") != null or
                                    std.mem.indexOf(u8, val, "max-content") != null)
                                {
                                    const g = try unsup_counts.getOrPut("min/max-content in grid track or size");
                                    if (!g.found_existing) g.value_ptr.* = 0;
                                    g.value_ptr.* += 1;
                                }
                                if (std.mem.indexOf(u8, key, "grid-template-areas") != null or
                                    std.mem.indexOf(u8, key, "grid-area") != null)
                                {
                                    const g = try unsup_counts.getOrPut("grid template areas / named lines");
                                    if (!g.found_existing) g.value_ptr.* = 0;
                                    g.value_ptr.* += 1;
                                }
                                if (std.mem.indexOf(u8, val, "auto-fill") != null or
                                    std.mem.indexOf(u8, val, "auto-fit") != null)
                                {
                                    const g = try unsup_counts.getOrPut("repeat(auto-fit/auto-fill, ...)");
                                    if (!g.found_existing) g.value_ptr.* = 0;
                                    g.value_ptr.* += 1;
                                }
                            }
                        }
                    }
                }
            }
            continue;
        };

        if (!res) {
            const cg = try cat_counts.getOrPut(category);
            if (!cg.found_existing) cg.value_ptr.* = 0;
            cg.value_ptr.* += 1;

            // Tally specific features in failing cases
            for (case.nodes) |node| {
                if (node.attributes) |attrs| {
                    if (attrs == .object) {
                        var it = attrs.object.iterator();
                        while (it.next()) |entry| {
                            const key = entry.key_ptr.*;
                            const val = if (entry.value_ptr.* == .string) entry.value_ptr.string else "";
                            if (std.mem.eql(u8, key, "flex-direction") and
                                std.mem.indexOf(u8, val, "reverse") != null)
                            {
                                const g = try fail_counts.getOrPut(
                                    "Flex reverse directions (row-reverse, column-reverse)",
                                );
                                if (!g.found_existing) g.value_ptr.* = 0;
                                g.value_ptr.* += 1;
                            }
                            if (std.mem.eql(u8, key, "grid-auto-rows") or std.mem.eql(u8, key, "grid-auto-columns")) {
                                const g = try fail_counts.getOrPut("Implicit grid tracks (grid-auto-rows/columns)");
                                if (!g.found_existing) g.value_ptr.* = 0;
                                g.value_ptr.* += 1;
                            }
                            if (std.mem.eql(u8, key, "flex-shrink") and !std.mem.eql(u8, val, "1")) {
                                const g = try fail_counts.getOrPut("Non-default flex-shrink factors");
                                if (!g.found_existing) g.value_ptr.* = 0;
                                g.value_ptr.* += 1;
                            }
                            if (std.mem.eql(u8, key, "flex-grow") and !std.mem.eql(u8, val, "0")) {
                                const g = try fail_counts.getOrPut("Non-default flex-grow factors");
                                if (!g.found_existing) g.value_ptr.* = 0;
                                g.value_ptr.* += 1;
                            }
                            if (std.mem.indexOf(u8, key, "gap") != null) {
                                const g = try fail_counts.getOrPut("Gaps in flex and grid");
                                if (!g.found_existing) g.value_ptr.* = 0;
                                g.value_ptr.* += 1;
                            }
                            if (std.mem.indexOf(u8, val, "fr") != null) {
                                const g = try fail_counts.getOrPut("Grid fr track distribution");
                                if (!g.found_existing) g.value_ptr.* = 0;
                                g.value_ptr.* += 1;
                            }
                            if (std.mem.indexOf(u8, val, "minmax") != null) {
                                const g = try fail_counts.getOrPut("Grid minmax() track sizing");
                                if (!g.found_existing) g.value_ptr.* = 0;
                                g.value_ptr.* += 1;
                            }
                            if (std.mem.eql(u8, key, "position") and std.mem.eql(u8, val, "absolute")) {
                                const g = try fail_counts.getOrPut("Absolute positioned items in flex/grid");
                                if (!g.found_existing) g.value_ptr.* = 0;
                                g.value_ptr.* += 1;
                            }
                            if (std.mem.indexOf(u8, val, "%") != null) {
                                const g = try fail_counts.getOrPut("Percentage dimensions/insets");
                                if (!g.found_existing) g.value_ptr.* = 0;
                                g.value_ptr.* += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    std.debug.print("\n=== FAILURES BY CATEGORY ===\n", .{});
    var cit = cat_counts.iterator();
    while (cit.next()) |e| {
        std.debug.print("  - {s: <20}: {d} failures\n", .{ e.key_ptr.*, e.value_ptr.* });
    }

    std.debug.print("\n=== KEY FAILURE CLUSTERS ===\n", .{});
    var fit = fail_counts.iterator();
    while (fit.next()) |e| {
        std.debug.print("  - {s: <55}: {d} occurrences\n", .{ e.key_ptr.*, e.value_ptr.* });
    }

    std.debug.print("\n=== TOP UNSUPPORTED GAPS ===\n", .{});
    var uit = unsup_counts.iterator();
    while (uit.next()) |e| {
        std.debug.print("  - {s: <55}: {d} occurrences\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
}
