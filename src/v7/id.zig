//! Dense frame nodes and persistent, registry-owned widget handles.

pub const FrameNodeId = enum(u32) {
    root = 0,
    _,

    pub fn index(self: FrameNodeId) u32 {
        return @intFromEnum(self);
    }
};

/// A widget handle is valid only in its owner registry and live generation.
pub const WidgetId = struct {
    owner: u64,
    slot: u32,
    generation: u32,

    pub fn eql(a: WidgetId, b: WidgetId) bool {
        return a.owner == b.owner and a.slot == b.slot and a.generation == b.generation;
    }
};
