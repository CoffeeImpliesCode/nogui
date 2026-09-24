const std = @import("std");
const fixture = @import("fixture.zig");

const expected_digest = [32]u8{
    0x88, 0x07, 0x1b, 0x9f, 0xb9, 0x11, 0xc6, 0x0b,
    0x49, 0xf2, 0x99, 0x9a, 0x29, 0x96, 0x4b, 0x48,
    0x05, 0xdf, 0x92, 0xa6, 0x57, 0x41, 0xbf, 0x9d,
    0x73, 0xa8, 0x8e, 0x7c, 0x28, 0xbf, 0x3a, 0x2a,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const summary = try fixture.runAll(allocator, null);
    if (summary.passed != 5504 or summary.failed != 0 or summary.unsupported != 20) {
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
