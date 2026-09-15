const std = @import("std");
const fixture = @import("fixture.zig");
const fixture_options = @import("fixture_options");

const expected_digest = [32]u8{
    0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
    0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
    0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
    0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const filter: ?[]const u8 = if (fixture_options.filter.len == 0) null else fixture_options.filter;
    const summary = try fixture.runAll(allocator, filter);
    if ((filter == null and summary.passed != 5524) or summary.failed != 0 or summary.unsupported != 0) {
        return error.OracleMismatch;
    }
    if (!std.mem.eql(
        u8,
        summary.unsupported_sha256[0..],
        expected_digest[0..],
    )) return error.OracleMismatch;

    const digest = std.fmt.bytesToHex(summary.unsupported_sha256, .lower);
    const output = try std.fmt.allocPrint(
        allocator,
        "{{\"passed\":{d},\"failed\":{d},\"unsupported\":{d},\"unsupported_sha256\":\"{s}\"}}\n",
        .{ summary.passed, summary.failed, summary.unsupported, digest },
    );
    defer allocator.free(output);
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}
