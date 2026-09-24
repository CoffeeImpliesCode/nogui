//! Stable, Session-local listener tickets. Entries are tombstoned during dispatch,
//! then compacted without changing their monotonically assigned token ids.
const model = @import("model.zig");

pub const Token = struct {
    session: u64 = 0,
    id: u64 = 0,
};

pub const Kind = enum { changed, released, event, global_changed };

/// All three arguments are borrowed for the duration of one dispatch only.
/// The third argument is a `*Session`, erased to avoid coupling the table to
/// the Session implementation. `value` points to an event or typed weak key.
pub const Handler = *const fn (*const anyopaque, *const anyopaque, *anyopaque) void;

pub const Entry = struct {
    id: u64,
    kind: Kind,
    source: model.ModelKey = .{},
    source_marker: *const u8 = model.marker(void),
    event_marker: *const u8 = model.marker(void),
    owner: model.ErasedWeakModel,
    handler: Handler,
    active: bool = true,
};
