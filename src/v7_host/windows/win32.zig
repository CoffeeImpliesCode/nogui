//! The bound Windows SDK surface the E03 adapters share.
//!
//! Every declaration here is taken from the Windows SDK headers, not from a
//! re-derivation: `shellapi.h`, `wincred.h`, `ole32.h`, `objbase.h`,
//! `shobjidl.h` and `user32.h`. The GUIDs are written as their documented text
//! and parsed with `std.os.windows.GUID.parse`, so a mistyped interface is a
//! runtime `CLASS_E_CLASSNOTAVAILABLE` instead of a silent success against the
//! wrong object.
//!
//! Target gating. `is_windows` is comptime-known, and every call into this
//! module is behind `if (comptime !is_windows) return ...`. A Linux, macOS or
//! mobile build therefore never emits a reference to `shell32`, `advapi32` or
//! `ole32`, and a Windows adapter built there reports `unavailable` instead of
//! pretending. This is the same rule the Linux adapters follow in reverse: an
//! inapplicable target says so by name and never emulates the other one.
//!
//! Wide strings. Windows takes `W` entry points only, so every name crossing
//! this seam is UTF-16LE. Conversion lives here rather than in each adapter so
//! there is one definition of what a lossy conversion means: invalid UTF-8 is
//! an error, never a replacement character, because a mangled AUMID or target
//! name is a different credential and a different app group.
const std = @import("std");
const builtin = @import("builtin");

pub const windows = std.os.windows;

pub const is_windows = builtin.os.tag == .windows;

pub const Hwnd = windows.HWND;
pub const Hmenu = windows.HMENU;
pub const Hinstance = windows.HINSTANCE;
pub const Dword = windows.DWORD;
pub const Word = windows.WORD;
pub const Bool = windows.BOOL;
pub const Long = windows.LONG;
pub const Ulong = windows.ULONG;
pub const Guid = windows.GUID;
pub const Win32Error = windows.Win32Error;
pub const FileTime = windows.FILETIME;

/// `HRESULT`. `std.os.windows` does not export one, so it is declared here with
/// the ABI the SDK's `winerror.h` defines: a signed 32-bit result whose
/// failure bit is the sign bit.
pub const Hresult = i32;

pub const s_ok: Hresult = 0;
pub const s_false: Hresult = 1;
pub const e_notimpl: Hresult = @bitCast(@as(u32, 0x8000_4001));
pub const e_nointerface: Hresult = @bitCast(@as(u32, 0x8000_4002));
pub const e_pointer: Hresult = @bitCast(@as(u32, 0x8000_4003));
pub const e_abort: Hresult = @bitCast(@as(u32, 0x8000_4004));
pub const e_fail: Hresult = @bitCast(@as(u32, 0x8000_4005));
pub const e_unexpected: Hresult = @bitCast(@as(u32, 0x8000_FFFF));
pub const e_accessdenied: Hresult = @bitCast(@as(u32, 0x8007_0005));
pub const e_invalidarg: Hresult = @bitCast(@as(u32, 0x8007_0057));
pub const e_outofmemory: Hresult = @bitCast(@as(u32, 0x8007_000E));
pub const class_e_classnotavailable: Hresult = @bitCast(@as(u32, 0x8004_0111));
pub const class_e_noaggregation: Hresult = @bitCast(@as(u32, 0x8004_0110));
pub const co_e_classstring: Hresult = @bitCast(@as(u32, 0x8004_01F0));
pub const ro_e_closed: Hresult = @bitCast(@as(u32, 0x8000_13FF));
/// `WPARAM`. `std.os.windows` declares `LPARAM` but not its unsigned twin, and
/// `winuser.h` sizes both as a pointer on every architecture nogui targets.
pub const Wparam = usize;

/// `LRESULT`. The same story as `Wparam` one type along: `std.os.windows`
/// declares `LPARAM` and no `LRESULT`, and `winuser.h` sizes both as a pointer
/// on every architecture nogui targets.
///
/// `std.os.windows` does spell that size out, as `LONG_PTR`, and defines it as
/// exactly this type, so the binding is that definition rather than a second
/// opinion about what a pointer-sized signed result is.
pub const Lresult = isize;

/// `WNDPROC` from `winuser.h`: the shape of a window procedure. It is a plain
/// function pointer rather than an interface, so a subclass can hold the one
/// it replaced and forward to it, which is the whole contract a subclass has
/// with the window it is attached to.
pub const Wndproc = *const fn (
    hwnd: Hwnd,
    message: u32,
    wparam: Wparam,
    lparam: windows.LPARAM,
) callconv(.winapi) Lresult;

/// `S_OK` is success and `S_FALSE` is a successful negative answer. Both are
/// success; only the sign bit separates them.
pub fn succeeded(hr: Hresult) bool {
    return hr >= 0;
}

pub fn failed(hr: Hresult) bool {
    return hr < 0;
}

/// True for the one HRESULT that means "this interface exists but says no".
/// `E_ABORT` is the SDK's own "refuse the call" answer, and a caller that
/// treats it as a plain failure loses the difference between a policy refusal
/// and a broken build.
pub fn isRefused(hr: Hresult) bool {
    return hr == e_abort;
}

pub fn guid(comptime text: []const u8) Guid {
    return Guid.parse(text);
}

/// The thread's last Win32 error. Callers read it immediately after the call
/// that can fail, because any other Win32 call may overwrite it.
pub fn lastError() Win32Error {
    return windows.GetLastError();
}

/// UTF-8 to a NUL-terminated UTF-16LE string. The sentinel is part of the
/// allocation and the slice length excludes it, so `.ptr` is the pointer a
/// `PCWSTR` parameter wants.
pub fn wide(allocator: std.mem.Allocator, utf8: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, utf8);
}

/// UTF-16LE to owned UTF-8. Unpaired surrogates are an error: a name the SDK
/// could not spell is not a name this adapter may substitute.
pub fn narrow(allocator: std.mem.Allocator, utf16le: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(allocator, utf16le);
}

/// Wipe before free. `std.crypto.secureZero` is a volatile write loop, so the
/// optimizer may not delete it; this wrapper only exists so every wipe in this
/// directory reads the same and so the free cannot be reordered past it.
pub fn wipeAndFree(allocator: std.mem.Allocator, bytes: []u8) void {
    if (bytes.len != 0) std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

/// Wipe in place, keeping the allocation. Used for the caller's own buffers.
pub fn wipe(bytes: []u8) void {
    if (bytes.len != 0) std.crypto.secureZero(u8, bytes);
}

/// `GetLastError` returns a raw `DWORD`. `std.os.windows.Win32Error` is an
/// enum with duplicate values and gaps, so `@enumFromInt` on an arbitrary
/// error code is not legal; the adapters here read the raw value and match
/// the codes they name. These are the SDK's own numbers.
pub extern "kernel32" fn GetLastError() callconv(.winapi) Dword;

pub const error_success: Dword = 0;
pub const error_invalid_function: Dword = 1;
pub const error_access_denied: Dword = 5;
pub const error_not_enough_memory: Dword = 8;
pub const error_not_supported: Dword = 50;
pub const error_invalid_parameter: Dword = 87;
pub const error_invalid_name: Dword = 123;
pub const error_invalid_flags: Dword = 1004;
pub const error_not_found: Dword = 1168;
pub const error_cancelled: Dword = 1223;
pub const error_no_such_logon_session: Dword = 1312;
pub const error_logon_failure: Dword = 1326;
pub const error_password_expired: Dword = 1330;
pub const error_account_disabled: Dword = 1331;
pub const error_invalid_credential: Dword = 1338;
pub const error_timeout: Dword = 1460;
pub const error_bad_username: Dword = 2202;

/// `ERROR_FILE_NOT_FOUND`. The registry reports absence with the same number
/// the filesystem does, so "this key is not there" is one value rather than
/// one per store.
pub const error_file_not_found: Dword = 2;

// ── shell32: app identity ─────────────────────────────

pub extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(APPID: [*:0]const u16) callconv(.winapi) Hresult;
pub extern "shell32" fn GetCurrentProcessExplicitAppUserModelID(APPID: *?[*:0]const u16) callconv(.winapi) Hresult;
pub extern "shell32" fn SHGetKnownFolderPath(
    *const Guid,
    Dword,
    ?*anyopaque,
    [*][*:0]const u16,
) callconv(.winapi) Hresult;
pub extern "shell32" fn SHCreateItemFromParsingName(
    *const u16,
    ?*anyopaque,
    *const Guid,
    *anyopaque,
) callconv(.winapi) Hresult;

/// `SHGetKnownFolderPath` writes into a buffer the caller allocates with
/// `CoTaskMemAlloc`, so the pointer has to come back through `CoTaskMemFree`.
pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(
    *const Guid,
    ?*anyopaque,
    Dword,
    *const Guid,
    *anyopaque,
) callconv(.winapi) Hresult;
pub extern "ole32" fn CoInitializeEx(?*anyopaque, Dword) callconv(.winapi) Hresult;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;

// ── this process's own image, its data root, the shell's refresh ──

/// `GetModuleFileNameW` from `libloaderapi.h`. A null `hModule` names the
/// process image itself, so this is the path of the executable that is
/// running -- the string a file association has to name if it wants the shell
/// to start THIS program and not a sibling that answers to the same name.
pub extern "kernel32" fn GetModuleFileNameW(
    hModule: ?Hinstance,
    lpFilename: [*]u16,
    nSize: Dword,
) callconv(.winapi) Dword;

pub const ModulePathError = error{
    /// The loader named no path for this image, or a path longer than the
    /// longest string Windows accepts.
    ModulePathUnavailable,
} || std.mem.Allocator.Error;

/// The path of this process's image, owned UTF-8.
///
/// `GetModuleFileNameW` reports truncation by answering the buffer size it was
/// given, so a full buffer is a retry with a wider one rather than a path that
/// stops in the middle: a truncated command line in a file association starts
/// a different program or none at all. `MAX_PATH` is only the buffer the SDK
/// suggests, so the retry doubles until the path fits or until the longest
/// string Windows accepts is reached, and a path that still does not fit is a
/// refusal rather than a truncation.
pub fn moduleFileName(gpa: std.mem.Allocator) ModulePathError![]u8 {
    if (comptime !is_windows) return error.ModulePathUnavailable;
    var size: Dword = 260;
    while (size <= 32_767) {
        const buffer = try gpa.alloc(u16, size);
        defer gpa.free(buffer);
        const written = GetModuleFileNameW(null, buffer.ptr, size);
        if (written == 0) return error.ModulePathUnavailable;
        if (written < size) return narrow(gpa, buffer[0..written]);
        size *= 2;
    }
    return error.ModulePathUnavailable;
}

/// `FOLDERID_LocalAppData` from `knownfolders.h`: the per-user, per-machine
/// application's own writable data root. It is the one known folder whose
/// answer is the same string for every process of the same user on every run,
/// which is what a synthetic record has to be filed under when a SECOND
/// process has to find it again without being told where it is.
pub const folderid_local_app_data: Guid = guid("{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}");

/// `KF_FLAG_DEFAULT` from `winbase.h`: no redirection, no default creation.
pub const known_folder_default: Dword = 0;

pub const KnownFolderError = error{
    /// This build has no Windows known folder to resolve.
    NotWindowsTarget,
    /// The shell named no path, or named one this adapter cannot spell.
    KnownFolderUnavailable,
} || std.mem.Allocator.Error;

/// The per-user application data root, owned UTF-8.
///
/// `SHGetKnownFolderPath` allocates the answer with `CoTaskMemAlloc` and the
/// SDK documents `CoTaskMemFree` as its only release, so it comes back through
/// that and nowhere else. The result is narrowed here rather than handed on as
/// UTF-16, because every model in this directory is UTF-8 and a path re-spelt
/// at each boundary is a path that can be spelled two ways.
pub fn localAppData(gpa: std.mem.Allocator) KnownFolderError![]u8 {
    if (comptime !is_windows) return error.NotWindowsTarget;
    var slot: ?[*:0]const u16 = null;
    const hr = SHGetKnownFolderPath(
        &folderid_local_app_data,
        known_folder_default,
        null,
        &slot,
    );
    if (failed(hr)) return error.KnownFolderUnavailable;
    const owned = slot orelse return error.KnownFolderUnavailable;
    defer CoTaskMemFree(@ptrCast(@constCast(owned)));
    return narrow(gpa, std.mem.span(owned));
}

/// `SHChangeNotify` from `shlobj_core.h`, the shell's own "re-read what you
/// know about file types" call.
///
/// Explorer reads the file-type table when it starts and when a registration
/// tells it to read it again. A registration written without this call is
/// correct in the registry and invisible in the shell until the next logon,
/// which is the difference between an association that works and one that is
/// merely present.
pub extern "shell32" fn SHChangeNotify(
    wEventId: i32,
    uFlags: Dword,
    dwItem1: ?*anyopaque,
    dwItem2: ?*anyopaque,
) callconv(.winapi) void;

/// `SHCNE_ASSOCCHANGED` and `SHCNF_IDLIST` from `shlobj_core.h`. There are no
/// items to name for this event: it announces that the association table
/// itself changed.
pub const shcne_assocchanged: i32 = 0x0800_0000;
pub const shcnf_idlist: Dword = 0x0000_0000;

// ── advapi32: the Windows Credential Manager ───────────────────────

/// `CRED_TYPE_GENERIC` from `wincred.h`.
pub const cred_type_generic: Dword = 1;
/// `CRED_PERSIST_SESSION`.
pub const cred_persist_session: Dword = 1;
/// `CRED_PERSIST_LOCAL_MACHINE`.
pub const cred_persist_local_machine: Dword = 2;
/// `CRED_PERSIST_ENTERPRISE`.
pub const cred_persist_enterprise: Dword = 3;

/// `CREDENTIALW` from `wincred.h`, field for field. `CredentialBlobSize` is a
/// byte count and `CredentialBlob` is opaque secret material, which is why the
/// provider never logs a struct and never formats one.
pub const CredentialW = extern struct {
    Flags: Dword,
    Type: Dword,
    TargetName: ?[*:0]u16,
    Comment: ?[*:0]u16,
    LastWritten: FileTime,
    CredentialBlobSize: Dword,
    CredentialBlob: ?[*]u8,
    Persist: Dword,
    AttributeCount: Dword,
    Attributes: ?*anyopaque,
    TargetAlias: ?[*:0]u16,
    UserName: ?[*:0]u16,
};

pub extern "advapi32" fn CredReadW(
    TargetName: [*:0]const u16,
    Type: Dword,
    Flags: Dword,
    Credential: *?*CredentialW,
) callconv(.winapi) Bool;
pub extern "advapi32" fn CredWriteW(Credential: *const CredentialW, Flags: Dword) callconv(.winapi) Bool;
pub extern "advapi32" fn CredDeleteW(TargetName: [*:0]const u16, Type: Dword, Flags: Dword) callconv(.winapi) Bool;
pub extern "advapi32" fn CredFree(Buffer: ?*anyopaque) callconv(.winapi) void;
pub extern "advapi32" fn CredIsWritable() callconv(.winapi) Bool;

// ── advapi32: the registry ─────────────────────────────

/// `HKEY` from `winreg.h`. It is `DECLARE_HANDLE(HKEY)`, so it is a
/// pointer-sized opaque value on every architecture nogui targets, and it is
/// declared as that integer rather than as a pointer for one reason: the two
/// hives an ordinary process may write are VALUES, and a pointer built from a
/// constant would claim an address the constant does not have.
pub const Hkey = isize;

/// `HKEY_CURRENT_USER` from `winreg.h`: this user's own hive.
///
/// The file-type table a run may write lives under the per-user `Classes` key,
/// never under the machine-wide hive or the machine-wide classes root. A
/// machine-wide association changes how EVERY account on the machine opens
/// that file type, which no single process may decide on its own; the
/// per-user hive needs no elevation, so it is also the only one this
/// directory can name without an approval it cannot obtain.
pub const hkey_current_user: Hkey = 0x8000_0001;

/// `KEY_SET_VALUE | KEY_CREATE_SUB_KEY` from `winreg.h`: the two rights a
/// value write and a subkey creation need, and nothing else.
pub const key_write: Dword = 0x0000_0006;

/// `DELETE` from `winreg.h`. `RegDeleteKeyW` checks this on the PARENT handle
/// it is given rather than on the subkey it removes, so a run that wants to
/// take a key back out has to open its parent with this right.
pub const registry_delete: Dword = 0x0001_0000;

/// `REG_SZ` from `winreg.h`: a NUL-terminated string. `cbData` counts BYTES
/// including the terminator, which is why the writers below pass
/// `2 * (chars + 1)` and not the character count.
pub const reg_sz: Dword = 1;

/// `LPCTSTR` in the W form: the key path or value name, NUL-terminated.
/// `lpSubKey` is never null in the calls below, because a null subkey names
/// the handle itself and a run that meant "the classes root" should say so.
pub extern "advapi32" fn RegCreateKeyExW(
    hKey: Hkey,
    lpSubKey: [*:0]const u16,
    Reserved: Dword,
    lpClass: ?[*:0]const u16,
    dwOptions: Dword,
    samDesired: Dword,
    lpSecurityAttributes: ?*const anyopaque,
    phkResult: *Hkey,
) callconv(.winapi) Long;

pub extern "advapi32" fn RegOpenKeyExW(
    hKey: Hkey,
    lpSubKey: [*:0]const u16,
    ulOptions: Dword,
    samDesired: Dword,
    phkResult: *Hkey,
) callconv(.winapi) Long;

/// `lpValueName` is null for the key's DEFAULT value, which is where Windows
/// reads a file type's ProgID and where it reads the command line a ProgID
/// runs. `lpData` is a byte count's worth of opaque bytes because `REG_SZ` is
/// written as wide characters on Windows and nothing here may assume a
/// terminator the caller did not write.
pub extern "advapi32" fn RegSetValueExW(
    hKey: Hkey,
    lpValueName: ?[*:0]const u16,
    Reserved: Dword,
    dwType: Dword,
    lpData: ?*const anyopaque,
    cbData: Dword,
) callconv(.winapi) Long;

/// `RegDeleteKeyW` refuses a key that still has SUBKEYS, which is why a run
/// that takes a registration back out removes the leaves first and reports
/// the one leaf it did not recognise instead of leaving a half-built tree.
pub extern "advapi32" fn RegDeleteKeyW(
    hKey: Hkey,
    lpSubKey: [*:0]const u16,
) callconv(.winapi) Long;

/// `RegQueryValueExW` from `winreg.h`, the read side of `RegSetValueExW`.
///
/// The size query comes first because the value's length is not known before
/// it is read, and it is the only way the registry will say how much room the
/// value needs. `lpData` is bytes and not characters: the count that comes
/// back is a byte count, which for a `REG_SZ` on Windows is two per unit plus
/// two for the terminator.
pub extern "advapi32" fn RegQueryValueExW(
    hKey: Hkey,
    lpValueName: ?[*:0]const u16,
    lpReserved: ?*Dword,
    lpType: ?*Dword,
    lpData: ?*anyopaque,
    lpcbData: *Dword,
) callconv(.winapi) Long;

pub extern "advapi32" fn RegCloseKey(hKey: Hkey) callconv(.winapi) Long;

// ── user32: window and menu handles ──────────────────────────

/// `GWL_WNDPROC` from `winuser.h`.
pub const gwl_wndproc: i32 = -4;
/// `GWL_STYLE`.
pub const gwl_style: i32 = -16;
/// `GWL_EXSTYLE`.
pub const gwl_exstyle: i32 = -20;
/// `WS_OVERLAPPEDWINDOW`.
pub const ws_overlappedwindow: u32 = 0x00CF_0000;
/// `WS_POPUP`.
pub const ws_popup: u32 = 0x8000_0000;
/// `WS_CAPTION`.
pub const ws_caption: u32 = 0x00C0_0000;
/// `WS_THICKFRAME`.
pub const ws_thickframe: u32 = 0x0004_0000;
/// `WS_MINIMIZEBOX`.
pub const ws_minimizebox: u32 = 0x0002_0000;
/// `WS_SYSMENU`.
pub const ws_sysmenu: u32 = 0x0008_0000;

pub extern "user32" fn GetWindowLongPtrW(hwnd: Hwnd, nIndex: i32) callconv(.winapi) isize;
pub extern "user32" fn SetWindowLongPtrW(hwnd: Hwnd, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongW(hwnd: Hwnd, nIndex: i32) callconv(.winapi) i32;
pub extern "user32" fn SetWindowLongW(hwnd: Hwnd, nIndex: i32, dwNewLong: i32) callconv(.winapi) i32;
pub extern "user32" fn GetWindowTextLengthW(hwnd: Hwnd) callconv(.winapi) i32;
pub extern "user32" fn GetWindowTextW(hwnd: Hwnd, lpString: [*]u16, nMaxCount: i32) callconv(.winapi) i32;
pub extern "user32" fn SetWindowTextW(hwnd: Hwnd, lpString: ?[*:0]const u16) callconv(.winapi) Bool;
pub extern "user32" fn IsWindow(hwnd: Hwnd) callconv(.winapi) Bool;
pub extern "user32" fn GetMenu(hwnd: Hwnd) callconv(.winapi) ?Hmenu;
pub extern "user32" fn SetMenu(hwnd: Hwnd, hmenu: ?Hmenu) callconv(.winapi) Bool;
pub extern "user32" fn DrawMenuBar(hwnd: Hwnd) callconv(.winapi) Bool;
pub extern "user32" fn PostMessageW(
    hwnd: Hwnd,
    Msg: u32,
    wParam: Wparam,
    lParam: windows.LPARAM,
) callconv(.winapi) Bool;
pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;

/// `CallWindowProcW` and `DefWindowProcW` from `winuser.h`. A window procedure
/// that does not forward is a broken window: the sizing, activation, close and
/// menu-loop messages are all answered by the procedure SDL installed, so a
/// menu that never opens and a window that never repaints are what swallowing
/// them produces.
pub extern "user32" fn CallWindowProcW(
    previous: ?Wndproc,
    hwnd: Hwnd,
    message: u32,
    wparam: Wparam,
    lparam: windows.LPARAM,
) callconv(.winapi) Lresult;
pub extern "user32" fn DefWindowProcW(
    hwnd: Hwnd,
    message: u32,
    wparam: Wparam,
    lparam: windows.LPARAM,
) callconv(.winapi) Lresult;

// ── the process command line ────────────────────────────

/// `GetCommandLineW` from `kernel32.h`: the command line THIS PROCESS WAS
/// STARTED with, exactly as the shell wrote it.
///
/// It is the door a shell-launched entry comes through, and it is the only
/// one: a jump list selection the user picks while no window of this app is
/// running is handed to the shell, and the shell starts the process with the
/// entry's own argument. Reading this is not a reconstruction of what the
/// arguments must have been -- it is the argument list itself.
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;

/// `CommandLineToArgvW` from `shellapi.h`: the shell's own splitter. The
/// quoting rules are the ones the shell used to write the line, so parsing it
/// any other way would decode a command line the shell never produced.
///
/// The returned array and every string in it are one `LocalAlloc` block, so
/// it is released with `LocalFree` and nothing in it is freed separately.
pub extern "shell32" fn CommandLineToArgvW(
    command_line: [*:0]const u16,
    count: *c_int,
) callconv(.winapi) ?[*:0][*:0]u16;

/// `LocalFree` from `kernel32.h`, and the only way to release what
/// `CommandLineToArgvW` allocated.
pub extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;

/// `GetDpiForWindow` from `winuser.h`. It answers the DPI of the window's own
/// monitor, which is the factor between the logical units a layout is written in
/// and the physical pixels the window procedure is handed. A handle that is not
/// a window answers zero.
pub extern "user32" fn GetDpiForWindow(hwnd: Hwnd) callconv(.winapi) u32;

/// `USER_DEFAULT_SCREEN_DPI` from `winuser.h`: the DPI that names 100% scaling,
/// and therefore the divisor that turns a DPI into a factor.
pub const default_dpi: u32 = 96;

/// `WM_COMMAND` from `winuser.h`. A menu or an accelerator reaches the window
/// procedure as this message, and its `wParam` low word is the control or menu
/// identifier the native menu was built with.
pub const wm_command: u32 = 0x0111;
/// `WM_MENUCHAR`.
pub const wm_menuchar: u32 = 0x0121;
/// `WM_INITMENUPOPUP`.
pub const wm_initmenupopup: u32 = 0x0127;
/// `WM_NULL` from `winuser.h`.
pub const wm_null: u32 = 0x0000;

/// `MF_BYPOSITION` and the rest of the `MF_*` menu flags, as the SDK spells
/// them. `TrackPopupMenuEx` needs these verbatim, so they are not re-derived.
pub const mf_string: u32 = 0x0000_0000;
pub const mf_grayed: u32 = 0x0000_0001;
pub const mf_disabled: u32 = 0x0000_0002;
pub const mf_separator: u32 = 0x0000_0800;
pub const mf_checked: u32 = 0x0000_0008;
pub const mf_popup: u32 = 0x0000_0010;
pub const mf_byposition: u32 = 0x0000_0400;

pub const tpm_leftalign: u32 = 0x0000;
pub const tpm_returncmd: u32 = 0x0100;
pub const tpm_rightbutton: u32 = 0x0002;

pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?Hmenu;
pub extern "user32" fn DestroyMenu(hmenu: ?Hmenu) callconv(.winapi) Bool;
pub extern "user32" fn AppendMenuW(
    hmenu: ?Hmenu,
    uFlags: u32,
    uIDNewItem: usize,
    lpNewItem: ?[*:0]const u16,
) callconv(.winapi) Bool;
pub extern "user32" fn GetMenuItemCount(hmenu: ?Hmenu) callconv(.winapi) c_int;
pub extern "user32" fn InsertMenuItemW(
    hmenu: ?Hmenu,
    uItem: usize,
    bNewItem: Bool,
    lpMenuItem: *const MenuItemInfoW,
) callconv(.winapi) Bool;
pub extern "user32" fn SetMenuItemInfoW(
    hmenu: ?Hmenu,
    uItem: usize,
    bNewItem: Bool,
    lpMenuItem: *const MenuItemInfoW,
) callconv(.winapi) Bool;
pub extern "user32" fn TrackPopupMenuEx(
    hmenu: ?Hmenu,
    uFlags: u32,
    x: i32,
    y: i32,
    hwnd: ?Hwnd,
    lpRect: ?*const Rect,
) callconv(.winapi) Bool;
pub extern "user32" fn EnableMenuItem(hmenu: ?Hmenu, uIDEnableItem: usize, uEnable: u32) callconv(.winapi) Bool;
pub extern "user32" fn CheckMenuItem(hmenu: ?Hmenu, uIDCheckItem: usize, uCheck: u32) callconv(.winapi) Bool;

/// `MENUITEMINFOW` from `winuser.h`.
pub const MenuItemInfoW = extern struct {
    cbSize: Dword,
    fMask: Dword,
    fType: Dword,
    fState: Dword,
    wID: Dword,
    hSubMenu: ?Hmenu,
    hbmpChecked: ?*anyopaque,
    hbmpUnchecked: ?*anyopaque,
    dwItemData: windows.ULONG_PTR,
    dwTypeData: ?[*:0]u16,
    cch: Dword,
    hbmpItem: ?*anyopaque,
};

/// `MIIM_*` field mask.
pub const miim_state: u32 = 0x0000_0001;
pub const miim_id: u32 = 0x0000_0002;
pub const miim_submenu: u32 = 0x0000_0004;
pub const miim_checkmarks: u32 = 0x0000_0008;
pub const miim_type: u32 = 0x0000_0010;
pub const miim_data: u32 = 0x0000_0020;
pub const miim_string: u32 = 0x0000_0040;
pub const miim_ftype: u32 = 0x0000_0100;

/// `MFT_STRING`, `MFT_SEPARATOR` and `MFT_MENUBARBREAK` from `winuser.h`.
pub const mft_string: u32 = 0x0000_0000;
pub const mft_separator: u32 = 0x0000_0800;
/// `MFS_DISABLED` and `MFS_GRAYED`.
pub const mfs_disabled: u32 = 0x0000_0003;
pub const mfs_checked: u32 = 0x0000_0008;

/// `MIIM_STATE | MIIM_ID | MIIM_STRING`, which is the mask
/// `AppendMenuItemW` needs for a text row and nothing more.
pub const mii_string_id: u32 = miim_state | miim_id | miim_string;
/// `MIIM_STATE | MIIM_ID | MIIM_SUBMENU`, which is the mask a popup row needs.
pub const mii_submenu_id: u32 = miim_state | miim_id | miim_submenu;
/// `MIIM_STATE | MIIM_ID | MIIM_FTYPE`, which is the mask a separator needs.
pub const mii_separator_id: u32 = miim_state | miim_id | miim_ftype;

/// `RECT` from `winuser.h`.
pub const Rect = extern struct {
    left: Long,
    top: Long,
    right: Long,
    bottom: Long,
};

/// `DwmSetWindowAttribute` from `dwmapi.h`, used for the Windows 10 1809 and
/// later dark title bar. It is a real platform call and it is a no-op on a
/// build of Windows that does not have the attribute, which is reported
/// honestly rather than assumed.
pub extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: Hwnd,
    dwAttribute: u32,
    pvAttribute: ?*const anyopaque,
    cbAttribute: Dword,
) callconv(.winapi) Hresult;

/// `DwmGetWindowAttribute` from `dwmapi.h`, the read side of the call above.
///
/// It exists because a request is not a fact: `DwmSetWindowAttribute` returns
/// `S_OK` for a window manager that accepted the write, and a window that
/// reports success while the caption is still drawn light is a window whose
/// state this directory cannot otherwise describe. Every attribute read in
/// this file goes through here, so the DWM ABI is declared once.
pub extern "dwmapi" fn DwmGetWindowAttribute(
    hwnd: Hwnd,
    dwAttribute: u32,
    pvAttribute: ?*anyopaque,
    cbAttribute: Dword,
) callconv(.winapi) Hresult;

/// `DWMWA_USE_IMMERSIVE_DARK_MODE` (20) and its pre-20H1 predecessor
/// `DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1` (19).
pub const dwma_use_immersive_dark_mode_19: u32 = 19;
pub const dwma_use_immersive_dark_mode_20: u32 = 20;
/// `DWMWA_CAPTION_COLOR` (35) and `DWMWA_BORDER_COLOR` (34).
pub const dwma_border_color: u32 = 34;
pub const dwma_caption_color: u32 = 35;
/// `DWMWA_COLOR_DEFAULT`, the documented "follow the system" value.
pub const dwma_color_default: u32 = 0xFFFF_FFFF;
/// `DWMWA_COLOR_NONE`, the documented "no colour at all" value.
pub const dwma_color_none: u32 = 0xFFFF_FFFE;
