//! Process-wide SDL lifetime, reference counted by the hosts that use it.
//!
//! SDL video, events and the clipboard are global to the process, so they are
//! initialized once and torn down once. Quitting SDL while another host is
//! still running takes that host's window and event state with it, which is why
//! a bare `sdl3.quit` per `Application` is wrong. Every `Application` and every
//! test that needs SDL acquires this session instead, and the last release
//! performs the quit.
const std = @import("std");
const sdl3 = @import("sdl3");

/// Read by `active` without the gate, so it stays atomic. Every mutation
/// happens under it.
var holders: std.atomic.Value(u32) = .init(0);
/// The lifecycle of the session. Read and written only under the gate, so it
/// needs no atomicity of its own.
var state: enum { uninitialized, ready, failed } = .uninitialized;

/// Serializes initialization, shutdown and holder-count transitions. SDL's
/// device probe and final shutdown run under this gate; later sessions may
/// initialize again. A failed probe stays failed for the process lifetime.
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.flag.cmpxchgStrong(false, true, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// One per process, so a static instance is the whole requirement.
var gate: SpinLock = .{};

pub const Error = error{
    /// SDL refused to initialize. A later call reports this without retrying,
    /// because a second attempt would probe the same devices again.
    SdlInitFailed,
};

pub const Options = struct {
    video_driver: ?[:0]const u8 = null,
    render_driver: ?[:0]const u8 = null,
};

/// Initializes SDL for the first holder. A later holder joins without touching
/// the driver, so `video_driver` and `render_driver` are only honored on the
/// first call and must be chosen before it. A refusal takes no holder and is
/// reported to every later call without touching SDL again.
pub fn acquire(options: Options) Error!void {
    gate.lock();
    defer gate.unlock();

    switch (state) {
        // A refused initialization is final. The devices it failed on would
        // only be probed a second time, so a later caller is told the outcome
        // instead of being handed the session it was already refused.
        .failed => return Error.SdlInitFailed,
        // SDL is up, so this holder only counts up. The driver hints are
        // ignored here, which is what makes them first-call-only.
        .ready => {
            _ = holders.fetchAdd(1, .monotonic);
            return;
        },
        .uninitialized => {},
    }

    if (options.video_driver) |driver| {
        sdl3.hints.setWithPriority(.video_driver, driver, .override) catch
            return initFailed();
    }
    if (options.render_driver) |driver| {
        sdl3.hints.setWithPriority(.render_driver, driver, .override) catch
            return initFailed();
    }
    sdl3.init(.{ .video = true, .events = true }) catch
        return initFailed();

    // The count rises only once SDL is really up, so a holder exists for
    // exactly the callers that were given a session to give back.
    state = .ready;
    holders.store(1, .monotonic);
}

/// Records a refusal without taking a holder: a caller that was refused never
/// received a session, so it has nothing to hand back with `release`.
fn initFailed() Error {
    state = .failed;
    return Error.SdlInitFailed;
}

/// Releases one holder. SDL is quit only when the last one leaves, so a second
/// host keeps its windows and event queue alive.
pub fn release() void {
    gate.lock();
    defer gate.unlock();

    switch (holders.fetchSub(1, .acq_rel)) {
        0 => {
            holders.store(1, .release);
            @panic("sdl_session released more often than acquired");
        },
        1 => {},
        else => return,
    }
    if (state != .ready) return;
    sdl3.quit(.{ .video = true, .events = true });
    state = .uninitialized;
}

var test_held = false;

/// Initializes SDL once for a whole test binary and never quits it. Process
/// exit reclaims the driver, whereas a per-test quit would tear down and
/// re-probe the same devices for every test and can hang while an event
/// thread is still running. A holder stays registered, so an `Application`
/// created and released inside the tests never quits SDL.
pub fn acquireForTest(driver: [:0]const u8) Error!void {
    if (test_held) return;
    test_held = true;
    acquire(.{ .video_driver = driver }) catch |err| {
        test_held = false;
        return err;
    };
}

/// True while at least one holder keeps SDL alive.
pub fn active() bool {
    return holders.load(.monotonic) != 0;
}
