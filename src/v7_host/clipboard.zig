//! SDL3 host platform clipboard service with callback offer ownership and primary selection.
const std = @import("std");
const sdl3 = @import("sdl3");
const c = sdl3.c;
/// Only the tests in this file need it: they drive SDL's own clipboard, which
/// needs a live video driver.
const sdl_session = @import("sdl_session.zig");

const nogui = @import("nogui");
pub const core = nogui.clipboard;

pub const Format = core.Format;
pub const Selection = core.Selection;
pub const Capability = core.Capability;
pub const Entry = core.Entry;
pub const Error = core.Error;
pub const Item = core.Item;
pub const Offer = core.Offer;
const hostHasText = hasText;
const hostReadItem = readItem;

/// Query whether the platform host natively supports primary selection.
/// X11 and Wayland video drivers support this; dummy, macOS, and Windows do not.
pub fn supportsPrimarySelection() bool {
    const driver = sdl3.video.getCurrentDriverName() orelse return false;
    return std.mem.eql(u8, driver, "x11") or std.mem.eql(u8, driver, "wayland");
}

/// Explicit capability reporting.
pub fn hasPrimaryCapability() bool {
    return supportsPrimarySelection();
}

/// Query whether the primary selection has non-empty text.
pub fn hasPrimaryText() bool {
    if (!supportsPrimarySelection()) return false;
    return c.SDL_HasPrimarySelectionText();
}

/// Read text from the primary selection, freeing SDL's allocated buffer.
/// Returns error.UnsupportedCapability if the platform does not support primary selection.
pub fn getPrimaryText(allocator: std.mem.Allocator) !?[]u8 {
    if (!supportsPrimarySelection()) return error.UnsupportedCapability;
    if (!c.SDL_HasPrimarySelectionText()) return null;

    const raw = c.SDL_GetPrimarySelectionText();
    if (raw == null) return null;
    // SDL returns a C pointer, so the cast names the address SDL_free takes.
    defer c.SDL_free(@ptrCast(raw));

    const span = std.mem.span(raw);
    const owned = try allocator.dupe(u8, span);
    return owned;
}

/// Store UTF-8 text in the primary selection.
/// Returns error.UnsupportedCapability if the platform does not support primary selection.
pub fn setPrimaryText(allocator: std.mem.Allocator, text: []const u8) !void {
    if (!supportsPrimarySelection()) return error.UnsupportedCapability;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidText;

    const null_terminated = try allocator.dupeSentinel(u8, text, 0);
    defer allocator.free(null_terminated);

    if (!c.SDL_SetPrimarySelectionText(null_terminated.ptr)) {
        return error.SdlPrimaryFailed;
    }
}

/// Clear the primary selection text.
pub fn clearPrimary() !void {
    if (!supportsPrimarySelection()) return error.UnsupportedCapability;
    if (!c.SDL_SetPrimarySelectionText("")) {
        return error.SdlPrimaryFailed;
    }
}

/// Every MIME spelling the core recognizes for a format, the format's own MIME
/// first. A listing that names an alias is that format, so the host asks SDL
/// for each spelling before it concludes the clipboard will not hand the
/// format over.
const mime_aliases = [_][]const [:0]const u8{
    &[_][:0]const u8{
        "text/plain;charset=utf-8",
        "text/plain",
        "UTF8_STRING",
        "text/plain;charset=UTF-8",
        "text/plain; charset=utf-8",
        "text/plain; charset=UTF-8",
    },
    &[_][:0]const u8{"image/png"},
    &[_][:0]const u8{"application/json"},
};

comptime {
    if (mime_aliases.len != Format.count) @compileError("one alias list per clipboard Format");
    for (mime_aliases, 0..) |aliases, i| {
        const fmt: Format = @fromBackingInt(@intCast(i));
        if (aliases.len == 0 or !std.mem.eql(u8, aliases[0], fmt.mime())) {
            @compileError("a Format's own MIME must lead its alias list");
        }
    }
}

/// Query whether clipboard data exists for a format. Every spelling the core
/// recognizes counts, so `has` accepts the same spellings `read` accepts. It
/// stays true for a format the clipboard advertises and will not serve, so it
/// reports what is offered, not what can be read.
pub fn hasData(format: Format) bool {
    for (mime_aliases[@backingInt(format)]) |alias| {
        if (c.SDL_HasClipboardData(alias.ptr)) return true;
    }
    return false;
}

/// Query whether clipboard contains non-empty text.
///
/// This is SDL's own text query, so it asks for the spellings that video driver
/// names for text, which on several of them is `text/plain;charset=utf-8` alone.
/// An owner advertising only another spelling the core recognizes holds text
/// this reports as none. `hasData` sweeps every recognized spelling, and that
/// sweep is what `readText` reads through.
pub fn hasText() bool {
    return c.SDL_HasClipboardText();
}

/// Read one format's bytes, trying the spelling the clipboard listed first and
/// then every other spelling the core recognizes for it. SDL hands bytes over
/// per spelling and serves only what the owner advertised, so an owner that
/// lists one text spelling and serves another is still readable. Returns null
/// only when SDL serves no spelling of the format at all.
fn readFormatBytes(
    allocator: std.mem.Allocator,
    format: Format,
    listed: [*c]const u8,
) !?[]u8 {
    for (mime_aliases[@backingInt(format)], 0..) |alias, i| {
        // A listing that repeats a spelling is not asked for it twice.
        if (i != 0 and std.ascii.eqlIgnoreCase(alias, std.mem.span(listed))) continue;
        const mime: [*c]const u8 = if (i == 0) listed else alias.ptr;
        var size: usize = 0;
        const raw = c.SDL_GetClipboardData(mime, &size);
        if (raw == null) continue;
        defer c.SDL_free(raw);
        const slice: [*]const u8 = @ptrCast(raw);
        const bytes = try allocator.dupe(u8, slice[0..size]);
        return bytes;
    }
    return null;
}

/// Read clipboard data for one format, freeing SDL's temporary buffer
/// immediately.
///
/// The answer separates an absent clipboard from one this build cannot read,
/// exactly as `readText` does:
/// - null when the clipboard offers no spelling this core recognizes for the
///   format. That is the only answer that means "the clipboard holds nothing
///   here".
/// - `error.UnreadableClipboardFormat` when the clipboard advertises a
///   spelling of the format and serves none of them. The clipboard holds the
///   format and this build cannot take it, which is a failure to read and
///   never an absent clipboard.
/// - the served bytes otherwise. An offer that really is empty comes back as
///   an empty slice, which is a different answer again from null.
pub fn readData(allocator: std.mem.Allocator, format: Format) !?[]u8 {
    // The sweep below cannot tell "the clipboard advertises no spelling of
    // this format" from "it advertises one and refuses every spelling", so the
    // offered test runs first and the refusal becomes the answer.
    if (!hasData(format)) return null;
    return (try readFormatBytes(allocator, format, format.mime().ptr)) orelse
        error.UnreadableClipboardFormat;
}

/// Read UTF-8 text from the clipboard, freeing SDL's buffer immediately.
///
/// SDL's own text read asks for `text/plain;charset=utf-8` and nothing else,
/// so an owner that advertises another spelling this core recognizes reads as
/// no text at all, even though the bytes are right there. Text therefore takes
/// the path every other supported format takes: the alias sweep decides whether
/// any spelling is offered, and the same per-format read answers which spelling
/// is served.
/// - null when the clipboard offers no spelling this core recognizes. That is
///   the only answer that means "this clipboard holds no text for this build".
/// - the served bytes otherwise. An offer that really is empty comes back as an
///   empty slice, which is a different answer from null.
/// - `error.UnreadableClipboardFormat` when a spelling is offered and none of
///   them is served. The clipboard holds text this build cannot read, which is a
///   failure to read and never an empty or absent clipboard.
pub fn readText(allocator: std.mem.Allocator) !?[]u8 {
    // Text is one of the core's formats, so the per-format read already
    // answers exactly this contract. Sweeping the spellings a second time here
    // would only ask SDL the same question twice and let the two answers drift.
    return readData(allocator, .text_utf8);
}

/// Read the whole clipboard into one owned Item.
///
/// Returns null only for a clipboard that holds nothing. Every other outcome is
/// an error, because an Item carries only the formats the core models and a
/// shorter answer reads as "this is everything the clipboard held":
/// - `error.UnreadableClipboardFormat` when a listed format this build models
///   is served under no spelling SDL knows, so an item would lose it.
/// - `error.UnrecognizedClipboardContent` when the listing names any MIME type
///   this build cannot carry, including when it names none at all. A restore
///   built from the modeled subset alone destroys the flavors it never took.
///
/// Readable bytes stay readable through `readData` and `readText`, which answer
/// per format and are not whole-clipboard snapshots.
pub fn readItem(allocator: std.mem.Allocator) !?Item {
    var count: usize = 0;
    const mimes = c.SDL_GetClipboardMimeTypes(&count);
    // SDL hands back ONE heap block that holds the MIME pointer array and
    // every MIME string copied into it, and that block's head is the pointer
    // this call returns. It is the only address SDL_free accepts; the address
    // of a local that merely holds the pointer is not. SDL returns that head
    // even for an empty listing, so the release is not tied to the count.
    const head: ?*anyopaque = @ptrCast(mimes);
    defer {
        if (head) |p| c.SDL_free(p);
    }

    // SDL lists no format for a clipboard it holds no data on, so an empty
    // listing is the one case plain text can still answer.
    if (mimes == null or count == 0) return readTextItem(allocator);

    var entries: [Format.count]Entry = undefined;
    var entry_count: usize = 0;
    var staged: [Format.count]?[]u8 = @splat(null);
    defer for (staged) |bytes| if (bytes) |owned| allocator.free(owned);

    // A format is marked read only after its spellings have been tried,
    // because a listing can name one spelling the owner refuses and another
    // it serves. Marking a format on sight drops a format that is readable.
    var attempted: [Format.count]bool = @splat(false);
    var unreadable: ?Format = null;
    // Listed MIME types this build cannot carry in an Item.
    var unmodeled: usize = 0;

    for (0..count) |i| {
        const mime_ptr = mimes[i] orelse {
            // A listed entry with no name cannot be shown to be modeled.
            unmodeled += 1;
            continue;
        };
        const mime_str = std.mem.span(mime_ptr);
        const fmt = Format.fromMime(mime_str) orelse {
            // A flavor no Item can hold would be dropped by a restore built
            // from that item, so the listing is reported instead of shortened.
            unmodeled += 1;
            continue;
        };
        const idx = @backingInt(fmt);
        if (attempted[idx]) continue;

        const bytes = try readFormatBytes(allocator, fmt, mime_ptr);
        attempted[idx] = true;

        const owned = bytes orelse {
            if (unreadable == null) unreadable = fmt;
            continue;
        };

        staged[idx] = owned;
        entries[entry_count] = .{ .format = fmt, .bytes = owned };
        entry_count += 1;
    }

    // One item holds only the formats the core models. A listed format this
    // build cannot read, and any listed flavor it cannot model at all, both
    // mean a whole-item restore would put back less than the clipboard held,
    // so both refuse. The second test also covers a listing this build
    // recognizes nothing in, which is not an empty clipboard either.
    if (unreadable != null) return error.UnreadableClipboardFormat;
    if (unmodeled != 0 or entry_count == 0) return error.UnrecognizedClipboardContent;

    const item = try Item.init(allocator, entries[0..entry_count]);
    return item;
}

/// Build an item from plain clipboard text for a clipboard SDL lists no format
/// for. A listing that names formats this build does not support is not this
/// path: that clipboard holds data and reports so.
///
/// The text read answers the one case that is empty, so a text offer this build
/// cannot read passes its refusal through instead of becoming an empty item.
fn readTextItem(allocator: std.mem.Allocator) !?Item {
    const txt = (try readText(allocator)) orelse return null;
    defer allocator.free(txt);
    const item = try Item.fromText(allocator, txt);
    return item;
}

/// Host clipboard service managing active offers and SDL3 integration.
pub const Clipboard = struct {
    allocator: std.mem.Allocator,
    /// The offer this service owns and must release. SDL may hold it as its
    /// clipboard user data, but never the handle: the cleanup callback only
    /// ends the offer, so no SDL callback can outlive the handle's owner.
    current_offer: ?*Offer = null,

    /// Initialize a host clipboard service.
    pub fn init(allocator: std.mem.Allocator) Clipboard {
        return .{
            .allocator = allocator,
        };
    }

    /// Release the offer SDL still holds, then the service.
    ///
    /// Clearing drops SDL's reference from inside the call: SDL runs the
    /// offer's cleanup callback before `SDL_ClearClipboardData` returns, and
    /// only then forgets the user data. That is what makes releasing the
    /// handle afterwards safe. With no video device SDL holds no reference,
    /// because the device is what carries it.
    pub fn deinit(self: *Clipboard) void {
        const offer = self.current_offer;
        self.current_offer = null;
        if (offer) |held| {
            if (sdl3.video.getCurrentDriverName() != null) {
                _ = c.SDL_ClearClipboardData();
            }
            held.deinit();
        }
        self.* = undefined;
    }

    /// Offer an Item to the system clipboard.
    /// Clones the item so caller mutation or deinitialization cannot affect the offer.
    pub fn set(self: *Clipboard, item: *const Item) !void {
        const offer = try Offer.initClone(self.allocator, item);
        try self.installOffer(offer);
    }

    /// Offer an Item taking ownership, including on a failed SDL call.
    pub fn setOwned(self: *Clipboard, item: Item) !void {
        var owned = item;
        const offer = Offer.init(self.allocator, owned) catch |err| {
            owned.deinit();
            return err;
        };
        try self.installOffer(offer);
    }

    /// Offer pure UTF-8 text to the clipboard.
    pub fn setText(self: *Clipboard, str: []const u8) !void {
        const item = try Item.fromText(self.allocator, str);
        try self.setOwned(item);
    }

    fn installOffer(self: *Clipboard, offer: *Offer) !void {
        if (sdl3.video.getCurrentDriverName() == null) {
            // SDL video is down, so the call cannot store the offer and this
            // service keeps the only reference to the handle.
            offer.deinit();
            return error.SdlClipboardFailed;
        }

        // SDL cancels the offer it held before it stores this one, and that
        // cancel runs the old offer's cleanup callback, so the old handle is
        // safe to release only once this call has returned.
        const previous = self.current_offer;
        const ret = c.SDL_SetClipboardData(
            Offer.dataCallback,
            Offer.cleanupCallback,
            offer,
            @ptrCast(offer.mime_storage.ptr),
            offer.mime_storage.len,
        );

        if (previous) |ended| {
            if (ended.active.load(.acquire)) {
                // SDL kept the old offer as its clipboard user data, so this
                // offer was never stored. The old handle stays owned here
                // until the next clear ends it, and this one is released now.
                self.current_offer = ended;
                offer.deinit();
                return error.SdlClipboardFailed;
            }
            ended.deinit();
        }

        self.current_offer = offer;
        if (!ret) {
            // A failed set either ended this offer in its own cleanup callback
            // or left it as SDL's clipboard user data. Both leave the handle
            // owned here, and a clear or `deinit` drops SDL's reference before
            // releasing it, so no SDL callback can reach a released offer.
            return error.SdlClipboardFailed;
        }
    }

    /// Clear the clipboard, releasing the offer SDL held.
    pub fn clear(self: *Clipboard) !void {
        if (!c.SDL_ClearClipboardData()) return error.SdlClearFailed;
        // That clear cancelled SDL's clipboard data, so SDL ran the offer's
        // cleanup callback and will not call into it again: the handle is
        // free to release.
        if (self.current_offer) |ended| {
            self.current_offer = null;
            ended.deinit();
        }
    }

    /// Query whether clipboard data exists for a format.
    pub fn has(self: *const Clipboard, format: Format) bool {
        _ = self;
        return hasData(format);
    }

    /// Query whether clipboard text exists.
    pub fn hasText(self: *const Clipboard) bool {
        _ = self;
        return hostHasText();
    }

    /// Read data for a format from the clipboard. Null is a clipboard that
    /// offers no spelling of the format; a format the clipboard offers and
    /// will not serve is `error.UnreadableClipboardFormat`.
    pub fn read(self: *Clipboard, allocator: std.mem.Allocator, format: Format) !?[]u8 {
        _ = self;
        return readData(allocator, format);
    }

    /// Read the whole clipboard into one owned Item. A clipboard this build
    /// cannot hold whole is an error, never null, as `readItem` reports.
    pub fn readItem(self: *Clipboard, allocator: std.mem.Allocator) !?Item {
        _ = self;
        return hostReadItem(allocator);
    }

    /// Query whether primary selection is supported by the native platform.
    pub fn supportsPrimary(self: *const Clipboard) bool {
        _ = self;
        return supportsPrimarySelection();
    }

    /// Set primary selection text. Returns error.UnsupportedCapability if unsupported.
    pub fn setPrimary(self: *Clipboard, str: []const u8) !void {
        return setPrimaryText(self.allocator, str);
    }

    /// Read primary selection text. Returns error.UnsupportedCapability if unsupported.
    pub fn getPrimary(self: *Clipboard, allocator: std.mem.Allocator) !?[]u8 {
        _ = self;
        return getPrimaryText(allocator);
    }

    /// Clear primary selection text. Returns error.UnsupportedCapability if unsupported.
    pub fn clearPrimarySelection(self: *Clipboard) !void {
        _ = self;
        return clearPrimary();
    }
};

test "host clipboard capability check conforms to driver" {
    // Under uninitialized or dummy SDL, primary selection reports honestly
    const primary_supported = supportsPrimarySelection();
    if (sdl3.video.getCurrentDriverName()) |driver| {
        const expected = std.mem.eql(u8, driver, "x11") or std.mem.eql(u8, driver, "wayland");
        try std.testing.expectEqual(expected, primary_supported);
    } else {
        try std.testing.expect(!primary_supported);
    }
    try std.testing.expectEqual(primary_supported, hasPrimaryCapability());
}

test "host primary selection returns UnsupportedCapability when disabled" {
    if (!supportsPrimarySelection()) {
        try std.testing.expectError(error.UnsupportedCapability, getPrimaryText(std.testing.allocator));
        try std.testing.expectError(error.UnsupportedCapability, setPrimaryText(std.testing.allocator, "text"));
        try std.testing.expectError(error.UnsupportedCapability, clearPrimary());
        try std.testing.expect(!hasPrimaryText());
    }
}

test "host keeps the offer handle after SDL ends its service" {
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();

    const item = try Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = "mock" },
    });
    const offer = try Offer.init(std.testing.allocator, item);
    clip.current_offer = offer;

    // SDL's terminal callback only ends the service. The handle stays owned by
    // this service, which is what keeps the callback storage alive exactly as
    // long as the offer SDL references.
    Offer.cleanupCallback(offer);
    try std.testing.expect(!offer.active.load(.acquire));
    try std.testing.expect(clip.current_offer == offer);
    // An ended offer serves no bytes even while its handle is still owned.
    var size: usize = 0;
    try std.testing.expect(Offer.dataCallback(offer, "text/plain", &size) == null);
}

/// The offer tests below drive SDL's own clipboard implementation. Under a real
/// display driver that would overwrite the clipboard the user owns, so they run
/// only on the dummy driver, which keeps the offer in process memory and
/// touches nothing outside this process.
fn requireDummyClipboard() !void {
    try sdl_session.acquireForTest("dummy");
    const driver = sdl3.video.getCurrentDriverName() orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, driver, "dummy")) return error.SkipZigTest;
}

fn expectNoClipboardItem() !void {
    if (try readItem(std.testing.allocator)) |item| {
        var owned = item;
        owned.deinit();
        return error.TestUnexpectedResult;
    }
}

test "api-w18 an offered item owns its bytes after the caller buffer is gone" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();

    const caller = try std.testing.allocator.dupe(u8, "caller bytes");
    var item = try Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = caller },
    });
    defer item.deinit();

    try clip.set(&item);
    // The offer must not read the caller's buffer any more.
    std.testing.allocator.free(caller);

    const stored = (try clip.read(std.testing.allocator, .text_utf8)).?;
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualStrings("caller bytes", stored);
}

test "api-w18 a host offer reads back through SDL and frees every SDL buffer" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    var clip = Clipboard.init(std.testing.allocator);
    try clip.setText("host offer round trip");

    var listed = (try clip.readItem(std.testing.allocator)).?;
    defer listed.deinit();
    try std.testing.expectEqualStrings("host offer round trip", listed.text().?);
    try std.testing.expect(clip.hasText());
    try std.testing.expect(clip.has(.text_utf8));

    const data = (try clip.read(std.testing.allocator, .text_utf8)).?;
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("host offer round trip", data);

    const text = (try readText(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("host offer round trip", text);

    try clip.clear();
    clip.deinit();
}

test "api-w18 replacing an offer releases the previous one exactly once" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    var clip = Clipboard.init(std.testing.allocator);
    // Every set cancels the offer SDL held, so a leak or a double free of any
    // of the three offers fails this test.
    try clip.setText("first offer");
    try clip.setText("second offer");
    try clip.setText("third offer");
    try std.testing.expect(clip.current_offer != null);

    const data = (try clip.read(std.testing.allocator, .text_utf8)).?;
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("third offer", data);

    try clip.clear();
    clip.deinit();
}

test "api-w18 tearing the host clipboard down releases the offer SDL still held" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    var clip = Clipboard.init(std.testing.allocator);
    try clip.setText("offer alive at teardown");
    try std.testing.expect(clip.current_offer != null);

    // Teardown runs with the offer still installed in SDL. A handle SDL ended
    // but the host never released leaks, and one both released is a double
    // free; either fails this test.
    clip.deinit();

    // SDL ran no callback after teardown, because the clear inside it dropped
    // SDL's own reference to the offer.
    try std.testing.expect(!hasText());
    try expectNoClipboardItem();
}

test "api-w18 an empty clipboard reports nothing and frees SDL's MIME block" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    try expectNoClipboardItem();
    try std.testing.expect(!hasText());
    try std.testing.expect(!hasData(.text_utf8));
    if (try readText(std.testing.allocator)) |text| {
        std.testing.allocator.free(text);
        return error.TestUnexpectedResult;
    }
    if (try readData(std.testing.allocator, .text_utf8)) |data| {
        std.testing.allocator.free(data);
        return error.TestUnexpectedResult;
    }
}

/// A clipboard owner whose listing and whose answers disagree, which is what a
/// real selection does: the MIME types an owner claims are no promise that it
/// serves every spelling it claims. SDL serves a spelling only when the owner
/// advertised that exact spelling, so every spelling served below is in the
/// listing and every refusal is this owner's, not SDL's.
const StubOwner = struct {
    /// MIME types this owner claims, in listing order.
    listing: [][*:0]const u8,
    /// The one claimed spelling whose data is handed over; null serves none.
    served: ?[:0]const u8,
    /// The exact bytes served for `served`.
    bytes: []const u8,

    fn data(
        userdata: ?*anyopaque,
        mime_type: [*c]const u8,
        size: [*c]usize,
    ) callconv(.c) ?*const anyopaque {
        const raw = userdata orelse return null;
        const self: *StubOwner = @ptrCast(@alignCast(raw));
        const served = self.served orelse return null;
        if (!std.mem.eql(u8, std.mem.span(mime_type), served)) return null;
        size.* = self.bytes.len;
        return self.bytes.ptr;
    }

    fn cleanup(userdata: ?*anyopaque) callconv(.c) void {
        _ = userdata;
    }

    /// Claim the listing in SDL's clipboard and hold it until the next clear.
    fn install(self: *StubOwner) !void {
        const mimes = self.listing;
        if (!c.SDL_SetClipboardData(data, cleanup, self, @ptrCast(mimes.ptr), mimes.len)) {
            return error.TestUnexpectedResult;
        }
    }
};

/// Bytes carrying the PNG signature. The item validator reads the signature
/// and nothing else, so no decoder is involved: what is proven is that the
/// bytes the clipboard served come back whole.
const stub_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDRstub";

/// JSON this file owns, so the item validator has something it can parse.
const stub_json = "{\"probe\":\"host clipboard\"}";

test "host a listed format SDL will not serve is an error, not an empty clipboard" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    // The listing carries one readable format and one this owner refuses, so
    // the clipboard holds data this build cannot read whole.
    var listing = [_][*:0]const u8{ "text/plain", "image/png" };
    var owner: StubOwner = .{
        .listing = listing[0..],
        .served = "text/plain",
        .bytes = "readable text",
    };
    try owner.install();
    defer _ = c.SDL_ClearClipboardData();

    // The text the clipboard does serve reads back, so this is a clipboard
    // with content and not an absent one.
    const text = (try readData(std.testing.allocator, .text_utf8)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("readable text", text);
    try std.testing.expect(hasData(.image_png));

    // An item carrying the text but not the image is a snapshot of less than
    // the whole clipboard, so the read refuses instead of shortening it.
    try std.testing.expectError(error.UnreadableClipboardFormat, readItem(std.testing.allocator));

    // The refusal consumed nothing, so what the owner holds is still there.
    try std.testing.expect(hasData(.image_png));
}

test "host reads the text spelling an owner serves when the listing names another" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    // The listing leads with the charset spelling, which this owner refuses,
    // and serves the plain one. SDL's own text read asks only for the charset
    // spelling, so a host that read nothing but the spelling the listing named
    // first would answer with no text at all.
    var listing = [_][*:0]const u8{ "text/plain;charset=utf-8", "text/plain" };
    var owner: StubOwner = .{
        .listing = listing[0..],
        .served = "text/plain",
        .bytes = "alias text",
    };
    try owner.install();
    defer _ = c.SDL_ClearClipboardData();

    var listed = (try readItem(std.testing.allocator)).?;
    defer listed.deinit();
    try std.testing.expectEqualStrings("alias text", listed.text().?);

    // The same bytes through the per-format read, so both paths agree.
    const data = (try readData(std.testing.allocator, .text_utf8)).?;
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("alias text", data);
}

test "host text reads the spelling an owner serves when SDL asks only for its own" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    // The listing names the charset spelling, which this owner refuses, and
    // serves the plain one. SDL's own text read asks only for the charset
    // spelling, so it reports this clipboard as holding no text at all.
    var listing = [_][*:0]const u8{ "text/plain;charset=utf-8", "text/plain" };
    var owner: StubOwner = .{
        .listing = listing[0..],
        .served = "text/plain",
        .bytes = "alias text",
    };
    try owner.install();
    defer _ = c.SDL_ClearClipboardData();

    // What this pinned SDL answers on its own, so the read below is not taken
    // on faith: SDL hands back a buffer that says nothing is there.
    const sdl_text = c.SDL_GetClipboardText();
    if (sdl_text == null) return error.TestUnexpectedResult;
    defer c.SDL_free(@ptrCast(sdl_text));
    try std.testing.expectEqualStrings("", std.mem.span(sdl_text));

    // The host read sweeps every spelling the core recognizes, so the bytes the
    // owner does serve are the ones a paste receives.
    const text = (try readText(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("alias text", text);

    // The per-format read answers the same bytes, so the two never disagree.
    const data = (try readData(std.testing.allocator, .text_utf8)).?;
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("alias text", data);
}

test "host text reads a clipboard whose only offer is the plain spelling" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    // An owner offering nothing but the plain spelling. This is what a real
    // selection looks like when it never mentions the charset spelling SDL's
    // own text read insists on.
    var listing = [_][*:0]const u8{"text/plain"};
    var owner: StubOwner = .{
        .listing = listing[0..],
        .served = "text/plain",
        .bytes = "plain only",
    };
    try owner.install();
    defer _ = c.SDL_ClearClipboardData();

    // The offer is recognized even though it is not the spelling SDL asks for.
    try std.testing.expect(hasData(.text_utf8));

    const text = (try readText(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("plain only", text);

    const data = (try readData(std.testing.allocator, .text_utf8)).?;
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("plain only", data);

    // The whole-item read answers the same text for the same clipboard.
    var listed = (try readItem(std.testing.allocator)).?;
    defer listed.deinit();
    try std.testing.expectEqualStrings("plain only", listed.text().?);
}

test "host text keeps an empty offer apart from an absent one" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    // This SDL copies whatever the owner's callback returns and only fails the
    // copy, so an owner handing back a valid pointer with no bytes produces a
    // zero-length buffer rather than a null one. That is a clipboard offering
    // empty text, which is a different clipboard from one offering no text.
    var listing = [_][*:0]const u8{"text/plain"};
    var owner: StubOwner = .{
        .listing = listing[0..],
        .served = "text/plain",
        .bytes = "",
    };
    try owner.install();
    defer _ = c.SDL_ClearClipboardData();

    try std.testing.expect(hasData(.text_utf8));

    // The read succeeds and yields no bytes, which is what keeps a paste from
    // being told the clipboard was empty.
    const text = (try readText(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 0), text.len);

    const data = (try readData(std.testing.allocator, .text_utf8)).?;
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(usize, 0), data.len);

    var listed = (try readItem(std.testing.allocator)).?;
    defer listed.deinit();
    try std.testing.expectEqualStrings("", listed.text().?);
}

test "host a text offer the clipboard will not serve is a typed failure" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    // The listing claims text and this owner serves none of it. The clipboard
    // holds something and this build cannot read it, so answering with no text
    // would report a clipboard that holds nothing.
    var listing = [_][*:0]const u8{ "text/plain;charset=utf-8", "text/plain" };
    var owner: StubOwner = .{
        .listing = listing[0..],
        .served = null,
        .bytes = "",
    };
    try owner.install();
    defer _ = c.SDL_ClearClipboardData();

    try std.testing.expect(hasData(.text_utf8));
    try std.testing.expectError(error.UnreadableClipboardFormat, readText(std.testing.allocator));

    // The refusal consumed nothing, so the offer the clipboard holds is intact,
    // and the whole-item read names the same refusal rather than shortening.
    try std.testing.expect(hasData(.text_utf8));
    try std.testing.expectError(error.UnreadableClipboardFormat, readItem(std.testing.allocator));
}

test "host text reports absent only for a clipboard offering no text spelling" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    // A clipboard holding only a format that is not text. Reading text here has
    // nothing to work with and says so; it is not a failure to read.
    var listing = [_][*:0]const u8{"image/png"};
    var owner: StubOwner = .{
        .listing = listing[0..],
        .served = "image/png",
        .bytes = stub_png,
    };
    try owner.install();
    defer _ = c.SDL_ClearClipboardData();

    try std.testing.expect(hasData(.image_png));
    try std.testing.expect(!hasData(.text_utf8));
    if (try readText(std.testing.allocator)) |text| {
        std.testing.allocator.free(text);
        return error.TestUnexpectedResult;
    }
}

test "host a clipboard of unsupported MIME types is an error, not an absent one" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    // Data is on the clipboard and none of it is in a format the core
    // supports. Reporting nothing there would let a restore guard clear a
    // clipboard it never captured.
    var listing = [_][*:0]const u8{"image/webp"};
    var owner: StubOwner = .{
        .listing = listing[0..],
        .served = "image/webp",
        .bytes = "RIFFstub",
    };
    try owner.install();
    defer _ = c.SDL_ClearClipboardData();

    try std.testing.expectError(error.UnrecognizedClipboardContent, readItem(std.testing.allocator));
    // Nothing the core supports is there, which is what makes this refusal a
    // statement about the clipboard contents and not about an empty clipboard.
    try std.testing.expect(!hasData(.image_png));
    try std.testing.expect(!hasData(.metadata_json));
    try std.testing.expect(!hasText());
}

test "host refuses an item from a listing that names a flavor it cannot hold" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    // A browser copy carries plain text beside markup this build cannot carry,
    // and the owner really serves the text: SDL hands these exact bytes back
    // through its own clipboard read below.
    var listing = [_][*:0]const u8{ "text/plain", "text/html" };
    var owner: StubOwner = .{
        .listing = listing[0..],
        .served = "text/plain",
        .bytes = "mixed text",
    };
    try owner.install();
    defer _ = c.SDL_ClearClipboardData();

    const text = (try readData(std.testing.allocator, .text_utf8)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("mixed text", text);
    try std.testing.expect(hasData(.text_utf8));

    // An item with the text and nothing for the markup is not the clipboard,
    // and a restore built from it would drop the markup the owner held, so the
    // whole-item read refuses instead of answering with part of the listing.
    try std.testing.expectError(error.UnrecognizedClipboardContent, readItem(std.testing.allocator));
}

test "host one item carries every recognized format its listing serves" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();

    var offered = try Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = "every format" },
        .{ .format = .image_png, .bytes = stub_png },
        .{ .format = .metadata_json, .bytes = stub_json },
    });
    defer offered.deinit();
    try clip.set(&offered);

    // The listing names the text twice, once per spelling, so a host that
    // marked a spelling read before reading it would drop a format the
    // listing plainly offers.
    var read_back = (try readItem(std.testing.allocator)).?;
    defer read_back.deinit();
    try std.testing.expectEqual(3, read_back.count());
    try std.testing.expectEqualStrings("every format", read_back.text().?);
    try std.testing.expectEqualStrings(stub_png, read_back.imagePng().?);
    try std.testing.expectEqualStrings(stub_json, read_back.metadataJson().?);

    try clip.clear();
}

test "api-w18 an unsupported primary selection never overwrites the normal clipboard" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    try clip.setText("normal clipboard stays");

    // The dummy driver has no primary selection, so every primary request is
    // refused before SDL is asked to change anything.
    try std.testing.expect(!clip.supportsPrimary());
    try std.testing.expectError(error.UnsupportedCapability, clip.setPrimary("primary text"));
    try std.testing.expectError(error.UnsupportedCapability, clip.getPrimary(std.testing.allocator));
    try std.testing.expectError(error.UnsupportedCapability, clip.clearPrimarySelection());
    try std.testing.expect(!hasPrimaryText());

    // The normal clipboard still holds the offered bytes, so a refused primary
    // request neither overwrote nor cleared it.
    const data = (try clip.read(std.testing.allocator, .text_utf8)).?;
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("normal clipboard stays", data);
}

test "api-w18 an unreadable format is not an absent clipboard" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    // A clipboard holding only a PNG. Nothing on it is text, so a text read
    // has nothing to work with and says so with null.
    var png_listing = [_][*:0]const u8{"image/png"};
    var png_owner: StubOwner = .{
        .listing = png_listing[0..],
        .served = "image/png",
        .bytes = stub_png,
    };
    try png_owner.install();
    defer _ = c.SDL_ClearClipboardData();

    try std.testing.expect(!hasData(.text_utf8));
    try std.testing.expect((try readData(std.testing.allocator, .text_utf8)) == null);
    try std.testing.expect((try readText(std.testing.allocator)) == null);

    // The same clipboard, now listing a text spelling its owner will not
    // serve. Both read paths must refuse by name: null here would report a
    // clipboard holding nothing, which is the answer the listing above earns
    // and this one does not.
    var text_listing = [_][*:0]const u8{ "text/plain", "image/png" };
    var text_owner: StubOwner = .{
        .listing = text_listing[0..],
        .served = "image/png",
        .bytes = stub_png,
    };
    try text_owner.install();

    try std.testing.expect(hasData(.text_utf8));
    try std.testing.expectError(
        error.UnreadableClipboardFormat,
        readData(std.testing.allocator, .text_utf8),
    );
    try std.testing.expectError(error.UnreadableClipboardFormat, readText(std.testing.allocator));

    // The refusal names the format it could not read and nothing else: the
    // image the same clipboard does serve still comes back whole.
    const served_png = (try readData(std.testing.allocator, .image_png)).?;
    defer std.testing.allocator.free(served_png);
    try std.testing.expectEqualStrings(stub_png, served_png);
}

test "api-w18 PRIMARY and CLIPBOARD are two services, not one alias" {
    try requireDummyClipboard();
    _ = c.SDL_ClearClipboardData();

    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    try clip.setText("clipboard offer");

    // Each domain answers from its own capability query, so one being present
    // never reports for the other.
    try std.testing.expectEqual(clip.supportsPrimary(), hasPrimaryCapability());
    try std.testing.expect(hasText());

    if (clip.supportsPrimary()) {
        // A primary selection is its own store. The offer just installed is
        // not in it, and writing it leaves the clipboard bytes alone.
        try std.testing.expect((try clip.getPrimary(std.testing.allocator)) == null);
        try clip.setPrimary("primary offer");
        try std.testing.expect(hasPrimaryText());
        try clip.clearPrimarySelection();
        try std.testing.expect(!hasPrimaryText());
    } else {
        // A refused primary request changes nothing on the clipboard, which is
        // what makes it a separate service rather than a redirect into one.
        try std.testing.expectError(error.UnsupportedCapability, clip.setPrimary("primary offer"));
        try std.testing.expectError(error.UnsupportedCapability, clip.getPrimary(std.testing.allocator));
        try std.testing.expectError(error.UnsupportedCapability, clip.clearPrimarySelection());
        try std.testing.expect(!hasPrimaryText());
    }

    // Either way the two answers never carry each other's bytes.
    const clipboard_bytes = (try clip.read(std.testing.allocator, .text_utf8)).?;
    defer std.testing.allocator.free(clipboard_bytes);
    try std.testing.expectEqualStrings("clipboard offer", clipboard_bytes);
    try std.testing.expect(hasText());
    try clip.clear();
}
