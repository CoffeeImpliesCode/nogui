//! Typed, synchronous actions for one App. Only registration allocates for
//! parameter-free actions; JSON payload storage ends when dispatch returns.
//! An optional observer times each dispatch without changing its result.
const std = @import("std");
const model = @import("model.zig");
const Session = @import("session.zig").Session;
const WidgetId = @import("id.zig").WidgetId;
const WidgetTree = @import("widget.zig").WidgetTree;
const key_context = @import("key_context.zig");
const Clock = @import("clock.zig").Clock;

pub const Scope = key_context.Scope;
pub const Path = key_context.Path;

pub const Availability = enum {
    /// This scope handles the action.
    available,
    /// This scope consumes the action without running it or trying ancestors.
    disabled,
    /// Skip this scope and try the next ancestor, then App.
    unavailable,
};
pub const Result = enum { handled, disabled, unavailable };

/// What one binding says about an action's tick mark. `unavailable` is the
/// same answer `inspect` gives when no live binding owns the action, so a
/// menu never draws a mark that no live model reported.
pub const CheckState = enum { unavailable, unchecked, checked };

/// What a decided binding allows. `inspect` reports it as the matching
/// `Availability`, because an unavailable binding never reaches a decision.
const Decision = enum { available, disabled };

/// The binding that owns an action for a focused context, and what it allows.
/// The binding is held by value because answering costs a user callback, and
/// that callback may cancel a binding: with no dispatch in flight that
/// compacts the list and shifts every later row down. A position would then
/// name a different owner, so the row that decided is the one carried out.
const Decided = struct { binding: Binding, decision: Decision };

/// Shape of a payload in action/menu discovery. `none` means no parameters;
/// object fields marked `required` have no Zig default value.
pub const Schema = union(enum) {
    none,
    boolean,
    integer,
    number,
    string: ?usize,
    enumeration: []const [:0]const u8,
    object: []const Field,
    array: Array,
    optional: *const Schema,

    pub const Field = struct { name: []const u8, value: Schema, required: bool };
    pub const Array = struct { item: *const Schema, length: ?usize = null };
};

fn schemaFor(comptime T: type) Schema {
    return switch (@typeInfo(T)) {
        .void => .none,
        .bool => .boolean,
        .int => .integer,
        .float => .number,
        .@"enum" => blk: {
            rejectCustomDecoder(T);
            break :blk .{ .enumeration = std.meta.fieldNames(T) };
        },
        .optional => |info| .{ .optional = &struct {
            const value = schemaFor(info.child);
        }.value },
        .pointer => |info| blk: {
            if (info.size != .slice) @compileError("action JSON supports only slice pointers");
            if (info.child == u8) break :blk .{ .string = null };
            break :blk .{ .array = .{ .item = &struct {
                const value = schemaFor(info.child);
            }.value } };
        },
        .array => |info| blk: {
            if (info.child == u8) break :blk .{ .string = info.len };
            break :blk .{ .array = .{
                .item = &struct {
                    const value = schemaFor(info.child);
                }.value,
                .length = info.len,
            } };
        },
        .@"struct" => |info| blk: {
            if (info.is_tuple) @compileError("action JSON requires named struct fields");
            rejectCustomDecoder(T);
            const fields = struct {
                const values = init: {
                    var result: [info.field_names.len]Schema.Field = undefined;
                    for (info.field_names, info.field_types, info.field_attrs, 0..) |name, field_type, attrs, index| {
                        if (attrs.@"comptime") @compileError("action JSON rejects comptime fields");
                        result[index] = .{
                            .name = name,
                            .value = schemaFor(field_type),
                            .required = attrs.default_value_ptr == null,
                        };
                    }
                    break :init result;
                };
            };
            break :blk .{ .object = &fields.values };
        },
        else => @compileError("unsupported action JSON payload type"),
    };
}

fn rejectCustomDecoder(comptime T: type) void {
    if (@hasDecl(T, "jsonParse") or @hasDecl(T, "jsonParseFromValue")) {
        @compileError("action JSON requires reflected fields, not a custom decoder");
    }
}

/// A descriptor is a comptime type, not a runtime string callback. Names are
/// stable lowercase dotted identifiers; both registration and dispatch use it.
pub fn Action(comptime Parameters: type, comptime stable_name: []const u8) type {
    comptime {
        if (!validName(stable_name)) @compileError("invalid action name");
        _ = schemaFor(Parameters);
    }
    return struct {
        pub const name = stable_name;
        pub const Payload = Parameters;
        pub const schema = schemaFor(Parameters);
    };
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] < 'a' or name[0] > 'z') return false;
    for (name[1..]) |byte| {
        if (byte >= 'a' and byte <= 'z') continue;
        if (byte >= '0' and byte <= '9') continue;
        if (byte == '.' or byte == '_' or byte == '-') continue;
        return false;
    }
    return true;
}

/// One completed dispatch. The name is the registered name, so an alias
/// reports once under its target. The event holds no payload, because the
/// decode arena is already freed when the event is built.
pub const DispatchEvent = struct {
    name: []const u8,
    /// Widget that decided the dispatch. The App scope has no widget, and
    /// `unavailable` names no scope at all.
    target: ?WidgetId = null,
    start_ns: i96,
    end_ns: i96,
    duration_ns: u64,
    result: Result,
    /// Zero for the outermost dispatch. A handler that dispatches again
    /// nests one level deeper.
    depth: u32,
};

/// Timing attached to dispatch. The callback runs on the dispatching thread
/// after the dispatch returns, so it observes finished work only. It must not
/// block, allocate, or keep the event past the call.
pub const Observer = struct {
    /// Monotonic time in the host. The deterministic service injects its
    /// virtual clock here.
    clock: Clock,
    user: *anyopaque,
    on_dispatch: *const fn (*anyopaque, DispatchEvent) void,
};

pub const Descriptor = struct {
    name: []const u8,
    schema: Schema,
    /// Reports the widget that decided the result through `selected`.
    dispatch_fn: *const fn (
        *Registry,
        *const WidgetTree,
        ?WidgetId,
        ?[]const u8,
        *?WidgetId,
    ) anyerror!Result,
};
pub const Alias = struct { name: []const u8, target: []const u8 };

/// Copyable bits are not a second ownership ticket; either copy can cancel
/// once. Registry IDs differ across Apps, including across Session lifetimes.
pub const Token = struct { registry: u64 = 0, id: u64 = 0 };
var next_registry_id: std.atomic.Value(u64) = .init(1);

const Binding = struct {
    id: u64,
    action_name: []const u8,
    scope: Scope,
    owner: model.ErasedWeakModel,
    state_fn: *const fn (*Session, model.ErasedWeakModel) anyerror!Availability,
    check_fn: ?*const fn (*Session, model.ErasedWeakModel) anyerror!CheckState = null,
    invoke_fn: *const fn (*Session, model.ErasedWeakModel, *const anyopaque) anyerror!void,
    active: bool = true,
};
const Listener = struct {
    id: u64,
    action_name: []const u8,
    owner: model.ErasedWeakModel,
    alive_fn: *const fn (*Session, model.ErasedWeakModel) anyerror!bool,
    invoke_fn: *const fn (*Session, model.ErasedWeakModel, *const anyopaque) anyerror!void,
    active: bool = true,
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    id: u64,
    next_token_id: u64 = 1,
    actions: std.ArrayList(Descriptor) = .empty,
    alias_entries: std.ArrayList(Alias) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    listeners: std.ArrayList(Listener) = .empty,
    observer: ?Observer = null,
    dispatch_depth: usize = 0,
    needs_compact: bool = false,

    pub fn init(gpa: std.mem.Allocator, session: *Session) !Registry {
        var id = next_registry_id.load(.monotonic);
        while (id != 0 and id != std.math.maxInt(u64)) {
            if (next_registry_id.cmpxchgWeak(id, id + 1, .monotonic, .monotonic)) |observed| {
                id = observed;
            } else {
                return .{ .gpa = gpa, .session = session, .id = id };
            }
        }
        return error.IdExhausted;
    }

    pub fn deinit(self: *Registry) void {
        std.debug.assert(self.dispatch_depth == 0);
        for (self.alias_entries.items) |entry| {
            self.gpa.free(entry.name);
            self.gpa.free(entry.target);
        }
        self.alias_entries.deinit(self.gpa);
        self.actions.deinit(self.gpa);
        self.bindings.deinit(self.gpa);
        self.listeners.deinit(self.gpa);
        self.* = undefined;
    }

    /// Register each canonical name once. An action with no live eligible
    /// handler is discoverable but returns `unavailable`, never a fake success.
    pub fn register(self: *Registry, comptime A: type) !void {
        comptime validateAction(A);
        if (self.occupied(A.name)) return error.DuplicateAction;
        try self.actions.append(self.gpa, .{
            .name = A.name,
            .schema = A.schema,
            .dispatch_fn = struct {
                fn call(
                    registry: *Registry,
                    tree: *const WidgetTree,
                    focus: ?WidgetId,
                    json: ?[]const u8,
                    selected: *?WidgetId,
                ) anyerror!Result {
                    return registry.dispatchAction(A, tree, focus, json, selected);
                }
            }.call,
        });
    }

    /// Forward alias targets may be registered later. Cycles are rejected at
    /// insertion, including a self-alias. Both names are owned by Registry.
    pub fn registerAlias(self: *Registry, name: []const u8, target: []const u8) !void {
        if (!validName(name) or !validName(target)) return error.InvalidActionName;
        if (self.occupied(name)) return error.DuplicateAction;
        var candidate = target;
        var remaining = self.alias_entries.items.len + 1;
        while (remaining > 0) : (remaining -= 1) {
            if (std.mem.eql(u8, candidate, name)) return error.AliasCycle;
            const next = self.aliasTarget(candidate) orelse break;
            candidate = next;
        }
        if (remaining == 0) return error.AliasCycle;
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const owned_target = try self.gpa.dupe(u8, target);
        errdefer self.gpa.free(owned_target);
        try self.alias_entries.append(self.gpa, .{ .name = owned_name, .target = owned_target });
    }

    /// Slices stay valid until the next registry mutation or deinit. Inspect
    /// aliases separately: a forward alias has no canonical descriptor yet.
    pub fn descriptors(self: *const Registry) []const Descriptor {
        return self.actions.items;
    }

    pub fn aliases(self: *const Registry) []const Alias {
        return self.alias_entries.items;
    }

    pub fn descriptor(self: *const Registry, name: []const u8) ?Descriptor {
        const canonical = self.canonicalName(name) orelse return null;
        for (self.actions.items) |entry| {
            if (std.mem.eql(u8, entry.name, canonical)) return entry;
        }
        return null;
    }

    /// The latest binding at the nearest eligible scope wins. Unavailable
    /// bindings fall through; disabled bindings suppress every outer fallback.
    /// The owner is weak: an expired owner behaves as unavailable.
    pub fn bind(
        self: *Registry,
        comptime A: type,
        comptime Owner: type,
        comptime handler: fn (*Owner, *const A.Payload, *Session) anyerror!void,
        comptime availability: ?fn (*const Owner, *Session) Availability,
        scope: Scope,
        owner: model.WeakModel(Owner),
    ) !Token {
        comptime validateAction(A);
        if (self.descriptor(A.name) == null) return error.UnknownAction;
        _ = try self.session.castWeak(Owner, owner.erase());
        const id = try self.reserveToken();
        try self.bindings.append(self.gpa, .{
            .id = id,
            .action_name = A.name,
            .scope = scope,
            .owner = owner.erase(),
            .state_fn = struct {
                fn call(session: *Session, weak: model.ErasedWeakModel) anyerror!Availability {
                    const typed = session.castWeak(Owner, weak) catch |err| switch (err) {
                        error.StaleModel => return .unavailable,
                        else => return err,
                    };
                    if (availability) |check| {
                        var state: Availability = .unavailable;
                        const User = struct { output: *Availability, session: *Session };
                        try session.read(Owner, typed, User{ .output = &state, .session = session }, struct {
                            fn run(value: *const Owner, user: User) !void {
                                user.output.* = check(value, user.session);
                            }
                        }.run);
                        return state;
                    }
                    return .available;
                }
            }.call,
            .invoke_fn = invocationAdapter(A, Owner, handler),
        });
        return .{ .registry = self.id, .id = id };
    }

    /// Declare the tick mark one binding reports. The mark is read from the
    /// same weak owner, under the same scoped read, as that binding's
    /// availability, and both answers come from one walk of the bindings, so
    /// a greyed row and the mark beside it can never disagree.
    ///
    /// An action bound without a mark reports `unchecked` for as long as it
    /// stays bound. The owner may already be gone: a released owner reports
    /// `unavailable` at query time, which is not the mark it used to hold.
    pub fn bindCheck(
        self: *Registry,
        comptime Owner: type,
        comptime checked: fn (*const Owner, *Session) bool,
        token: Token,
    ) !void {
        if (token.registry != self.id or token.id == 0) return error.UnknownBinding;
        for (self.bindings.items) |*entry| {
            if (entry.id != token.id or !entry.active) continue;
            // The erased owner must be the type `checked` was written
            // against, so a mark is never read from another model's storage.
            if (entry.owner.type_marker != model.marker(Owner)) return error.WrongType;
            entry.check_fn = checkAdapter(Owner, checked);
            return;
        }
        return error.UnknownBinding;
    }

    /// Listeners run after a successful handler, in registration order. Their
    /// payload pointer is borrowed only during this synchronous call. New
    /// listeners registered during an action start with the next action.
    pub fn listen(
        self: *Registry,
        comptime A: type,
        comptime Owner: type,
        comptime handler: fn (*Owner, *const A.Payload, *Session) anyerror!void,
        owner: model.WeakModel(Owner),
    ) !Token {
        comptime validateAction(A);
        if (self.descriptor(A.name) == null) return error.UnknownAction;
        _ = try self.session.castWeak(Owner, owner.erase());
        const id = try self.reserveToken();
        try self.listeners.append(self.gpa, .{
            .id = id,
            .action_name = A.name,
            .owner = owner.erase(),
            .alive_fn = struct {
                fn call(session: *Session, weak: model.ErasedWeakModel) anyerror!bool {
                    _ = session.castWeak(Owner, weak) catch |err| switch (err) {
                        error.StaleModel => return false,
                        else => return err,
                    };
                    return true;
                }
            }.call,
            .invoke_fn = invocationAdapter(A, Owner, handler),
        });
        return .{ .registry = self.id, .id = id };
    }

    pub fn unbind(self: *Registry, token: *Token) bool {
        return self.cancel(token, false);
    }

    pub fn unlisten(self: *Registry, token: *Token) bool {
        return self.cancel(token, true);
    }

    fn cancel(self: *Registry, token: *Token, listener: bool) bool {
        if (token.registry != self.id or token.id == 0) return false;
        if (listener) {
            for (self.listeners.items) |*entry| {
                if (entry.id != token.id or !entry.active) continue;
                entry.active = false;
                token.* = .{};
                if (self.dispatch_depth == 0) self.compact() else self.needs_compact = true;
                return true;
            }
        } else {
            for (self.bindings.items) |*entry| {
                if (entry.id != token.id or !entry.active) continue;
                entry.active = false;
                token.* = .{};
                if (self.dispatch_depth == 0) self.compact() else self.needs_compact = true;
                return true;
            }
        }
        return false;
    }

    /// Attach or clear dispatch timing. Without an observer, dispatch
    /// takes no timestamps and allocates nothing. The observer is never
    /// called during `deinit`, so clear it before its user data dies.
    pub fn setObserver(self: *Registry, observer: ?Observer) void {
        self.observer = observer;
    }

    /// Query the result without parsing parameters or invoking any handler.
    pub fn inspect(self: *const Registry, tree: *const WidgetTree, focused: ?WidgetId, name: []const u8) !Availability {
        const resolved = self.descriptor(name) orelse return error.UnknownAction;
        const decided = try self.decide(tree, focused, resolved.name) orelse return .unavailable;
        return switch (decided.decision) {
            .available => .available,
            .disabled => .disabled,
        };
    }

    /// Read the tick mark of an action without running it. No handler runs,
    /// no payload is parsed, and the mark comes from the same binding that
    /// decided availability, so a `disabled` action keeps the mark its model
    /// reports instead of losing it to the greyed-out row. `unavailable` is
    /// `inspect`'s own answer when no live binding owns the action.
    pub fn inspectCheck(
        self: *const Registry,
        tree: *const WidgetTree,
        focused: ?WidgetId,
        name: []const u8,
    ) !CheckState {
        const resolved = self.descriptor(name) orelse return error.UnknownAction;
        const decided = try self.decide(tree, focused, resolved.name) orelse return .unavailable;
        const binding = decided.binding;
        const checked = binding.check_fn orelse return .unchecked;
        return checked(self.session, binding.owner);
    }

    /// The newest binding at the nearest eligible scope that is not
    /// unavailable, together with what it allows. `inspect`, `inspectCheck`
    /// and `dispatchPayload` all resolve through this one walk, so a mark, a
    /// greyed row and a click can never name different owners for one action.
    fn decide(
        self: *const Registry,
        tree: *const WidgetTree,
        focused: ?WidgetId,
        canonical_name: []const u8,
    ) !?Decided {
        var path = Path.init(tree, focused);
        while (path.next()) |scope| {
            var index = self.bindings.items.len;
            while (index > 0) {
                index -= 1;
                const binding = self.bindings.items[index];
                if (!binding.active or !binding.scope.eql(scope)) continue;
                if (!std.mem.eql(u8, binding.action_name, canonical_name)) continue;
                const state = try binding.state_fn(self.session, binding.owner);
                switch (state) {
                    .available => return .{ .binding = binding, .decision = .available },
                    .disabled => return .{ .binding = binding, .decision = .disabled },
                    .unavailable => continue,
                }
            }
        }
        return null;
    }

    /// Unknown names and malformed JSON are errors even without a handler.
    /// For void actions, omitted JSON, `null`, and `{}` are valid and never
    /// allocate; every other document is invalid. Non-void JSON is decoded
    /// once into a dispatch-local arena, which is freed before return.
    ///
    /// The observer attached when the call starts times the dispatch and
    /// gets one event after the dispatch returns. A failed dispatch reports
    /// no event, because it produced no result.
    pub fn dispatch(
        self: *Registry,
        tree: *const WidgetTree,
        focused: ?WidgetId,
        name: []const u8,
        json: ?[]const u8,
    ) !Result {
        const resolved = self.descriptor(name) orelse return error.UnknownAction;
        const observer = self.observer;
        const start_ns = if (observer) |active| active.clock.now() else 0;
        const depth: u32 = @intCast(self.dispatch_depth);
        var selected: ?WidgetId = null;
        self.dispatch_depth += 1;
        defer {
            self.dispatch_depth -= 1;
            if (self.dispatch_depth == 0 and self.needs_compact) self.compact();
        }
        const result = try resolved.dispatch_fn(self, tree, focused, json, &selected);
        if (observer) |active| {
            const end_ns = active.clock.now();
            active.on_dispatch(active.user, .{
                .name = resolved.name,
                .target = selected,
                .start_ns = start_ns,
                .end_ns = end_ns,
                .duration_ns = durationNs(start_ns, end_ns),
                .result = result,
                .depth = depth,
            });
        }
        return result;
    }

    fn dispatchAction(
        self: *Registry,
        comptime A: type,
        tree: *const WidgetTree,
        focused: ?WidgetId,
        json: ?[]const u8,
        selected: *?WidgetId,
    ) !Result {
        if (A.Payload == void) {
            if (json) |document| {
                const trimmed = std.mem.trim(u8, document, " \t\r\n");
                const empty_object = trimmed.len >= 2 and trimmed[0] == '{' and
                    trimmed[trimmed.len - 1] == '}' and
                    std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n").len == 0;
                if (!std.mem.eql(u8, trimmed, "null") and !empty_object) {
                    return error.InvalidParameters;
                }
            }
            const value: void = {};
            return self.dispatchPayload(A, tree, focused, &value, selected);
        } else {
            const document = json orelse return error.InvalidParameters;
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const raw = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), document, .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidParameters,
            };
            if (!matchesSchema(&A.schema, raw)) return error.InvalidParameters;
            const value = try decodeValue(A.Payload, arena.allocator(), raw);
            return self.dispatchPayload(A, tree, focused, &value, selected);
        }
    }

    fn dispatchPayload(
        self: *Registry,
        comptime A: type,
        tree: *const WidgetTree,
        focused: ?WidgetId,
        value: *const A.Payload,
        selected: *?WidgetId,
    ) !Result {
        const listener_limit = self.listeners.items.len;
        const decided = try self.decide(tree, focused, A.name) orelse return .unavailable;
        // The decided row travels by value, so a callback that cancels a
        // binding mid-answer cannot change which owner runs the handler.
        const binding = decided.binding;
        switch (decided.decision) {
            .disabled => {
                selected.* = scopeTarget(binding.scope);
                return .disabled;
            },
            .available => {
                selected.* = scopeTarget(binding.scope);
                try binding.invoke_fn(self.session, binding.owner, @ptrCast(value));
                var listener_index: usize = 0;
                while (listener_index < listener_limit) : (listener_index += 1) {
                    const entry = self.listeners.items[listener_index];
                    if (!entry.active or !std.mem.eql(u8, entry.action_name, A.name)) continue;
                    if (!try entry.alive_fn(self.session, entry.owner)) {
                        self.listeners.items[listener_index].active = false;
                        self.needs_compact = true;
                        continue;
                    }
                    try entry.invoke_fn(self.session, entry.owner, @ptrCast(value));
                }
                return .handled;
            },
        }
    }

    fn canonicalName(self: *const Registry, name: []const u8) ?[]const u8 {
        var current = name;
        var remaining = self.alias_entries.items.len + 1;
        while (remaining > 0) : (remaining -= 1) {
            current = self.aliasTarget(current) orelse return current;
        }
        return null;
    }

    fn aliasTarget(self: *const Registry, name: []const u8) ?[]const u8 {
        for (self.alias_entries.items) |alias| {
            if (std.mem.eql(u8, alias.name, name)) return alias.target;
        }
        return null;
    }

    fn occupied(self: *const Registry, name: []const u8) bool {
        for (self.actions.items) |action| {
            if (std.mem.eql(u8, action.name, name)) return true;
        }
        return self.aliasTarget(name) != null;
    }

    fn reserveToken(self: *Registry) !u64 {
        if (self.next_token_id == std.math.maxInt(u64)) return error.CapacityExceeded;
        const id = self.next_token_id;
        self.next_token_id += 1;
        return id;
    }

    fn compact(self: *Registry) void {
        var length: usize = 0;
        for (self.bindings.items) |entry| {
            if (!entry.active) continue;
            self.bindings.items[length] = entry;
            length += 1;
        }
        self.bindings.items.len = length;
        length = 0;
        for (self.listeners.items) |entry| {
            if (!entry.active) continue;
            self.listeners.items[length] = entry;
            length += 1;
        }
        self.listeners.items.len = length;
        self.needs_compact = false;
    }
};

/// The widget that owns a scope. The App scope has no widget.
fn scopeTarget(scope: Scope) ?WidgetId {
    return switch (scope) {
        .app => null,
        .widget => |id| id,
    };
}

/// A monotonic clock never moves backwards. An injected clock that does
/// reports no duration instead of a negative one.
fn durationNs(start_ns: i96, end_ns: i96) u64 {
    if (end_ns <= start_ns) return 0;
    return @intCast(end_ns - start_ns);
}

fn invocationAdapter(
    comptime A: type,
    comptime Owner: type,
    comptime handler: fn (*Owner, *const A.Payload, *Session) anyerror!void,
) *const fn (*Session, model.ErasedWeakModel, *const anyopaque) anyerror!void {
    return struct {
        fn call(session: *Session, weak: model.ErasedWeakModel, erased_value: *const anyopaque) anyerror!void {
            const typed = try session.castWeak(Owner, weak);
            const value: *const A.Payload = @ptrCast(@alignCast(erased_value));
            const User = struct { value: *const A.Payload, session: *Session };
            try session.update(Owner, typed, User{ .value = value, .session = session }, struct {
                fn run(owner: *Owner, user: User) !void {
                    try handler(owner, user.value, user.session);
                }
            }.run);
        }
    }.call;
}

/// Read one binding's tick mark through its erased weak owner. A released
/// owner answers `unavailable` rather than the mark it held when it was
/// bound, which is the same expired-owner rule the availability read uses.
fn checkAdapter(
    comptime Owner: type,
    comptime checked: fn (*const Owner, *Session) bool,
) *const fn (*Session, model.ErasedWeakModel) anyerror!CheckState {
    return struct {
        fn call(session: *Session, weak: model.ErasedWeakModel) anyerror!CheckState {
            const typed = session.castWeak(Owner, weak) catch |err| switch (err) {
                error.StaleModel => return .unavailable,
                else => return err,
            };
            var marked: bool = false;
            const User = struct { output: *bool, session: *Session };
            try session.read(Owner, typed, User{ .output = &marked, .session = session }, struct {
                fn run(value: *const Owner, user: User) !void {
                    user.output.* = checked(value, user.session);
                }
            }.run);
            return if (marked) .checked else .unchecked;
        }
    }.call;
}

/// Build the typed value from the validated JSON tree. Immutable strings
/// borrow the tree's arena storage, rather than allocating and copying again.
fn decodeValue(comptime T: type, arena: std.mem.Allocator, value: std.json.Value) !T {
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => value.bool,
        .int => std.json.parseFromValueLeaky(T, arena, value, .{}) catch
            return error.InvalidParameters,
        .float => blk: {
            const number = std.json.parseFromValueLeaky(T, arena, value, .{}) catch
                return error.InvalidParameters;
            if (!std.math.isFinite(number)) return error.InvalidParameters;
            break :blk number;
        },
        .@"enum" => std.meta.stringToEnum(T, value.string) orelse
            return error.InvalidParameters,
        .optional => |info| if (value == .null) null else try decodeValue(info.child, arena, value),
        .pointer => |info| blk: {
            if (info.child == u8) {
                if (info.sentinel()) |sentinel| {
                    const buffer = try arena.allocSentinel(u8, value.string.len, sentinel);
                    @memcpy(buffer, value.string);
                    break :blk buffer;
                }
                if (info.attrs.@"const") break :blk value.string;
                break :blk try arena.dupe(u8, value.string);
            }
            const source = value.array.items;
            const result = if (info.sentinel()) |sentinel|
                try arena.allocSentinel(info.child, source.len, sentinel)
            else
                try arena.alloc(info.child, source.len);
            for (source, result) |element, *slot| {
                slot.* = try decodeValue(info.child, arena, element);
            }
            break :blk result;
        },
        .array => |info| blk: {
            // SAFETY: filled element-wise below. The decode contract requires
            // the JSON value to carry exactly info.len items; both the memcpy
            // and the element loop cover the whole array.
            var result: T = undefined;
            if (info.child == u8) {
                @memcpy(&result, value.string);
            } else {
                for (value.array.items, &result) |element, *slot| {
                    slot.* = try decodeValue(info.child, arena, element);
                }
            }
            break :blk result;
        },
        .@"struct" => |info| blk: {
            // SAFETY: the inline loop assigns every field or returns an error.
            var result: T = undefined;
            inline for (info.field_names, info.field_types, info.field_attrs) |name, field_type, attrs| {
                if (value.object.get(name)) |element| {
                    @field(result, name) = try decodeValue(field_type, arena, element);
                } else if (attrs.default_value_ptr != null) {
                    @field(result, name) = attrs.defaultValue(field_type).?;
                } else {
                    return error.InvalidParameters;
                }
            }
            break :blk result;
        },
        else => comptime unreachable,
    };
}

/// std.json accepts numeric strings for integer/float fields and numeric enum
/// tags. Schema validation rules those out before typed conversion.
fn matchesSchema(schema: *const Schema, value: std.json.Value) bool {
    return switch (schema.*) {
        .none => value == .null,
        .boolean => value == .bool,
        .integer => value == .integer or value == .number_string,
        .number => value == .integer or value == .float or value == .number_string,
        .string => |length| switch (value) {
            .string => |text| if (length) |required| text.len == required else true,
            else => false,
        },
        .optional => |child| if (value == .null) true else matchesSchema(child, value),
        .enumeration => |names| switch (value) {
            .string => |text| for (names) |name| {
                if (std.mem.eql(u8, name, text)) break true;
            } else false,
            else => false,
        },
        .array => |spec| switch (value) {
            .array => |items| blk: {
                if (spec.length) |length| {
                    if (items.items.len != length) break :blk false;
                }
                for (items.items) |item| {
                    if (!matchesSchema(spec.item, item)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |fields| switch (value) {
            .object => |object| blk: {
                var keys = object.iterator();
                while (keys.next()) |entry| {
                    const field = for (fields) |*candidate| {
                        if (std.mem.eql(u8, candidate.name, entry.key_ptr.*)) break candidate;
                    } else break :blk false;
                    if (!matchesSchema(&field.value, entry.value_ptr.*)) break :blk false;
                }
                for (fields) |field| {
                    if (field.required and object.get(field.name) == null) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
    };
}

fn validateAction(comptime A: type) void {
    if (!@hasDecl(A, "name") or !@hasDecl(A, "Payload") or !@hasDecl(A, "schema")) {
        @compileError("expected Action(Payload, name) descriptor");
    }
    if (!validName(A.name)) @compileError("invalid action name");
    if (A != Action(A.Payload, A.name)) {
        @compileError("expected Action(Payload, name) descriptor");
    }
}
