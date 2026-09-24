//! E02: native file and message dialogs on macOS.
//!
//! THE DECISION, AND ITS EVIDENCE. SDL3's macOS dialog backends are AppKit's
//! own panels, so reusing SDL here is not a fallback to something less native:
//!
//!   * `src/dialog/cocoa/SDL_cocoadialog.m` builds `NSOpenPanel` for opening
//!     files and folders and `NSSavePanel` for saving, sets the title and the
//!     accept prompt, maps filters to `allowedContentTypes` on macOS 11 and
//!     `allowedFileTypes` before that, honours a default directory, and runs
//!     the panel as a real sheet with `beginSheetModalForWindow:` whenever a
//!     parent window is given.
//!   * `src/video/cocoa/SDL_cocoamessagebox.m` builds an `NSAlert` with the
//!     requested style, the requested buttons, their key equivalents, and the
//!     same sheet attachment.
//!
//! So `install` puts the shared `dialogs.DialogManager` back on that path, and
//! `coverage` names the one thing the panel cannot express. Which of those
//! symbols a consumer actually reads is stated under WHO READS THIS below,
//! because a limit nobody can observe is not yet a limit anybody is given.
//!
//! TWO REAL LIMITS, both stated rather than papered over:
//!
//!   * A CANCEL LABEL CANNOT BE EXPRESSED. The cocoa file backend reads the
//!     title, the accept prompt, the filters, the location and the parent
//!     window, and no cancel label at all. So `FileOptions.cancel_label` has no
//!     effect on macOS, `coverage` reports it as unsupported, and the shared
//!     path now refuses the request outright instead of dropping the label.
//!   * FILTERS ARE A SUGGESTION. The same backend sets
//!     `allowsOtherFileTypes` on, so a person may choose a type the filter
//!     excludes. A host that treats a filter as a constraint has to validate
//!     the paths it gets back.
//!
//! WHO READS THIS, AND WHO DOES NOT. Stated here rather than left for the next
//! reader to discover, because a capability advertised with no reachable
//! consumer is the same as no capability at all:
//!
//!   * `isNativeBackend` and `coverage` ARE read. `macos/root.zig` calls
//!     `isNativeBackend` to fill `Capabilities.native_dialogs` and carries a
//!     `Coverage` in `Capabilities.dialog_coverage`, NULL off this target.
//!     `w23_macos_smoke.zig` calls `coverage` on a labelled and on an
//!     unlabelled request and asserts on `supported`, `unsupported`, `isFull`
//!     and `droppedOptions`, so the file-dialog limit is observed in a running
//!     process and not only by the tests at the foot of this file.
//!   * `Option.note` has NO caller outside this file. The prose that explains
//!     each limit to a host is stated here but read nowhere: `coverage` reports
//!     an option by tag, and no consumer asks what that tag means to a person.
//!   * `messageCoverage` IS observed: the same `reportDialogCoverage` reads it
//!     in the same run as the file half. Both halves are whole for their own
//!     reasons and neither can drop, so that call asserts the served count
//!     tracks the request rather than a difference that cannot exist.
//!   * `install` and `Decision` have no caller either. Nothing needs to put a
//!     fresh `DialogManager` on SDL's path, because it already falls through
//!     to SDL whenever no provider is set, so the decision that says so is
//!     read by nothing.
//!
//! WHY THE COVERAGE ANSWER IS THIS TARGET'S OWN. `coverage` is a PURE function
//! over the shared `FileOptions`: no SDL, no AppKit and no shim. So it needs
//! no macOS SDK to compile or to run, and the smoke above gets a real macOS
//! answer on Linux rather than a missing-SDK refusal. The three tests at the
//! foot of this file already build and execute here for the same reason:
//! `src/v7_host/root.zig` imports `macos/root.zig` in its own `test` block,
//! and `macos/root.zig` imports this file in its `test` block.
//!
//! WHAT THE PLATFORM NOW DOES WITH A CANCEL LABEL. macOS still cannot express
//! one, but it no longer answers as though it had: `launchSdlFile` refuses a
//! cancel label on the cocoa driver and delivers `FileOutcome.unsupported`,
//! which is the same outcome `portalFileDialog` returns for the identical
//! request. So a host reads ONE answer for this option whichever backend
//! answers it, and `coverage` still names the label because the limit is
//! real even though it is now stated by a refusal rather than by a silence.
const std = @import("std");
const sdl3 = @import("sdl3");
const dialogs = @import("../dialogs.zig");

/// What the platform does with one part of a request.
pub const Option = enum {
    title,
    accept_label,
    cancel_label,
    filters,
    default_location,
    parent_window,
    multiple_selection,
    folder_choice,
    save_target,
    message_buttons,
    message_severity,

    pub fn supported(self: Option) bool {
        return switch (self) {
            .cancel_label => false,
            else => true,
        };
    }

    /// What a host should know about the parts that are not supported, or
    /// about the ones whose macOS meaning differs from the request's.
    pub fn note(self: Option) []const u8 {
        return switch (self) {
            .cancel_label => "AppKit's panel owns its cancel button and SDL's cocoa backend never reads a " ++
                "cancel label, so this request is REFUSED as unsupported rather than shown differently.",
            .default_location => "AppKit opens the panel AT the path rather than in it: " ++
                "a path ending in '/' is the directory itself, and any other path is split, " ++
                "so the panel opens in the parent with the last component already in the name field.",
            .filters => "Filters become allowedContentTypes, and the panel allows another type anyway, so a filter " ++
                "is a suggestion a person can override. A glob-mode filter reaches AppKit as the " ++
                "`*.<extension>` list SDL takes, and one that is not that shape is refused rather than " ++
                "shown as a different filter.",
            .parent_window => "Shown as a real sheet, so the parent window is blocked by AppKit's own modal session " ++
                "rather than by a nested run loop.",
            .save_target => "A default location that names a file also seeds the name field, " ++
                "so a save starts on that name.",
            .title, .accept_label, .multiple_selection, .folder_choice, .message_buttons, .message_severity => "",
        };
    }
};

/// The options one coverage can name. `unsupported` counts every option the
/// platform dropped, so a request that overflows this table still reports how
/// many parts of it macOS cannot express.
pub const max_dropped = 8;

/// The parts of a request this platform serves, and the parts it does not.
pub const Coverage = struct {
    supported: usize = 0,
    unsupported: usize = 0,
    /// The options a request asked for that macOS cannot express. A host reads
    /// this before it asks, so a dropped label is never a surprise. The tail
    /// past `dropped_len` is never read and holds a real option, so the
    /// default is never bytes no code wrote.
    dropped: [max_dropped]Option = [_]Option{.title} ** max_dropped,
    dropped_len: usize = 0,

    pub fn isFull(self: Coverage) bool {
        return self.unsupported == 0;
    }

    /// The options this coverage named, in the order they were asked for.
    pub fn droppedOptions(self: *const Coverage) []const Option {
        return self.dropped[0..self.dropped_len];
    }

    fn name(self: *Coverage, option: Option) void {
        if (self.dropped_len == self.dropped.len) return;
        self.dropped[self.dropped_len] = option;
        self.dropped_len += 1;
    }
};

/// What the file panel can express for one request.
pub fn coverage(options: dialogs.FileOptions) Coverage {
    var result: Coverage = .{};
    const asked = [_]Option{
        .title,
        .filters,
        .default_location,
        .multiple_selection,
        .save_target,
    };
    for (asked) |option| {
        // A request only counts an option it actually asked for.
        const wanted = switch (option) {
            .title => options.title != null,
            .filters => options.filters.len != 0,
            .default_location => options.default_location != null,
            .multiple_selection => options.mode == .open_multiple_files,
            .save_target => options.mode == .save_file or options.mode == .open_folder,
            else => true,
        };
        if (!wanted) continue;
        if (option.supported()) {
            result.supported += 1;
        } else {
            result.unsupported += 1;
            result.name(option);
        }
    }
    if (options.cancel_label != null) {
        result.unsupported += 1;
        result.name(.cancel_label);
    }
    if (options.accept_label != null) result.supported += 1;
    if (options.parent_window != null) result.supported += 1;
    return result;
}

/// Whether the message box can express one request. Everything the shared
/// `MessageOptions` carries is an `NSAlert` property, so nothing is dropped.
pub fn messageCoverage(options: dialogs.MessageOptions) Coverage {
    var result: Coverage = .{};
    if (options.title.len != 0) result.supported += 1;
    if (options.message.len != 0) result.supported += 1;
    result.supported += 1; // severity maps to NSAlertStyle.
    if (options.buttons.len != 0) result.supported += 1;
    if (options.parent_window != null) result.supported += 1;
    return result;
}

/// What the shared dialog manager should use on this process.
pub const Decision = enum {
    /// The manager is on SDL's path, which on macOS is AppKit's own panels.
    native_sdl_path,
    /// The process is not on the Cocoa video driver, so SDL's panels are not
    /// the platform's and the manager is left exactly as it was.
    not_this_platform,

    pub fn ok(self: Decision) bool {
        return self == .native_sdl_path;
    }
};

/// Whether this process is on the Cocoa video driver, which is what decides
/// whether SDL's dialogs are AppKit's.
pub fn isNativeBackend() bool {
    const driver = sdl3.video.getCurrentDriverName() orelse return false;
    return std.mem.eql(u8, driver, "cocoa");
}

/// Put the shared dialog manager on the native macOS path.
///
/// This clears any provider the manager was carrying, which routes both file
/// and message dialogs through SDL — and through AppKit on macOS. A process on
/// another video driver is left untouched, because clearing a provider there
/// would change behaviour on a platform this module says nothing about.
pub fn install(manager: *dialogs.DialogManager) Decision {
    if (!isNativeBackend()) return .not_this_platform;
    manager.setProvider(null);
    return .native_sdl_path;
}

test "api-w23 macos dialog coverage names the one option macOS cannot express" {
    const full = coverage(.{});
    try std.testing.expect(full.isFull());
    try std.testing.expectEqual(@as(usize, 0), full.unsupported);

    const with_cancel = coverage(.{ .cancel_label = "Not this one" });
    try std.testing.expect(!with_cancel.isFull());
    try std.testing.expectEqual(@as(usize, 1), with_cancel.unsupported);
    try std.testing.expectEqual(Option.cancel_label, with_cancel.droppedOptions()[0]);
    try std.testing.expect(Option.cancel_label.note().len != 0);
}

test "api-w23 macos dialog coverage counts what a request actually asked for" {
    const open = coverage(.{
        .mode = .open_file,
        .title = "Open",
        .filters = &.{.{ .name = "Text", .pattern = "txt" }},
        .default_location = "/tmp",
    });
    try std.testing.expectEqual(@as(usize, 3), open.supported);
    try std.testing.expectEqual(@as(usize, 0), open.unsupported);

    const many = coverage(.{ .mode = .open_multiple_files });
    try std.testing.expectEqual(@as(usize, 1), many.supported);

    const folder = coverage(.{ .mode = .open_folder });
    try std.testing.expectEqual(@as(usize, 1), folder.supported);
}

test "api-w23 macos message dialog coverage drops nothing" {
    const covered = messageCoverage(.{
        .title = "Title",
        .message = "Message",
        .severity = .critical,
        .buttons = &.{.{ .id = 0, .text = "OK" }},
        .parent_window = 1,
    });
    try std.testing.expect(covered.isFull());
    try std.testing.expectEqual(@as(usize, 5), covered.supported);
}
