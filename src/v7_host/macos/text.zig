//! E02: macOS text services — the find pasteboard and the character palette.
//!
//! THE CHARACTER PALETTE. `orderFrontCharacterPalette:` shows the system
//! palette, and the palette delivers what a person picks through
//! `NSTextInputClient`'s `insertText:replacementRange:`. A client-rendered text
//! field has no `NSTextView` for that to land in, so this module owns a
//! zero-sized `NSTextView` in the window's content view and makes it the first
//! responder while a focused edit wants palette input. The view is a MIRROR,
//! not a second document: the host writes the focused edit's text and
//! selection into it, the palette inserts into that, and the insertion comes
//! back here as bytes and byte offsets the host applies to its own edit. The
//! view is never read back as a source of truth, and it holds nothing the host
//! has not already given it.
//!
//! THE FIND PASTEBOARD. AppKit's Find panel and an application share one named
//! pasteboard, `NSPasteboardNameFind`. Writing the current selection or search
//! text to it is how a client-rendered field takes part in the system's Find,
//! and the finder's own options ride on the same pasteboard as a property
//! list. Both directions are here, and both go through one measurement of a
//! character, so an offset AppKit names and one the core names cannot drift
//! apart.
const std = @import("std");
const sdl3 = @import("sdl3");
const native = @import("native.zig");

const Error = native.Error;
const Status = native.Status;
const shim = native.shim;

/// One insertion the palette made into the mirror.
///
/// `byte_start` and `byte_length` address the mirror the host last wrote, in
/// the core's UTF-8 byte offsets, so a host applies this to its own edit
/// without knowing that AppKit thinks in UTF-16.
pub const Insertion = struct {
    /// Borrowed from the responder that produced it, and valid until the next
    /// `drainInsertions`.
    text: []const u8,
    byte_start: usize,
    byte_length: usize,

    /// The range of the mirror this insertion replaces.
    pub fn range(self: Insertion) struct { start: usize, end: usize } {
        return .{ .start = self.byte_start, .end = self.byte_start + self.byte_length };
    }
};

/// Insertions buffered between the palette and the host.
pub const insert_limit = 16;

/// Bytes one buffered insertion may carry. A longer insertion is refused and
/// counted rather than truncated into text the host would apply to a range
/// the palette never named.
pub const insert_text_limit = 512;

/// Bytes of answer one service request may write. A longer answer is refused
/// rather than truncated into something the sender would read as complete.
pub const reply_limit = 4096;

/// What an incoming service request carries. `send_type` and `return_type` are
/// uniform type identifiers such as `public.utf8-plain-text`; `text` is the
/// string flavour of the pasteboard, empty when it holds none.
pub const ServiceRequest = struct {
    send_type: []const u8,
    return_type: []const u8,
    text: []const u8,
};

/// Routes an incoming service request into the host's model.
///
/// The handler writes its answer into the scratch slice and returns how many
/// bytes it wrote, or null to decline. Declining is not a platform failure: it
/// is this application saying it will not answer, so the service stays
/// unanswered rather than receiving an empty string that reads as a real
/// answer.
pub const ServiceRoute = struct {
    context: ?*anyopaque = null,
    perform: *const fn (?*anyopaque, ServiceRequest, []u8) ?usize,
};

/// The code point `bytes` holds, where its width has already been checked.
///
/// `std.unicode.utf8Decode` reads the length of the slice it is handed as the
/// width of the character, so a slice one byte short of a character decodes as
/// something else instead of failing, which is why it is deprecated. Both
/// callers below already know the width, so the fixed-size decoders are
/// called directly. They reject a missing continuation, an overlong form and a
/// three-byte sequence that encodes a surrogate half, which is exactly what
/// the deprecated function rejected.
fn decodeCodepoint(bytes: []const u8) !u21 {
    return switch (bytes.len) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        4 => std.unicode.utf8Decode4(bytes[0..4].*),
        else => unreachable,
    };
}

/// One character measured in the two units the two directions count in.
///
/// This is the only place a character is measured. Every conversion in this
/// module asks it, so a codepoint past the basic plane is a surrogate pair in
/// both directions rather than in one of them, and bytes that name no
/// character are refused in both rather than counted in one.
const Measured = struct {
    /// Bytes the character occupies in the core's UTF-8.
    bytes: usize,
    /// UTF-16 code units an `NSRange` counts it as.
    units: usize,
};

/// The character starting at byte `at`, or null when those bytes are not one.
///
/// Bytes that name no character are refused rather than counted: a truncated
/// sequence, an overlong form, and a surrogate half written out as UTF-8 all
/// stand for nothing, so counting one would aim a selection or a replacement
/// at a place the text does not have.
fn measureAt(text: []const u8, at: usize) ?Measured {
    const width = std.unicode.utf8ByteSequenceLength(text[at]) catch return null;
    if (width == 0 or at + width > text.len) return null;
    const code = decodeCodepoint(text[at..][0..width]) catch return null;
    return .{ .bytes = width, .units = if (code >= 0x10000) 2 else 1 };
}

/// The byte offset in `text` that UTF-16 code unit `unit` addresses.
///
/// Returns null for an index past the end, because clamping it would silently
/// aim a replacement at the wrong characters. A surrogate pair is two code
/// units, so an index that lands in the middle of one resolves to the start of
/// the character that owns it: there is no position inside a code point for a
/// text engine to name.
pub fn byteOffsetOfUtf16(text: []const u8, unit: usize) ?usize {
    var units: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        if (units >= unit) return at;
        const measured = measureAt(text, at) orelse return null;
        const start = at;
        at += measured.bytes;
        units += measured.units;
        // The unit named a position inside the character just consumed, which
        // happens for the trailing half of a surrogate pair. Returning where
        // the walk stopped instead would aim an insertion one whole character
        // further on than the palette asked for, so the position resolves to
        // the character that owns it.
        if (unit < units) return start;
    }
    if (units >= unit) return at;
    return null;
}

/// The byte offset at or before `at` that AppKit can name, clamped to `text`.
///
/// The core addresses a selection in UTF-8 byte offsets and those can land
/// inside a character, while an `NSRange` counts UTF-16 code units and has no
/// position inside one. This resolves such an offset to the start of the
/// character that contains it, which is the rule the accessibility bridge
/// applies to a byte offset on every target. UTF-8 self-synchronises, so the
/// start of a codepoint is exactly a byte that is not a continuation byte and
/// walking back to one is enough.
pub fn characterStart(text: []const u8, at: usize) usize {
    var start = @min(at, text.len);
    // The end of the text is where the walk stops as well as where it starts:
    // there is no byte to read past it, and it is a boundary already.
    while (start > 0 and start < text.len and (text[start] & 0xc0) == 0x80) start -= 1;
    return start;
}

/// The UTF-16 length of a UTF-8 string, which is what an `NSRange` counts.
///
/// Bytes that name no character end the count rather than extending it, so
/// this reports how much of `text` is text and never invents a code unit for
/// the tail that is not one.
pub fn utf16Length(text: []const u8) usize {
    var units: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        const measured = measureAt(text, at) orelse break;
        units += measured.units;
        at += measured.bytes;
    }
    return units;
}

const Buffered = struct {
    text: [insert_text_limit]u8,
    len: usize = 0,
    byte_start: usize = 0,
    byte_length: usize = 0,
};

/// The window's first responder for text services.
///
/// It is one object for two jobs because AppKit delivers both through the same
/// slot: an incoming service request and a palette insertion both go to
/// whatever is first responder. Its address has to outlive `deinit`, because
/// the shim keeps the pointer for as long as the view is in the window.
///
/// Allocate one, then initialize it in place.
///     const responder = try gpa.create(Responder);
///     errdefer gpa.destroy(responder);
///     responder.* = Responder.init(gpa, io);
pub const Responder = struct {
    gpa: std.mem.Allocator,
    /// The Io the insertion ring's mutex waits on. AppKit delivers a palette
    /// insertion on its own thread, so the window that owns this responder has
    /// to keep its Io alive for as long as the shim holds the view.
    io: std.Io,
    handle: ?*anyopaque = null,
    closed: bool = false,
    /// The text the host's focused edit currently holds, mirrored so AppKit
    /// has real content to insert into. Owned.
    mirror: std.ArrayListUnmanaged(u8) = .empty,
    /// The mirror's selection, in byte offsets.
    selection_start: usize = 0,
    selection_length: usize = 0,
    /// Scratch the service handler writes its answer into, and the length it
    /// wrote. A FIXED buffer, not a list: the handler is handed the whole
    /// `reply_limit` every time, so one short answer cannot permanently shrink
    /// what the next one may write. The shim copies it before the callback
    /// returns, so it may be reused immediately.
    reply: [reply_limit]u8,
    reply_len: usize = 0,
    /// The host's own selection, for a service this application sends, with
    /// room for the terminating NUL the shim reads past it with.
    selection: std.ArrayListUnmanaged(u8) = .empty,
    has_selection: bool = false,
    /// Where an incoming service request goes. Null means this application
    /// answers no services, and every request is declined.
    route: ?ServiceRoute = null,
    /// Whether AppKit may enable a Services menu item. The host decides.
    validates: bool = true,
    /// How many service requests reached the host, and how many it answered.
    /// The difference is the number a person chose that this application
    /// declined, which is a fact the host may want to show.
    performed: u32 = 0,
    answered: u32 = 0,
    insertions: [insert_limit]Buffered,
    insertion_count: u16 = 0,
    insertion_head: u16 = 0,
    /// Insertions the ring refused: because the host was not draining, because
    /// the insertion was too long for a slot, or because the platform named no
    /// bytes at all. Counted under the same lock that buffers them.
    dropped: u32 = 0,
    mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Responder {
        return .{
            .gpa = gpa,
            .io = io,
            // SAFETY: the handler fills this scratch and `onPerform` writes a
            // NUL at the length it wrote, so the shim reads only bytes the
            // handler produced.
            .reply = undefined,
            // SAFETY: `drainInsertions` reads only the slots `onInsert`
            // counted, and each of those was filled before it was counted.
            .insertions = undefined,
        };
    }

    /// Add the view to a window's content view and start receiving.
    pub fn attach(self: *Responder, window: sdl3.video.Window) Error!void {
        if (!native.available) return error.ShimUnavailable;
        if (self.handle != null) return;
        const borrowed = (try native.NativeWindow.borrow(window)) orelse return error.Unsupported;
        const services: shim.nogui_macos_services_callbacks = .{
            .user = @ptrCast(self),
            .on_perform = onPerform,
            .on_write = onWrite,
            .on_validate = onValidate,
        };
        const text: shim.nogui_macos_text_callbacks = .{
            .user = @ptrCast(self),
            .on_insert = onInsert,
        };
        const handle = shim.nogui_macos_responder_new(borrowed.handle, &services, &text) orelse
            return error.ShimUnavailable;
        // The reply scratch is a fixed array on the responder, so a service
        // handler always has a real slice to write into and the callback path
        // never allocates.
        self.handle = handle;
    }

    pub fn detach(self: *Responder) void {
        self.closed = true;
        const handle = self.handle orelse return;
        self.handle = null;
        if (!native.available) return;
        shim.nogui_macos_responder_free(handle);
    }

    pub fn deinit(self: *Responder) void {
        self.detach();
        self.mirror.deinit(self.gpa);
        self.selection.deinit(self.gpa);
        self.* = undefined;
    }

    /// Where incoming service requests go. Without one, every request is
    /// declined, which is what an application that provides no service says.
    pub fn setServiceRoute(self: *Responder, route: ?ServiceRoute) void {
        self.route = route;
    }

    /// Publish the focused edit's text and selection to the mirror.
    ///
    /// The core stays the authority: this only gives AppKit something real to
    /// measure a palette insertion against.
    pub fn setMirror(
        self: *Responder,
        text: []const u8,
        selection: struct { start: usize, length: usize },
    ) Error!void {
        if (!native.available) return error.ShimUnavailable;
        const handle = self.handle orelse return error.Unsupported;
        const start = characterStart(text, selection.start);
        // The end saturates rather than wrapping, so a selection range past
        // the whole address space still resolves to the end of the text
        // instead of to a position in front of the start.
        const end = @max(start, characterStart(text, selection.start +| selection.length));
        self.mirror.clearRetainingCapacity();
        self.mirror.appendSlice(self.gpa, text) catch return error.OutOfMemory;
        self.selection_start = start;
        self.selection_length = end - start;
        // AppKit's NSRange counts UTF-16 code units, so the core's byte
        // offsets are converted here and nowhere else. Both ends are already on
        // a character start, which is the only place an NSRange can point: a
        // byte offset in the middle of a character would otherwise be counted
        // as the prefix in front of it and hand AppKit a selection the host
        // never published.
        try native.check(Status.of(shim.nogui_macos_text_mirror(
            handle,
            if (text.len == 0) null else text.ptr,
            text.len,
            utf16Length(text[0..start]),
            utf16Length(text[start..end]),
        )));
    }

    /// The text the host last published, and its selection. A host reads this
    /// to know what an insertion was measured against.
    pub fn mirrored(self: *const Responder) []const u8 {
        return self.mirror.items;
    }

    /// Make the responder first responder, which is what a service request and
    /// a palette insertion both need.
    pub fn makeFirstResponder(self: *Responder) Error!bool {
        if (!native.available) return error.ShimUnavailable;
        const handle = self.handle orelse return error.Unsupported;
        return native.fact(shim.nogui_macos_text_make_first_responder(handle));
    }

    /// Show the system character palette. The system dismisses it when the
    /// first responder changes, so there is no close call that could disagree
    /// with what a person sees.
    pub fn openCharacterPalette() Error!void {
        if (!native.available) return error.ShimUnavailable;
        try native.check(Status.of(shim.nogui_macos_text_open_character_palette()));
    }

    /// Take every buffered insertion, oldest first. The returned views borrow
    /// the responder's ring and stay valid until the next call.
    pub fn drainInsertions(self: *Responder, out: *[insert_limit]Insertion) usize {
        var count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        while (self.insertion_count > 0 and count < insert_limit) {
            const slot = &self.insertions[self.insertion_head];
            out[count] = .{
                .text = slot.text[0..slot.len],
                .byte_start = slot.byte_start,
                .byte_length = slot.byte_length,
            };
            self.insertion_head = (self.insertion_head + 1) % insert_limit;
            self.insertion_count -= 1;
            count += 1;
        }
        self.mutex.unlock(self.io);
        return count;
    }

    /// Insertions the ring refused.
    ///
    /// Read under the lock `onInsert` writes it under, so what a host reads is
    /// what the platform made rather than a value it raced for.
    pub fn droppedInsertions(self: *Responder) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.dropped;
    }

    /// Set the text this application offers when it sends a service.
    ///
    /// The shim reads the answer with `[NSString stringWithUTF8String:]`,
    /// which runs to the first zero byte, so one byte is reserved for a
    /// terminator the shim can find. Without it the string would run into
    /// whatever followed the selection in memory.
    pub fn setSelection(self: *Responder, text: ?[]const u8) Error!void {
        self.selection.clearRetainingCapacity();
        self.has_selection = false;
        if (text) |value| {
            if (value.len + 1 > native.max_text) return error.BadArgument;
            self.selection.appendSlice(self.gpa, value) catch return error.OutOfMemory;
            self.selection.append(self.gpa, 0) catch return error.OutOfMemory;
            self.has_selection = true;
        }
    }

    /// Whether AppKit may enable a Services menu item. The host decides, and a
    /// host that has not said otherwise accepts.
    pub fn setValidates(self: *Responder, validates: bool) void {
        self.validates = validates;
    }

    /// How many service requests reached the host, and how many it answered.
    pub fn serviceCounts(self: *const Responder) struct { performed: u32, answered: u32 } {
        return .{ .performed = self.performed, .answered = self.answered };
    }

    fn fromUser(user: ?*anyopaque) ?*Responder {
        const ptr = user orelse return null;
        const self: *Responder = @ptrCast(@alignCast(ptr));
        // A callback that arrives after `detach` finds the closed flag and
        // drops the event, which is the whole reason the flag exists.
        if (self.closed) return null;
        return self;
    }

    // A `const char *` argument crosses as `[*c]const u8`, which is the shape
    // the shim header declares. C may pass NULL for any of them, so each is
    // read as a pointer that can be null rather than as an optional: a null
    // here is "the platform sent no such string", which is a value a caller
    // has to see and not a fault.

    fn onInsert(
        user: ?*anyopaque,
        utf8: [*c]const u8,
        len: usize,
        location: u64,
        length: u64,
    ) callconv(.c) void {
        const self = Responder.fromUser(user) orelse return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Every refusal is refused whole and every refusal is counted. Text too
        // long for a slot is not truncated, a full ring is not overwritten, and
        // a platform that named no bytes has sent nothing. Counting all three
        // is what lets a host tell a person that a character was eaten instead
        // of leaving them to wonder where it went.
        if (utf8 == null or len > insert_text_limit or self.insertion_count == insert_limit) {
            self.dropped +%= 1;
            return;
        }
        const bytes = utf8[0..len];
        // An offset the mirror cannot address is a real defect, not a value to
        // guess at, so it is counted with the other refusals. The sum
        // saturates: a palette that reported a range past the whole address
        // space would otherwise wrap to a position in front of itself and the
        // host would apply the insertion at the wrong characters.
        const start = byteOffsetOfUtf16(self.mirror.items, @intCast(location)) orelse {
            self.dropped +%= 1;
            return;
        };
        const end = byteOffsetOfUtf16(self.mirror.items, @intCast(location +| length)) orelse {
            self.dropped +%= 1;
            return;
        };
        const tail = (self.insertion_head + self.insertion_count) % insert_limit;
        const slot = &self.insertions[tail];
        @memcpy(slot.text[0..len], bytes);
        slot.len = len;
        slot.byte_start = start;
        slot.byte_length = end - start;
        self.insertion_count += 1;
    }

    fn onPerform(
        user: ?*anyopaque,
        send_type: [*c]const u8,
        return_type: [*c]const u8,
        text: [*c]const u8,
        text_len: usize,
    ) callconv(.c) [*c]const u8 {
        const self = Responder.fromUser(user) orelse return null;
        const route = self.route orelse return null;
        self.performed +%= 1;
        const request: ServiceRequest = .{
            .send_type = native.view(send_type),
            .return_type = native.view(return_type),
            .text = if (text == null) "" else text[0..text_len],
        };
        const written = route.perform(route.context, request, self.reply[0..]) orelse return null;
        // The answer has to end in a NUL inside the scratch for the shim to
        // read it, so a handler that filled the whole buffer has no room for
        // one and is declined rather than answered with a truncated string.
        if (written >= self.reply.len) return null;
        self.answered +%= 1;
        // The shim copies this before the callback returns, so the length is
        // the only thing that has to survive it.
        self.reply[written] = 0;
        self.reply_len = written;
        return @ptrCast(&self.reply);
    }

    fn onWrite(user: ?*anyopaque) callconv(.c) [*c]const u8 {
        const self = Responder.fromUser(user) orelse return null;
        // `setSelection` always leaves a terminator, so this reads to the
        // selection's end and no further.
        if (!self.has_selection or self.selection.items.len <= 1) return null;
        return @ptrCast(self.selection.items.ptr);
    }

    fn onValidate(user: ?*anyopaque, label: [*c]const u8) callconv(.c) c_int {
        const self = Responder.fromUser(user) orelse return 0;
        _ = label;
        return if (self.validates) 1 else 0;
    }
};

pub const FindContent = enum { empty, text_only, other };

/// Inspect all declared flavors before a text-only consumer changes the board.
pub fn findContent() Error!FindContent {
    if (comptime !native.available) return error.ShimUnavailable;
    const raw = shim.nogui_macos_find_pasteboard_content();
    if (raw < 0) return native.fail(Status.of(raw));
    return switch (raw) {
        0 => .empty,
        1 => .text_only,
        2 => .other,
        else => error.PlatformFault,
    };
}

/// Write the focused selection or the search text to the shared find
/// pasteboard, which is how a client-rendered field takes part in the system's
/// Find.
pub fn writeFindText(text: []const u8) Error!void {
    if (!native.available) return error.ShimUnavailable;
    try native.check(Status.of(shim.nogui_macos_find_pasteboard_write(text.ptr, text.len)));
}

/// Read what the finder last put on the shared pasteboard. An empty slice is
/// the finder's "no text", which is a value and not a failure.
pub fn readFindText(gpa: std.mem.Allocator) Error![]u8 {
    return native.readString(gpa, .find_text, 0, null);
}

pub fn clearFindText() Error!void {
    if (!native.available) return error.ShimUnavailable;
    try native.check(Status.of(shim.nogui_macos_find_pasteboard_clear()));
}

/// The finder's own options, as the XML property list it stores. Null is the
/// platform saying there are none yet, which is not the same as an empty list.
pub fn readFindOptions(gpa: std.mem.Allocator) Error!?[]u8 {
    const text = try native.readString(gpa, .find_options, 0, null);
    if (text.len == 0) {
        gpa.free(text);
        return null;
    }
    return text;
}

/// Hand the finder a new options property list. Text that is not a property
/// list is refused, so the finder never receives something it cannot read.
pub fn writeFindOptions(plist: []const u8) Error!void {
    if (!native.available) return error.ShimUnavailable;
    var scratch = native.Scratch.init(std.heap.page_allocator);
    defer scratch.deinit();
    const owned = (try scratch.nul(plist)) orelse return error.BadArgument;
    try native.check(Status.of(shim.nogui_macos_find_options_write(owned)));
}

test "api-w23 macos utf16 offsets address the same characters the core does" {
    const text = "aé\u{1F600}z";
    // a(1) e-acute(1) emoji(2) z(1) => 5 code units, 8 bytes.
    try std.testing.expectEqual(@as(usize, 8), text.len);
    try std.testing.expectEqual(@as(usize, 5), utf16Length(text));
    try std.testing.expectEqual(@as(usize, 0), byteOffsetOfUtf16(text, 0).?);
    try std.testing.expectEqual(@as(usize, 1), byteOffsetOfUtf16(text, 1).?);
    try std.testing.expectEqual(@as(usize, 3), byteOffsetOfUtf16(text, 2).?);
    // The second half of a surrogate pair resolves to the character that owns
    // it, because no position inside a code point can be named.
    try std.testing.expectEqual(@as(usize, 3), byteOffsetOfUtf16(text, 3).?);
    try std.testing.expectEqual(@as(usize, 7), byteOffsetOfUtf16(text, 4).?);
    try std.testing.expectEqual(@as(usize, 8), byteOffsetOfUtf16(text, 5).?);
    // An index past the end is refused rather than clamped.
    try std.testing.expect(byteOffsetOfUtf16(text, 6) == null);
    try std.testing.expectEqual(@as(usize, 0), utf16Length(""));
    try std.testing.expectEqual(@as(usize, 0), byteOffsetOfUtf16("", 0).?);

    // Bytes that are not text have no character position to name, so they are
    // refused rather than walked. A truncated codepoint is one, and so is a
    // surrogate half written out as UTF-8: it stands for no character, and
    // counting it as one would address an insertion at a place the text does
    // not have.
    const lone_surrogate = "\xed\xa0\x80";
    try std.testing.expectEqual(@as(usize, 0), utf16Length(lone_surrogate));
    // The start of the text is addressable whatever follows it — a range that
    // begins at zero is a real position — but nothing past the bytes that are
    // not a character can be named.
    try std.testing.expectEqual(@as(usize, 0), byteOffsetOfUtf16(lone_surrogate, 0).?);
    try std.testing.expect(byteOffsetOfUtf16(lone_surrogate, 1) == null);
    const truncated = "a\xc3";
    // "a" counts, and the boundary after it is a position the string really
    // has; the codepoint the string cuts off is not, so nothing past it can be
    // named either.
    try std.testing.expectEqual(@as(usize, 1), utf16Length(truncated));
    try std.testing.expectEqual(@as(usize, 1), byteOffsetOfUtf16(truncated, 1).?);
    try std.testing.expect(byteOffsetOfUtf16(truncated, 2) == null);

    // The other direction, which is the rule a byte offset gets: one that
    // lands inside a character resolves to that character's start, so a range
    // built from it is a range AppKit can point at.
    try std.testing.expectEqual(@as(usize, 0), characterStart(text, 0));
    try std.testing.expectEqual(@as(usize, 1), characterStart(text, 1));
    // Byte 2 is the first half of "é" and byte 3 the middle of the emoji; both
    // name the character they are inside.
    try std.testing.expectEqual(@as(usize, 1), characterStart(text, 2));
    try std.testing.expectEqual(@as(usize, 3), characterStart(text, 4));
    try std.testing.expectEqual(@as(usize, 3), characterStart(text, 6));
    // An offset past the text is the end of it, and the end is a position.
    try std.testing.expectEqual(@as(usize, 8), characterStart(text, 99));
}

test "api-w23 macos insertion ring is bounded and drains oldest first" {
    var responder = Responder.init(std.testing.allocator, std.testing.io);
    defer responder.deinit();
    var out: [insert_limit]Insertion = undefined;
    for (0..insert_limit) |index| {
        responder.insertions[index] = .{
            .text = undefined,
            .len = 1,
            .byte_start = index,
            .byte_length = 0,
        };
        responder.insertions[index].text[0] = @intCast('a' + @as(u8, @intCast(index % 26)));
    }
    responder.insertion_count = insert_limit;
    try std.testing.expectEqual(insert_limit, responder.drainInsertions(&out));
    for (out[0..insert_limit], 0..) |insertion, index| {
        try std.testing.expectEqual(@as(usize, 1), insertion.text.len);
        try std.testing.expectEqual(@as(u8, @intCast('a' + @as(u8, @intCast(index % 26)))), insertion.text[0]);
        try std.testing.expectEqual(index, insertion.byte_start);
    }
    try std.testing.expectEqual(@as(usize, 0), responder.drainInsertions(&out));
}

test "api-w23 macos service request with no route is declined" {
    var responder = Responder.init(std.testing.allocator, std.testing.io);
    defer responder.deinit();
    const bytes = "hello";
    // No route means this application provides no service, and the shim is
    // told so instead of being handed an empty answer.
    try std.testing.expect(
        Responder.onPerform(@ptrCast(&responder), null, null, bytes.ptr, bytes.len) == null,
    );
    try std.testing.expectEqual(@as(u32, 0), responder.serviceCounts().answered);
}

test "api-w23 macos a service request with nothing in it reaches the handler empty" {
    var responder = Responder.init(std.testing.allocator, std.testing.io);
    defer responder.deinit();
    const Sink = struct {
        const Self = @This();
        send_type: []const u8 = "",
        text: []const u8 = "",

        fn answer(context: ?*anyopaque, request: ServiceRequest, out: []u8) ?usize {
            _ = out;
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.send_type = request.send_type;
            self.text = request.text;
            return null;
        }
    };
    var sink: Sink = .{};
    responder.setServiceRoute(.{ .context = &sink, .perform = Sink.answer });
    // A service with no send type, sent over a pasteboard that holds no
    // string, reaches the shim as NULL for both. That is a request with
    // nothing in it, and the host sees it as empty rather than as a read past
    // a null pointer.
    try std.testing.expect(Responder.onPerform(@ptrCast(&responder), null, null, null, 0) == null);
    try std.testing.expectEqual(@as(usize, 0), sink.send_type.len);
    try std.testing.expectEqual(@as(usize, 0), sink.text.len);
    // The request still reached the host: declining it afterwards is this
    // application answering, not the callback being skipped.
    try std.testing.expectEqual(@as(u32, 1), responder.serviceCounts().performed);
    try std.testing.expectEqual(@as(u32, 0), responder.serviceCounts().answered);
}

test "api-w23 macos both utf16 directions measure the same characters" {
    const text = "aé\u{1F600}zだ";
    // Every character start resolves back to the byte it came from, so the
    // two directions cannot disagree about where a character is.
    var at: usize = 0;
    while (at < text.len) {
        const resolved = byteOffsetOfUtf16(text, utf16Length(text[0..at])).?;
        try std.testing.expectEqual(at, resolved);
        // The walk advances by the width the one measurement path reports for
        // the character it stands on. These bytes are a literal of real text,
        // so a byte that measures as no character at all is a failure here,
        // not a length to guess past.
        at += (measureAt(text, at) orelse return error.TestUnexpectedResult).bytes;
    }
    // The whole length resolves to the whole text, not to its last character.
    try std.testing.expectEqual(text.len, byteOffsetOfUtf16(text, utf16Length(text)).?);

    // Bytes that name no character are refused by the direction that has to
    // name a position. The other direction reports how far the text is
    // readable, which is the one fact it can answer for them.
    try std.testing.expect(byteOffsetOfUtf16("a\xc3", 2) == null);
    try std.testing.expectEqual(@as(usize, 1), utf16Length("a\xc3"));
    try std.testing.expectEqual(@as(usize, 0), utf16Length("\xed\xa0\x80"));
}

test "api-w23 macos a full insertion ring refuses the next one and counts it" {
    var responder = Responder.init(std.testing.allocator, std.testing.io);
    defer responder.deinit();
    try responder.mirror.appendSlice(std.testing.allocator, "abc");

    const one = "x";
    // Fill the ring exactly. Nothing is refused while there is room.
    for (0..insert_limit) |_| {
        Responder.onInsert(@ptrCast(&responder), one.ptr, 1, 0, 0);
    }
    try std.testing.expectEqual(@as(u16, insert_limit), responder.insertion_count);
    try std.testing.expectEqual(@as(u32, 0), responder.droppedInsertions());

    // One more is refused rather than overwriting the oldest, and the refusal
    // is counted. A ring that dropped it in silence would report zero here,
    // and the host would never learn that a character was eaten.
    Responder.onInsert(@ptrCast(&responder), one.ptr, 1, 0, 0);
    try std.testing.expectEqual(@as(u16, insert_limit), responder.insertion_count);
    try std.testing.expectEqual(@as(u32, 1), responder.droppedInsertions());

    // Draining makes room again. The refusal still stands: it counted an
    // insertion the host will never see, not a slot it has recovered.
    var out: [insert_limit]Insertion = undefined;
    try std.testing.expectEqual(insert_limit, responder.drainInsertions(&out));
    try std.testing.expectEqual(@as(u32, 1), responder.droppedInsertions());
    Responder.onInsert(@ptrCast(&responder), one.ptr, 1, 0, 0);
    try std.testing.expectEqual(@as(u16, 1), responder.insertion_count);
    try std.testing.expectEqual(@as(u32, 1), responder.droppedInsertions());
}

test "api-w23 macos an insertion no slot can hold is refused and counted" {
    var responder = Responder.init(std.testing.allocator, std.testing.io);
    defer responder.deinit();
    try responder.mirror.appendSlice(std.testing.allocator, "abc");

    // A slot holds `insert_text_limit` bytes. Longer text is refused whole,
    // because truncating it would hand the host an insertion replacing a range
    // the palette never named.
    const too_long = &@as([insert_text_limit + 1]u8, @splat('y'));
    Responder.onInsert(@ptrCast(&responder), too_long.ptr, too_long.len, 0, 0);
    try std.testing.expectEqual(@as(u16, 0), responder.insertion_count);
    try std.testing.expectEqual(@as(u32, 1), responder.droppedInsertions());
    var out: [insert_limit]Insertion = undefined;
    try std.testing.expectEqual(@as(usize, 0), responder.drainInsertions(&out));

    // A platform that named no bytes is the same kind of loss, counted beside
    // it rather than passed off as nothing having arrived.
    Responder.onInsert(@ptrCast(&responder), null, 1, 0, 0);
    try std.testing.expectEqual(@as(u16, 0), responder.insertion_count);
    try std.testing.expectEqual(@as(u32, 2), responder.droppedInsertions());
}
