//! E05: the macOS accessibility adapter.
//!
//! The semantic tree, the action queue, the character/byte offset conversion
//! and the diffing are the SHARED adapter's, in `../accessibility.zig`, and
//! this module reuses them rather than reimplementing them. What it owns is
//! the part that is macOS:
//!
//!   * ATTACHING. On Unix an adapter is built around a D-Bus connection in its
//!     constructor. On macOS it is built around the content view of a real
//!     window, so the host hands the window over separately, and this module
//!     does that: the `NSWindow` comes from SDL's own window property and the
//!     bridge subclasses its content view.
//!   * MAIN THREAD. AccessKit builds its macOS adapter from a
//!     `MainThreadMarker` (`SubclassingAdapter::for_window`), so
//!     `nogui_accesskit_bridge_set_view` refuses a call that is anywhere else
//!     and answers the same `false` it uses for a real refusal. `attach`
//!     therefore does every native operation inside `native.onMain`: a worker
//!     that attached directly got a platform refusal for a correct call.
//!   * FOCUS. SDL puts the keyboard focus on the window rather than its content
//!     view, and VoiceOver asks the window which element is focused.
//!     AccessKit ships a helper that adds that forwarder to a window class, and
//!     it can only be added once per class and never undone. So `attach` asks
//!     for it here, on the class the real window's own `NSWindow` is, and
//!     remembers what it already installed rather than asking twice — the
//!     helper's `class_addMethod` fails for a selector that already exists and
//!     its Rust side asserts that success, so a second call would be reported
//!     as a refusal that never happened.
//!     The same is true one step earlier: a class the bounded record below
//!     cannot hold is refused BEFORE the patch, because a forwarder that got
//!     installed without being remembered is the same false refusal, one
//!     attach later.
//!   * TRUST. macOS only lets a trusted process serve an accessibility tree.
//!     `AXIsProcessTrusted` is the fact, and asking for it is a request that
//!     shows the system prompt, so it is a separate call a host makes on a
//!     person's action. A process that is not trusted cannot be fixed from
//!     inside the application, which is why this is reported rather than
//!     retried. Nothing in this module requests it.
//!   * SCALE. The shared adapter publishes physical pixels and is told the
//!     logical-to-physical factor by its host. On macOS that factor is the
//!     window's backing scale factor, and the macOS adapter divides by the same
//!     number on the way back, so the two agree by construction. It is read on
//!     the main thread with everything else, because that is where the screen
//!     it reads lives.
const std = @import("std");
const sdl3 = @import("sdl3");
const native = @import("native.zig");
const shared = @import("../accessibility.zig");

/// The AccessKit C ABI, opened here rather than through the shim.
///
/// The shim header declares no framework of its own, and the bridge's ABI
/// lives in the canonical shared bridge header the whole host already links,
/// so a second `@cImport` is what makes these declarations visible here. That
/// header declares the five common entry points plus the two macOS ones this
/// adapter needs (`set_view` and `add_focus_forwarder`), so each ABI is
/// declared exactly once across the project.
const bridge = @cImport({
    @cInclude("nogui_accesskit_bridge.h");
});

const Error = native.Error;
const Status = native.Status;

/// The shared adapter. Its semantics, its action queue, its offsets and its
/// tree diffing are the ones the Unix path uses, unchanged.
pub const Adapter = shared.Adapter;
pub const State = shared.State;
pub const Capability = shared.Capability;
pub const Bell = shared.Bell;
pub const NodeId = shared.NodeId;
/// The shared tree-publication errors, named apart from the native ones so a
/// caller can tell a capacity failure from a platform refusal.
pub const TreeError = shared.Error;
pub const max_nodes = shared.max_nodes;
pub const max_queue = shared.max_queue;
pub const characterIndexOf = shared.characterIndexOf;
pub const byteOffsetOf = shared.byteOffsetOf;

/// The class-name limit this module reads and remembers with. It is
/// `native`'s, because that is where the shim's buffer contract is defined, so
/// a class can never be installed without also being remembered.
const class_name_limit = native.class_name_limit;

/// The longest class name this module patches or records: one byte shorter
/// than the buffer `native` reads a class name into, because that buffer holds
/// the name AND the terminator the C ABI reads. A window's class is therefore
/// always this long or shorter, and a host that supplies a longer name is
/// refused rather than truncated — a truncated name would put the forwarder on
/// a class with a different name, which is a class no window has.
const max_class_name_len = class_name_limit - 1;

/// The classes one process has already had the focus forwarder added to.
///
/// The forwarder is a method added to an existing `NSWindow` subclass, which
/// cannot be undone, and AccessKit's helper panics when `class_addMethod`
/// refuses — so asking twice is not a harmless repeat but a false refusal.
/// The record is what makes the answer independent of how many times a caller
/// asks, and it is bounded so a caller cannot grow it.
///
/// Every record is a fixed value: no allocation, so attaching a window cannot
/// fail for want of memory, and a test can hold one of its own instead of
/// sharing the process's.
const ForwarderRecord = struct {
    /// The most classes one record can hold a forwarder for. A process has one
    /// window class in practice; the bound is what makes "refuse before
    /// patching" possible, because a class that cannot be remembered must
    /// never be patched at all.
    const limit = 8;

    slots: [limit][max_class_name_len]u8 = @splat(@as([max_class_name_len]u8, @splat(0))),
    /// How many bytes each slot actually holds. A slot is as wide as the
    /// longest name and is zero past it, so this is what makes a lookup an
    /// exact comparison instead of a comparison against that padding.
    lengths: [limit]u8 = @splat(0),
    count: usize = 0,

    /// Whether this exact class is held.
    ///
    /// The comparison is over the stored name's own length. A slot is the full
    /// width of a class-name buffer, so comparing a whole slot against a name
    /// compares a length the name never has: nothing would ever be found,
    /// every attach would ask AccessKit to add a selector the class already
    /// has, and that second ask comes back as a refusal that never happened.
    fn holds(self: *const ForwarderRecord, name: []const u8) bool {
        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            const length: usize = self.lengths[index];
            if (std.mem.eql(u8, self.slots[index][0..length], name)) return true;
        }
        return false;
    }

    /// Whether the platform still has to be asked about this class.
    ///
    /// Every refusal is made here, BEFORE anything irreversible happens: a
    /// name no slot can hold is `error.BadArgument`, and a name this bounded
    /// record has no room for is `error.Refused`. `false` means the class is
    /// already held, so the platform must not be asked again — AccessKit's
    /// helper reports a second `class_addMethod` for a selector that now
    /// exists as the failure its Rust side asserts against.
    fn needsPatch(self: *const ForwarderRecord, name: []const u8) Error!bool {
        if (name.len > max_class_name_len) return error.BadArgument;
        if (self.holds(name)) return false;
        if (self.count == limit) return error.Refused;
        return true;
    }

    /// Record a class the platform has just patched.
    ///
    /// Only a class `needsPatch` asked for reaches here, so the name fits, the
    /// slot is free and the class is not already held. Anything else is a bug
    /// in this module rather than a case to absorb: a class installed and not
    /// recorded is the false refusal described above, one attach later.
    fn remember(self: *ForwarderRecord, name: []const u8) void {
        std.debug.assert(name.len <= max_class_name_len);
        std.debug.assert(!self.holds(name));
        std.debug.assert(self.count < limit);
        @memcpy(self.slots[self.count][0..name.len], name);
        self.lengths[self.count] = @intCast(name.len);
        self.count += 1;
    }
};

/// The one record for this process, because the forwarder is a property of the
/// process and cannot be undone: two records would each ask the platform to
/// patch a selector the class already has.
var installed_forwarders: ForwarderRecord = .{};

/// Whether this build has the AccessKit bridge linked. Without it the shared
/// adapter reports `State.unavailable` and every call here refuses.
pub const linked = shared.linked;

/// A trust read. The shim's AX call is an ApplicationServices object and
/// requires the main thread, so this marshals; `capabilities` may be read
/// from any thread.
const TrustRead = struct {
    trusted: bool = false,
};

fn readTrustOnMain(call: *TrustRead) void {
    call.trusted = native.shim.nogui_macos_accessibility_is_trusted() == 1;
}

const TrustRequest = struct {
    status: Status = .ok,
};

fn requestTrustOnMain(call: *TrustRequest) void {
    call.status = Status.of(native.shim.nogui_macos_accessibility_request_trust());
}

/// Whether this process is trusted to serve an accessibility tree.
///
/// macOS only lets a trusted process answer accessibility requests, and a
/// process cannot grant itself that: a person has to approve it in System
/// Settings. `false` therefore means the application has to tell the person
/// what to do, not retry. This reads the fact and prompts nothing, so it is
/// safe to poll.
pub fn isTrusted() bool {
    if (!native.available) return false;
    var call: TrustRead = .{};
    native.onMain(TrustRead, readTrustOnMain, &call) catch return false;
    return call.trusted;
}

/// Ask macOS to show its "grant accessibility access" prompt.
///
/// This is a request to a person, so a host calls it only in answer to an
/// action, and the answer arrives later through `isTrusted`. Returns false when
/// the system declined to show the prompt, which is a different fact from the
/// person declining it.
pub fn requestTrust() Error!bool {
    if (!native.available) return error.ShimUnavailable;
    if (!linked) return error.Unsupported;
    var call: TrustRequest = .{};
    native.onMain(TrustRequest, requestTrustOnMain, &call) catch return error.NotOnMainThread;
    if (call.status == .unavailable) return false;
    try native.check(call.status);
    return true;
}

/// Add the focus forwarder to a window class, once per class.
///
/// The class has to be an `NSWindow` subclass and the caller has to be on the
/// main thread, so this marshals: a host that called it from a worker was told
/// the platform refused a request it never made. The modification cannot be
/// undone, so a class this has already patched is answered without asking the
/// platform again — AccessKit's helper asserts that `class_addMethod`
/// succeeded, and a second call for a selector that now exists is exactly the
/// case where it does not.
///
/// A class that cannot be patched is a typed refusal, never a silent false:
/// `error.BadArgument` for a name longer than the buffer the name is read
/// into, and `error.Refused` for one this module's bounded record has no slot
/// for. Both are decided before the patch, because a forwarder that got
/// installed without being remembered comes back as a refusal that never
/// happened.
///
/// `attach` calls this for the class of the window it was handed, so a host
/// never has to make a separate startup call for it. This stays public for a
/// host that has a window class of its own and wants it patched before any
/// window exists.
pub fn addFocusForwarder(class_name: []const u8) Error!bool {
    if (!native.available) return error.ShimUnavailable;
    if (!linked) return error.Unsupported;
    var scratch = native.Scratch.init(std.heap.page_allocator);
    defer scratch.deinit();
    const owned = (try scratch.nul(class_name)) orelse return error.BadArgument;
    var call: ForwarderCall = .{ .owned = owned, .class_name = class_name };
    try native.onMain(ForwarderCall, forwarderOnMain, &call);
    if (call.failure) |err| return err;
    return true;
}

/// One forwarder installation, carried across the hop to the main thread.
const ForwarderCall = struct {
    /// The NUL-terminated name the bridge reads.
    owned: [*:0]const u8,
    /// The same name as a slice, so the record can compare it without going
    /// back to C.
    class_name: []const u8,
    /// The typed refusal, if there was one. Carrying the error rather than a
    /// boolean is what keeps "this record cannot hold that class" apart from
    /// "AccessKit declined the class": one is this module's own bound, the
    /// other is the platform's answer.
    failure: ?Error = null,
};

fn forwarderOnMain(call: *ForwarderCall) void {
    installForwarderOnMain(&installed_forwarders, call.owned, call.class_name) catch |err| {
        call.failure = err;
    };
}

/// Ask AccessKit to patch one window class and remember the answer.
///
/// The caller must be on main, which is also where the record is read and
/// written: the preflight and the patch are one step there, so two callers
/// reaching the same class cannot both pass the preflight and then both patch
/// it. This is the only place the bridge's forwarder entry point is named, and
/// it is reached only through `native.onMain`, which keeps the symbol out of a
/// build that is not macOS.
fn installForwarderOnMain(
    record: *ForwarderRecord,
    owned: [*:0]const u8,
    class_name: []const u8,
) Error!void {
    _ = try ensureForwarder(bridge.nogui_accesskit_bridge_add_focus_forwarder, record, owned, class_name);
}

/// Add the forwarder to one class, exactly once, and record it.
///
/// The order is the whole point. Preflight first, so a class that cannot be
/// remembered is never patched; patch second; remember third, so a class that
/// WAS patched is always recorded. Dropping either end turns the next ask for
/// that class into a `class_addMethod` for a selector the class already has.
///
/// `patch` is a parameter so those rules can be exercised off macOS, where
/// there is no `NSWindow` subclass to patch. `owned` is the C string the patch
/// reads and `class_name` is the same text as a slice.
fn ensureForwarder(
    comptime patch: *const fn ([*c]const u8) callconv(.c) bool,
    record: *ForwarderRecord,
    owned: [*:0]const u8,
    class_name: []const u8,
) Error!bool {
    // The identity is the C string the patch reads, which stops at the first
    // NUL. Recording a name that carries one would install a forwarder under
    // the text before it and remember the whole slice, and the next attach —
    // which reads the class off the window and never sees the rest — would
    // not find it and would patch that class a second time.
    const cut = std.mem.findScalar(u8, class_name, 0) orelse class_name.len;
    if (!try record.needsPatch(class_name[0..cut])) return true;
    if (!patch(owned)) return error.Refused;
    record.remember(class_name[0..cut]);
    return true;
}

/// Attach the shared adapter to a window.
///
/// This is the macOS half of the shared adapter's lifecycle: the adapter
/// already exists (it was self-initialised, because the bridge holds a pointer
/// to it), and this hands the bridge the window whose content view carries the
/// tree. The window is borrowed from SDL, so the adapter's view disappears with
/// the window and the caller must detach before destroying it.
///
/// EVERYTHING NATIVE HAPPENS ON THE MAIN THREAD. AccessKit builds its adapter
/// from a `MainThreadMarker`, and the key state and the backing scale are
/// AppKit facts, so a call made from a worker was refused by the bridge and
/// reported as `error.Refused` for something the caller did correctly. One hop
/// carries the whole attach: the focus forwarder, the view, and the scale.
///
/// A refusal is reported rather than attached past: `error.Refused` for a
/// window the platform declined or a view the adapter already carries, and for
/// a class this module's bounded forwarder record has no slot for — the last is
/// decided before the patch, because a forwarder installed without being
/// remembered is the same false refusal one attach later. Reading the window's
/// class name can fail too, as `error.BadArgument` or `error.BufferTooSmall`.
pub fn attach(adapter: *Adapter, window: sdl3.video.Window) Error!void {
    if (!native.available) return error.ShimUnavailable;
    if (!linked) return error.Unsupported;
    // The shared adapter holds its bridge privately and hands it out through
    // `bridgeHandle`, because a target adapter has to attach a native view to
    // a bridge the shared adapter owns. The handle is opaque on both sides: it
    // is the same pointer, and the C ABI is the only thing that names its
    // type.
    const bridge_ptr: *bridge.nogui_accesskit_bridge =
        @ptrCast(adapter.bridgeHandle() orelse return error.Unsupported);
    const borrowed = (try native.NativeWindow.borrow(window)) orelse return error.Unsupported;
    var call: AttachCall = .{
        .bridge = bridge_ptr,
        .borrowed = borrowed,
    };
    // One hop for the whole attach. The wait is what keeps `borrowed` alive
    // across it: this does not return until the work has run on main.
    try native.onMain(AttachCall, attachOnMain, &call);
    if (call.failure) |err| return err;
    // The shared adapter publishes physical pixels, and the macOS adapter
    // divides by this same factor on the way back to screen coordinates. The
    // factor was read on main above, because that is where the screen it names
    // lives; publishing it is the shared adapter's own field and stays here.
    adapter.setScale(call.scale, call.scale);
}

/// One attach, carried across the hop to the main thread.
const AttachCall = struct {
    bridge: *bridge.nogui_accesskit_bridge,
    borrowed: native.NativeWindow,
    /// The window's Objective-C class name, in fixed storage so nothing has to
    /// be allocated to hold it across a thread boundary.
    class_buf: [class_name_limit]u8 = @splat(0),
    /// The typed refusal the platform made, if it made one. Carrying the error
    /// rather than a boolean is what keeps "the window named no class",
    /// "AccessKit declined the window" and "the adapter already has a view"
    /// distinguishable instead of one `false`.
    failure: ?Error = null,
    scale: f32 = 1,
};

fn attachOnMain(call: *AttachCall) void {
    // The focus forwarder goes on the class of the window that was actually
    // handed over. SDL names `SDL3Window`, but reading it here is the only
    // answer that is right for a host whose window is a different class, and
    // no host has to make a separate startup call for it.
    const named = call.borrowed.className(&call.class_buf) catch |err| {
        call.failure = err;
        return;
    };
    installForwarderOnMain(&installed_forwarders, named.ptr, named) catch |err| {
        // A window with no forwarder has no focus path VoiceOver can follow,
        // so this is reported instead of being attached past — and a class the
        // record cannot hold is refused here, before the patch, rather than
        // installed and forgotten.
        call.failure = err;
        return;
    };
    if (bridge.nogui_accesskit_bridge_set_view(call.bridge, call.borrowed.handle, call.borrowed.isKey()) == false) {
        // The platform refused the window, or the adapter already has one.
        call.failure = error.Refused;
        return;
    }
    call.scale = call.borrowed.backingScale();
}

/// Detach before the window goes away.
///
/// The bridge's teardown restores the content view's class, so a window that is
/// destroyed with the bridge still attached would leave a view whose subclass
/// points at freed Rust.
pub fn detach(adapter: *Adapter) void {
    adapter.deinit();
}

/// The screen reader's view of what the adapter published, for a host that
/// wants to see the near side without a screen reader attached.
pub fn lastRole(adapter: *const Adapter) []const u8 {
    return adapter.lastRole();
}

pub fn lastLabel(adapter: *const Adapter) []const u8 {
    return adapter.lastLabel();
}

pub fn lastActions(adapter: *const Adapter) u32 {
    return adapter.lastActions();
}

test "api-w23 a macos accessibility attach refuses off macos by name" {
    // Off this target there is no NSWindow behind an SDL window and no
    // MainThreadMarker to hand AccessKit, so the attach is a typed
    // unavailability rather than a platform refusal for a correct call.
    if (comptime native.available) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(gpa, std.testing.io);
    defer adapter.deinit();
    try std.testing.expectError(
        error.ShimUnavailable,
        attach(&adapter, .{ .value = @ptrFromInt(0x1234) }),
    );
}

test "api-w23 a macos focus forwarder refuses off macos by name" {
    // The helper needs an NSWindow subclass and the main thread, neither of
    // which exists off macOS. Reporting it as an unavailability keeps a host's
    // "no forwarder here" honest instead of looking like a broken class.
    if (comptime native.available) return error.SkipZigTest;
    try std.testing.expectError(error.ShimUnavailable, addFocusForwarder("SDL3Window"));
}

test "api-w23 a macos accessibility adapter with no bridge serves nothing" {
    // A build without the bridge has no handle to hand AccessKit, so the
    // adapter publishes no tree rather than one nothing will read.
    if (comptime native.available) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(gpa, std.testing.io);
    defer adapter.deinit();
    try std.testing.expect(adapter.bridgeHandle() == null);
    try std.testing.expectEqual(State.unavailable, adapter.stateOf());
}

/// AccessKit's helper, stood in for.
///
/// Off macOS there is no `NSWindow` subclass to patch, so the rules that decide
/// WHEN the platform is asked are exercised against this instead. The count is
/// the fact those rules turn on: asking the helper to add a selector a class
/// already has is exactly the call its Rust side asserts against.
const ForwarderProbe = struct {
    var calls: usize = 0;
    var answer: bool = true;

    fn reset(accepts: bool) void {
        calls = 0;
        answer = accepts;
    }

    fn patch(class_name: [*c]const u8) callconv(.c) bool {
        _ = class_name;
        calls += 1;
        return answer;
    }
};

/// Ask about one class the way `installForwarderOnMain` does, through the
/// stand-in. The name is given once because production hands the seam the same
/// text twice: as the C string the bridge reads and as the slice the record
/// compares.
fn askForwarder(record: *ForwarderRecord, name: [:0]const u8) Error!bool {
    return ensureForwarder(&ForwarderProbe.patch, record, name.ptr, name);
}

test "api-w23 a macos focus forwarder is asked for once per class" {
    // AccessKit's helper asserts that `class_addMethod` succeeded, and adding a
    // selector a class already has is the case where it does not. So the
    // record of what was installed is what keeps a second attach from being
    // reported as a platform refusal that never happened, and it has to
    // distinguish one class from another rather than treating any install as
    // covering the rest.
    ForwarderProbe.reset(true);
    var record: ForwarderRecord = .{};
    try std.testing.expect(try askForwarder(&record, "NoguiOnceClass"));
    try std.testing.expect(try askForwarder(&record, "NoguiOnceClass"));
    try std.testing.expectEqual(@as(usize, 1), ForwarderProbe.calls);
    try std.testing.expect(try askForwarder(&record, "NoguiOtherOnceClass"));
    try std.testing.expectEqual(@as(usize, 2), ForwarderProbe.calls);
    try std.testing.expect(record.holds("NoguiOnceClass"));
    try std.testing.expect(record.holds("NoguiOtherOnceClass"));
}

test "api-w23 a macos forwarder record tells two class names apart" {
    // The record is per class, not per process: a host with a window class and
    // a tab class has to get a forwarder on both of them. A lookup that
    // matched a prefix, or compared a whole slot rather than the stored name's
    // own length, would answer "already installed" for a class that never was,
    // and the names that share a prefix with a held one are exactly the names
    // a prefix match confuses.
    ForwarderProbe.reset(true);
    var record: ForwarderRecord = .{};
    try std.testing.expect(try askForwarder(&record, "NoguiProbeWindow"));
    try std.testing.expect(try askForwarder(&record, "NoguiProbeWindowTab"));
    try std.testing.expect(record.holds("NoguiProbeWindow"));
    try std.testing.expect(record.holds("NoguiProbeWindowTab"));
    try std.testing.expect(!record.holds("NoguiProbeWindowTa"));
    try std.testing.expect(!record.holds("NoguiProbeWindo"));
    try std.testing.expect(!record.holds("NoguiProbeWindowTabs"));
    try std.testing.expect(!record.holds(""));
    try std.testing.expectEqual(@as(usize, 2), ForwarderProbe.calls);
}

test "api-w23 a macos forwarder record remembers the name the bridge reads" {
    // AccessKit's helper reads a C string, so a name carrying an embedded NUL
    // is patched under the text before it. Recording the whole slice would
    // install a forwarder on `NoguiCutName` and remember `NoguiCutName\0Tab`,
    // and the next attach — which reads the class off the window and never
    // sees the rest — would not find it and would patch that class a second
    // time.
    ForwarderProbe.reset(true);
    var record: ForwarderRecord = .{};
    try std.testing.expect(try ensureForwarder(
        &ForwarderProbe.patch,
        &record,
        "NoguiCutName\x00Tab",
        "NoguiCutName\x00Tab",
    ));
    try std.testing.expect(record.holds("NoguiCutName"));
    try std.testing.expect(!record.holds("NoguiCutName\x00Tab"));
    try std.testing.expect(try askForwarder(&record, "NoguiCutName"));
    try std.testing.expectEqual(@as(usize, 1), ForwarderProbe.calls);
}

test "api-w23 a macos refused forwarder is not remembered" {
    // AccessKit's helper answers false for a class that is not an `NSWindow`
    // subclass. Nothing was installed, so nothing may be recorded: a record
    // that remembered the refusal would answer "already installed" for a class
    // with no forwarder at all, which is the same false refusal the record is
    // here to prevent.
    ForwarderProbe.reset(false);
    var record: ForwarderRecord = .{};
    try std.testing.expectError(error.Refused, askForwarder(&record, "NoguiRefusedClass"));
    try std.testing.expect(!record.holds("NoguiRefusedClass"));
    try std.testing.expectEqual(@as(usize, 1), ForwarderProbe.calls);
    // The class is asked for again and answered by the platform, because the
    // record never claimed it.
    ForwarderProbe.reset(true);
    try std.testing.expect(try askForwarder(&record, "NoguiRefusedClass"));
    try std.testing.expectEqual(@as(usize, 1), ForwarderProbe.calls);
    try std.testing.expect(record.holds("NoguiRefusedClass"));
}

test "api-w23 a macos forwarder record refuses a class it cannot remember" {
    // A name too long to store is refused rather than truncated. Truncating it
    // would install a forwarder on one class and remember another, so the next
    // attach would ask the platform again and be reported as a refusal that
    // never happened — the exact defect the record is here to prevent. The
    // refusal is made before the platform is asked, because the platform's
    // answer cannot be undone.
    //
    // The length refused is the buffer width: that buffer holds the name AND
    // the terminator the C ABI reads, so a name of `class_name_limit` bytes
    // leaves no room for the terminator, and `max_class_name_len` is the
    // longest name that fits and is remembered.
    ForwarderProbe.reset(true);
    var record: ForwarderRecord = .{};
    const too_long = "x" ** class_name_limit;
    const longest = "x" ** max_class_name_len;
    try std.testing.expectError(error.BadArgument, askForwarder(&record, too_long));
    try std.testing.expect(!record.holds(too_long));
    try std.testing.expectEqual(@as(usize, 0), ForwarderProbe.calls);
    try std.testing.expect(try askForwarder(&record, longest));
    try std.testing.expect(record.holds(longest));
    try std.testing.expectEqual(@as(usize, 1), ForwarderProbe.calls);
}

test "api-w23 a macos full forwarder record refuses a class before patching it" {
    // The bound is what makes that refusal safe rather than a silent drop: a
    // class with no slot must never reach the platform, because the forwarder
    // cannot be undone and a class that was installed without being recorded
    // comes back as a refusal that never happened. The bound refuses a NEW
    // class and leaves the ones already patched answering for themselves.
    ForwarderProbe.reset(true);
    var record: ForwarderRecord = .{};
    const classes = [_][:0]const u8{
        "NoguiFullClassA",
        "NoguiFullClassB",
        "NoguiFullClassC",
        "NoguiFullClassD",
        "NoguiFullClassE",
        "NoguiFullClassF",
        "NoguiFullClassG",
        "NoguiFullClassH",
    };
    try std.testing.expectEqual(ForwarderRecord.limit, classes.len);
    for (classes) |name| {
        try std.testing.expect(try askForwarder(&record, name));
    }
    try std.testing.expectError(error.Refused, askForwarder(&record, "NoguiOneClassTooMany"));
    try std.testing.expect(!record.holds("NoguiOneClassTooMany"));
    try std.testing.expect(try askForwarder(&record, "NoguiFullClassA"));
    try std.testing.expectEqual(@as(usize, ForwarderRecord.limit), ForwarderProbe.calls);
    try std.testing.expectEqual(ForwarderRecord.limit, record.count);
}
