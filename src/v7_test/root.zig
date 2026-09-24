//! Deterministic core context; optional real-font and windowless GPU contexts
//! take their public dependency modules explicitly and initialize only on request.
pub const Context = @import("context.zig").Context;
pub const QueryHandle = @import("context.zig").QueryHandle;
pub const NodeSnapshot = @import("context.zig").NodeSnapshot;
pub const RunReport = @import("context.zig").RunReport;
pub const VirtualClock = @import("clock.zig").VirtualClock;
pub const dispatcher = @import("dispatcher.zig");
pub const TextContext = @import("text_context.zig").TextContext;
pub const OffscreenContext = @import("offscreen_context.zig").OffscreenContext;

test {
    _ = @import("w06_contract_test.zig");
}
