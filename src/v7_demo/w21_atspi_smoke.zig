//! W21 real AT-SPI gate smoke — one live Wayland window whose semantic tree is
//! published through the REAL `accessibility.Adapter` to AccessKit's AT-SPI
//! backend, so a real registry, a real screen reader and a real accessibility
//! client can all observe it on the session's own bus.
//!
//! Nothing here fabricates a platform adapter and nothing stubs a reader: the
//! scene publishes a button, a checkbox, a slider, a two-option radio group,
//! a determinate progress leaf, a text field, a virtualized list and a modal
//! dialog through `Adapter.publish`, and every value change
//! comes back through `Adapter.drain` onto the ordinary activation, edit and
//! focus seam. If the registry is unreachable, `Adapter.stateOf()` stays
//! `inactive` and the run says so instead of claiming coverage.
//!
//! Two modes, one model:
//!
//+//!   * HEADLESS is the default. It opens no window, needs no compositor and
//!     needs no AT-SPI registry, so it runs anywhere the suite runs. It builds
//!     real frames, publishes them through the real adapter, drives the real
//!     request ring and ASSERTS what crossed the boundary. A failed assertion
//!     is a non-zero exit, not a line of prose.
//!   * NATIVE (`--native`) is opt-in. It opens one real window and holds it,
//!     so an external AT-SPI client can read the same tree from the session's
//!     own bus. That window PAINTS what it publishes: the App's own tree
//!     paint, then the app-owned overlays the semantic tree describes — the
//!     text field's shaped glyphs, its selection and its caret, the list's
//!     window of virtual rows with the selected one, and the modal's scrim
//!     and dialog panel. Nothing about the model, the publisher or the
//!     adapter differs between the modes; only the frame source and the hold
//!     loop do.
//!
//! What both modes observe:
//!   1. `publish` against a committed frame, and the `inactive -> active`
//!      transition when a screen reader actually asks for the tree.
//!   2. Every native request `drain` replays, reported as a count plus the
//!      model counters it moved, so a replay is proven by the model and not by
//!      the adapter's own report.
//!   3. A virtualized list whose window is ONE decision: the rows the painter
//!      draws and the rows the platform is handed are the same logical range,
//!      the selected row is inside that window with the extent it is drawn at,
//!      the row's identity is its stable key, and a native activation of a
//!      visible row reaches `select_row`.
//!   4. Text that is not pure ASCII: the field publishes real per-character
//!      byte lengths, and the caret the platform receives is a CHARACTER index
//!      while the model's is a byte offset. Both are printed, so an external
//!      client can be checked against the conversion in either direction.
//!   5. An authored modal dialog: the modal state is a flag this app set, and
//!      opening it moves the published focus into the dialog subtree while
//!      every unrelated node keeps its identity.
//!   6. A REAL radio group: two drawn `ctx.radio` options that share the
//!      view's own `?u32`, published by the core's built-in policy as
//!      `radio_button` with one option marked selected, inside a KEYED row
//!      that is published as their `radio_group`. The relation is resolved
//!      through the public `semantics.nodeId` seam from the identity the App
//!      bound to that row, so it names a node this tree really contains.
//!   7. A REAL determinate progress leaf, drawn next to the slider and bound
//!      to the SAME value, published by the core's own progress policy as
//!      `progress_indicator`. Four facts are read back out of the adapter's
//!      own buffers rather than out of the value this run wrote: the leaf is
//!      announced under a non-empty name that resolves back to it and to no
//!      other control; its number and its range equal what the MODEL holds,
//!      where the bounds live on the view rather than in a literal beside the
//!      assertion, because two controls agreeing with each other is internal
//!      consistency and not the claim; its action word is zero AND PRESENT,
//!      since a node the update dropped reads as no actions at all; and a
//!      numeric write through the adapter's value interface is refused.
//!
//! Item 7's read-only policy is AUTHORED here and asserted in
//! `checkPublishedTree`: the core publishes the indicator with
//! `states.read_only` and an EMPTY action set, and it binds the leaf's own
//! optional key, so the specimen really reaches the bridge as a
//! `progress_indicator` with a number and a range behind it.
//!
//! What AT-SPI does with that policy is the platform's own business, and it is
//! not a flag this fixture can expect. The pinned provider's translation emits
//! the read-only state only for a role it reports as read-only capable, and a
//! determinate progress indicator is not one, so a healthy run legitimately
//! sees `enabled`/`sensitive` and no read-only state at all. The policy is
//! therefore proved at the platform edge by ATTEMPTING a native value write
//! inside the published range and showing that the model's own write counter,
//! its value and the number the platform was last told all stay exactly where
//! they were — never by a flag that the role does not publish, and never by a
//! guard here keyed on the role.
//!
//! That attempt is a DIFFERENTIAL, because a refused write and a dead request
//! look identical from the model alone: the same numeric write is first aimed
//! at the slider that shares the value, where it applies and moves the write
//! counter, and then at the indicator, where the ring takes it and the model
//! records nothing. Both requests are checked for queue acceptance against
//! the adapter's own drop counter, so neither outcome can be an artefact of a
//! request the ring refused to carry.
//!
//!   8. A REAL focused text endpoint on that same field, through the core's
//!      own public integration: `App.registerTextEndpoint` binds it to the
//!      identity the App gave the field's carrier, the endpoint owns a WEAK
//!      handle on a registered model, and every op resolves the model's own
//!      UTF-8 bytes against the UTF-16 code units the platform speaks. So a
//!      committed native keypress inserts into the SAME buffer an AT-SPI
//!      `replace_selected_text` writes, an arrow key moves the SAME caret the
//!      published selection names, and the caret rectangle handed to the
//!      input method is the rectangle the painter drew.
//!
//! The binding is tied to focus, not to the run. `PanelView`'s own focus rule
//! gives the field the keyboard when nothing else has it, and binds the
//! endpoint right there because `App.registerTextEndpoint` accepts only the
//! focused widget. Focus loss is the App's own `textInputManager().reconcile`,
//! which drops the registration, cancels any composition and stops native
//! text input; a field that takes the keyboard again binds itself again. The
//! window tears the registration down before it releases the surface, and
//! `main` releases the borrowed model last, so no endpoint can outlive the
//! model it edits through.
//!
//! Native mode reaches the App the way every consumer of the core does: the
//! host translates an SDL event, publishes it on the `on_event` hook, and
//! this window hands it to `App.handle`. That handoff is why a real keypress
//! is a real edit here rather than an event the host received and nobody
//! consumed. It is the host's OWN routing, with no key handling of this
//! file's own: a printable key inserts because SDL delivers committed text
//! for a window whose text input this endpoint started, and an arrow key
//! moves the caret because the core's own manager routes the key to the
//! focused endpoint.
//!
//! Headless mode additionally asserts, each against the adapter's own buffers
//! or the model's own counters rather than against the value just written:
//!   * the modal flag, the list's set relationship and the published row's
//!     membership reach the bridge, and only where the app set them;
//!   * the published rows ARE the painted window: same first row, same count,
//!     and a target extent per row that contains the pixels painted in it;
//!   * a published row's identity is its key, so moving the selection replaces
//!     the row and leaves every other node alone;
//!   * a platform CHARACTER selection edits the model at the matching BYTE
//!     offsets, and an index past the end of the run is refused;
//!   * two requests replayed in ONE batch cannot carry the published run's
//!     length into the model, so a caret that moves after an edit cannot undo
//!     the edit;
//!   * a preedit survives an erase, a caret write and a whole-value write
//!     inside its own composition, and the commit that follows replaces it
//!     instead of appending a second copy;
//!   * a whole value handed over by the platform becomes the model's whole
//!     buffer in ONE write, through the same setter the composed replacement
//!     uses;
//!   * a whole value handed over AS the published run — the same bytes at the
//!     same address a selection request carries — is still a whole write, so
//!     what `set_value` means comes from the request and not from where the
//!     bytes live;
//!   * logical bounds cross as physical pixels at the scale the adapter holds;
//!   * a node the app hides leaves the tree and a node it disables stays in it
//!     with no action, so neither can be driven from the platform;
//!   * an abandoned stage publishes nothing and leaves the live tree alone.
//!
//! Every `published:` line is what the adapter handed AccessKit, read back from
//! the adapter's own buffers. It is the near side of the bridge, never a value
//! AT-SPI echoed back: a line here is a claim about the published tree, and
//! confirming the platform agrees is an external client's job. Nothing in this
//! file reports speech, because a screen reader's voice is never observed from
//! inside the application.
//!
//! Every `model:` line is the MODEL's own value, and the application prints
//! the whole model ONCE on its first committed frame, on a single
//! `model: baseline` line. Every later `model:` line is a change only, because
//! a key that never moves would otherwise never be printed at all and an
//! external client would have to decide whether an absent counter meant zero
//! or meant nothing observed. The spelling stays `key=value` on every line,
//! so a client that joins at any point still holds each key at its last
//! observed value, and no key is ever defaulted into the gap.
//!
//!
//! What the native pixels are measured from, and why that is the same
//! measurement the semantic edge publishes:
//!
//!   * The field's run is shaped by the ONE text service the frame's text
//!     engine rasterizes with. Its glyphs, its selection boxes, its caret
//!     and the per-character advances the platform receives all come from
//!     that one layout, so a caret on screen and a caret published to AT-SPI
//!     are one number and not two that agree today.
//!   * Per-character positions are published in the NODE's own coordinate
//!     space, which is what AccessKit asks for, and every painted overlay is
//!     placed from the carrier's own `visualBorderRect`. The run reports the
//!     arithmetic that connects the two (`paint: agree`), so a reviewer can
//!     check the agreement instead of taking it on trust.
//!   * The list's window is decided ONCE, from the carrier's own box and the
//!     app's selection, and both halves read it: the annotator publishes it as
//!     `first_visible` plus `visible_rows`, and the painter draws it. Rows sit
//!     on the published `row_height`, each inside its own slice of the
//!     carrier's box, and each is named by the same accessor the published row
//!     node is named by.
//!   * A native request that arrives from OUTSIDE this process is what moves
//!     a label, a value or a selection. The run drives two of them through
//!     the real ring so the pixels, the model and the published tree are
//!     provably the same state, and it holds no second copy of any of it.
//!   * A committed keypress from a real keyboard and an AT-SPI edit are the
//!     same edit. `q` typed into the focused field arrives as committed text,
//!     the core's manager hands it to this field's endpoint, and the bytes
//!     move once; Left moves the caret and moves no byte. Both are visible
//!     on their own report lines, and neither is an echo of the other: a
//!     `drain: applied=` line is this process's near side of the bridge and
//!     never a native keystroke.
//!
//! In native mode it drives the host as an EXTERNAL loop: `Application.step()`
//! is called here, never `Application.run()`.
//!
//! Run it: `zig build w21-atspi-smoke` for the headless gate, or
//! `zig build w21-atspi-smoke -- --native [--hold-ms 25000] [--ppm out.ppm]
//! [--bell] [--no-synthetic]` for the window. `--ppm` writes the last
//! presented frame's own pixels, read back out of the Oklab target the two
//! passes wrote. `--bell` asks the real platform for ONE ring through the
//! window this run owns and reports what the platform answered; it is opt-in
//! because a bell is a sound on somebody's desk. `--no-synthetic` drives
//! neither in-process request batch, so an external client's calls are the
//! only thing that moves the model.
//!
//! With `--no-synthetic` nothing inside the process moves the model, so the
//! exact acceptance contract is: type `q` at the focused field with a real
//! keyboard, read the changed text once from a `model:` line, then press Left
//! and read a caret-only delta from the model and the published selection.
//! The caret's byte offset is what the app holds; the character index is what
//! the platform is given; `text_writes` counts the text requests that reached
//! the model, and a caret motion is not one of them.
//!
//! `--require-accessibility-active` is the one flag an APPROVED acceptance
//! run adds: it turns the native mode's published-tree assertions on and fails
//! the run unless a screen reader has actually attached. It is off by default,
//! because a plain `--native` run is established evidence that the window
//! paints and publishes what it describes, and turning it into a failure
//! whenever no reader happened to attach would throw that evidence away. The
//! flag states a stronger demand and only that demand.

const std = @import("std");
const Io = std.Io;
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const nogui = @import("nogui");
const host = @import("nogui_host");
/// `accessibility.zig` is re-exported by the host root, so the smoke reaches
/// the adapter through the same module the window host lives in.
const accessibility = host.accessibility;
/// The public frame adapter: the text engine, the scene lowering and the
/// Oklab-to-sRGB blit a presented frame goes through. The headless mode
/// never reaches it, so a windowless run links no font engine and creates no
/// device.
const frame_api = @import("v7_frame");
const NativeFrame = frame_api.NativeFrame;
const TextLayout = frame_api.native.TextLayout;
const SceneRect = frame_api.native.SceneRect;
const no_clip = frame_api.native.no_clip;
const srgbToOklab = frame_api.srgbToOklab;
/// The window-logical box the semantic bounds and the painted overlays share.
pub const Rect = nogui.widget.Rect;

const Session = nogui.Session;
const App = nogui.App;
const WidgetId = nogui.WidgetId;
const FrameNodeId = nogui.FrameNodeId;
const ComponentKey = nogui.ComponentKey;
const contract = host.window_contract;
const Application = host.Application;
/// The focused-text protocol the App owns: the endpoint this field publishes,
/// the weak registered-model ownership behind it, and the conversions between
/// the model's UTF-8 bytes and the UTF-16 code units every native text API
/// speaks. The model itself stays in `PanelView`, so the AT-SPI edit path and
/// the native one edit the SAME bytes rather than two that agree today.
const text_input = nogui.text_input;
/// The protocol's own range and selection types, named apart from the
/// semantic edge's `TextSelection` so a byte offset and a UTF-16 offset can
/// never be confused for one another in this file.
const Utf16Range = text_input.Utf16Range;
const Utf16Selection = text_input.Selection;

const semantics = accessibility.semantics;

const OnFrameFn = @typeInfo(@FieldType(Application.Hooks, "on_frame")).optional.child;
const managed_window_ptr =
    @typeInfo(@typeInfo(OnFrameFn).pointer.child).@"fn".param_types[2].?;

/// Long enough for a screen reader to start, attach, and read the tree.
const default_hold_ms: u64 = 25_000;
/// How long after the first native request batch the second one is sent, so
/// the focused field's caret and selection are real reported pixels before
/// the dialog opens and takes that focus away.
const exercise_gap_ms: u64 = 600;
/// One row name plus one composed text edit, in one buffer the smoke owns.
const scratch_bytes: usize = semantics.Scratch.default_capacity;
/// The logical surface the headless gate lays out against. It is the same
/// size the native window asks for, so a bounds fact observed headlessly is a
/// fact about the same scene. The height is the whole column with the radio
/// row AND the modal open, plus headroom: a scene that only fits while its
/// dialog is closed would fail a frame for a reason that has nothing to do
/// with the tree it is publishing.
const headless_surface: semantics.Size = .{ .width = 520, .height = 760 };
/// Published slots the change report can diff. A tree larger than this is
/// reported in full every publish, and the overflow is announced rather than
/// silently dropped.
const node_slots: usize = 64;
/// One formatted node line. A published name is clamped before it reaches
/// here, so the buffer cannot overflow on an unusually long accessible name.
/// A line that still did not fit fails the run instead of truncating a claim.
const line_bytes: usize = 512;
/// Accessible names clamped to this many bytes in a report line.
const report_name_bytes: usize = 96;
/// Bytes the change report keeps its OWN copy of the live text in. The
/// model's buffer is exactly this long, so the copy is whole: an alias of
/// the live buffer would compare it with itself and report nothing after
/// the first reading.
const model_text_bytes: usize = 96;

/// A span of the model's own UTF-8 bytes. Every range that crosses the text
/// protocol arrives in UTF-16 code units and is resolved into one of these
/// before it touches the buffer, so the conversion has exactly one shape.
const ByteRange = struct {
    start: usize = 0,
    end: usize = 0,
};

/// Which way an offset that lands inside a surrogate pair is resolved. A
/// range START keeps the bytes before it and a range END takes the character
/// that pair belongs to, so a range the platform expressed over half a
/// supplementary character still addresses whole characters and never splits
/// one.
const Snap = enum { start, end };

/// The view a text endpoint's handlers act on. The endpoint carries it as its
/// own `user` payload, so the vtable stays a comptime value with no receiver.
fn viewOf(user: *anyopaque) *PanelView {
    return @ptrCast(@alignCast(user));
}

/// The byte offset `units` addresses inside `value`, whose characters are
/// described by `table`, snapped to a character boundary.
///
/// Null when `units` is past the end of `value`: that is a range the model
/// cannot address at all, and reporting it is better than clamping it into a
/// silent edit of the wrong bytes. A table shorter than the value resolves as
/// far as it reaches and then stops, because a truncated table describes the
/// run only up to its own end.
fn unitsToByte(value: []const u8, table: []const u8, units: usize, snap: Snap) ?usize {
    var byte: usize = 0;
    var seen: usize = 0;
    for (table) |entry| {
        if (byte >= value.len) break;
        if (seen == units) return byte;
        const size = @min(@as(usize, entry), value.len - byte);
        const width: usize = if (size == 4) 2 else 1;
        if (seen + width > units) {
            return switch (snap) {
                .start => byte,
                .end => byte + size,
            };
        }
        seen += width;
        byte += size;
    }
    return if (seen >= units) byte else null;
}

/// The byte offset of SCALAR `index` inside `value`.
///
/// A scalar is one Unicode code point, which is the unit a positioned edit
/// addresses: a supplementary character is four bytes and two UTF-16 code
/// units and is still ONE of them. Null when the value holds no such scalar,
/// because that is a position the model cannot name.
fn scalarOffset(value: []const u8, index: usize) ?usize {
    var at: usize = 0;
    var seen: usize = 0;
    while (at < value.len) {
        if (seen == index) return at;
        const size = std.unicode.utf8ByteSequenceLength(value[at]) catch return null;
        if (size == 0) return null;
        at += size;
        seen += 1;
    }
    return if (seen == index) at else null;
}

/// Where a byte offset ends up after an edit of `[low, high)` in the same
/// buffer. A byte before the edit keeps its offset, one after it moves with
/// the tail, and one inside it collapses to where the edit began.
fn offsetThrough(byte: usize, low: usize, high: usize) usize {
    if (byte <= low) return byte;
    if (byte >= high) return byte - (high - low);
    return low;
}

/// Whether a byte separates words in this model's own value. The field is one
/// short line with no segmentation table of its own, so it names the two
/// separators it actually treats as such instead of implying a UAX #29
/// segmentation the bytes never carried.
fn isSeparator(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == 0x0b or byte == 0x0c;
}

/// Whether `value` names bytes inside `buffer`, in either order.
///
/// The only question a caller has about a borrowed payload: bytes that live in
/// the same storage can move under it, so one address range is compared here
/// rather than a pointer identity that would miss an interior slice.
fn overlapsBuffer(buffer: []const u8, value: []const u8) bool {
    if (value.len == 0) return false;
    const low = @intFromPtr(buffer.ptr);
    const high = low + buffer.len;
    const at = @intFromPtr(value.ptr);
    return at < high and at + value.len > low;
}

const c_text: [4]f32 = .{ 0.92, 0.94, 1.0, 1 };
const c_field: [4]f32 = .{ 0.18, 0.34, 0.55, 1 };
const c_list: [4]f32 = .{ 0.30, 0.28, 0.18, 1 };

// ── The native paint's own constants ───────────
//
// These are the numbers the native window paints with and the numbers the
// semantic edge publishes. Each one has exactly one definition, so a painted
// pixel and a published rectangle cannot come from two places that happen to
// agree today.

/// Characters the per-character table can hold. The model's own
/// `char_lengths` is exactly this long, so every character a run can hold has
/// a published position and a published advance.
const text_slots: usize = 96;
/// Rows one list can paint at once. The list's own box decides how many of
/// them fit; this is only the bound on the layouts kept alive for them.
const row_slots: usize = 8;
/// The row pitch, in logical units. This is the number the list PUBLISHES as
/// its row height and the number the painted rows are placed on, so a screen
/// reader's row geometry and the row a person sees are one measurement.
const row_height: f32 = 24;
/// The size every app-owned run is shaped at: the field, the rows and the
/// dialog's caption. One size, so the three never disagree about a glyph.
const ui_font_size: f32 = 15;
/// Horizontal inset of the field's own run inside its carrier's border box.
/// The same number offsets the published per-character positions, because
/// those are measured in the carrier's coordinate space.
const field_inset: f32 = 10;
/// Inset of a row's own background and text inside the list's box.
const row_inset: f32 = 6;
const caret_width: f32 = 2;
/// Padding around the dialog's own button, and the height of the caption
/// band above it.
const dialog_pad: f32 = 14;
const dialog_caption_height: f32 = 22;
/// The dialog's caption. It is the panel's own text: the panel frames the
/// button the tree published as the dialog node, and the caption says what
/// that panel is.
const dialog_caption = "W21 dialog owns input";

/// The layers the app-owned overlays paint on. A widget's own layer is a
/// small layout number, so this whole band is above every tree node: a caret
/// can never end up behind a button, and the dialog's frame never hides the
/// button the tree really drew. The order inside the band is the order a
/// modal needs: content, then the scrim that dims it, then the dialog.
const overlay_layer: u32 = 1 << 24;
const row_layer: u32 = overlay_layer + 1;
const row_glyph_layer: u32 = overlay_layer + 2;
const selection_layer: u32 = overlay_layer + 3;
const field_glyph_layer: u32 = overlay_layer + 4;
const scrim_layer: u32 = overlay_layer + 5;
const dialog_layer: u32 = overlay_layer + 6;
const caret_layer: u32 = overlay_layer + 7;
/// The dialog's own caption, above the frame it is written in.
const caption_layer: u32 = overlay_layer + 8;

const c_field_text: [4]f32 = .{ 0.95, 0.96, 1.0, 1 };
const c_placeholder: [4]f32 = .{ 0.55, 0.60, 0.70, 1 };
const c_selection: [4]f32 = .{ 0.24, 0.42, 0.72, 0.90 };
const c_caret: [4]f32 = .{ 1.0, 1.0, 1.0, 1 };
const c_row: [4]f32 = .{ 0.86, 0.88, 0.94, 1 };
const c_row_selected: [4]f32 = .{ 0.20, 0.38, 0.66, 1 };
const c_row_even: [4]f32 = .{ 0.74, 0.78, 0.86, 1 };
const c_scrim: [4]f32 = .{ 0.04, 0.05, 0.07, 0.72 };
const c_dialog: [4]f32 = .{ 0.32, 0.56, 0.92, 1 };
const c_dialog_text: [4]f32 = .{ 0.93, 0.95, 1.0, 1 };

const key_activate = "w21-activate";
const key_check = "w21-checkbox";
const key_slider = "w21-slider";
const key_text = "w21-text";
const key_list = "w21-list";
const key_list_add = "w21-list-add";
const key_list_remove = "w21-list-remove";
const key_modal = "w21-modal";
const key_modal_confirm = "w21-modal-confirm";
const key_radio_group = "w21-radio-group";
const key_progress = "w21-progress";
const key_radio_a = "w21-radio-a";
const key_radio_b = "w21-radio-b";

/// Published names. The annotator matches on the label the widget actually
/// carries, never on the identity key: the two are deliberately different
/// strings, so a mismatch here cannot pass unnoticed.
const label_activate = "W21 Activate";
const label_check = "W21 Checkbox";
const label_slider = "W21 Slider";
const label_text = "W21 Text Field";
const label_list = "W21 List";
const label_list_add = "W21 List Add";
const label_list_remove = "W21 List Remove";
const label_modal = "W21 Modal Open";
const label_modal_confirm = "W21 Modal Confirm";
const label_radio_a = "W21 Radio A";
const label_radio_group = "W21 Radio Group";
const label_progress = "W21 Progress";
const label_radio_b = "W21 Radio B";
/// Deliberately negative IDs prove the signed native custom-action path.
const action_add_row: i32 = -1;
const action_remove_row: i32 = std.math.minInt(i32);
/// The accessible name the platform is given for this window, on every
/// published frame. One string, so the name a reader hears and the name an
/// explicit publication names are the same one.
const window_name = "W21 AT-SPI Smoke";

// ── The scene ───────────────────────────

/// The field's authored value, as bytes. Named so the buffer below and the
/// length beside it cannot disagree about what this text is.
const initial_text = "Grüße ✓";

/// The same bytes in a full-capacity buffer. A struct field default is a
/// value rather than a string literal, so the literal is copied into the
/// fixed-size buffer once here instead of at every use.
const initial_text_buffer: [96]u8 = blk: {
    var buffer: [96]u8 = @splat(0);
    @memcpy(buffer[0..initial_text.len], initial_text);
    break :blk buffer;
};

/// Every value a screen reader can move lives here, on the app's own view
/// component, reached only through the ordinary input seam. A replayed request
/// that did not travel `activate` / `set_number` / `set_text` / `select_row`
/// leaves these counters untouched.
pub const PanelView = struct {
    app: *App,

    /// Bumped by the button's own `on_click`, reached only when activation
    /// reached the widget.
    button_hits: u32 = 0,
    /// The checkbox's live value; the widget holds this exact pointer.
    checked: bool = false,
    /// The slider's live value; the widget holds this exact pointer.
    level: f32 = 25,
    /// The bounds BOTH the slider and the progress leaf are drawn against, and
    /// the only place they are written down. They live on the model so a
    /// published range can be compared with what the app holds rather than
    /// with a literal written a second time beside the assertion: the two
    /// controls sharing one number is the claim, and a range copied into a
    /// check would only agree with itself.
    level_min: f32 = 0,
    level_max: f32 = 100,
    /// The radio group's own selection, shared by every option drawn below.
    /// The widget holds this exact pointer and the core publishes each
    /// option's `selected` state from it, so the tree a reader sees is the
    /// value the keyboard, a pointer and a native action all write. A radio
    /// has no activation callback, so this pointer IS the readback: a click
    /// has no other counter to move.
    radio_choice: ?u32 = 1,
    /// The radio group's own keyed container, resolved during the draw from
    /// the identity the App bound to it. The annotator needs that identity
    /// to name the group's published node, and `semantics.nodeId` turns it
    /// into the node's id through the same public seam the core uses for
    /// every other node, so the relation points at a real published node
    /// instead of at a number this file made up.
    radio_group: ?WidgetId = null,
    /// The text field's live value. Only `text_buf[0..text_len]` is live.
    /// The default is deliberately not ASCII: a caret in bytes and a caret in
    /// characters are different numbers, and the native edge has to convert.
    text_buf: [96]u8 = initial_text_buffer,
    text_len: usize = initial_text.len,
    /// One UTF-8 byte length per character, so the run is addressable and
    /// `set_text_selection` is offered. Only `char_lengths[0..characters]`.
    char_lengths: [96]u8 = @splat(0),
    /// Characters in the live value, which is what the platform addresses.
    characters: usize = 0,
    /// Caret in bytes, republished with the run's selection.
    caret: usize = 0,
    /// Selection anchor in bytes. Equal to `caret` is a collapsed caret.
    anchor: usize = 0,
    /// The preedit an input method is composing, in the model's own bytes.
    /// Null when nothing is being composed. It is what a commit replaces and
    /// what a cancel restores, so without it a composition commit would
    /// append its own text a second time instead of replacing the preedit.
    /// An edit that does not replace the preedit carries this range through
    /// the buffer rather than dropping it: the manager owns the composition's
    /// lifetime and ends that record itself, on a replace, a commit or a
    /// cancel, and a mark this model threw away early would leave it
    /// composing over bytes nobody can point at.
    marked: ?ByteRange = null,
    /// Writes that reached the model through the TEXT path: a whole value, a
    /// selection-only request naming a position in the published run, a
    /// composition, or an erasure. A caret moved by a KEY is not one of
    /// those — it changes no byte, and the caret is reported on its own line
    /// precisely so a motion is observable without being counted as an edit.
    text_writes: u32 = 0,
    number_writes: u32 = 0,
    focus_writes: u32 = 0,

    /// Logical rows the list publishes. Large enough that the selected row is
    /// never materialized, so the published selection is the only row node a
    /// screen reader can ever see.
    rows: usize = 250_000,
    /// Position the app considers selected, published as `position_in_set` and
    /// as the one published row node.
    selected_row: usize = 40_000,
    row_picks: u32 = 0,
    rows_added: u32 = 0,
    rows_removed: u32 = 0,
    modal_open: bool = false,
    modal_confirms: u32 = 0,

    /// The keyed dialog carrier, so the focus rule can find it after commit.
    modal_node: FrameNodeId = .root,

    /// The two carriers whose CONTENT is not the tree's own paint: the text
    /// field's run and the list's rows. Their identities are the keyed nodes
    /// this component created, not a second record of any value: the native
    /// window resolves them to the box the layout gave them and paints inside
    /// it, and the published bounds come from the same node.
    field_node: FrameNodeId = .root,
    list_node: FrameNodeId = .root,
    /// The one text service the native window shapes the field with, reached
    /// through the view so the annotator and the painter read the SAME
    /// measurement. Null in the headless gate, which opens no window and
    /// links no font engine: there the run publishes its byte/character
    /// table and no advance, which is honest, because no glyph is painted.
    shaper: ?*Shaper = null,

    /// The registered model this field's text endpoint borrows, held STRONG
    /// here and WEAK by the endpoint. `main` creates it before the first
    /// frame and releases it while the App is still whole, so an endpoint can
    /// never outlive the borrow it edits through.
    field_model: ?nogui.Model(FieldModel) = null,

    pub fn text(self: *const PanelView) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    /// The window this list publishes AND paints this frame.
    ///
    /// The box is the carrier's own resolved border box, which is the value
    /// `semantics` resolves the list node's bounds from as well, so a row's
    /// published extent and the rectangle it is painted in are one geometry
    /// rather than two that happen to agree today.
    ///
    /// Annotation uses the resolved candidate tree; painting and action
    /// handling outside that hook use the committed tree.
    pub fn listWindow(self: *PanelView) ListWindow {
        const frame_tree = self.app.semantic_tree orelse self.app.tree_ptr;
        const box: Rect = if (frame_tree) |tree|
            nogui.widget.visualBorderRect(tree, self.list_node)
        else
            .{};
        return rowWindow(box, self.rows, self.selected_row);
    }

    /// The list this view publishes, carrying the window above as the core's
    /// own first row and visible count.
    ///
    /// Nothing is derived on the publish side: the core is told which row the
    /// box starts at and how many rows it shows, so it stages those rows and
    /// places each one where the painter put it, and it stages no row the
    /// window does not hold.
    fn listDescriptor(self: *PanelView) semantics.VirtualList {
        const window = self.listWindow();
        return .{
            .keys = .{ .context = self, .at = rowKey },
            .row_count = self.rows,
            .row_height = row_height,
            .selected_index = self.selected_row,
            .first_visible = window.first,
            .visible_rows = window.count,
            .name = rowName,
            .context = self,
        };
    }

    /// One UTF-8 byte length per character of `value`.
    ///
    /// The lengths are measured from the bytes, not assumed: a field that
    /// publishes the wrong table would make every platform offset wrong, and
    /// the platform has no way to check it.
    fn measureCharacters(self: *PanelView, value: []const u8) usize {
        const bounded = @min(value.len, self.char_lengths.len);
        var characters: usize = 0;
        var at: usize = 0;
        while (at < bounded) {
            const length = std.unicode.utf8ByteSequenceLength(value[at]) catch {
                // A truncated or invalid byte is its own single-byte unit, so
                // the table still covers the whole run.
                self.char_lengths[characters] = 1;
                characters += 1;
                at += 1;
                continue;
            };
            const step = @min(length, bounded - at);
            self.char_lengths[characters] = @intCast(step);
            characters += 1;
            at += step;
        }
        if (characters < self.char_lengths.len) self.char_lengths[characters] = 0;
        return characters;
    }

    /// The model's own value, written back through the ordinary text path.
    ///
    /// This is the AT-SPI edit path, and the REQUEST says which of two
    /// things it is. A null value is a selection-only: it carries a position
    /// and nothing else, so no character byte moves, no character table entry
    /// changes, and the preedit mark survives exactly as it survives a caret
    /// motion. A non-null value is the field's ENTIRE new contents — empty
    /// bytes, and bytes that borrow this model's own buffer because they ARE
    /// this model's own value, because the buffer becomes exactly them.
    ///
    /// What the two requests mean is never read off the bytes they carry:
    /// the same bytes at the same address through the same setter are a whole
    /// write here and were a position there, so only the request tells them
    /// apart.
    ///
    /// A whole value that lands while an input method is composing replaces
    /// the bytes that composition wrote, so that composition ends first
    /// through the manager's OWN cancel. The cancel restores what the preedit
    /// replaced and retires the record; a restore left behind by a superseded
    /// composition would otherwise put its bytes into whatever the field
    /// composed next.
    ///
    /// That cancel restores through THIS endpoint into THIS buffer, so a
    /// whole value that borrows those bytes is rewritten before it could be
    /// copied. `@memmove` covers a copy that overlaps itself; it cannot cover
    /// a restore that has already run, so the borrowed payload is held aside
    /// for exactly that case and handed on afterwards.
    fn setText(self: *PanelView, value: ?[]const u8, selection: semantics.TextSelection) bool {
        const next = value orelse {
            // The core bounded both endpoints against the run it published,
            // and this clamps them against the bytes the model holds now: a
            // selection computed before the model grew is exactly how this
            // arrives.
            self.select(selection.anchor, selection.focus);
            self.text_writes += 1;
            return true;
        };
        // A bounded field REFUSES a whole value it cannot store instead of
        // storing the part that fits. `splice` clips to a whole character
        // because the ORDINARY keyboard path asks to type and typing into a
        // full field stops at its edge, but a screen reader's whole contents
        // are an exact request and half of them is a different value. The
        // refusal returns before any composition cancel, selection, copy or
        // model state moves, so an oversized request leaves the open preedit
        // and the published selection exactly as they were.
        if (next.len > self.text_buf.len) return false;
        return self.writeWholeText(next, selection);
    }

    /// The whole value the model takes, and the caret the request names.
    ///
    /// A null `selection` is this file's own ordinary whole write, which
    /// leaves the caret collapsed after the last byte written. The public
    /// callback always supplies one: the core always knows it.
    fn writeWholeText(
        self: *PanelView,
        value: []const u8,
        selection: ?semantics.TextSelection,
    ) bool {
        // A payload borrowed from this model's own bytes cannot survive a
        // cancel that rewrites them, so it is held aside first — and only for
        // that case: a composition open AND the value inside the live bytes.
        // The stage is this model's own buffer size, which is the largest
        // whole value this write can store anyway, so the bound is the
        // model's and not a capacity invented here. Nothing is allocated and
        // a payload of the caller's own is handed on untouched.
        var staged: [model_text_bytes]u8 = undefined;
        var payload = value;
        if (self.marked != null and overlapsBuffer(self.text_buf[0..self.text_len], value)) {
            const held = @min(value.len, staged.len);
            @memcpy(staged[0..held], value[0..held]);
            payload = staged[0..held];
        }
        if (self.marked != null) {
            self.app.textInputManager().cancelComposition() catch |err| std.log.err(
                "W21: the composition did not cancel before an external text write: {s}",
                .{@errorName(err)},
            );
        }
        const written = self.splice(0, self.text_len, payload);
        if (selection) |sel| {
            self.select(sel.anchor, sel.focus);
        } else {
            self.select(written.end, written.end);
        }
        self.marked = null;
        self.text_writes += 1;
        return true;
    }

    /// Publish the model's byte selection.
    ///
    /// Both ends are clamped to the value: a selection that names a byte the
    /// model does not hold is a selection at the end, not a caret sitting in
    /// bytes nobody painted.
    fn select(self: *PanelView, anchor: usize, caret: usize) void {
        self.anchor = @min(anchor, self.text_len);
        self.caret = @min(caret, self.text_len);
    }

    /// Replace `[start, end)` in the model's own bytes with `value`, and
    /// report where the written bytes are.
    ///
    /// The buffer is the hard bound, and a value too long for it is cut back
    /// to a WHOLE character: half a codepoint is not text, and the next
    /// reader would have to reject the whole value because of it.
    ///
    /// `value` may BORROW this buffer, and a whole write is exactly that
    /// case: the run a publish committed is a slice of these very bytes, so
    /// a whole value can be the model's own value. A whole write replaces
    /// `[0, text_len)`, so `keep` is zero and the tail moves nothing before
    /// the written bytes land, and the copy is a `@memmove` because
    /// `@memcpy` is defined over regions that do not overlap. Every other
    /// caller passes bytes of its own — the manager's own storage, the host's
    /// preedit, or an empty string — and none of them is staged into a
    /// second buffer to get here.
    fn splice(self: *PanelView, start: usize, end: usize, value: []const u8) ByteRange {
        const low = @min(start, end);
        const high = @min(@max(start, end), self.text_len);
        const at = @min(low, self.text_len);
        const keep = self.text_len - high;
        var taken = @min(value.len, self.text_buf.len - (at + keep));
        while (taken > 0 and taken < value.len and !text_input.isUtf8Boundary(value, taken)) {
            taken -= 1;
        }
        if (keep != 0) {
            @memmove(self.text_buf[at + taken ..][0..keep], self.text_buf[high..][0..keep]);
        }
        if (taken != 0) @memmove(self.text_buf[at..][0..taken], value[0..taken]);
        self.text_len = at + taken + keep;
        self.characters = self.measureCharacters(self.text());
        return .{ .start = at, .end = at + taken };
    }

    /// UTF-16 code units before the byte offset `byte`, or null when the
    /// value is not valid UTF-8. Every offset the platform sends is
    /// translated through this one place, so a byte offset and a character
    /// index cannot be confused for one another anywhere else in this file.
    fn unitsBefore(self: *const PanelView, byte: usize) ?usize {
        return text_input.utf8ToUtf16(self.text(), @min(byte, self.text_len)) catch null;
    }

    /// The byte offset `units` addresses in this model's own value.
    fn bytesForUnits(self: *const PanelView, units: usize, snap: Snap) ?usize {
        return unitsToByte(self.text(), self.char_lengths[0..self.characters], units, snap);
    }

    /// The slice of the character table that describes `value[range.start ..
    /// range.end]`. A range INSIDE the written bytes has to be resolved
    /// against the bytes it names and not against the whole document.
    fn tableFor(self: *const PanelView, start: usize, end: usize) []const u8 {
        var byte: usize = 0;
        var index: usize = 0;
        while (index < self.characters and byte < start) : (index += 1) {
            byte += self.char_lengths[index];
        }
        const first = index;
        var stop = byte;
        while (index < self.characters and stop < end) : (index += 1) {
            stop += self.char_lengths[index];
        }
        return self.char_lengths[first..index];
    }

    /// The model's byte selection as the protocol's UTF-16 selection, with
    /// its direction kept: a selection whose anchor sits after its focus is
    /// reversed, and that is how the caret tells the fixed end from the
    /// moving one.
    fn selectionUnits(self: *const PanelView) Utf16Selection {
        const anchor = self.unitsBefore(self.anchor) orelse 0;
        const focus = self.unitsBefore(self.caret) orelse 0;
        return .{
            .range = if (anchor <= focus)
                .{ .start = anchor, .end = focus }
            else
                .{ .start = focus, .end = anchor },
            .reversed = anchor > focus,
        };
    }

    /// The marked preedit as a UTF-16 range, or null when nothing is being
    /// composed.
    fn markedUnits(self: *const PanelView) ?Utf16Range {
        const marked = self.marked orelse return null;
        const start = self.unitsBefore(marked.start) orelse return null;
        const end = self.unitsBefore(marked.end) orelse return null;
        return .{ .start = start, .end = end };
    }

    /// The byte range a replacement request names: its own UTF-16 range, else
    /// the marked preedit, else the selection.
    ///
    /// The marked range is what stops a composition commit from appending a
    /// SECOND copy of its own text, so it is consulted before the selection
    /// and never after it.
    fn targetRange(self: *const PanelView, range: ?Utf16Range) ByteRange {
        if (range) |units| {
            const low = @min(units.start, units.end);
            const high = @max(units.start, units.end);
            const start = self.bytesForUnits(low, .start) orelse 0;
            const end = self.bytesForUnits(high, .end) orelse self.text_len;
            return .{ .start = @min(start, end), .end = @max(start, end) };
        }
        if (self.marked) |marked| return marked;
        return .{ .start = @min(self.anchor, self.caret), .end = @max(self.anchor, self.caret) };
    }

    /// Replace the range the request names with `value`, and leave a
    /// collapsed caret after what was written: a replacement is a fresh
    /// insertion, and a selection that survived it would describe bytes that
    /// are no longer there.
    fn replaceUnits(self: *PanelView, range: ?Utf16Range, value: []const u8) void {
        const target = self.targetRange(range);
        const written = self.splice(target.start, target.end, value);
        self.select(written.end, written.end);
        self.marked = null;
        self.text_writes += 1;
    }

    /// Replace and mark the result as a preedit.
    ///
    /// The selection the composing input method asked for is expressed in the
    /// NEW text's own UTF-16 units, so it is resolved inside what was just
    /// written and nowhere else — which is what keeps a half-composed commit
    /// from landing past the preedit. With no selection the caret sits at the
    /// end of the preedit.
    fn replaceAndMarkUnits(
        self: *PanelView,
        range: ?Utf16Range,
        value: []const u8,
        inside: ?Utf16Range,
    ) void {
        const target = self.targetRange(range);
        const written = self.splice(target.start, target.end, value);
        self.marked = written;
        if (inside) |sel| {
            const preedit = self.text_buf[written.start..written.end];
            const table = self.tableFor(written.start, written.end);
            const from = unitsToByte(preedit, table, @min(sel.start, sel.end), .start) orelse 0;
            const to = unitsToByte(preedit, table, @max(sel.start, sel.end), .end) orelse preedit.len;
            self.select(written.start + from, written.start + to);
        } else {
            self.select(written.end, written.end);
        }
        self.text_writes += 1;
    }

    /// One character of the model's own table, in the direction asked for.
    ///
    /// That table is the platform's addressing unit as well, so a caret the
    /// platform can name and a caret that moves are the same step. The field
    /// holds no grapheme table of its own, so a combining sequence is one
    /// unit per character; that is stated here rather than left for a reader
    /// to discover from a caret that stopped between two marks.
    fn stepCharacter(self: *const PanelView, byte: usize, direction: text_input.Move.Direction) usize {
        const at = @min(byte, self.text_len);
        switch (direction) {
            .backward => {
                var index = self.characters;
                while (index > 0) {
                    index -= 1;
                    const start = self.charOffset(index);
                    if (start < at) return start;
                }
                return 0;
            },
            .forward => {
                var index: usize = 0;
                while (index < self.characters) : (index += 1) {
                    const start = self.charOffset(index);
                    const end = @min(start + self.char_lengths[index], self.text_len);
                    if (end > at) return end;
                }
                return self.text_len;
            },
        }
    }

    /// The byte offset character `index` starts at. The table is walked from
    /// the start because the model keeps no reverse index and a field is one
    /// short line; a second index would be a second answer to the same
    /// question.
    fn charOffset(self: *const PanelView, index: usize) usize {
        var byte: usize = 0;
        var at: usize = 0;
        while (at < index and at < self.characters) : (at += 1) {
            byte += self.char_lengths[at];
        }
        return byte;
    }

    /// One word, in the direction asked for: past the run of separators, then
    /// past the run of everything else. Every byte of a multibyte character
    /// is a non-separator, so the walk crosses a whole character or none of
    /// it and always stops on a boundary.
    fn stepWord(self: *const PanelView, byte: usize, direction: text_input.Move.Direction) usize {
        const value = self.text();
        const at = @min(byte, value.len);
        switch (direction) {
            .backward => {
                var index = at;
                while (index > 0 and isSeparator(value[index - 1])) index -= 1;
                while (index > 0 and !isSeparator(value[index - 1])) index -= 1;
                return index;
            },
            .forward => {
                var index = at;
                while (index < value.len and !isSeparator(value[index])) index += 1;
                while (index < value.len and isSeparator(value[index])) index += 1;
                return index;
            },
        }
    }

    /// Move the caret by the unit the request names, resolved against the
    /// model's own bytes.
    ///
    /// `Move.offset` is an absolute UTF-16 offset rather than a distance, so
    /// a cancelled composition puts the caret back where the composition began
    /// instead of stepping from wherever the cancel found it.
    fn moveCaret(self: *PanelView, request: text_input.Move) void {
        const direction = request.direction;
        const caret = if (request.offset) |units|
            self.bytesForUnits(units, .start) orelse self.text_len
        else switch (request.unit) {
            .grapheme => self.stepCharacter(self.caret, direction),
            .word => self.stepWord(self.caret, direction),
            .line, .document => switch (direction) {
                .backward => 0,
                .forward => self.text_len,
            },
        };
        self.select(if (request.extend) self.anchor else caret, caret);
        // The mark survives a motion. It is the range a commit replaces, and
        // a caret that walked into the middle of a preedit must not make the
        // commit append a second copy of that preedit's text; the manager
        // owns the preedit's lifetime and drops it on a commit or a cancel.
    }

    /// The marked preedit carried through an edit of `[low, high)`.
    ///
    /// What is left of the mark is what the next composition update has to
    /// replace, so a preedit the edit half removed keeps the half that
    /// survived rather than a range that names bytes which are gone.
    fn markThrough(self: *const PanelView, low: usize, high: usize) ?ByteRange {
        const marked = self.marked orelse return null;
        const start = offsetThrough(marked.start, low, high);
        const end = offsetThrough(marked.end, low, high);
        return .{ .start = @min(start, end), .end = @max(start, end) };
    }

    /// The deletion the protocol resolves: the selection when it has one,
    /// else the unit in the direction asked for. `extend` selects instead of
    /// deleting, which is what a shifted erase means and is the same motion a
    /// shifted arrow key makes.
    ///
    /// An erasure carries the preedit mark through the edit instead of
    /// dropping it. The core does not end a composition on this path — only a
    /// replacement does — so a mark cleared here would leave the manager
    /// composing over a model that no longer says where, and the preedit
    /// update that follows would append a SECOND copy of the composition at a
    /// collapsed caret. Carrying it is what makes that update replace the
    /// bytes the preedit still owns.
    fn erase(self: *PanelView, request: text_input.Erase) void {
        if (request.extend) {
            self.moveCaret(.{
                .unit = request.unit,
                .direction = if (request.backward) .backward else .forward,
                .extend = true,
            });
            return;
        }
        const low = @min(self.anchor, self.caret);
        const high = @max(self.anchor, self.caret);
        const range = if (high > low) ByteRange{ .start = low, .end = high } else blk: {
            const direction: text_input.Move.Direction =
                if (request.backward) .backward else .forward;
            const edge = switch (request.unit) {
                .grapheme => self.stepCharacter(self.caret, direction),
                .word => self.stepWord(self.caret, direction),
                .line, .document => if (request.backward) 0 else self.text_len,
            };
            break :blk ByteRange{ .start = @min(edge, self.caret), .end = @max(edge, self.caret) };
        };
        const marked = self.markThrough(range.start, range.end);
        const erased = self.splice(range.start, range.end, "");
        self.select(erased.start, erased.start);
        self.marked = marked;
        self.text_writes += 1;
    }

    /// The stable identity the App bound to the field's carrier, resolved
    /// from the committed tree. Null before a frame named it, which is exactly
    /// when there is no identity to bind an endpoint to.
    fn fieldWidgetId(self: *const PanelView) ?WidgetId {
        if (self.field_node == .root) return null;
        const tree = self.app.tree_ptr orelse return null;
        const node = tree.nodeConst(self.field_node) orelse return null;
        return node.widget_id;
    }

    /// Bind the field to the App's text endpoint, and let the App retire it.
    ///
    /// `App.registerTextEndpoint` accepts only the focused widget, so this
    /// runs where this app's own focus rule runs. Focus loss is the App's own
    /// `textInputManager().reconcile`: it drops the registration and stops
    /// native text input, so a field that takes the keyboard again has to
    /// bind itself again. That round trip is why this is a re-bind beside the
    /// focus rule and not a one-time publish beside the draw.
    fn rebindTextEndpoint(self: *PanelView, session: *Session) !void {
        const model = self.field_model orelse return;
        if (self.app.textInputManager().focusedId() != null) return;
        const current = self.app.focus_manager.current orelse return;
        const field = self.fieldWidgetId() orelse return;
        if (!current.eql(field)) return;
        const carrier = self.field_node;
        try session.update(FieldModel, model, carrier, struct {
            fn run(entry: *FieldModel, node: FrameNodeId) void {
                entry.carrier = node;
            }
        }.run);
        self.app.registerTextEndpoint(.{
            .id = field,
            .owner = model.weak().erase(),
            .ops = fieldOps(),
            .user = self,
            // The field's own policy, stated where it is bound: one line that
            // folds a newline to a space, editable, and with printable keys
            // NOT routed to an input method. That last part is what makes one
            // physical keypress insert exactly once — the key is ignored and
            // only the committed text the platform delivers reaches the
            // model.
            .policy = .{},
        });
    }

    /// The field starts with a real multi-byte value and a collapsed caret at
    /// the end, so the first publish already exercises the character
    /// conversion instead of an ASCII case where bytes and characters agree.
    pub fn init(self: *PanelView) void {
        self.characters = self.measureCharacters(self.text());
        self.caret = self.text_len;
        self.anchor = self.caret;
    }

    fn onActivate(self: *PanelView, _: usize) void {
        self.button_hits += 1;
    }

    fn onListAdd(self: *PanelView, _: usize) void {
        self.rows += 1;
        self.rows_added += 1;
    }

    fn onListRemove(self: *PanelView, _: usize) void {
        if (self.rows > 1) self.rows -= 1;
        self.rows_removed += 1;
    }

    fn onModalToggle(self: *PanelView, _: usize) void {
        self.modal_open = !self.modal_open;
    }

    fn onModalConfirm(self: *PanelView, _: usize) void {
        self.modal_confirms += 1;
    }

    pub fn draw(self: *PanelView, ctx: *nogui.DrawCtx) !void {
        _ = try ctx.column(.{ .gap = 10, .padding = 16 });
        _ = try ctx.label(.{ .text = "W21 AT-SPI smoke" });

        _ = try ctx.button(.{
            .key = @as(ComponentKey, .{ .static = key_activate }),
            .label = label_activate,
            .on_click_with_data = nogui.bind(PanelView.onActivate, 0),
            .height = 48,
            .fill = c_field,
            .color = c_text,
        });
        _ = try ctx.checkbox(.{
            .key = @as(ComponentKey, .{ .static = key_check }),
            .label = label_check,
            .value = &self.checked,
            .height = 32,
        });
        _ = try ctx.slider(.{
            .key = @as(ComponentKey, .{ .static = key_slider }),
            .label = label_slider,
            .value = &self.level,
            .min = self.level_min,
            .max = self.level_max,
            .height = 28,
        });

        // A REAL determinate progress leaf, bound to the SAME value the
        // slider owns, so a native set on the slider moves the progress the
        // very next frame publishes. Nothing here remaps its role: the core's
        // own progress policy publishes the indicator, its number and its
        // range from the widget, so what a reader announces is what the app
        // holds rather than a value this file wrote beside it.
        _ = try ctx.progress(.{
            .key = @as(ComponentKey, .{ .static = key_progress }),
            .label = label_progress,
            .value = self.level,
            .min = self.level_min,
            .max = self.level_max,
            .height = 20,
        });

        // Two options of one REAL radio group, sharing the view's own
        // `?u32`. The row is their common parent AND the group's own keyed
        // container: siblings are what the core's arrow-key traversal walks,
        // so Tab reaches the first option and Left/Right move between them
        // through the ordinary key seam rather than through anything this
        // file owns. Its bound identity is kept so the annotator can publish
        // the row as the real `radio_group` both options point at; a plain
        // row is decoration the built-in policy omits, so publication is
        // forced and only for the keyed row this scene owns.
        const group_row = try ctx.row(.{
            .key = @as(ComponentKey, .{ .static = key_radio_group }),
            .gap = 12,
        });
        self.radio_group = ctx.widgetIdOf(group_row);
        _ = try ctx.radio(.{
            .key = @as(ComponentKey, .{ .static = key_radio_a }),
            .label = label_radio_a,
            .selected = &self.radio_choice,
            .option = 1,
            .height = 28,
        });
        _ = try ctx.radio(.{
            .key = @as(ComponentKey, .{ .static = key_radio_b }),
            .label = label_radio_b,
            .selected = &self.radio_choice,
            .option = 2,
            .height = 28,
        });
        ctx.pop();

        // The core has no text-input widget kind, so the carrier is a real
        // keyed button whose published ROLE and TEXT come from the annotator.
        // The widget is real; only its semantic role is remapped. It is also
        // a REAL text consumer: while it holds the keyboard the App binds
        // this identity to the field's text endpoint, so a committed native
        // key and an AT-SPI edit reach the same bytes. Its node is kept
        // because the native window paints the run inside the box the layout
        // gave THIS node, the published bounds come from it too, and that
        // same box is the box the endpoint measures its caret in.
        self.field_node = try ctx.button(.{
            .key = @as(ComponentKey, .{ .static = key_text }),
            .label = label_text,
            .visual_label = "",
            .height = 40,
            .fill = c_field,
        });
        // The list's carrier is the same kind of carrier: a real node whose
        // published role and list payload come from the annotator. Its box is
        // tall enough for several rows of the list's own row pitch, so the
        // window the native window paints is a window a reader can see.
        self.list_node = try ctx.button(.{
            .key = @as(ComponentKey, .{ .static = key_list }),
            .label = label_list,
            .visual_label = "",
            .height = row_height * 5,
            .fill = c_list,
        });
        _ = try ctx.button(.{
            .key = @as(ComponentKey, .{ .static = key_list_add }),
            .label = label_list_add,
            .on_click_with_data = nogui.bind(PanelView.onListAdd, 0),
            .height = 36,
        });
        _ = try ctx.button(.{
            .key = @as(ComponentKey, .{ .static = key_list_remove }),
            .label = label_list_remove,
            .on_click_with_data = nogui.bind(PanelView.onListRemove, 0),
            .height = 36,
            // The app's own rule, and the reason the scene has a modal worth
            // publishing: a dialog owns input, so the list cannot be mutated
            // behind it. The control STAYS in the tree, so a screen reader
            // announces that it exists and is unavailable; the core publishes
            // it with no action, so it cannot be driven either way.
            .disabled = self.modal_open,
        });
        _ = try ctx.button(.{
            .key = @as(ComponentKey, .{ .static = key_modal }),
            .label = label_modal,
            .on_click_with_data = nogui.bind(PanelView.onModalToggle, 0),
            .height = 36,
        });

        if (self.modal_open) {
            self.modal_node = try ctx.button(.{
                .key = @as(ComponentKey, .{ .static = key_modal_confirm }),
                .label = label_modal_confirm,
                .on_click_with_data = nogui.bind(PanelView.onModalConfirm, 0),
                .height = 44,
                .fill = c_list,
                .color = c_text,
            });
        } else {
            self.modal_node = .root;
        }

        ctx.pop();
    }
};

// ── The focused text endpoint ─────────────────────
//
// The field is a REAL text consumer of the core's focused-text protocol, not
// a published role with nothing behind it: the App's own focus rule hands it
// the keyboard, the App binds this endpoint to that identity, and every op
// below edits the bytes `PanelView` already holds. A committed keypress from
// the platform and a `replace_selected_text` from AT-SPI therefore land in
// one buffer through one set of primitives.

/// The registered model this field's endpoint borrows.
///
/// The bytes themselves stay in `PanelView`, which the caller owns, so the
/// slices the annotator hands the publisher keep borrowing the caller's own
/// storage and the AT-SPI edit path keeps writing the same 96 bytes the
/// native path reads. This model owns the endpoint's own answer to "which
/// carrier am I bound to": `main` creates it before the first frame and
/// releases it while the App is still whole, and the endpoint holds only a
/// WEAK handle on it. While it is registered every borrow succeeds; once it
/// is released the next borrow fails as a lost model, which the core reports
/// as `error.EndpointReleased` and answers by dropping the registration
/// rather than editing bytes the caller is about to free.
const FieldModel = struct {
    /// The carrier node the endpoint was last bound under, written at every
    /// registration and printed by the run. The App already refuses an
    /// endpoint whose identity is not the focused widget; recording the
    /// carrier as well lets the report name the keyed node the live
    /// registration belongs to instead of only that one exists.
    carrier: FrameNodeId = .root,
};

/// The protocol vtable for this model.
///
/// Built once and shared by every registration: the vtable takes no receiver,
/// so the endpoint's own `user` pointer is what carries the view into each
/// handler, and a re-bind after a focus round trip costs no new table.
fn fieldOps() text_input.Ops {
    return text_input.Adapter(FieldModel).ops(.{
        .text = readFieldText,
        .selection = readFieldSelection,
        .marked = readFieldMarked,
        .move = moveFieldCaret,
        .erase = eraseFieldText,
        .replace = replaceFieldText,
        .replace_and_mark = replaceAndMarkFieldText,
        .unmark = unmarkFieldText,
        .caret = fieldCaretGeometry,
        .index_at = fieldIndexAt,
    });
}

/// The bytes a UTF-16 range names, copied out for the caller that owns them.
///
/// A range end that lands inside a surrogate pair has no byte of its own, so
/// it snaps outward to the character that pair belongs to and `served`
/// reports the range actually read. A range the value cannot address at all
/// answers null rather than a truncated read of the wrong bytes.
fn readFieldText(
    gpa: std.mem.Allocator,
    _: *const FieldModel,
    user: *anyopaque,
    range: Utf16Range,
    served: *Utf16Range,
) anyerror!?[]u8 {
    const view = viewOf(user);
    const low = @min(range.start, range.end);
    const high = @max(range.start, range.end);
    const start = view.bytesForUnits(low, .start) orelse return null;
    const end = view.bytesForUnits(high, .end) orelse return null;
    served.* = .{
        .start = view.unitsBefore(start) orelse low,
        .end = view.unitsBefore(end) orelse high,
    };
    const value = try gpa.dupe(u8, view.text_buf[start..end]);
    return value;
}

fn readFieldSelection(_: *const FieldModel, user: *anyopaque) anyerror!Utf16Selection {
    return viewOf(user).selectionUnits();
}

fn readFieldMarked(_: *const FieldModel, user: *anyopaque) anyerror!?Utf16Range {
    return viewOf(user).markedUnits();
}

/// Caret motion. No byte changes and no write is counted: the caret has its
/// own report line, so a key that only moves the caret stays visible without
/// being counted as an edit of the published text.
fn moveFieldCaret(_: *FieldModel, user: *anyopaque, request: text_input.Move) anyerror!Utf16Selection {
    const view = viewOf(user);
    view.moveCaret(request);
    return view.selectionUnits();
}

fn eraseFieldText(_: *FieldModel, user: *anyopaque, request: text_input.Erase) anyerror!void {
    viewOf(user).erase(request);
}

fn replaceFieldText(_: *FieldModel, user: *anyopaque, range: ?Utf16Range, value: []const u8) anyerror!void {
    viewOf(user).replaceUnits(range, value);
}

fn replaceAndMarkFieldText(
    _: *FieldModel,
    user: *anyopaque,
    range: ?Utf16Range,
    value: []const u8,
    inside: ?Utf16Range,
) anyerror!void {
    viewOf(user).replaceAndMarkUnits(range, value, inside);
}

/// Drop the preedit mark and keep its bytes. Nothing else changes: the mark
/// is not published, so an unmark moves no byte and no selection.
fn unmarkFieldText(_: *FieldModel, user: *anyopaque) anyerror!void {
    viewOf(user).marked = null;
}

/// The caret's box in window-logical coordinates, taken from the SAME layout
/// the painted caret and the published per-character advances come from, so
/// an input method anchors where the field really draws it. Null with no
/// window: a windowless run links no font engine and measures nothing, and a
/// fabricated rectangle would hang the platform's candidate window over
/// pixels that were never laid out.
fn fieldCaretGeometry(
    _: *FieldModel,
    user: *anyopaque,
    range: Utf16Range,
) anyerror!?text_input.Caret {
    const view = viewOf(user);
    const shaper = view.shaper orelse return null;
    const byte = view.bytesForUnits(range.end, .start) orelse return null;
    const rect = shaper.caretRect(byte) orelse return null;
    return .{ .area = .{
        .x = rect.x,
        .y = rect.y,
        .w = rect.w,
        .h = rect.h,
    }, .cursor = 0 };
}

/// The UTF-16 offset nearest a window point, from the model's own published
/// per-character advances, and nothing at all outside the field's run: a
/// press in empty space answers null rather than silently parking the caret
/// at offset zero.
fn fieldIndexAt(
    _: *FieldModel,
    user: *anyopaque,
    point: nogui.geometry.WindowPoint,
) anyerror!?usize {
    const view = viewOf(user);
    const shaper = view.shaper orelse return null;
    if (point.y < shaper.origin_y or point.y > shaper.origin_y + shaper.line_height) return null;
    if (shaper.characters == 0) return view.unitsBefore(0);
    var after: usize = 0;
    for (0..shaper.characters) |index| {
        if (point.x < shaper.characterX(index)) break;
        after = index + 1;
    }
    const byte = if (after == shaper.characters) view.text_len else shaper.offsets[after];
    return view.unitsBefore(byte);
}

// ── Virtualized row accessors ───────────

fn rowKey(context: *anyopaque, index: usize) u64 {
    _ = context;
    return @as(u64, index) + 1;
}

fn rowName(context: *anyopaque, key: u64, index: usize, buf: []u8) usize {
    _ = context;
    _ = key;
    const text = std.fmt.bufPrint(buf, "W21 row {d}", .{index + 1}) catch return 0;
    return text.len;
}

// ── The list's one window ─────────────────────

/// The rows a list shows, and the box they are drawn in.
///
/// ONE window per frame, decided from the carrier's own box and the app's
/// current selection and read by BOTH halves of this demo: the annotator
/// publishes it, the painter draws it. Two decisions — one for the pixels and
/// one for the platform — drift the moment either side moves alone, and a
/// screen reader is then told about rows nobody can see while the row the app
/// has selected is published with no extent at all.
pub const ListWindow = struct {
    box: Rect,
    /// Logical position of the row drawn at the top of the box.
    first: usize,
    /// How many rows the box shows.
    count: usize,

    pub fn end(self: ListWindow) usize {
        return self.first + self.count;
    }

    /// Whether `index` is one of the rows this window draws.
    pub fn holds(self: ListWindow, index: usize) bool {
        return index >= self.first and index < self.end();
    }

    /// The rectangle the row in `slot` is painted in, and the band its
    /// published extent is taken from: that row's own slice of the carrier's
    /// box, on the published pitch, inset sideways so the fill keeps a
    /// gutter and the glyphs a margin.
    pub fn rowRect(self: ListWindow, slot: usize) Rect {
        return .{
            .x = self.box.x + row_inset,
            .y = self.box.y + @as(f32, @floatFromInt(slot)) * row_height,
            .w = self.box.w - 2 * row_inset,
            .h = row_height,
        };
    }
};

/// The window the list shows, from the box the layout gave its carrier.
///
/// How many whole rows fit on the published row pitch IS the row count, with
/// no floor under it: a row the box cannot hold is a row nothing draws, so a
/// list collapsed to nothing publishes none rather than one nobody can see.
/// The shape caches bound that count from above, because a row nobody can
/// shape is a row nobody can paint, and a published window wider than the
/// painted one is exactly the drift this window exists to remove.
///
/// The window holds the selection, centred, and is clamped to the list, so a
/// selection at either end shows the end of the list and never past it.
fn rowWindow(box: Rect, rows: usize, selected: usize) ListWindow {
    const fit: usize = if (row_height > 0 and std.math.isFinite(row_height) and
        box.h > 0 and std.math.isFinite(box.h))
        @intFromFloat(@floor(box.h / row_height))
    else
        0;
    const count: usize = @min(fit, @min(rows, row_slots));
    const last_first: usize = if (rows > count) rows - count else 0;
    const centred: usize = if (selected > count / 2) selected - count / 2 else 0;
    // A window with no rows has no first row either. Publishing a position
    // the painter never drew is the one drift this window exists to remove,
    // and the core places a row published beside the window from it.
    const first: usize = if (count == 0) 0 else @min(centred, last_first);
    return .{ .box = box, .first = first, .count = count };
}

// ── Annotator ───────────────────────────

const custom_actions: [2]semantics.CustomAction = .{
    .{ .id = action_add_row, .name = "Add row" },
    .{ .id = action_remove_row, .name = "Remove row" },
};

/// The per-character geometry a `semantics.Text` borrows: one origin and one
/// advance per character, in the carrier node's own coordinate space and in
/// the model's byte-length order. One named type so the shaper that measures
/// it and the annotator that publishes it cannot drift apart.
const PublishedGeometry = struct {
    positions: []const f32,
    widths: []const f32,
};

/// Turns the scene's real widget nodes into the semantic nodes the gate names.
/// It only remaps roles and fills in payloads the core does not carry; it
/// never invents a value the app does not hold.
fn annotate(
    context: *anyopaque,
    node: *const nogui.widget.WidgetNode,
    draft: *semantics.Draft,
) !void {
    const self: *PanelView = @ptrCast(@alignCast(context));
    const button = switch (node.kind) {
        .button => |value| value,
        else => {
            // The radio group's own container is a KEYED row, which the
            // built-in policy omits because a plain row is decoration. It is
            // published here as the real `radio_group` its options point at,
            // recognized by the identity the App bound to THIS row rather
            // than by a label a row does not carry. Publication is forced, so
            // it needs exactly the stable owner the key gave it.
            if (self.radio_group) |group| {
                if (node.widget_id) |owner| {
                    if (owner.eql(group)) {
                        draft.publish = true;
                        draft.role = .radio_group;
                        draft.name = label_radio_group;
                        return;
                    }
                }
            }
            switch (node.kind) {
                .radio => {
                    // The relation is named through the PUBLIC identity seam,
                    // from the same bound owner the group node itself is
                    // published under, so it resolves against a node this tree
                    // really contains rather than against a number invented
                    // beside it.
                    if (self.radio_group) |group| {
                        draft.radio_group = semantics.nodeId(group, .self_node);
                    }
                },
                // A progress leaf needs nothing from here: the core's own
                // policy already publishes its role, its number and its range
                // from the widget, and remapping it would only be able to lose
                // one of the three.
                else => {},
            }
            return;
        },
    };
    if (std.mem.eql(u8, button.label, label_text)) {
        draft.role = .text_input;
        // The selection is in the app's own UTF-8 bytes and the character
        // table is measured from the value, so the platform's character
        // offsets are exact.
        //
        // The per-character ADVANCES come from the same text service the
        // native window rasterizes with, and they are published in the
        // carrier node's own coordinate space, which is what AccessKit asks
        // for. A windowless run has no service and paints no glyph, so it
        // publishes none: an absent advance is honest, a fabricated one
        // would put the screen reader's caret where nothing is drawn.
        var geometry: PublishedGeometry = .{
            .positions = &.{},
            .widths = &.{},
        };
        if (self.shaper) |shape| {
            const tree = self.app.semantic_tree orelse self.app.tree_ptr orelse
                return error.MissingSemanticTree;
            try shape.measure(
                self.text(),
                self.char_lengths[0..self.characters],
                nogui.widget.visualBorderRect(tree, self.field_node),
            );
            geometry = shape.published();
        }
        draft.text = .{
            .value = self.text(),
            .placeholder = "type here",
            .selection = .{ .anchor = self.anchor, .focus = self.caret },
            .character_lengths = self.char_lengths[0..self.characters],
            .character_positions = geometry.positions,
            .character_widths = geometry.widths,
        };
        // The field states its own policy, and `Draft.actions` REPLACES the
        // core's set rather than adding to it, so every action this node
        // answers has to be named here. `set_value` is the one a screen
        // reader's SetTextContents arrives on, with the field's whole new
        // characters as the payload; the core writes those bytes through the
        // same setter `replace_selected_text` uses, so a reader that writes
        // the whole value and one that writes a selection are two doors into
        // this one buffer. `click` is absent on purpose: this is a field, not
        // a button, and an activation it would ignore is not one to offer.
        var actions: semantics.ActionSet = .{};
        actions.enable(.focus);
        actions.enable(.blur);
        actions.enable(.replace_selected_text);
        actions.enable(.set_text_selection);
        actions.enable(.set_value);
        draft.actions = actions;
    } else if (std.mem.eql(u8, button.label, label_list)) {
        // The rows the painter draws, published as the rows a screen reader
        // can address: same window, same first row, same pitch, same count.
        // The app's selection is inside that window rather than beside it, so
        // the selected row is a node with the extent it is drawn at instead
        // of a row nobody can see.
        draft.list = self.listDescriptor();
        draft.name = label_list;
    } else if (std.mem.eql(u8, button.label, label_list_add)) {
        // A dialog owns input, so the list's mutator behind it leaves the
        // tree entirely. Suppressing publication is the stronger of the two
        // policies: an absent node cannot be activated at all, where a
        // disabled one is announced and refused.
        if (self.modal_open) {
            draft.publish = false;
            return;
        }
        draft.custom_actions = custom_actions[0..1];
    } else if (std.mem.eql(u8, button.label, label_list_remove)) {
        // The named action is published whether or not the dialog owns input,
        // and the platform decides what that means: AT-SPI has no `disabled`
        // state, so the pinned provider publishes a disabled node WITHOUT the
        // enabled/sensitive pair, without focus, and with none of its named
        // actions. A reader therefore still finds the control announced and
        // unavailable, and no action can be performed on it either way.
        draft.custom_actions = custom_actions[1..2];
    } else if (std.mem.eql(u8, button.label, label_modal_confirm)) {
        // Modality is authored, not inferred: the app says this subtree owns
        // input, and the core's modal state is what the platform flag maps
        // from. The focus rule in `Harness.advance` still moves the reader
        // into it.
        draft.role = .dialog;
        draft.modal = true;
    }
}

// ── Dispatcher ──────────────────────────

fn activate(context: *anyopaque, id: WidgetId) void {
    const self: *PanelView = @ptrCast(@alignCast(context));
    const tree = self.app.tree_ptr orelse return;
    self.app.activate(tree, id);
}

fn focusWidget(context: *anyopaque, id: ?WidgetId) void {
    const self: *PanelView = @ptrCast(@alignCast(context));
    const tree = self.app.tree_ptr orelse return;
    if (id) |target| {
        if (self.app.focus_manager.set(tree, target, self.app.focusObserver())) self.focus_writes += 1;
    } else {
        self.app.focus_manager.blur(self.app.focusObserver());
    }
}

fn setNumber(context: *anyopaque, id: WidgetId, value: f64) bool {
    const self: *PanelView = @ptrCast(@alignCast(context));
    const tree = self.app.tree_ptr orelse return false;
    const dense = tree.frameNode(id) orelse return false;
    const node = tree.nodeConst(dense) orelse return false;
    switch (node.kind) {
        .slider => |slider| {
            slider.value.* = @floatCast(value);
            self.number_writes += 1;
            return true;
        },
        else => return false,
    }
}

fn readNumber(context: *anyopaque, id: WidgetId) ?f64 {
    const self: *PanelView = @ptrCast(@alignCast(context));
    const tree = self.app.tree_ptr orelse return null;
    const dense = tree.frameNode(id) orelse return null;
    const node = tree.nodeConst(dense) orelse return null;
    return switch (node.kind) {
        .slider => |slider| @floatCast(slider.value.*),
        else => null,
    };
}

fn setText(
    context: *anyopaque,
    _: WidgetId,
    value: ?[]const u8,
    selection: semantics.TextSelection,
) bool {
    const self: *PanelView = @ptrCast(@alignCast(context));
    return self.setText(value, selection);
}

/// The model's LIVE value, selection and whole-value capacity.
///
/// The core composes an edit against this and nothing else, so it answers
/// from the bytes this view holds NOW rather than from the run the last
/// publication handed out: two requests replayed into one batch resolve in
/// order against the updated model. `capacity` is this buffer's real length,
/// the largest whole value a write can store, and not the unused tail room.
fn readText(context: *anyopaque, id: WidgetId) ?semantics.TextEditState {
    const self: *PanelView = @ptrCast(@alignCast(context));
    const tree = self.app.tree_ptr orelse return null;
    const dense = tree.frameNode(id) orelse return null;
    const node = tree.nodeConst(dense) orelse return null;
    // The identity is resolved against the COMMITTED tree, so a read asked
    // for some other control answers nothing rather than this field's bytes.
    switch (node.kind) {
        .button => |button| if (!std.mem.eql(u8, button.label, label_text)) return null,
        else => return null,
    }
    return .{
        .value = self.text(),
        // Both ends with their direction kept: a backwards selection has an
        // anchor AFTER its focus, and collapsing both ends into the span's
        // start would turn it into a caret somewhere it never was.
        .selection = .{ .anchor = self.anchor, .focus = self.caret },
        .capacity = self.text_buf.len,
    };
}

fn selectRow(context: *anyopaque, _: WidgetId, index: usize, _: u64) bool {
    const self: *PanelView = @ptrCast(@alignCast(context));
    self.selected_row = index;
    self.row_picks += 1;
    return true;
}

fn makeDispatcher(context: *anyopaque) semantics.Dispatcher {
    return .{
        .context = context,
        .activate = activate,
        .focus = focusWidget,
        .set_number = setNumber,
        .read_number = readNumber,
        .set_text = setText,
        .read_text = readText,
        .select_row = selectRow,
    };
}

// ── Reporting ───────────────────────────

const Reporter = struct {
    io: Io,
    buffer: [8192]u8 = @splat(0),

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }

    /// Emit bytes that are already formatted. Used for the per-node report
    /// lines, which are built in the harness's own buffer so a line can be
    /// hashed before it is decided to be worth printing.
    fn write(self: *Reporter, bytes: []const u8) !void {
        try Io.File.stdout().writeStreamingAll(self.io, bytes);
    }
};

fn deviceExtent(managed: managed_window_ptr) !noapi.Extent2D {
    const pixels = try managed.native.sdl.getSizeInPixels();
    return .{ .width = @intCast(pixels[0]), .height = @intCast(pixels[1]) };
}

/// The published node whose accessible name is exactly `name`, or null. Names
/// are unique in this scene by construction; a miss is a fact the caller has
/// to report, never a node to substitute.
fn nodeNamed(
    snapshot: *const semantics.Snapshot,
    name: []const u8,
) ?*const semantics.Node {
    for (snapshot.nodes) |*node| {
        if (std.mem.eql(u8, node.name, name)) return node;
    }
    return null;
}

/// The first published node standing for a virtualized row, or null. A list
/// publishes every row its viewport shows plus whichever row the app has
/// selected, so this is a row a user can really see and click.
fn rowNode(snapshot: *const semantics.Snapshot) ?*const semantics.Node {
    for (snapshot.nodes) |*node| {
        if (node.row != null) return node;
    }
    return null;
}

/// The published row node the list marks as its current selection, or null.
/// A list publishes every row its viewport shows, so this — not the first
/// row found — is what identifies the selection.
fn selectedRowNode(snapshot: *const semantics.Snapshot) ?*const semantics.Node {
    for (snapshot.nodes) |*node| {
        if (node.row == null or !node.states.selected) continue;
        return node;
    }
    return null;
}

/// How many row nodes the snapshot marks as selected. A list has one
/// selection, so a second mark would tell a screen reader two rows are the
/// current one.
fn selectedRowCount(snapshot: *const semantics.Snapshot) u32 {
    var marked: u32 = 0;
    for (snapshot.nodes) |node| {
        if (node.row == null or !node.states.selected) continue;
        marked += 1;
    }
    return marked;
}

/// The role name for a role byte the bridge received. A byte this core does
/// not name is reported as `?` rather than guessed at.
fn roleName(byte: u8) []const u8 {
    const role = std.enums.fromInt(semantics.Role, byte) orelse return "?";
    return @tagName(role);
}

/// The role byte the adapter published for `id`, or `unknown` when it
/// published none. A node with no published role must never compare equal to
/// a role the app authored, so absence maps to the wire value that means
/// "this core does not name it".
fn publishedRole(adapter: *const accessibility.Adapter, id: semantics.NodeId) u8 {
    return adapter.lastRole(id) orelse @backingInt(semantics.Role.unknown);
}

/// The accessible name the adapter's own LABEL buffer holds for `id`, or null
/// when the last update carried no such node.
///
/// The buffer is the bridge's own copy, so it answers "what may a screen reader
/// call this control", which the committed snapshot cannot: the core states a
/// name and the adapter converts it, and a conversion that dropped it would
/// leave the tree correct and every announcement nameless.
fn publishedName(
    adapter: *const accessibility.Adapter,
    id: semantics.NodeId,
) ?[]const u8 {
    return adapter.lastLabel(id);
}

/// The numeric range the adapter's own ABI node carries, read out of the very
/// buffer the bridge was handed rather than out of the committed snapshot.
///
/// `lastNumericValue` answers for the number, and the range is the other half
/// of what makes a number announceable: a percentage is a number divided by a
/// span, so an indicator whose bounds never crossed the bridge would be
/// announced with a value and no scale. Null means the node published no range
/// at all, which is a fact rather than a zero-to-zero span.
fn publishedNumericRange(
    adapter: *const accessibility.Adapter,
    id: semantics.NodeId,
) ?struct { min: f64, max: f64 } {
    for (adapter.tree.nodes.items) |node| {
        if (node.id != id) continue;
        if (!node.has_min_numeric_value or !node.has_max_numeric_value) return null;
        return .{ .min = node.min_numeric_value, .max = node.max_numeric_value };
    }
    return null;
}

/// Tolerance for a physical-pixel comparison. The core's logical bounds are
/// `f32` and the platform rectangle is `f64`, so the conversion is compared
/// as an engineering fact, not as bit equality.
fn near(got: f64, want: f64) bool {
    return @abs(got - want) <= 0.001;
}

/// State bit N of the node state bitmask, as the bridge defines it. Only the
/// bits this scene asserts are named; the layout lives in the adapter.
const state_disabled: u32 = 1 << 1;
const state_modal: u32 = 1 << 8;
const state_read_only: u32 = 1 << 10;

var exts_storage: [][*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_storage;
}

// ── The published model half ─────────────────────
//
// Everything the gate needs that does not depend on a window existing: the
// app, the view, the semantic publisher and the accessibility adapter. Both
// modes drive this exact half, so a fact asserted headlessly is a fact about
// the tree the native window publishes.

const Harness = struct {
    gpa: std.mem.Allocator,
    io: Io,
    session: *Session,
    app: *App,
    view: *PanelView,
    adapter: *accessibility.Adapter,
    /// Built once: the bridge hands the adapter a raw pointer, and `drain`
    /// borrows this address for the whole run. There is no honest default, so
    /// the field has none: a zeroed `Dispatcher` would carry null function
    /// pointers, and it is built in the literal that creates the harness.
    disp: semantics.Dispatcher,
    /// Owns the published snapshot the App commits on every frame it builds.
    /// Same rule as `disp`: it needs this run's allocator, and a zeroed
    /// `Publisher` would carry a null allocator vtable, so the field is
    /// built, not defaulted. `App.semantic_publication` borrows THIS address
    /// for the whole run, so the field must outlive every configured frame.
    publisher: semantics.Publisher,
    scratch_bytes: [scratch_bytes]u8 = @splat(0),
    /// The logical size of the last frame the App built, which is the surface
    /// that frame published. The App hands the publisher its own surface;
    /// this keeps it for the reports and for the native census.
    logical: semantics.Size = .{ .width = 0, .height = 0 },
    /// The factor the adapter was told to apply. Kept here as well, so a
    /// report never names a conversion factor the adapter does not hold.
    scale_x: f32 = 1,
    scale_y: f32 = 1,
    /// The generation the last publish carried, read from the snapshot the
    /// App committed rather than from a frame counter kept beside it.
    published_generation: u64 = 0,
    /// Nodes the last `publish` carried, which is the size of THAT UPDATE,
    /// not of the whole tree.
    carried: usize = 0,
    /// The model as this report last printed it. Every field is the model's
    /// own value, never a stand-in: a key is compared against THIS to decide
    /// whether the next pass has something new to say about it.
    last_reported: Report = .{},
    /// False until the complete first reading has been published. The first
    /// pass prints the WHOLE model, so every key a client later reads was
    /// observed once at its real value instead of being absent and guessed.
    model_baseline: bool = false,
    reported_state: accessibility.State = .unavailable,
    /// The formatted line for one published node. It is hashed before it is
    /// decided to be worth printing, so a steady tree is silent.
    line: [line_bytes]u8 = @splat(0),
    /// Per published slot, the node identity and line hash last emitted for
    /// it. Indexed by the node's slot in the snapshot, which the publisher
    /// only reuses after the next `stage`.
    seen: [node_slots]Seen = @splat(.{}),
    /// False once the App has been deinitialized. The window half must
    /// deinit it BEFORE the GPU device goes away, so ownership is tracked
    /// rather than assumed.
    app_live: bool = true,

    /// What one publish pass moved. `applied` is what the request ring
    /// replayed into the model; `refocused` says the app's own focus rule
    /// moved the keyboard, which the published tree carries only once the
    /// next App frame commits.
    const Advanced = struct {
        applied: usize = 0,
        refocused: bool = false,
    };

    const Seen = struct {
        id: semantics.NodeId = 0,
        hash: u64 = 0,
        live: bool = false,
    };

    const Report = struct {
        button_hits: u32 = 0,
        checked: bool = false,
        level: f32 = 0,
        radio_choice: ?u32 = null,
        /// The live text AS PRINTED, held as a copy in this report's own
        /// buffer. The view overwrites its buffer in place, so an alias here
        /// would compare the live bytes with themselves and no later text
        /// change would ever be reported.
        text: [model_text_bytes]u8 = @splat(0),
        text_len: usize = 0,
        caret: usize = 0,
        rows: usize = 0,
        selected_row: usize = 0,
        modal_open: bool = false,
        focus_writes: u32 = 0,
        number_writes: u32 = 0,
        text_writes: u32 = 0,
        row_picks: u32 = 0,
        rows_added: u32 = 0,
        rows_removed: u32 = 0,
        modal_confirms: u32 = 0,
    };

    fn scratch(self: *Harness) semantics.Scratch {
        // One buffer split in two: the row name and the composed edit never
        // need more than this together.
        return .{
            .row_name = self.scratch_bytes[0 .. scratch_bytes / 2],
            .text_value = self.scratch_bytes[scratch_bytes / 2 ..],
        };
    }

    /// Set the logical-to-physical factor, and remember what was set.
    fn setScale(self: *Harness, x: f32, y: f32) void {
        if (!(x > 0) or !std.math.isFinite(x)) return;
        if (!(y > 0) or !std.math.isFinite(y)) return;
        self.scale_x = x;
        self.scale_y = y;
        self.adapter.setScale(x, y);
    }

    /// One headless frame: build the tree, which publishes it inside the
    /// same transaction, then replay and republish what the bridge buffered.
    fn headlessFrame(self: *Harness, report: *Reporter, tick: u32) !Advanced {
        self.logical = headless_surface;
        // A frame the App cannot prepare publishes nothing at all: it aborts
        // its own attempt, so the committed snapshot is still the one the
        // last successful frame left here.
        _ = try self.app.frame(tick, headless_surface);
        return self.advance(report);
    }

    /// Republish the tree the App committed and replay whatever the bridge
    /// buffered. Order matters: drain FIRST, so a request that changed the
    /// model is in the same publish the next reader sees.
    ///
    /// The snapshot is the one the App committed when it built the frame this
    /// tree belongs to. Nothing is staged here: that App frame published it,
    /// and a frame it could not annotate never reached this point, so a
    /// refused publication cannot advance the live tree.
    ///
    /// Returns what this pass moved. A failure travels back to the caller and
    /// is REPORTED rather than raised, because a smoke that cannot publish
    /// has to say so instead of aborting on the way there.
    fn advance(self: *Harness, report: *Reporter) !Advanced {
        const tree = self.app.tree_ptr orelse return .{};
        // A modal takes focus the moment it opens. This is the app's rule, not
        // the adapter's: it runs whether or not a reader is attached. The App
        // publishes the keyboard it holds when a frame commits, so a rule
        // that runs between frames is published by the NEXT one, and the
        // caller asks for that frame rather than assuming it.
        var moved = false;
        if (self.view.modal_open and self.view.modal_node != .root) {
            if (tree.nodeConst(self.view.modal_node)) |node| {
                if (node.widget_id) |target| {
                    const current = self.app.focus_manager.current;
                    if (current == null or !current.?.eql(target)) {
                        moved = self.app.focus_manager.set(tree, target, self.app.focusObserver());
                    }
                }
            }
        }

        // With nothing focused, the text field takes focus. This is the app's
        // own rule, in the same place and for the same reason as the modal's:
        // it runs whether or not a reader is attached, it is why a reader
        // lands on the control with text in it, and it is what makes the
        // field's caret a real focus indicator rather than decoration. A
        // control that already owns focus keeps it, so a modal still wins.
        if (self.app.focus_manager.current == null and self.view.field_node != .root) {
            if (tree.nodeConst(self.view.field_node)) |node| {
                if (node.widget_id) |target| {
                    const focused = self.app.focus_manager.set(
                        tree,
                        target,
                        self.app.focusObserver(),
                    );
                    moved = moved or focused;
                }
            }
        }

        // The field that just took the keyboard is now a focused text
        // element, and it binds the App's text endpoint here for the same
        // reason it takes focus here: the App accepts an endpoint only for
        // the focused widget, so binding beside the rule is the only place
        // that can be right. Focus loss retires the registration through the
        // App's own reconcile, so this is a re-bind after every round trip
        // rather than a one-time publish. Native mode starts SDL text input
        // from inside that registration; headless mode has no native port to
        // start, and the registration is inert there rather than absent.
        try self.view.rebindTextEndpoint(self.session);

        const snapshot = self.publisher.snapshot() orelse {
            try report.emit("publish: the App has not published a frame yet\n", .{});
            return .{ .refocused = moved };
        };

        const applied = self.adapter.drain(
            snapshot,
            &self.disp,
            self.scratch(),
        );
        self.carried = self.adapter.publish(
            snapshot,
            .{ .focused = true },
        ) catch |err| {
            try report.emit("publish: adapter refused: {s}\n", .{@errorName(err)});
            return .{ .applied = applied, .refocused = moved };
        };
        self.published_generation = snapshot.generation;
        try self.reportModel(report, applied);
        try self.reportPublished(report, snapshot);
        return .{ .applied = applied, .refocused = moved };
    }

    fn reportModel(self: *Harness, report: *Reporter, applied: usize) !void {
        if (applied != 0) {
            try report.emit("drain: applied={d} dropped={d} pending={}\n", .{
                applied,
                self.adapter.droppedRequests(),
                self.adapter.hasPending(),
            });
        }
        const state = self.adapter.stateOf();
        if (state != self.reported_state) {
            self.reported_state = state;
            const capability = self.adapter.capability();
            try report.emit("adapter: linked={} state={s} adapter={} screen_reader={} bell={}\n", .{
                accessibility.linked,
                @tagName(state),
                capability.adapter,
                capability.screen_reader,
                capability.bell,
            });
        }
        const view = self.view;
        const last = &self.last_reported;
        if (!self.model_baseline) {
            // The COMPLETE first reading, published once, from the live view,
            // on the first pass that has a committed tree to read. Every line
            // after this one is a change only, so a key that never moves -
            // a counter still at zero, a flag still false - would otherwise
            // never be printed at all, and a client would have to decide
            // whether an absent key meant zero or meant nothing observed.
            // Nothing here is a template: every value on this line is what
            // the model holds at this pass, and the seed right below is that
            // same reading, so the next pass still reports only what moved.
            try report.emit("model: baseline button_hits={d} checked={} level={d:.2} " ++
                "radio_choice={?} text=\"{s}\" caret={d} text_writes={d} number_writes={d} " ++
                "focus_writes={d} rows={d} selected_row={d} row_picks={d} rows_added={d} " ++
                "rows_removed={d} modal_open={} modal_confirms={d}\n", .{
                view.button_hits,
                view.checked,
                view.level,
                view.radio_choice,
                view.text(),
                view.caret,
                view.text_writes,
                view.number_writes,
                view.focus_writes,
                view.rows,
                view.selected_row,
                view.row_picks,
                view.rows_added,
                view.rows_removed,
                view.modal_open,
                view.modal_confirms,
            });
            last.* = Report{
                .button_hits = view.button_hits,
                .checked = view.checked,
                .level = view.level,
                .radio_choice = view.radio_choice,
                .caret = view.caret,
                .rows = view.rows,
                .selected_row = view.selected_row,
                .modal_open = view.modal_open,
                .focus_writes = view.focus_writes,
                .number_writes = view.number_writes,
                .text_writes = view.text_writes,
                .row_picks = view.row_picks,
                .rows_added = view.rows_added,
                .rows_removed = view.rows_removed,
                .modal_confirms = view.modal_confirms,
            };
            setReportedText(last, view.text());
            self.model_baseline = true;
            return;
        }
        if (last.button_hits != view.button_hits) {
            try report.emit("model: button_hits={d}\n", .{view.button_hits});
            last.button_hits = view.button_hits;
        }
        if (last.checked != view.checked) {
            try report.emit("model: checked={}\n", .{view.checked});
            last.checked = view.checked;
        }
        if (last.level != view.level) {
            try report.emit("model: level={d:.2}\n", .{view.level});
            last.level = view.level;
        }
        if (last.radio_choice != view.radio_choice) {
            try report.emit("model: radio_choice={?}\n", .{view.radio_choice});
            last.radio_choice = view.radio_choice;
        }
        const text = view.text();
        if (!std.mem.eql(u8, reportedText(last), text)) {
            try report.emit("model: text=\"{s}\"\n", .{text});
            setReportedText(last, text);
        }
        // The caret and the write count are reported on their own. A
        // selection-only write leaves every character exactly where it was,
        // and a text block that printed only when the characters moved would
        // swallow that write whole: the model moved and the report said
        // nothing at all.
        if (last.caret != view.caret or last.text_writes != view.text_writes) {
            try report.emit("model: caret={d} text_writes={d}\n", .{ view.caret, view.text_writes });
            last.caret = view.caret;
            last.text_writes = view.text_writes;
        }
        if (last.rows != view.rows) {
            try report.emit("model: rows={d} rows_added={d} rows_removed={d}\n", .{
                view.rows,
                view.rows_added,
                view.rows_removed,
            });
            last.rows = view.rows;
        }
        if (last.selected_row != view.selected_row) {
            try report.emit("model: selected_row={d} row_picks={d}\n", .{
                view.selected_row,
                view.row_picks,
            });
            last.selected_row = view.selected_row;
        }
        if (last.modal_open != view.modal_open) {
            try report.emit("model: modal_open={}\n", .{view.modal_open});
            last.modal_open = view.modal_open;
        }
        if (last.focus_writes != view.focus_writes) {
            try report.emit("model: focus_writes={d}\n", .{view.focus_writes});
            last.focus_writes = view.focus_writes;
        }
        if (last.number_writes != view.number_writes) {
            try report.emit("model: number_writes={d}\n", .{view.number_writes});
            last.number_writes = view.number_writes;
        }
        if (last.row_picks != view.row_picks) {
            try report.emit("model: row_picks={d}\n", .{view.row_picks});
            last.row_picks = view.row_picks;
        }
        if (last.rows_added != view.rows_added) {
            try report.emit("model: rows_added={d}\n", .{view.rows_added});
            last.rows_added = view.rows_added;
        }
        if (last.rows_removed != view.rows_removed) {
            try report.emit("model: rows_removed={d}\n", .{view.rows_removed});
            last.rows_removed = view.rows_removed;
        }
        if (last.modal_confirms != view.modal_confirms) {
            try report.emit("model: modal_confirms={d}\n", .{view.modal_confirms});
            last.modal_confirms = view.modal_confirms;
        }
    }

    /// The text this report last printed, out of its OWN copy.
    fn reportedText(last: *const Report) []const u8 {
        return last.text[0..last.text_len];
    }

    /// Keep a COPY of the live text.
    ///
    /// The view overwrites its buffer in place, so a slice of it stored here
    /// would be compared against those same live bytes on the next pass and
    /// every text change after the first reading would look unchanged.
    fn setReportedText(last: *Report, value: []const u8) void {
        const bounded = @min(value.len, last.text.len);
        @memcpy(last.text[0..bounded], value[0..bounded]);
        last.text_len = bounded;
    }

    /// Report the tree the adapter handed the bridge, read back from the
    /// adapter's own buffers.
    ///
    /// A node is printed when THIS update carried it and its line changed, so
    /// a steady tree reports nothing and a change reports exactly once. Slots
    /// past `node_slots` cannot be diffed, so they are reported every publish
    /// and the overflow is announced rather than silently dropped.
    ///
    /// A node this update did NOT carry is not printed at all. Its descriptor
    /// is absent from the adapter's buffers, not empty in them, and formatting
    /// that absence as an unknown role, an empty name and a zero rectangle
    /// would state a clear the platform was never told about: identical to a
    /// name, a selection or a role that really was cleared. Silence is the
    /// honest form of "unchanged", so a control this update left alone keeps
    /// the last descriptor this report really printed for it, and a real clear
    /// is still carried and still printed. The `carried=` and `full=` fields
    /// above are the near-side record of what this update declared.
    fn reportPublished(
        self: *Harness,
        report: *Reporter,
        snapshot: *const semantics.Snapshot,
    ) !void {
        try report.emit("published: nodes={d} carried={d} full={} generation={d} focus={d}\n", .{
            snapshot.count(),
            self.carried,
            self.adapter.lastWasFullTree(),
            snapshot.generation,
            snapshot.focus,
        });
        var overflowed = false;
        for (snapshot.nodes, 0..) |*node, slot| {
            // Inclusion is the adapter's own answer, not this report's guess:
            // `lastRole` scans the node buffer the last update filled, so a
            // null means the update did NOT carry this node. Reading any other
            // field back for it would report the adapter saying it has none,
            // which is not what the platform was sent.
            const role = self.adapter.lastRole(node.id) orelse continue;
            const line = try self.nodeLine(node, role);
            const digest = std.hash.Wyhash.hash(0x57_32_31, line);
            if (slot < node_slots) {
                const seen = &self.seen[slot];
                if (seen.live and seen.id == node.id and seen.hash == digest) continue;
                seen.* = .{ .id = node.id, .hash = digest, .live = true };
            } else {
                overflowed = true;
            }
            try report.write(line);
        }
        if (overflowed) {
            try report.emit("published: report_table_overflow nodes>{d}\n", .{node_slots});
        }
    }

    /// One published node as the ADAPTER's buffers hold it. Every value is
    /// read back from the adapter, so the line describes what crossed the
    /// boundary rather than what the core intended to send.
    ///
    /// `role` is the role THIS update carried, already resolved by the
    /// caller. A node the update omitted never reaches here, so the readbacks
    /// below are answering about a node that really is in the buffer.
    fn nodeLine(self: *Harness, node: *const semantics.Node, role: u8) ![]const u8 {
        const id = node.id;
        const name = self.adapter.lastLabel(id) orelse "";
        // A published name is clamped before it reaches the line buffer, so an
        // unusually long name truncates the REPORT and says so. The published
        // tree is untouched: the name the bridge holds is the whole name.
        const shown = name[0..@min(name.len, report_name_bytes)];
        const ellipsis: []const u8 = if (shown.len == name.len) "" else "...";
        const rect = self.adapter.lastRect(id) orelse .{ 0, 0, 0, 0 };
        var writer: std.Io.Writer = .fixed(&self.line);
        try writer.print(
            "node: id={d} role={s} name=\"{s}{s}\" flags=0x{x} actions=0x{x} " ++
                "rect=[{d:.1},{d:.1},{d:.1},{d:.1}]",
            .{
                id,
                roleName(role),
                shown,
                ellipsis,
                self.adapter.lastFlags(id) orelse 0,
                self.adapter.lastActions(id) orelse 0,
                rect[0],
                rect[1],
                rect[2],
                rect[3],
            },
        );
        if (self.adapter.lastSetPosition(id)) |set| {
            try writer.print(" set={d}/{d}", .{ set.position, set.size });
        }
        if (self.adapter.lastMemberOf(id)) |list| {
            try writer.print(" member_of={d}", .{list});
        }
        if (self.adapter.lastCharacterLengths(id)) |lengths| {
            try writer.print(" characters={d}", .{lengths.len});
            if (self.adapter.lastTextSelection(id)) |sel| {
                try writer.print(" sel={d}..{d} cursor={d}", .{
                    sel.anchor,
                    sel.focus,
                    sel.cursor,
                });
            }
        }
        try writer.writeAll("\n");
        return writer.buffered();
    }

    /// The end-of-run model state, printed by both modes so the two runs are
    /// comparable line for line.
    fn reportSummary(self: *Harness, report: *Reporter) !void {
        const view = self.view;
        try report.emit("model: button_hits={d} checked={} level={d:.2} radio_choice={?} " ++
            "text=\"{s}\" text_writes={d} " ++
            "number_writes={d} focus_writes={d} rows={d} selected_row={d} row_picks={d} " ++
            "rows_added={d} rows_removed={d} modal_open={} modal_confirms={d}\n", .{
            view.button_hits,
            view.checked,
            view.level,
            view.radio_choice,
            view.text(),
            view.text_writes,
            view.number_writes,
            view.focus_writes,
            view.rows,
            view.selected_row,
            view.row_picks,
            view.rows_added,
            view.rows_removed,
            view.modal_open,
            view.modal_confirms,
        });
        try report.emit("published: generation={d} carried={d} nodes={d} scale={d:.3}x{d:.3}\n", .{
            self.published_generation,
            self.carried,
            if (self.publisher.snapshot()) |snapshot| snapshot.count() else 0,
            self.scale_x,
            self.scale_y,
        });
    }
};

// ── The painted half ───────────────────────
//
// Everything below is the native mode's own pixels, and none of it holds a
// value. Every label, value, selection and rectangle it draws is read out of
// the model and the committed tree at paint time, and every glyph it draws is
// shaped by the ONE text service the frame's own engine rasterizes with. A
// second copy of the model here would be a second answer to every question
// the AT-SPI tree answers, and this file has exactly one.

/// The field's one shaped measurement: the layout, the per-character
/// geometry the platform is given, and the caret box.
///
/// It holds the adapter's text service, which is the same service the engine
/// rasterizes with, and at most ONE layout of the field's current bytes,
/// rebuilt only when the bytes, the character table or the box they are laid
/// out in change. The painted glyphs, the selection boxes, the caret and the
/// published advances all read that one layout, so none of them can describe
/// text the model no longer holds.
const Shaper = struct {
    gpa: std.mem.Allocator,
    engine: *frame_api.TextEngine,
    layout: ?TextLayout = null,
    /// Exactly what the live layout describes, compared before the layout is
    /// reused.
    keyed: Key = .{},
    /// Where the run starts inside the carrier's box, in window coordinates.
    /// The run is centred vertically, so the glyphs and the caret share one
    /// line box.
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    line_height: f32 = 0,
    /// Visual lines in the live layout. One: the run is truncated to a single
    /// line, so no glyph can escape the carrier's box.
    lines: u32 = 0,
    /// One x per character RELATIVE TO THE CARRIER'S OWN ORIGIN, which is the
    /// coordinate space AccessKit asks for, and one advance per character.
    /// `characters` is the live length of both, and it is the model's own
    /// character count.
    positions: [text_slots]f32 = @splat(0),
    widths: [text_slots]f32 = @splat(0),
    /// The byte offset each character starts at, in the model's own bytes.
    /// The platform addresses the run in characters, so a caret index has to
    /// become a byte offset somewhere, and this is that one place.
    offsets: [text_slots]usize = @splat(0),
    characters: usize = 0,
    /// Characters the layout has no position of its own for. A combining
    /// sequence is ONE grapheme and several characters, and the extra
    /// characters share that grapheme's x with no advance. Counted and
    /// reported, never guessed away.
    shared: u32 = 0,
    /// The run is empty, so what the field shows is its placeholder.
    empty: bool = true,

    const Key = struct {
        value: [text_slots]u8 = @splat(0),
        lengths: [text_slots]u8 = @splat(0),
        box_x: f32 = 0,
        box_y: f32 = 0,
        box_w: f32 = 0,
        box_h: f32 = 0,

        fn describes(self: *const Key, value: []const u8, table: []const u8, box: Rect) bool {
            if (!std.mem.eql(u8, self.value[0..value.len], value)) return false;
            if (!std.mem.eql(u8, self.lengths[0..table.len], table)) return false;
            return self.box_x == box.x and self.box_y == box.y and
                self.box_w == box.w and self.box_h == box.h;
        }
    };

    fn init(gpa: std.mem.Allocator, engine: *frame_api.TextEngine) Shaper {
        return .{ .gpa = gpa, .engine = engine };
    }

    fn deinit(self: *Shaper) void {
        self.drop();
        self.* = undefined;
    }

    fn drop(self: *Shaper) void {
        if (self.layout) |*live| {
            live.deinit();
            self.layout = null;
        }
    }

    /// Lay the field's own bytes out in its carrier's box and measure the
    /// per-character geometry. The layout is reused when nothing it describes
    /// changed, so a steady run shapes nothing.
    fn measure(self: *Shaper, value: []const u8, table_full: []const u8, box: Rect) !void {
        if (value.len > text_slots) return error.RunTooLongForTheField;
        const table = table_full[0..@min(table_full.len, text_slots)];
        if (self.layout != null and self.keyed.describes(value, table, box)) return;
        self.drop();
        const fresh = try self.engine.service.layout(self.gpa, .{
            .content = value,
            .style = .{
                .font = .{ .family = "InterVariable", .size = ui_font_size },
                .foreground = if (value.len == 0) c_placeholder else c_field_text,
            },
            .paragraph = .{
                .wrap = .flow,
                .wrap_width = @max(box.w - 2 * field_inset, 8),
                // One line, cut with a real ellipsis: a run longer than the
                // field is truncated INSIDE the box and never spills past it.
                .max_lines = 1,
                .truncate = .{ .mode = .end, .suffix = "…" },
            },
        });
        self.layout = fresh;
        self.empty = value.len == 0;
        self.lines = @intCast(fresh.lines.len);
        const line = if (fresh.lines.len == 0) null else fresh.lines[0];
        self.line_height = if (line) |item| item.height else 0;
        self.origin_x = box.x + field_inset;
        self.origin_y = box.y + (box.h - self.line_height) / 2;
        self.characters = @min(table.len, text_slots);
        self.shared = 0;
        var byte_at: usize = 0;
        for (0..self.characters) |index| {
            self.offsets[index] = byte_at;
            if (fresh.byteToPosition(byte_at, .downstream)) |position| {
                self.positions[index] = position.x + field_inset;
            } else |_| {
                // One grapheme, several characters: the extra characters sit
                // on the grapheme's own x and advance nothing.
                self.positions[index] = if (index == 0)
                    field_inset
                else
                    self.positions[index - 1];
                self.shared += 1;
            }
            byte_at += table[index];
        }
        if (self.characters != 0) {
            const last = self.characters - 1;
            const tail = fresh.byteToPosition(value.len, .downstream) catch null;
            const end = if (tail) |item| item.x else fresh.width;
            const last_x = self.positions[last] - field_inset;
            self.widths[last] = @max(end - last_x, 0);
            for (0..last) |index| {
                self.widths[index] = @max(self.positions[index + 1] - self.positions[index], 0);
            }
        }
        self.keyed = .{
            .box_x = box.x,
            .box_y = box.y,
            .box_w = box.w,
            .box_h = box.h,
        };
        @memcpy(self.keyed.value[0..value.len], value);
        @memcpy(self.keyed.lengths[0..table.len], table);
    }

    /// The per-character geometry in the node's own coordinate space, ready
    /// for a `semantics.Text` to borrow. One entry per character, in the
    /// same order as the model's own byte-length table.
    fn published(self: *const Shaper) PublishedGeometry {
        return .{
            .positions = self.positions[0..self.characters],
            .widths = self.widths[0..self.characters],
        };
    }

    /// The x the PLATFORM would derive for the caret at `byte`, relative to
    /// the node's origin: the published position of the character that starts
    /// there, or the last character's own position plus its own advance when
    /// the caret sits behind the whole run. This is the number a screen reader
    /// or a magnifier computes from what this file published, and it is here
    /// so the run can print it next to the caret it actually painted.
    fn publishedCaretX(self: *const Shaper, byte: usize) ?f32 {
        if (self.characters == 0) return null;
        for (0..self.characters) |index| {
            if (self.offsets[index] >= byte) return self.positions[index];
        }
        const last = self.characters - 1;
        return self.positions[last] + self.widths[last];
    }

    /// The x character `index` is drawn at, in WINDOW coordinates.
    ///
    /// `positions` is relative to the CARRIER's own origin, which is the
    /// space the platform is given, so a pointer press in window coordinates
    /// has to cross that one conversion before it can be compared with a
    /// published position. Doing it here means the conversion exists once
    /// instead of at every place that reads an advance.
    fn characterX(self: *const Shaper, index: usize) f32 {
        return self.origin_x + self.positions[index] - field_inset;
    }

    /// The caret's box in window-logical coordinates, from the live layout.
    /// Null when the caret's byte is not in the visible run: a caret nobody
    /// can see is not painted as one, and the run says so.
    fn caretRect(self: *const Shaper, byte: usize) ?Rect {
        const live = self.layout orelse return null;
        if (self.line_height <= 0 or live.lines.len == 0) return null;
        const position = live.byteToPosition(@min(byte, live.content.len), .downstream) catch return null;
        const line = live.lines[@min(position.line, live.lines.len - 1)];
        return .{
            .x = self.origin_x + position.x,
            .y = self.origin_y + line.y,
            .w = caret_width,
            .h = @max(line.height, self.line_height),
        };
    }
};

/// Shaped runs for the app-owned text that is not the field: the list's
/// visible rows and the dialog's caption.
///
/// One cache, keyed on each run's own content, wrap width, size and colour, so
/// a steady selection and a steady caption shape nothing at all. The colour is
/// part of the key because a glyph is the colour its own runs were shaped
/// with, and two runs with the same bytes in different colours are two runs.
const RunCache = struct {
    /// One slot per paintable row plus one for the dialog's caption.
    const slots: usize = row_slots + 1;
    /// Longest run this cache holds. A row name and the caption both fit.
    const run_bytes: usize = 48;

    gpa: std.mem.Allocator,
    engine: *frame_api.TextEngine,
    // SAFETY: `live` gates every read, and a slot's layout is written before
    // its `live` flag is set.
    layouts: [slots]TextLayout = undefined,
    live: [slots]bool = @splat(false),
    keys: [slots]Key = @splat(.{}),

    const Key = struct {
        value: [run_bytes]u8 = @splat(0),
        len: usize = 0,
        wrap: f32 = 0,
        color: [4]u32 = .{ 0, 0, 0, 0 },

        fn describes(self: *const Key, content: []const u8, wrap: f32, color: [4]f32) bool {
            if (self.len != content.len) return false;
            if (!std.mem.eql(u8, self.value[0..content.len], content)) return false;
            if (self.wrap != wrap) return false;
            return std.meta.eql(self.color, @as([4]u32, @bitCast(color)));
        }
    };

    fn init(gpa: std.mem.Allocator, engine: *frame_api.TextEngine) RunCache {
        return .{ .gpa = gpa, .engine = engine };
    }

    fn deinit(self: *RunCache) void {
        for (0..slots) |slot| self.drop(slot);
        self.* = undefined;
    }

    fn drop(self: *RunCache, slot: usize) void {
        if (!self.live[slot]) return;
        self.layouts[slot].deinit();
        self.live[slot] = false;
    }

    /// The layout for `content` in `slot`, shaped only when that slot's key
    /// changed. Null when there is nothing to draw, which frees the slot.
    fn layout(
        self: *RunCache,
        slot: usize,
        content: []const u8,
        wrap: f32,
        color: [4]f32,
    ) !?*const TextLayout {
        if (slot >= slots) return error.CacheSlotOutOfRange;
        if (content.len > run_bytes) return error.RunTooLongForTheCache;
        if (content.len == 0) {
            self.drop(slot);
            return null;
        }
        if (self.live[slot] and self.keys[slot].describes(content, wrap, color)) {
            return &self.layouts[slot];
        }
        self.drop(slot);
        const fresh = try self.engine.service.layout(self.gpa, .{
            .content = content,
            .style = .{
                .font = .{ .family = "InterVariable", .size = ui_font_size },
                .foreground = color,
            },
            .paragraph = .{
                .wrap = .flow,
                .wrap_width = @max(wrap, 8),
                .max_lines = 1,
                .truncate = .{ .mode = .end, .suffix = "…" },
            },
        });
        self.layouts[slot] = fresh;
        self.live[slot] = true;
        self.keys[slot] = .{ .len = content.len, .wrap = wrap, .color = @bitCast(color) };
        @memcpy(self.keys[slot].value[0..content.len], content);
        return &self.layouts[slot];
    }
};

/// What one presented frame actually recorded. Every number is read back out
/// of the rects that went into the scene, so the report can name pixels
/// instead of the text it meant to draw.
const PaintStats = struct {
    /// Scene rects this frame's overlays added to the tree's own lowering.
    rects: u32 = 0,
    field_glyphs: u32 = 0,
    field_selection: u32 = 0,
    field_placeholder: bool = false,
    field_focused: bool = false,
    caret: bool = false,
    rows: u32 = 0,
    row_glyphs: u32 = 0,
    selected_painted: bool = false,
    scrim: u32 = 0,
    dialog: u32 = 0,
    /// Logical-space geometry, so a report can compare what was painted with
    /// what was published.
    box: Rect = .{},
    run: Rect = .{},
    caret_rect: Rect = .{},
    list: Rect = .{},
    first_row: usize = 0,
    selected_row: usize = 0,
    /// Which slot of the window's row names the selected row was shaped in, so
    /// a report can name the row it drew and not just the index it drew at.
    selected_slot: usize = 0,
    selected_rect: Rect = .{},
    dialog_rect: Rect = .{},
    characters: usize = 0,
    shared: u32 = 0,
    truncated: bool = false,
};

/// The overlays the tree's own paint does not carry.
///
/// It is called between `buildScene` and `recordScene`, so what it appends is
/// part of the SAME lowering the tree's paint is in and both passes rasterize
/// out of one scene list. It reads the model and the committed tree and
/// nothing else: there is no field state here, no list state here, and no
/// value that could survive the model changing without the next frame
/// noticing.
const Painter = struct {
    harness: *Harness,
    engine: *frame_api.TextEngine,
    shaper: *Shaper,
    runs: *RunCache,
    /// The row name each painted row was shaped from, kept so a report can
    /// name the row it drew rather than the index it drew at.
    // SAFETY: `row_name_len` bounds every read, and a name is copied in before
    // its length is stored.
    row_name: [row_slots][RunCache.run_bytes]u8 = undefined,
    row_name_len: [row_slots]usize = @splat(0),

    /// The caption's slot. Rows take the slots below it, so a row window can
    /// never displace the dialog's own text.
    const caption_slot: usize = row_slots;

    fn paint(
        self: *Painter,
        tree: *const nogui.widget.WidgetTree,
        rects: *std.ArrayList(SceneRect),
    ) !PaintStats {
        const first: usize = rects.items.len;
        var stats: PaintStats = .{};
        try self.paintField(tree, rects, &stats);
        try self.paintList(rects, &stats);
        if (self.harness.view.modal_open) try self.paintModal(tree, rects, &stats);
        // The lowering stamps the submission counter on the tree's own rects;
        // these join that same counter, so a tie on the layer key is broken by
        // the order they were actually appended in rather than by whatever the
        // caller left in the field.
        for (rects.items[first..], first..) |*rect, order| rect.order = @intCast(order);
        stats.rects = @intCast(rects.items.len - first);
        return stats;
    }

    /// The field's own content inside its carrier: the selection behind the
    /// run, the run's glyphs, and the caret while the field holds focus.
    fn paintField(
        self: *Painter,
        tree: *const nogui.widget.WidgetTree,
        rects: *std.ArrayList(SceneRect),
        stats: *PaintStats,
    ) !void {
        const view = self.harness.view;
        if (view.field_node == .root) return;
        const box = nogui.widget.visualBorderRect(tree, view.field_node);
        try self.shaper.measure(
            view.text(),
            view.char_lengths[0..view.characters],
            box,
        );
        const live = self.shaper.layout orelse return;
        stats.box = box;
        stats.characters = self.shaper.characters;
        stats.shared = self.shaper.shared;
        stats.field_placeholder = self.shaper.empty;
        // A truncated run is one whose shaped ink is WIDER than the box it was
        // laid out in: the layout cut it and dropped the overflow, and the
        // measured ink width is what says so. Metadata the layout happened to
        // carry is not the fact.
        stats.truncated = live.lines.len != 0 and live.inkWidth() > live.width + 0.01;
        stats.run = .{
            .x = self.shaper.origin_x,
            .y = self.shaper.origin_y,
            .w = live.width,
            .h = self.shaper.line_height,
        };
        stats.field_focused = self.focused(tree, view.field_node);

        // The selection, resolved ONCE and behind the glyphs it covers.
        const low = @min(view.anchor, view.caret);
        const high = @max(view.anchor, view.caret);
        if (high > low and high <= view.text_len) {
            const boxes = live.rangeBounds(self.harness.gpa, .{
                .start = low,
                .end = high,
            }) catch &.{};
            defer self.harness.gpa.free(boxes);
            for (boxes) |item| try self.solid(rects, selection_layer, .{
                .x = self.shaper.origin_x + item.x,
                .y = self.shaper.origin_y + item.y,
                .w = item.width,
                .h = item.height,
            }, c_selection);
            stats.field_selection = @intCast(boxes.len);
        }

        // The glyphs, from the one layout the caret and the published
        // advances were measured from.
        const before: u32 = @intCast(rects.items.len);
        try self.engine.emitLayout(
            &self.engine.service,
            &live,
            self.shaper.origin_x,
            self.shaper.origin_y,
            no_clip,
            field_glyph_layer,
            rects,
        );
        stats.field_glyphs = @as(u32, @intCast(rects.items.len)) - before;

        // The caret. It IS the focus indicator, so an unfocused field draws
        // none, and a caret outside the visible run is not drawn at all.
        if (stats.field_focused) {
            if (self.shaper.caretRect(view.caret)) |caret| {
                try self.solid(rects, caret_layer, caret, c_caret);
                stats.caret = true;
                stats.caret_rect = caret;
            }
        }
    }

    /// The list's window of virtual rows: the SAME window the annotator
    /// publishes, drawn at the row pitch the list publishes and named by the
    /// same accessor the published row node is named by, so the row a reader
    /// hears and the row a person sees are the same string.
    ///
    /// Each row is painted in its own slice of the carrier's box, which is
    /// also the extent the core publishes for that row, so a platform
    /// rectangle always contains the pixels it points at.
    fn paintList(
        self: *Painter,
        rects: *std.ArrayList(SceneRect),
        stats: *PaintStats,
    ) !void {
        const view = self.harness.view;
        if (view.list_node == .root or view.rows == 0) return;
        // The window belongs to the view, not to the painter: the annotator
        // publishes this exact range on the same frame, so the rows a screen
        // reader can address and the rows a person can see are one set.
        const window = view.listWindow();
        stats.list = window.box;
        stats.first_row = window.first;

        for (0..window.count) |slot| {
            const index = window.first + slot;
            const selected = index == view.selected_row;
            const row = window.rowRect(slot);
            try self.solid(rects, row_layer, row, if (selected)
                c_row_selected
            else if (slot % 2 == 0)
                c_row
            else
                c_row_even);
            stats.rows += 1;
            if (selected) {
                stats.selected_painted = true;
                stats.selected_row = index;
                stats.selected_rect = row;
                stats.selected_slot = slot;
            }

            const name_len = rowName(self, rowKey(self, index), index, &self.row_name[slot]);
            self.row_name_len[slot] = name_len;
            const content = self.row_name[slot][0..name_len];
            const wrap = row.w - 2 * row_inset;
            if (try self.runs.layout(slot, content, wrap, if (selected) c_dialog_text else c_field_text)) |live| {
                const before: u32 = @intCast(rects.items.len);
                try self.engine.emitLayout(
                    &self.engine.service,
                    live,
                    row.x + row_inset,
                    row.y + (row.h - lineHeight(live)) / 2,
                    no_clip,
                    row_glyph_layer,
                    rects,
                );
                stats.row_glyphs += @as(u32, @intCast(rects.items.len)) - before;
            }
        }
        // Rows that fell out of the window release their layouts rather than
        // holding shaped text the list can no longer show.
        for (window.count..row_slots) |slot| self.runs.drop(slot);
    }

    /// The authored modal's own pixels: a scrim over the two regions the
    /// dialog blocks, and a panel that frames the button the tree published
    /// as the dialog node.
    ///
    /// The button's fill and its label are the TREE's paint, at a layer below
    /// this whole band, so the panel is drawn as a frame AROUND that button
    /// rather than over it, and the caption sits in the frame's own band. The
    /// dialog is therefore visible without hiding the control the platform can
    /// actually drive.
    fn paintModal(
        self: *Painter,
        tree: *const nogui.widget.WidgetTree,
        rects: *std.ArrayList(SceneRect),
        stats: *PaintStats,
    ) !void {
        const view = self.harness.view;
        if (view.modal_node == .root) return;
        const button = nogui.widget.visualBorderRect(tree, view.modal_node);
        const panel: Rect = .{
            .x = button.x - dialog_pad,
            .y = button.y - dialog_pad - dialog_caption_height,
            .w = button.w + 2 * dialog_pad,
            .h = button.h + 2 * dialog_pad + dialog_caption_height,
        };
        stats.dialog_rect = panel;

        // The scrim: the list and the field are what the dialog blocks, so
        // those two regions are what it dims. The tree's own chrome stays lit.
        if (view.list_node != .root) {
            try self.solid(
                rects,
                scrim_layer,
                nogui.widget.visualBorderRect(tree, view.list_node),
                c_scrim,
            );
            stats.scrim += 1;
        }
        if (view.field_node != .root) {
            try self.solid(
                rects,
                scrim_layer,
                nogui.widget.visualBorderRect(tree, view.field_node),
                c_scrim,
            );
            stats.scrim += 1;
        }

        // The frame: top band (with the caption), then the two sides and the
        // bottom. Four bands, because the interior belongs to the tree.
        try self.solid(rects, dialog_layer, .{
            .x = panel.x,
            .y = panel.y,
            .w = panel.w,
            .h = dialog_pad + dialog_caption_height,
        }, c_dialog);
        try self.solid(rects, dialog_layer, .{
            .x = panel.x,
            .y = panel.y + dialog_pad + dialog_caption_height,
            .w = dialog_pad,
            .h = panel.h - dialog_pad - dialog_caption_height,
        }, c_dialog);
        try self.solid(rects, dialog_layer, .{
            .x = panel.x + panel.w - dialog_pad,
            .y = panel.y + dialog_pad + dialog_caption_height,
            .w = dialog_pad,
            .h = panel.h - dialog_pad - dialog_caption_height,
        }, c_dialog);
        try self.solid(rects, dialog_layer, .{
            .x = panel.x,
            .y = panel.y + panel.h - dialog_pad,
            .w = panel.w,
            .h = dialog_pad,
        }, c_dialog);
        stats.dialog = 4;

        if (try self.runs.layout(caption_slot, dialog_caption, panel.w - 2 * dialog_pad, c_dialog_text)) |live| {
            const text_y = panel.y + dialog_pad + (dialog_caption_height - lineHeight(live)) / 2;
            try self.engine.emitLayout(
                &self.engine.service,
                live,
                panel.x + dialog_pad,
                text_y,
                no_clip,
                caption_layer,
                rects,
            );
            stats.dialog += 1;
        }
    }

    /// Whether the committed tree gives keyboard focus to this node. Read from
    /// the App's own focus manager, so a caret means the field really holds
    /// focus and not that this run decided to draw one.
    fn focused(self: *const Painter, tree: *const nogui.widget.WidgetTree, id: FrameNodeId) bool {
        const current = self.harness.app.focus_manager.current orelse return false;
        const node = tree.nodeConst(id) orelse return false;
        const widget = node.widget_id orelse return false;
        return current.eql(widget);
    }

    /// One solid rect through the shared Oklab lowering, on this run's own
    /// allocator.
    fn solid(
        self: *Painter,
        out: *std.ArrayList(SceneRect),
        z: u32,
        box: Rect,
        color: [4]f32,
    ) !void {
        try appendSolid(self.harness.gpa, out, z, no_clip, box, color);
    }
};

/// The first line's height in a shaped run, or zero for a run with no line.
fn lineHeight(layout: *const TextLayout) f32 {
    if (layout.lines.len == 0) return 0;
    return layout.lines[0].height;
}

/// One solid scene rect, in the same Oklab space every authored fill lowers
/// into. A zero-area or non-finite box is dropped rather than submitted: the
/// renderer has no meaning for it and a NaN in the bag poisons the sort.
fn appendSolid(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(SceneRect),
    z: u32,
    clip: u32,
    box: Rect,
    color: [4]f32,
) !void {
    if (box.w <= 0 or box.h <= 0) return;
    if (!std.math.isFinite(box.x) or !std.math.isFinite(box.y) or
        !std.math.isFinite(box.w) or !std.math.isFinite(box.h)) return;
    try out.append(gpa, .{
        .dst = .{ box.x, box.y, box.w, box.h },
        .src = .{ 0, 0, 1, 1 },
        .corners = .{ 0, 0, 0, 0 },
        .color = srgbToOklab(color),
        .curve = .{ 0, 0, 0, 0 },
        .material_index = 0,
        .clip_id = clip,
        .z = z,
        .origin = .{ box.x, box.y },
    });
}

// ── The native window half ─────────────────────
//
// The device, the surface, the public frame adapter, the window that
// presents through them and the host loop. All of it exists only in
// `--native` mode: nothing about the published tree depends on it, and the
// headless gate reaches none of it.

/// A SPIR-V module read from the build's `shaders/` directory, the same five
/// the demo pipeline and the other smokes read. The bytes stay owned for as
/// long as the adapter needs them; `shaderCreate` copies the module.
const Spv = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !Spv {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) {
            gpa.free(bytes);
            return error.ShaderModuleMalformed;
        }
        return .{ .bytes = bytes, .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }

    fn deinit(self: *Spv, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// The native half of the run: the device, the surface that presents into the
/// real window, and the public frame adapter that owns the text engine, the
/// scene renderer and the Oklab-to-sRGB blit.
///
/// The App is attached to `adapter.gpuEndpoint()`, not to a device of this
/// file's own, so the endpoint the tree's paint is recorded through and the
/// engine the text is shaped with are the same objects.
///
/// TEARDOWN ORDER, which the caller owns and which is why this is one value
/// with one `deinit`: the App detaches from the endpoint, then this value
/// goes, then SDL quits. Quitting SDL unloads the Vulkan loader, and a live
/// device would then dispatch through an unmapped page.
const NativeHalf = struct {
    gpu: noapi.Gpu,
    /// The platform surface. The real window and this device both outlive it,
    /// and noapi owns nothing here but the platform handle, so releasing it
    /// releases the surface alone.
    surface: noapi.Surface,
    adapter: NativeFrame,
    quad_vert: Spv,
    quad_frag: Spv,
    sort_comp: Spv,
    fullscreen_vert: Spv,
    blit_oklab: Spv,

    fn init(
        self: *NativeHalf,
        gpa: std.mem.Allocator,
        io: Io,
        managed: managed_window_ptr,
    ) !void {
        self.* = .{
            // SAFETY: the GPU handle is installed below, before any use.
            .gpu = undefined,
            // SAFETY: the surface is created inside this same `init`.
            .surface = undefined,
            // SAFETY: the adapter owns the device before `init` returns.
            .adapter = undefined,
            // SAFETY: the module is compiled below, before the pipeline uses it.
            .quad_vert = undefined,
            // SAFETY: the fragment module is compiled the same way.
            .quad_frag = undefined,
            // SAFETY: the sort module is compiled with the others.
            .sort_comp = undefined,
            // SAFETY: the fullscreen module is compiled with the others.
            .fullscreen_vert = undefined,
            // SAFETY: the blit module is compiled with the others.
            .blit_oklab = undefined,
        };
        try sdl3.vulkan.loadLibrary(null);
        const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
        const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
        const exts = try gpa.dupe([*:0]const u8, sdl_exts);
        // The loader reads the extension list while the instance is built and
        // not after, so the storage is released as soon as `Gpu.init` returns,
        // on both the success and the failure path.
        exts_storage = exts;
        defer {
            gpa.free(exts);
            exts_storage = &.{};
        }
        self.gpu = try noapi.Gpu.init(.{
            // Three, not two: the renderer rings its per-frame paint buffers
            // over three slots, one per in-flight frame.
            .frames_in_flight = frame_api.scene.frames_in_flight,
            .app_name = "w21-atspi-smoke",
            .validation = false,
            .loader = .{
                .get_instance_proc_addr = @ptrCast(get_proc_addr),
                .get_instance_extensions = &getExts,
            },
            .io = io,
            .allocator = gpa,
        });
        errdefer self.gpu.deinit();
        // A platform call, so it can fail; the surface is refused rather than
        // built on an unmeasured size. noapi creates the platform surface
        // from the window and owns it on the success path and the failure
        // path alike, so this file never holds an SDL wrapper to destroy and
        // never sees a Vulkan handle.
        self.surface = try noapi.Surface.initSdl(
            &self.gpu,
            @ptrCast(managed.native.sdl.value),
            @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
            .{ .extent = try deviceExtent(managed) },
        );
        errdefer self.surface.deinit();
        self.quad_vert = try Spv.load(gpa, io, "shaders/quad_vert.spv");
        errdefer self.quad_vert.deinit(gpa);
        self.quad_frag = try Spv.load(gpa, io, "shaders/quad_frag.spv");
        errdefer self.quad_frag.deinit(gpa);
        self.sort_comp = try Spv.load(gpa, io, "shaders/sort_comp.spv");
        errdefer self.sort_comp.deinit(gpa);
        self.fullscreen_vert = try Spv.load(gpa, io, "shaders/fullscreen_vert.spv");
        errdefer self.fullscreen_vert.deinit(gpa);
        self.blit_oklab = try Spv.load(gpa, io, "shaders/blit_oklab.spv");
        errdefer self.blit_oklab.deinit(gpa);
        try self.adapter.init(.{
            .allocator = gpa,
            .gpu = &self.gpu,
            // The face every app-owned run is shaped with. It carries Latin;
            // a composition it cannot shape is painted as the layout's own
            // missing-glyph boxes, and the run reports the count rather than
            // calling that text.
            .fonts = &.{.{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") }},
            .shaders = .{
                .quad_vert = self.quad_vert.words,
                .quad_frag = self.quad_frag.words,
                .sort_comp = self.sort_comp.words,
                .fullscreen_vert = self.fullscreen_vert.words,
                .blit_oklab = self.blit_oklab.words,
            },
            .name = "w21_atspi_blit_oklab",
        });
    }

    /// The App must already have detached from `adapter.gpuEndpoint()`.
    fn deinit(self: *NativeHalf, gpa: std.mem.Allocator) void {
        self.adapter.deinit();
        self.surface.deinit();
        // After the surface: the swapchain lives on this device.
        self.gpu.deinit();
        self.blit_oklab.deinit(gpa);
        self.fullscreen_vert.deinit(gpa);
        self.sort_comp.deinit(gpa);
        self.quad_frag.deinit(gpa);
        self.quad_vert.deinit(gpa);
        self.* = undefined;
    }
};

const Window = struct {
    harness: *Harness,
    application: *Application,
    handle: contract.WindowHandle,
    /// The device, the surface and the public frame adapter. The adapter owns
    /// the text engine the App is attached to and the one this window shapes
    /// with, so there is no second engine in this run.
    native: *NativeHalf,
    /// The field's one shaped measurement and the cache for the list's rows
    /// and the dialog's caption. Both borrow the engine above.
    shaper: Shaper,
    runs: RunCache,
    painter: Painter,
    /// True once this struct owns the device, the surface and the two
    /// measurement caches. Ownership moves here only after every field of
    /// this struct is whole, so no outer guard has to know the half exists.
    live: bool = false,
    /// The frame adapter's accounting and the size it last presented at,
    /// copied out before the adapter goes. The closing report outlives the
    /// adapter, so it reads these rather than reaching into a released one.
    stats: NativeFrame.Stats = .{},
    target: noapi.Extent2D = .{ .width = 0, .height = 0 },
    /// How many times the GPU half was actually released: one after a real
    /// teardown and never two, so the closing report can show that the host
    /// hook ran before SDL destroyed the window.
    retirements: u32 = 0,
    tick: u32 = 1,
    frames_committed: u32 = 0,
    /// Acquires the swapchain refused, each one retried on the next attempt.
    retries: u32 = 0,
    host_running: bool = true,
    /// What the LAST PRESENTED frame recorded, and what was last reported, so
    /// a steady frame is silent and a changed one reports once.
    painted: PaintStats = .{},
    reported: PaintStats = .{},
    reported_once: bool = false,
    /// Whether this run drives its OWN synthetic request batches at all. Off,
    /// nothing inside this process moves the model, so every counter this run
    /// reports is then an external client's call and nothing else.
    synthetic: bool = true,
    /// Which batch of native requests this run has already driven: 0 none, 1
    /// the field and list batch, 2 the dialog batch. The host draws on demand,
    /// so the second batch waits for the first one to have reached the model.
    exercise_step: u8 = 0,
    exercise_at_ms: u64 = 0,

    /// The focused-text endpoint facts this window last reported, and whether
    /// it has reported any at all. Change-only, like the paint block beside
    /// it: a steady hold prints one line and every transition prints one more.
    reported_endpoint: EndpointState = .{},
    reported_endpoint_once: bool = false,

    /// What this window knows about its focused text endpoint at one moment:
    /// whether the App holds a registration, WHICH keyed node that
    /// registration is bound under, whether SDL is delivering text for THIS
    /// window, and what the host reported for the native binding.
    const EndpointState = struct {
        bound: bool = false,
        carrier: FrameNodeId = .root,
        sdl_active: bool = false,
        status: text_input.NativeStatus = .stopped,
    };

    /// This run's own window record, or null once the platform has retired
    /// it. Every caller here runs on the hold loop, where the host may close
    /// the window from inside a step.
    fn managedWindow(self: *Window) ?managed_window_ptr {
        return self.application.getWindow(self.handle) catch null;
    }

    /// One committed frame, one presented image, and every control the
    /// semantic tree describes painted into it.
    ///
    /// The App's own tree paint and the app-owned overlays are ONE event: the
    /// tree's paint is lowered first, the overlays join the SAME scene list
    /// between `buildScene` and `recordScene`, and the two passes rasterize
    /// out of one lowering into one command buffer. A swapchain that is out
    /// of date is not a failure: the frame is retried, bounded, so a driver
    /// that never settles fails the run instead of spinning.
    fn render(self: *Window) !bool {
        const managed = try self.application.getWindow(self.handle);
        const logical: nogui.geometry.WindowSize = .{
            .width = @floatFromInt(managed.observed.size.width),
            .height = @floatFromInt(managed.observed.size.height),
        };
        if (logical.width <= 0 or logical.height <= 0) return false;
        // The window's OWN observed scale, given to the frame's text engine
        // and to the semantic edge alike, so a glyph, a caret and a published
        // rectangle are one measurement at any device pixel ratio.
        const viewport: NativeFrame.Viewport = .{
            .logical = logical,
            .device = try deviceExtent(managed),
            .scale = try managed.observed.pixelScale(),
        };
        self.harness.logical = .{ .width = logical.width, .height = logical.height };
        self.harness.setScale(viewport.scale.x, viewport.scale.y);

        var attempts: u32 = 0;
        while (attempts < 8) : (attempts += 1) {
            // SAFETY: `beginFrame` fills it before this iteration reads it, and
            // a refused begin continues without ever reading it.
            var frame: NativeFrame.Frame = undefined;
            if (!try self.native.adapter.beginFrame(&self.native.surface, viewport, &frame)) {
                self.retries += 1;
                continue;
            }
            var recording = true;
            errdefer if (recording) self.native.adapter.cancelFrame(&frame) catch
                @panic("surface recording cancellation failed");

            const time_ms = sdl3.timer.getMillisecondsSinceInit();
            self.harness.app.dispatchRootFrame(time_ms);
            const out = try self.harness.app.frameWithGpuAtTime(
                self.tick,
                time_ms,
                .{ .width = logical.width, .height = logical.height },
                &frame.gpu_frame,
            );
            defer if (out.json) |json| self.harness.gpa.free(json);
            self.tick += 1;

            var frame_paint = try self.native.adapter.buildScene(.{}, &out);
            defer frame_paint.deinit();
            self.painted = try self.painter.paint(out.tree, &self.native.adapter.sceneScratch().rects);
            try self.native.adapter.recordScene(&self.native.surface, &frame, &out, &frame_paint);
            // `present` closes the recording itself, so the guard is dropped
            // BEFORE the call: a present that fails must propagate its own
            // error, not reach a cancellation of a recording that is gone.
            recording = false;
            try self.native.adapter.present(&self.native.surface, &frame);
            self.frames_committed += 1;
            managed.markPresented();
            return true;
        }
        return error.SwapchainNeverSettled;
    }

    fn onFrame(
        context: *anyopaque,
        _: *Application,
        _: managed_window_ptr,
        _: nogui.frame_demand.FrameDemand.Work,
    ) anyerror!bool {
        const self: *Window = @ptrCast(@alignCast(context));
        return self.render();
    }

    fn onQuitRequest(_: *anyopaque, _: *Application, _: Application.QuitToken) Application.QuitDecision {
        return .approve;
    }

    /// The host's own events handed to the App.
    ///
    /// The host routes NO input to an App by itself: it translates one SDL
    /// event, publishes it on this hook and moves on. A window that does not
    /// hand those events over paints a model no key, pointer or text event
    /// can reach, and a field that owns a text endpoint would then own an
    /// edit path nothing can drive. This is that handoff and nothing more:
    /// the events are the host's own translated ones, and they enter the App
    /// through `App.handle`, which is where every consumer of the core gets
    /// its input.
    fn onEvent(context: *anyopaque, _: *Application, value: Application.Event) anyerror!void {
        const self: *Window = @ptrCast(@alignCast(context));
        switch (value) {
            .window => |window_event| {
                if (!std.meta.eql(window_event.handle, self.handle)) return;
                const translated = window_event.translated orelse return;
                switch (translated) {
                    // A close is the host's own business: `dispatch` already
                    // retired the window through `closeWindow`, and `step`
                    // reports the shutdown on the way out.
                    .close => {},
                    .resize => |resize| {
                        _ = try self.harness.app.handle(resize.core);
                        self.invalidate();
                    },
                    .input => |input| {
                        _ = try self.harness.app.handle(input);
                        self.invalidate();
                    },
                    .key_down => |key| {
                        _ = try self.harness.app.handle(key.core);
                        self.invalidate();
                    },
                }
            },
            .drop, .display, .system_wake => {},
        }
    }

    /// Ask the host for the frame that repaints the tree this event changed.
    /// The host draws on demand, so without this the window keeps showing the
    /// pixels the model had before the input.
    fn invalidate(self: *Window) void {
        const managed = self.managedWindow() orelse return;
        managed.demand.invalidateLayout();
    }

    /// The one place this window's GPU resources go, in the order the frame
    /// module requires: the App leaves the endpoint first, then the adapter,
    /// then the surface, then the device its swapchain lived on.
    ///
    /// Idempotent, because a platform can retire this window at any moment —
    /// the host hook calls this while the window is still alive — and the
    /// caller calls it again on the way out. The second call is a no-op and
    /// never a double free.
    fn releaseNative(self: *Window) void {
        if (!self.live) return;
        self.live = false;
        // The field's endpoint stops owning the keyboard here, while the
        // window that would have to answer for it still exists: native text
        // input is switched off before the surface and the device go, so
        // nothing is left composing into a field nobody paints any more.
        self.harness.app.textInputManager().clear();
        // The closing report outlives the frame adapter, so its numbers are
        // copied out while the adapter is still whole.
        self.stats = self.native.adapter.stats;
        self.target = self.native.adapter.targetExtent();
        // The view shapes through the cache that goes next, so that borrow
        // ends before it does.
        self.harness.view.shaper = null;
        self.runs.deinit();
        self.shaper.deinit();
        self.harness.app.detachGpu();
        self.native.deinit(self.harness.gpa);
        self.retirements += 1;
    }

    /// The host is about to destroy this window. Everything that presents
    /// INTO it is retired here, while the window still exists, because a
    /// surface that outlives its window is exactly what this hook prevents.
    fn onBeforeClose(context: *anyopaque, _: managed_window_ptr) void {
        const self: *Window = @ptrCast(@alignCast(context));
        self.releaseNative();
    }

    /// The frame accounting as it stands: the live adapter's own numbers
    /// while it is live, and the copy taken at retirement once it is gone.
    fn frameStats(self: *Window) NativeFrame.Stats {
        return if (self.live) self.native.adapter.stats else self.stats;
    }

    /// The size the last presented frame targeted, from the same two places.
    fn frameTarget(self: *Window) noapi.Extent2D {
        return if (self.live) self.native.adapter.targetExtent() else self.target;
    }

    /// Republish and replay on the host loop, outside the draw callback. The
    /// host draws on demand, so this is the only place a request that arrived
    /// between frames is replayed and the result republished.
    fn pump(self: *Window, report: *Reporter) !void {
        const moved = try self.harness.advance(report);
        // SYNTHETIC requests, injected into the adapter's ring from inside
        // this process. Whatever they move moves the model, and the next App
        // frame publishes that tree and paints it; but they prove the drain
        // and dispatch half of the native path only, and no line they print
        // is evidence about the platform layer.
        //
        // The dialog opens in a SECOND batch, a moment after the first one
        // has reached the model and been painted, so the focused field's
        // caret and its selection band are real reported pixels before the
        // dialog takes that focus away.
        if (self.synthetic) {
            const now = sdl3.timer.getMillisecondsSinceInit();
            switch (self.exercise_step) {
                0 => if (self.frames_committed >= 2) {
                    self.exercise_step = 1;
                    self.exercise_at_ms = now + exercise_gap_ms;
                    try self.driveSyntheticRequests(report);
                },
                1 => if (now >= self.exercise_at_ms and self.harness.view.text_writes != 0) {
                    self.exercise_step = 2;
                    try self.openDialog(report);
                },
                else => {},
            }
        }
        try self.reportPainted(report);
        try self.reportEndpoint(report);
        if (moved.applied == 0 and !moved.refocused) return;
        // A request that reached the model changed the tree, and a focus rule
        // that moved the keyboard changed the published focus. A reader sees
        // either one only in the next App frame, so ask for it: without this
        // the reader keeps the pre-request snapshot and the window keeps the
        // pre-request pixels.
        const managed = try self.application.getWindow(self.handle);
        managed.demand.invalidateLayout();
    }

    /// SYNTHETIC requests, handed to the adapter's ring directly from inside
    /// this process. They exercise the drain and dispatch half of the native
    /// path and NOTHING ELSE: no C ABI call, no Rust bridge, no AT-SPI bus
    /// and no screen reader is involved. Whatever they prove about the
    /// platform layer has to come from a real client in a separate run, and
    /// this output must never be read as that evidence.
    ///
    /// They are SHAPED the way a real client shapes them: the selection's
    /// target is the field, and each endpoint names the text run its
    /// character offset is a position in, exactly as AT-SPI reports it. The
    /// offsets are characters, so only the model's own character table knows
    /// which bytes that lands on.
    ///
    /// Nothing here writes a model value. Each request travels the ordinary
    /// dispatch path, so whatever changes is the model's own change, and the
    /// frame that repaints afterwards and the tree that republishes after
    /// that are both reading that same model.
    fn driveSyntheticRequests(self: *Window, report: *Reporter) !void {
        const snapshot = self.harness.publisher.snapshot() orelse {
            try report.emit("synthetic: no committed snapshot to address yet\n", .{});
            return;
        };
        const field = nodeNamed(snapshot, label_text) orelse {
            try report.emit("synthetic: the field is not published yet\n", .{});
            return;
        };
        const run = field.text_run orelse {
            try report.emit(
                "synthetic: the field published no text run, so a platform " ++
                    "would offer it no text to read at all\n",
                .{},
            );
            return;
        };
        const list = nodeNamed(snapshot, label_list) orelse return;
        // The Selection action, addressed the way a platform addresses it:
        // on the one row node the list publishes as its current selection,
        // which is inside the window the painter drew.
        const row = selectedRowNode(snapshot) orelse return;
        const view = self.harness.view;
        // Characters 1..3 of a deliberately non-ASCII run: the bytes this
        // lands on are 1..4, and only the model's own character table knows
        // that.
        const focus: usize = @min(@max(@min(view.characters, 3), 1), view.characters);
        _ = self.harness.adapter.enqueueRequest(.{
            .id = field.id,
            .action = @backingInt(semantics.Action.set_text_selection),
            .data = .text_selection,
            .anchor_index = 1,
            .focus_index = focus,
            .anchor_node = run,
            .focus_node = run,
        });
        _ = self.harness.adapter.enqueueRequest(.{
            .id = row.id,
            .action = @backingInt(semantics.Action.click),
        });
        try report.emit(
            "synthetic: injected (no AT-SPI client) set_text_selection 1..{d} " ++
                "into run {d} of field {d}, and a click on row {d} (logical {d}) " ++
                "of list {d} (row_count={d} selected={d})\n",
            .{
                focus,
                run,
                field.id,
                row.id,
                row.row.?.index,
                list.id,
                view.rows,
                view.selected_row,
            },
        );
    }

    /// The second SYNTHETIC batch: the click that opens the authored dialog,
    /// injected into the ring exactly like the first one, so no part of this
    /// run is a real client. The dialog, its focus rule and its scrim are
    /// the app's own response to the click either way.
    fn openDialog(self: *Window, report: *Reporter) !void {
        const snapshot = self.harness.publisher.snapshot() orelse return;
        const modal = nodeNamed(snapshot, label_modal) orelse return;
        _ = self.harness.adapter.enqueueRequest(.{
            .id = modal.id,
            .action = @backingInt(semantics.Action.click),
        });
        try report.emit(
            "synthetic: injected (no AT-SPI client) a click on {d} \"{s}\"\n",
            .{ modal.id, label_modal },
        );
    }

    /// What the last presented frame recorded, and the arithmetic that ties
    /// it to what the platform was given. Printed when it changed, and once
    /// more at the end of the hold so a steady run still names its last frame.
    fn reportPainted(self: *Window, report: *Reporter) !void {
        const stats = self.painted;
        if (self.reported_once and std.meta.eql(self.reported, stats)) return;
        self.reported = stats;
        self.reported_once = true;
        const view = self.harness.view;
        try report.emit(
            "paint: rects={d} field_glyphs={d} field_selection={d} placeholder={} focused={} " ++
                "caret={} rows={d} row_glyphs={d} selected_painted={} scrim={d} dialog={d} " ++
                "truncated={} characters={d} shared={d} preedit=absent(no_composition_endpoint)\n",
            .{
                stats.rects,
                stats.field_glyphs,
                stats.field_selection,
                stats.field_placeholder,
                stats.field_focused,
                stats.caret,
                stats.rows,
                stats.row_glyphs,
                stats.selected_painted,
                stats.scrim,
                stats.dialog,
                stats.truncated,
                stats.characters,
                stats.shared,
            },
        );
        try report.emit(
            "paint: field box=[{d:.1},{d:.1} {d:.1}x{d:.1}] run_origin=({d:.1},{d:.1}) " ++
                "run=[{d:.1},{d:.1} {d:.1}x{d:.1}] caret_rect=[{d:.1},{d:.1} {d:.1}x{d:.1}]\n",
            .{
                stats.box.x,
                stats.box.y,
                stats.box.w,
                stats.box.h,
                stats.run.x,
                stats.run.y,
                stats.run.x,
                stats.run.y,
                stats.run.w,
                stats.run.h,
                stats.caret_rect.x,
                stats.caret_rect.y,
                stats.caret_rect.w,
                stats.caret_rect.h,
            },
        );
        try report.emit(
            "paint: list box=[{d:.1},{d:.1} {d:.1}x{d:.1}] first_row={d} rows={d} " ++
                "row_height={d:.1} selected_row={d} selected_rect=[{d:.1},{d:.1} {d:.1}x{d:.1}] " ++
                "row_name=\"{s}\" painted={} published_row={}\n",
            .{
                stats.list.x,
                stats.list.y,
                stats.list.w,
                stats.list.h,
                stats.first_row,
                stats.rows,
                row_height,
                stats.selected_row,
                stats.selected_rect.x,
                stats.selected_rect.y,
                stats.selected_rect.w,
                stats.selected_rect.h,
                self.painter.row_name[stats.selected_slot][0..self.painter.row_name_len[stats.selected_slot]],
                stats.selected_painted,
                stats.selected_painted and stats.selected_row == view.selected_row,
            },
        );
        if (view.modal_open) {
            try report.emit(
                "paint: dialog panel=[{d:.1},{d:.1} {d:.1}x{d:.1}] caption=\"{s}\" " ++
                    "dialog_node={d} rects={d}\n",
                .{
                    stats.dialog_rect.x,
                    stats.dialog_rect.y,
                    stats.dialog_rect.w,
                    stats.dialog_rect.h,
                    dialog_caption,
                    view.modal_node,
                    stats.dialog,
                },
            );
        }
        try self.reportAgreement(report);
    }

    /// What the focused text endpoint is and what the platform made of it,
    /// printed when any of it changed.
    ///
    /// This is the run naming the REAL native path it is driving: whether the
    /// App holds a registration for the field, WHICH keyed node that
    /// registration is bound under, whether SDL is delivering committed text
    /// for THIS window, what the host reported for the native binding, and
    /// the model's own byte and character counts the endpoint reads and
    /// writes. It says nothing about what an AT-SPI client saw — that is this
    /// process's near side of the bridge and never an echo of it.
    fn reportEndpoint(self: *Window, report: *Reporter) !void {
        const manager = self.harness.app.textInputManager();
        var carrier: FrameNodeId = .root;
        var bound = false;
        if (self.harness.view.field_model) |model| {
            // The model is registered for as long as this run holds it, so a
            // refusal here means the teardown arrived first and the
            // registration went with it: the line then reports no binding
            // rather than a carrier that nothing borrows any more.
            if (self.harness.session.read(FieldModel, model, &carrier, struct {
                fn run(entry: *const FieldModel, out: *FrameNodeId) void {
                    out.* = entry.carrier;
                }
            }.run)) {
                bound = manager.focusedId() != null;
            } else |_| {
                carrier = .root;
            }
        }
        const state: EndpointState = .{
            .bound = bound,
            .carrier = carrier,
            .sdl_active = if (self.managedWindow()) |managed| managed.native.textInputActive() else false,
            .status = manager.native_status,
        };
        if (self.reported_endpoint_once and std.meta.eql(self.reported_endpoint, state)) return;
        self.reported_endpoint = state;
        self.reported_endpoint_once = true;
        const view = self.harness.view;
        try report.emit(
            "text_input: bound={} carrier={d} native={s} sdl_active={} bytes={d} " ++
                "characters={d} marked={}\n",
            .{
                state.bound,
                state.carrier,
                @tagName(state.status),
                state.sdl_active,
                view.text_len,
                view.characters,
                view.marked != null,
            },
        );
    }

    /// The agreement line. The platform's caret is the published position of
    /// the character at the model's caret byte, taken relative to the node's
    /// OWN origin; the painted caret is the layout's own x. Both are printed
    /// with the node's published physical rectangle, so the reader can check
    /// that the two agree at the scale the adapter holds instead of taking it
    /// on trust.
    fn reportAgreement(self: *Window, report: *Reporter) !void {
        const stats = self.painted;
        const harness = self.harness;
        const view = harness.view;
        const snapshot = harness.publisher.snapshot();
        const field = if (snapshot) |live| nodeNamed(live, label_text) else null;
        const published_rect = if (field) |node| harness.adapter.lastRect(node.id) else null;
        const caret_byte = view.caret;
        const published_x = self.shaper.publishedCaretX(caret_byte);
        const derived: ?f32 = if (published_x) |x| stats.box.x + x else null;
        const painted_x: ?f32 = if (stats.caret) stats.caret_rect.x else null;
        const delta: ?f32 = if (derived) |a| if (painted_x) |b| @abs(a - b) else null else null;
        var buffer: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        const published_text = try optFloat(&writer, published_x);
        const derived_text = try optFloat(&writer, derived);
        const painted_text = try optFloat(&writer, painted_x);
        const delta_text = try optFloat(&writer, delta);
        try report.emit(
            "paint: agree field_published={} field_id={d} published_rect=[{d:.1},{d:.1} {d:.1}x{d:.1}] " ++
                "caret_byte={d} characters={d} published_x={s} node_origin+published_x={s} " ++
                "painted_caret_x={s} delta={s} scale={d:.3}x{d:.3}\n",
            .{
                field != null,
                if (field) |node| node.id else 0,
                if (published_rect) |rect| rect[0] else 0,
                if (published_rect) |rect| rect[1] else 0,
                if (published_rect) |rect| rect[2] else 0,
                if (published_rect) |rect| rect[3] else 0,
                caret_byte,
                view.characters,
                published_text,
                derived_text,
                painted_text,
                delta_text,
                harness.scale_x,
                harness.scale_y,
            },
        );

        // The list's window: the logical rows the last frame painted beside
        // the ones the platform was handed, and whether the selected row's
        // published extent really contains the pixels painted inside it. The
        // caret line above proves the same agreement for the field's origin;
        // this proves it for a virtualized list, where the two halves can
        // disagree about WHICH rows exist without either of them looking
        // wrong on its own.
        const list = if (snapshot) |live| nodeNamed(live, label_list) else null;
        const published_list = if (list) |node|
            (if (snapshot) |live| live.list(node.id) else null)
        else
            null;
        const selected = if (snapshot) |live| selectedRowNode(live) else null;
        const extent = if (selected) |node| node.bounds else Rect{};
        const first_text = try optIndex(&writer, if (published_list) |p| p.first_visible else null);
        const rows_text = try optIndex(&writer, if (published_list) |p| p.visible_rows else null);
        try report.emit(
            "paint: agree list_published={} list_id={d} box=[{d:.1},{d:.1} {d:.1}x{d:.1}] " ++
                "painted_first={d} painted_rows={d} published_first={s} published_rows={s} " ++
                "selected_logical={d} selected_extent=[{d:.1},{d:.1} {d:.1}x{d:.1}] " ++
                "painted_selected_rect=[{d:.1},{d:.1} {d:.1}x{d:.1}] contains_pixels={}\n",
            .{
                published_list != null,
                if (list) |node| node.id else 0,
                stats.list.x,
                stats.list.y,
                stats.list.w,
                stats.list.h,
                stats.first_row,
                stats.rows,
                first_text,
                rows_text,
                stats.selected_row,
                extent.x,
                extent.y,
                extent.w,
                extent.h,
                stats.selected_rect.x,
                stats.selected_rect.y,
                stats.selected_rect.w,
                stats.selected_rect.h,
                containsRect(extent, stats.selected_rect),
            },
        );
    }

    /// The rows this window PAINTED, against the rows the platform was
    /// GIVEN, measured once the hold is over.
    ///
    /// The headless gate compares the published rows with the window the
    /// painter would draw, because it can measure the box without a window.
    /// This is the other half of that claim, measured where both halves exist
    /// at once: the last presented frame and the last committed snapshot are
    /// read together and must name the same logical rows, the same carrier
    /// box, and a selected row whose published extent contains the pixels
    /// painted inside it.
    fn checkListAgreement(self: *Window, report: *Reporter, checks: *Checks) !void {
        const stats = self.painted;
        const view = self.harness.view;
        const snapshot = self.harness.publisher.snapshot();
        const container = if (snapshot) |live| nodeNamed(live, label_list) else null;
        const published = if (container) |node|
            (if (snapshot) |live| live.list(node.id) else null)
        else
            null;
        const selected = if (snapshot) |live| selectedRowNode(live) else null;
        const box = if (container) |node| node.bounds else Rect{};
        const extent = if (selected) |node| node.bounds else Rect{};
        const window = view.listWindow();
        const published_first: usize = if (published) |p| p.first_visible else 0;
        const published_rows: ?usize = if (published) |p| p.visible_rows else null;
        const selected_index: ?usize = if (selected) |node| node.row.?.index else null;
        try checks.expect(
            report,
            "native.list_window_is_published_and_painted",
            stats.rows != 0 and stats.selected_painted and published != null and
                published_first == stats.first_row and
                (published_rows orelse 0) == @as(usize, stats.rows) and
                stats.first_row == window.first and
                @as(usize, stats.rows) == window.count and
                box.x == stats.list.x and box.y == stats.list.y and
                box.w == stats.list.w and box.h == stats.list.h and
                selected_index != null and
                selected_index.? == stats.selected_row and
                containsRect(extent, stats.selected_rect),
            checks.note("painted first={d} rows={d} box=[{d:.1},{d:.1} {d:.1}x{d:.1}] " ++
                "selected={d} rect=[{d:.1},{d:.1} {d:.1}x{d:.1}] | published " ++
                "present={s} first={d} rows={d}/{s} box=[{d:.1},{d:.1} {d:.1}x{d:.1}] " ++
                "selected={s} extent=[{d:.1},{d:.1} {d:.1}x{d:.1}] | window first={d} " ++
                "rows={d} over {d} logical rows", .{
                stats.first_row,
                stats.rows,
                stats.list.x,
                stats.list.y,
                stats.list.w,
                stats.list.h,
                stats.selected_row,
                stats.selected_rect.x,
                stats.selected_rect.y,
                stats.selected_rect.w,
                stats.selected_rect.h,
                present(published),
                published_first,
                published_rows orelse 0,
                present(published_rows),
                box.x,
                box.y,
                box.w,
                box.h,
                present(selected_index),
                extent.x,
                extent.y,
                extent.w,
                extent.h,
                window.first,
                window.count,
                view.rows,
            }),
        );
    }

    /// Pixels the PRESENTED passes wrote, counted in the Oklab readback of
    /// this run's own target: a pixel is INKED when its Lab triple differs
    /// from the scene's clear colour by more than the antialiasing noise
    /// floor. This is readback of what the window showed, not a re-render and
    /// not a model read, and each region is counted inside the box the last
    /// frame painted.
    fn census(self: *Window, report: *Reporter) !void {
        const pixels = try self.native.adapter.readTarget();
        const extent = self.native.adapter.targetExtent();
        const stats = self.painted;
        const logical = self.harness.logical;
        if (logical.width <= 0 or logical.height <= 0) return;
        // `logical` is already f32 (widget.Size); only the device extent needs
        // converting before the device-to-logical factor is taken.
        const scale_x = @as(f32, @floatFromInt(extent.width)) / logical.width;
        const scale_y = @as(f32, @floatFromInt(extent.height)) / logical.height;
        var total: u32 = 0;
        var field: u32 = 0;
        var row: u32 = 0;
        var dialog: u32 = 0;
        for (0..extent.height) |y| {
            for (0..extent.width) |x| {
                const at = (y * extent.width + x) * 4;
                if (@abs(pixels[at] - frame_api.scene.oklab_clear[0]) < 0.004 and
                    @abs(pixels[at + 1] - frame_api.scene.oklab_clear[1]) < 0.004 and
                    @abs(pixels[at + 2] - frame_api.scene.oklab_clear[2]) < 0.004) continue;
                total += 1;
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                if (pixelInside(stats.box, px, py, scale_x, scale_y)) field += 1;
                if (pixelInside(stats.selected_rect, px, py, scale_x, scale_y)) row += 1;
                if (pixelInside(stats.dialog_rect, px, py, scale_x, scale_y)) dialog += 1;
            }
        }
        try report.emit(
            "pixels: extent={d}x{d} inked={d} field_box={d} selected_row_box={d} dialog_box={d}\n",
            .{ extent.width, extent.height, total, field, row, dialog },
        );
    }

    /// The same buffer `census` measured, written as a P6 PPM, so the pixels
    /// can be inspected without believing this binary's own report.
    fn writePpm(self: *Window, report: *Reporter, path: []const u8) !void {
        const pixels = try self.native.adapter.readTarget();
        try frame_api.writePpm(
            self.harness.gpa,
            report.io,
            path,
            pixels,
            self.native.adapter.targetExtent(),
        );
        try report.emit("pixels: wrote {s}\n", .{path});
    }
};

/// Whether a device pixel falls inside a logical box at the given scale.
fn pixelInside(box: Rect, px: f32, py: f32, scale_x: f32, scale_y: f32) bool {
    if (box.w <= 0 or box.h <= 0) return false;
    return px >= box.x * scale_x and px <= (box.x + box.w) * scale_x and
        py >= box.y * scale_y and py <= (box.y + box.h) * scale_y;
}

/// Whether `outer` contains `inner`, edge for edge. A published extent that
/// does not contain the pixels it points at puts a reader's cursor in empty
/// space, which is the one thing a target rectangle must never be. An inner
/// box with no extent is not contained by anything: there is nothing there.
fn containsRect(outer: Rect, inner: Rect) bool {
    if (inner.w <= 0 or inner.h <= 0) return false;
    return outer.x <= inner.x and outer.y <= inner.y and
        outer.x + outer.w >= inner.x + inner.w and
        outer.y + outer.h >= inner.y + inner.h;
}

/// One report number that may not exist, written into `writer`. A measurement
/// that is absent prints as `absent` and never as a zero a reviewer could
/// mistake for a real position.
fn optFloat(writer: *std.Io.Writer, value: ?f32) ![]const u8 {
    const before = writer.buffered().len;
    if (value) |item| {
        try writer.print("{d:.2}", .{item});
    } else {
        try writer.print("absent", .{});
    }
    return writer.buffered()[before..];
}

/// One report count that may not exist, written into `writer`. A count the
/// core left unset prints as `absent` and never as a zero a reviewer could
/// mistake for a real row count.
fn optIndex(writer: *std.Io.Writer, value: ?usize) ![]const u8 {
    const before = writer.buffered().len;
    if (value) |item| {
        try writer.print("{d}", .{item});
    } else {
        try writer.print("absent", .{});
    }
    return writer.buffered()[before..];
}

// ── Headless assertions ─────────────────────

/// The headless gate's own tally and evidence buffer. Every assertion reads
/// the adapter's buffers or the model's counters, so a passing check is
/// evidence about the boundary rather than a restatement of the value the
/// smoke just wrote.
const Checks = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    buffer: [512]u8 = @splat(0),

    /// One line of evidence, formatted into the checker's own buffer. The
    /// returned slice is valid until the next call.
    fn note(self: *Checks, comptime fmt: []const u8, args: anytype) []const u8 {
        var writer: std.Io.Writer = .fixed(&self.buffer);
        writer.print(fmt, args) catch return "detail did not fit the report buffer";
        return writer.buffered();
    }

    fn expect(
        self: *Checks,
        report: *Reporter,
        name: []const u8,
        ok: bool,
        detail: []const u8,
    ) !void {
        if (ok) self.passed += 1 else self.failed += 1;
        try report.emit("check: {s}={s} {s}\n", .{
            name,
            if (ok) "ok" else "FAIL",
            detail,
        });
    }
};

/// The node a check needs, or a hard stop. A missing node is an absent
/// SUBJECT, not a failed assertion: continuing would report on nothing.
fn requireNode(
    node: ?*const semantics.Node,
    name: []const u8,
) error{MissingSubjectNode}!*const semantics.Node {
    if (node) |found| return found;
    std.log.err("W21 headless gate: \"{s}\" is not in the published tree", .{name});
    return error.MissingSubjectNode;
}

/// The publisher's committed snapshot, or a hard stop. Every check runs
/// against the published tree, never against a staged one.
fn requireSnapshot(h: *Harness) error{MissingSubjectNode}!*const semantics.Snapshot {
    const snapshot = h.publisher.snapshot() orelse {
        std.log.err("W21 headless gate: the publisher has no committed snapshot", .{});
        return error.MissingSubjectNode;
    };
    return snapshot;
}

/// Node identities captured as VALUES across frames. The publisher
/// alternates two slots, so a snapshot pointer does not outlive the next
/// `stage`; a captured id does.
const Ids = struct {
    activate: semantics.NodeId = 0,
    check_box: semantics.NodeId = 0,
    slider: semantics.NodeId = 0,
    field: semantics.NodeId = 0,
    list: semantics.NodeId = 0,
    list_add: semantics.NodeId = 0,
    list_remove: semantics.NodeId = 0,
    modal: semantics.NodeId = 0,
    row: semantics.NodeId = 0,
    /// The radio group's published container, and the determinate progress
    /// leaf. Both are nodes an external client reads by name, so both are
    /// captured here with the rest.
    radio_group: semantics.NodeId = 0,
    radio_a: semantics.NodeId = 0,
    radio_b: semantics.NodeId = 0,
    progress: semantics.NodeId = 0,
    /// The field's published text run: the node a platform reads the
    /// characters through, and the node a selection's offsets are positions
    /// in.
    run: semantics.NodeId = 0,

    fn capture(snapshot: *const semantics.Snapshot) error{MissingSubjectNode}!Ids {
        return .{
            .activate = (try requireNode(nodeNamed(snapshot, label_activate), label_activate)).id,
            .check_box = (try requireNode(nodeNamed(snapshot, label_check), label_check)).id,
            .slider = (try requireNode(nodeNamed(snapshot, label_slider), label_slider)).id,
            .field = (try requireNode(nodeNamed(snapshot, label_text), label_text)).id,
            .list = (try requireNode(nodeNamed(snapshot, label_list), label_list)).id,
            .list_add = (try requireNode(nodeNamed(snapshot, label_list_add), label_list_add)).id,
            .list_remove = (try requireNode(nodeNamed(snapshot, label_list_remove), label_list_remove)).id,
            .radio_group = (try requireNode(nodeNamed(snapshot, label_radio_group), label_radio_group)).id,
            .radio_a = (try requireNode(nodeNamed(snapshot, label_radio_a), label_radio_a)).id,
            .radio_b = (try requireNode(nodeNamed(snapshot, label_radio_b), label_radio_b)).id,
            .progress = (try requireNode(nodeNamed(snapshot, label_progress), label_progress)).id,
            .modal = (try requireNode(nodeNamed(snapshot, label_modal), label_modal)).id,
            .row = (try requireNode(selectedRowNode(snapshot), "the published selected row")).id,
            .run = ((try requireNode(nodeNamed(snapshot, label_text), label_text)).text_run orelse
                return error.MissingSubjectNode),
        };
    }

    /// Every named control still resolves to the identity captured earlier.
    /// The selected row is deliberately excluded: a selection move is
    /// allowed to replace it, and only it.
    fn stableExceptRow(self: Ids, snapshot: *const semantics.Snapshot) bool {
        return nodeIs(snapshot, label_activate, self.activate) and
            nodeIs(snapshot, label_check, self.check_box) and
            nodeIs(snapshot, label_radio_group, self.radio_group) and
            nodeIs(snapshot, label_radio_a, self.radio_a) and
            nodeIs(snapshot, label_radio_b, self.radio_b) and
            nodeIs(snapshot, label_progress, self.progress) and
            nodeIs(snapshot, label_slider, self.slider) and
            nodeIs(snapshot, label_text, self.field) and
            nodeIs(snapshot, label_list, self.list) and
            nodeIs(snapshot, label_list_add, self.list_add) and
            nodeIs(snapshot, label_list_remove, self.list_remove) and
            nodeIs(snapshot, label_modal, self.modal);
    }
};

/// Whether the node published under `name` is exactly `id`.
fn nodeIs(snapshot: *const semantics.Snapshot, name: []const u8, id: semantics.NodeId) bool {
    const node = nodeNamed(snapshot, name) orelse return false;
    return node.id == id;
}

/// How many published radio options the snapshot marks SELECTED. A group has
/// one selection, so a second mark is what would tell a screen reader that two
/// options are the current one.
fn selectedRadioCount(snapshot: *const semantics.Snapshot) u32 {
    var marked: u32 = 0;
    for (snapshot.nodes) |node| {
        if (node.role != .radio_button or !node.states.selected) continue;
        marked += 1;
    }
    return marked;
}

/// How many published radio options the snapshot marks CHECKED.
///
/// COUNTED SEPARATELY from SELECTED on purpose. SELECTED is the state a list
/// or a tab uses; CHECKED is the state that tells a screen reader which radio
/// option is current. A group whose only mark is SELECTED is announced as two
/// radios with nothing chosen, so both counts are reported and both are
/// required to be one.
fn checkedRadioCount(snapshot: *const semantics.Snapshot) u32 {
    var marked: u32 = 0;
    for (snapshot.nodes) |node| {
        if (node.role != .radio_button or node.states.checked != .on) continue;
        marked += 1;
    }
    return marked;
}
// ── Assertions both modes share ───────────────
//
// The headless gate and the approved native run publish the same tree through
// the same adapter, so every fact below is a fact about the tree an external
// AT-SPI client reads. The native mode calls these only under
// `--require-accessibility-active`: a plain `--native` run is a frame proof
// and stays one, while the approved run asks for more and may fail when it
// does not get it.

/// A screen reader is attached. Checked by the approved native run only,
/// because an inactive adapter means the tree was published to nobody and a
/// run that pretends otherwise is exactly the false pass this gate exists to
/// avoid.
fn checkAdapterActive(
    h: *Harness,
    report: *Reporter,
    checks: *Checks,
) !void {
    const capability = h.adapter.capability();
    try checks.expect(
        report,
        "adapter.screen_reader_attached",
        h.adapter.stateOf() == .active,
        checks.note("state={s} adapter={} screen_reader={} bell={}", .{
            @tagName(h.adapter.stateOf()),
            capability.adapter,
            capability.screen_reader,
            capability.bell,
        }),
    );
}

/// Every published role, the radio group's relation, the radio options' real
/// CHECKED marks, and the progress leaf's announced NAME, its number, its
/// range and its empty action set.
///
/// Nothing here is compared against the value this run just wrote: the roles
/// and the flags come back out of the adapter's own buffers, the relations out
/// of the committed snapshot, and BOTH numbers come from the numeric ABI field
/// handed to the bridge. The progress leaf is compared against the MODEL's own
/// bounds and against the SLIDER it shares a value with, because agreeing with
/// the slider is internal consistency while agreeing with the model is the
/// claim, and a reader that announces the two can then never be told two
/// different things about one number.
fn checkPublishedTree(
    h: *Harness,
    report: *Reporter,
    checks: *Checks,
) !void {
    const snapshot = try requireSnapshot(h);
    const ids = try Ids.capture(snapshot);
    const view = h.view;

    // ── Roles, read back out of the adapter ──
    const wanted = [_]struct { id: semantics.NodeId, role: semantics.Role }{
        .{ .id = ids.activate, .role = .button },
        .{ .id = ids.check_box, .role = .check_box },
        .{ .id = ids.slider, .role = .slider },
        .{ .id = ids.radio_group, .role = .radio_group },
        .{ .id = ids.radio_a, .role = .radio_button },
        .{ .id = ids.radio_b, .role = .radio_button },
        .{ .id = ids.progress, .role = .progress_indicator },
        .{ .id = ids.field, .role = .text_input },
        .{ .id = ids.list, .role = .list_box },
        .{ .id = ids.run, .role = .text_run },
        .{ .id = ids.row, .role = .list_item },
    };
    var roles_ok = true;
    for (wanted) |entry| {
        const got = publishedRole(h.adapter, entry.id);
        const in_tree = (snapshot.node(entry.id) orelse continue).role;
        if (got != @backingInt(entry.role) or in_tree != entry.role) roles_ok = false;
        _ = try report.emit("published: role id={d} core={s} bridge={s}\n", .{
            entry.id,
            @tagName(in_tree),
            roleName(got),
        });
    }
    try checks.expect(
        report,
        "role.published",
        roles_ok,
        checks.note("core and bridge roles compared for {d} named nodes", .{wanted.len}),
    );

    // ── The radio group, and the CHECKED mark each option carries ──
    {
        const option_a = try requireNode(snapshot.node(ids.radio_a), label_radio_a);
        const option_b = try requireNode(snapshot.node(ids.radio_b), label_radio_b);
        const group = try requireNode(snapshot.node(ids.radio_group), label_radio_group);
        try checks.expect(
            report,
            "relation.radio_group",
            group.role == .radio_group and
                option_a.relations.radio_group == ids.radio_group and
                option_b.relations.radio_group == ids.radio_group and
                option_a.parent == ids.radio_group and option_b.parent == ids.radio_group,
            checks.note("group={d} a={d}->{d} parent={d} b={d}->{d} parent={d}", .{
                ids.radio_group,
                ids.radio_a,
                option_a.relations.radio_group orelse 0,
                option_a.parent,
                ids.radio_b,
                option_b.relations.radio_group orelse 0,
                option_b.parent,
            }),
        );
        // CHECKED, not SELECTED. A radio a screen reader will not call
        // selected is a radio the reader cannot use, and SELECTED alone is a
        // list/tab state that says nothing about which option is current.
        const wanted_choice = view.radio_choice;
        const a_on = wanted_choice == @as(?u32, 1);
        const b_on = wanted_choice == @as(?u32, 2);
        try checks.expect(
            report,
            "radio.checked_marks",
            (a_on and option_a.states.checked == .on and option_b.states.checked == .off) or
                (b_on and option_a.states.checked == .off and option_b.states.checked == .on) or
                (wanted_choice == null and
                    option_a.states.checked == .off and option_b.states.checked == .off),
            checks.note("choice={?} a.checked={s} a.selected={} b.checked={s} b.selected={}", .{
                wanted_choice,
                @tagName(option_a.states.checked),
                option_a.states.selected,
                @tagName(option_b.states.checked),
                option_b.states.selected,
            }),
        );
    }

    // ── The progress leaf: a name a reader can call it by, the slider's own
    //    value over the MODEL's own bounds, and nothing it could drive ──
    //
    // The indicator is drawn beside the slider and bound to the SAME value, so
    // the two have to agree three times: in the NAME each is announced under,
    // in the numbers handed to the bridge, and in the ranges the tree
    // publishes. An indicator that announced a different span would report a
    // different percentage for the same number, and an indicator that
    // announced no span at all would report the number with nothing to read
    // it against.
    //
    // Every range here is compared with what the MODEL holds. The two controls
    // agreeing with EACH OTHER is internal consistency, which a tree with the
    // wrong bounds on both of them would satisfy; agreeing with the bounds the
    // app drew them at is the claim.
    //
    // READ-ONLY and NOT FOCUSABLE belong to the same claim. An indicator a
    // reader could operate, or reach with the keyboard, is not this indicator,
    // and this gate does not make one focusable in order to produce a spoken
    // line: an announcement nothing could legitimately reach is not evidence.
    {
        const indicator = try requireNode(snapshot.node(ids.progress), label_progress);
        const control = try requireNode(snapshot.node(ids.slider), label_slider);
        const published = h.adapter.lastNumericValue(ids.progress);
        const published_control = h.adapter.lastNumericValue(ids.slider);
        const model_level: f64 = @floatCast(view.level);
        const model_min: f64 = @floatCast(view.level_min);
        const model_max: f64 = @floatCast(view.level_max);
        // An absent node reads as no actions, so an update that dropped the
        // leaf entirely would satisfy a bare `== 0`. Presence is part of the
        // claim: the zero has to be a word the bridge holds, not a silence.
        const actions = h.adapter.lastActions(ids.progress);
        const flags = h.adapter.lastFlags(ids.progress);
        const name = publishedName(h.adapter, ids.progress);
        const span = publishedNumericRange(h.adapter, ids.progress);
        const control_span = publishedNumericRange(h.adapter, ids.slider);
        const span_matches = blk: {
            const indicator_range = indicator.range orelse break :blk false;
            const control_range = control.range orelse break :blk false;
            break :blk near(indicator_range.min, control_range.min) and
                near(indicator_range.max, control_range.max) and
                indicator_range.max > indicator_range.min;
        };
        const model_span = blk: {
            const indicator_range = indicator.range orelse break :blk false;
            break :blk near(indicator_range.min, model_min) and
                near(indicator_range.max, model_max) and
                indicator_range.max > indicator_range.min;
        };
        // A name is proved by ROUND TRIP, not by restating the label: the
        // bytes the bridge holds must be non-empty, must be the label this
        // scene authored, and must resolve in the committed tree back to this
        // node and to no other control in it. A shared or borrowed buffer
        // would name the slider instead.
        const named = if (name) |published_name|
            published_name.len > 0 and
                std.mem.eql(u8, published_name, label_progress) and
                !std.mem.eql(u8, published_name, label_slider) and
                nodeNamed(snapshot, published_name) == indicator
        else
            false;
        try checks.expect(
            report,
            "progress.announced_with_its_label",
            named and publishedRole(h.adapter, ids.progress) ==
                @backingInt(semantics.Role.progress_indicator),
            checks.note("name=\"{s}\" empty={} is_the_slider_name={} role={s}", .{
                if (name) |published_name| published_name else "<absent>",
                name == null or name.?.len == 0,
                if (name) |published_name|
                    std.mem.eql(u8, published_name, label_slider)
                else
                    false,
                roleName(publishedRole(h.adapter, ids.progress)),
            }),
        );
        try checks.expect(
            report,
            "progress.value_is_the_model_value",
            published != null and near(published.?, model_level) and
                published_control != null and near(published_control.?, published.?) and
                span_matches and model_span and
                span != null and near(span.?.min, model_min) and near(span.?.max, model_max) and
                control_span != null and near(control_span.?.min, model_min) and
                near(control_span.?.max, model_max) and
                actions != null and actions.? == 0 and
                flags != null and (flags.? & state_read_only) != 0 and
                indicator.states.read_only and !indicator.states.focusable,
            checks.note("published={?d} slider_published={?d} model={d:.4} " ++
                "published_range={?d}/{?d} slider_range={?d}/{?d} model_range={d:.4}/{d:.4} " ++
                "actions={?d} flags=0x{x} read_only={} focusable={} " ++
                "range_matches_slider={} range_is_the_model={}", .{
                published,
                published_control,
                view.level,
                if (span) |s| s.min else null,
                if (span) |s| s.max else null,
                if (control_span) |s| s.min else null,
                if (control_span) |s| s.max else null,
                view.level_min,
                view.level_max,
                actions,
                flags orelse 0,
                indicator.states.read_only,
                indicator.states.focusable,
                span_matches,
                model_span,
            }),
        );
    }
}

// ── The headless gate ─────────────────────

/// Whether an optional holds a value, rendered as `present` / `absent` so a
/// missing fact is visible in the evidence instead of collapsing into a zero.
fn present(value: anytype) []const u8 {
    return if (value) |_| "present" else "absent";
}

/// One key through the ordinary `App.handle` seam.
///
/// This is the seam the native window hands a translated host event to, so a
/// headless key reaches this field's endpoint through the core's own manager
/// exactly as a keyboard does. Nothing here touches the model directly.
fn pressKey(app: *App, key: nogui.event.Key, extend: bool) !void {
    _ = try app.handle(.{ .key_down = .{
        .key = key,
        .shift = extend,
        .logical = .{ .named = key },
    } });
}

/// Backspace as a host delivers it: an unidentified key carrying the
/// codepoint, which is what makes the core's own erase branch the path that
/// runs rather than an App shortcut.
fn pressErase(app: *App) !void {
    _ = try app.handle(.{ .key_down = .{
        .key = .unidentified,
        .logical = .{ .codepoint = 0x08 },
    } });
}

/// One preedit update. `phase` separates a composition's first update from the
/// one that follows an edit made inside it, because the manager treats them
/// differently and so does this gate.
fn composeText(app: *App, phase: nogui.event.CompositionPhase, text: []const u8) !void {
    _ = try app.handle(.{ .composition = .{
        .phase = phase,
        .text = text,
        .selection_start = text.len,
        .selection_end = text.len,
    } });
}

/// The commit that ends a composition.
fn commitText(app: *App, text: []const u8) !void {
    _ = try app.handle(.{ .text_input = .{ .text = text } });
}

/// The headless gate: no window, no compositor, no AT-SPI registry.
///
/// It builds real frames through the real App, publishes them through the
/// real adapter and drives the real request ring, so every fact it asserts
/// is a fact about the model the native window publishes. A failed assertion
/// is a non-zero exit.
fn runHeadless(h: *Harness, report: *Reporter) !void {
    var checks: Checks = .{};
    const view = h.view;
    try report.emit("mode: headless surface={d}x{d} linked={} state={s}\n", .{
        @as(u32, @intFromFloat(headless_surface.width)),
        @as(u32, @intFromFloat(headless_surface.height)),
        accessibility.linked,
        @tagName(h.adapter.stateOf()),
    });

    // ── Frame 1: the whole tree, and the relationships in it ──
    _ = try h.headlessFrame(report, 1);
    const first = try requireSnapshot(h);
    const ids = try Ids.capture(first);
    _ = try requireNode(first.node(semantics.window_node), "the window root");

    try checks.expect(
        report,
        "publish.first_is_whole_tree",
        h.adapter.lastWasFullTree() and h.carried == first.count(),
        checks.note("carried={d} nodes={d} full={}", .{
            h.carried,
            first.count(),
            h.adapter.lastWasFullTree(),
        }),
    );
    try checks.expect(
        report,
        "role.published",
        publishedRole(h.adapter, ids.activate) == @backingInt(semantics.Role.button) and
            publishedRole(h.adapter, ids.check_box) == @backingInt(semantics.Role.check_box) and
            publishedRole(h.adapter, ids.slider) == @backingInt(semantics.Role.slider) and
            publishedRole(h.adapter, ids.field) == @backingInt(semantics.Role.text_input) and
            publishedRole(h.adapter, ids.list) == @backingInt(semantics.Role.list_box) and
            publishedRole(h.adapter, ids.run) == @backingInt(semantics.Role.text_run) and
            publishedRole(h.adapter, ids.row) == @backingInt(semantics.Role.list_item),
        checks.note("button={s} check={s} slider={s} field={s} list={s} row={s}", .{
            roleName(publishedRole(h.adapter, ids.activate)),
            roleName(publishedRole(h.adapter, ids.check_box)),
            roleName(publishedRole(h.adapter, ids.slider)),
            roleName(publishedRole(h.adapter, ids.field)),
            roleName(publishedRole(h.adapter, ids.list)),
            roleName(publishedRole(h.adapter, ids.row)),
        }),
    );

    // The radio group is two REAL drawn options, so its role is read back
    // from the same adapter buffers as every other control here rather than
    // asserted against the annotator. Nothing in this file remaps a radio:
    // the core's built-in policy is what publishes `radio_button`, which is
    // exactly why a reader and this gate cannot disagree about the role.
    try checks.expect(
        report,
        "role.radio_published",
        publishedRole(h.adapter, ids.radio_a) == @backingInt(semantics.Role.radio_button) and
            publishedRole(h.adapter, ids.radio_b) == @backingInt(semantics.Role.radio_button) and
            selectedRadioCount(first) == 1 and checkedRadioCount(first) == 1,
        checks.note("radio_a={s} radio_b={s} selected_options={d} checked_options={d} radio_choice={?}", .{
            roleName(publishedRole(h.adapter, ids.radio_a)),
            roleName(publishedRole(h.adapter, ids.radio_b)),
            selectedRadioCount(first),
            checkedRadioCount(first),
            view.radio_choice,
        }),
    );

    // The group relation, resolved through the PUBLIC identity seam from the
    // identity the App bound to the keyed row. Both options point at a node
    // this same snapshot really contains, which is what the core's own
    // relation validation checked before this tree was ever published.
    {
        const option_a = try requireNode(first.node(ids.radio_a), label_radio_a);
        const option_b = try requireNode(first.node(ids.radio_b), label_radio_b);
        const group = try requireNode(first.node(ids.radio_group), label_radio_group);
        try checks.expect(
            report,
            "relation.radio_group",
            group.role == .radio_group and
                publishedRole(h.adapter, ids.radio_group) == @backingInt(semantics.Role.radio_group) and
                option_a.relations.radio_group == ids.radio_group and
                option_b.relations.radio_group == ids.radio_group and
                option_a.parent == ids.radio_group and option_b.parent == ids.radio_group,
            checks.note("group={d} role={s} a={d}->{d} parent={d} b={d}->{d} parent={d}", .{
                ids.radio_group,
                @tagName(group.role),
                ids.radio_a,
                option_a.relations.radio_group orelse 0,
                option_a.parent,
                ids.radio_b,
                option_b.relations.radio_group orelse 0,
                option_b.parent,
            }),
        );
    }

    // The progress leaf is a REAL drawn control, so its role, its NAME, its
    // number and its range all have to reach the adapter's own buffers. The
    // role alone would pass even if the value were lost, so the numeric ABI
    // field is compared with the model. A missing or different number fails.
    // An indicator a reader can act on is also wrong here, so the action word
    // must be zero rather than merely present — and PRESENT, because a node
    // the update dropped reads as no actions at all and would satisfy a bare
    // `== 0` without the bridge ever having been asked.
    //
    // The range is compared with what the MODEL holds, not with the slider it
    // shares a value with. Two controls agreeing with each other is internal
    // consistency: a tree carrying the same wrong bounds on both of them would
    // satisfy it, and the bounds the app drew them at are the claim.
    {
        const progress = try requireNode(first.node(ids.progress), label_progress);
        const published = h.adapter.lastNumericValue(ids.progress);
        const actions = h.adapter.lastActions(ids.progress);
        const flags = h.adapter.lastFlags(ids.progress);
        const name = publishedName(h.adapter, ids.progress);
        const span = publishedNumericRange(h.adapter, ids.progress);
        const control_span = publishedNumericRange(h.adapter, ids.slider);
        const model_min: f64 = @floatCast(view.level_min);
        const model_max: f64 = @floatCast(view.level_max);
        const tree_span = blk: {
            const range = progress.range orelse break :blk false;
            break :blk near(range.min, model_min) and
                near(range.max, model_max) and
                range.max > range.min;
        };
        // A name is proved by ROUND TRIP, not by restating the label: the
        // bytes the bridge holds must be non-empty, must be the label this
        // scene authored, and must resolve in the committed tree back to this
        // node and to no other control in it. A shared or borrowed buffer
        // would name the slider instead.
        const named = if (name) |published_name|
            published_name.len > 0 and
                std.mem.eql(u8, published_name, label_progress) and
                !std.mem.eql(u8, published_name, label_slider) and
                nodeNamed(first, published_name) == progress
        else
            false;
        try checks.expect(
            report,
            "progress.announced_with_its_label",
            named and publishedRole(h.adapter, ids.progress) ==
                @backingInt(semantics.Role.progress_indicator),
            checks.note("progress={d} name=\"{s}\" absent={} empty={} " ++
                "is_the_slider_name={} role={s}", .{
                ids.progress,
                if (name) |published_name| published_name else "<absent>",
                name == null,
                name == null or name.?.len == 0,
                if (name) |published_name|
                    std.mem.eql(u8, published_name, label_slider)
                else
                    false,
                roleName(publishedRole(h.adapter, ids.progress)),
            }),
        );
        try checks.expect(
            report,
            "progress.value_is_the_model_value",
            progress.role == .progress_indicator and
                publishedRole(h.adapter, ids.progress) == @backingInt(semantics.Role.progress_indicator) and
                published != null and near(published.?, @as(f64, @floatCast(view.level))) and
                actions != null and actions.? == 0 and
                flags != null and (flags.? & state_read_only) != 0 and
                tree_span and span != null and
                near(span.?.min, model_min) and near(span.?.max, model_max) and
                control_span != null and near(control_span.?.min, model_min) and
                near(control_span.?.max, model_max) and
                progress.range != null and progress.range.?.max > progress.range.?.min and
                progress.states.read_only,
            checks.note("progress={d} role={s} published={?d} model={d:.4} " ++
                "actions={?d} flags=0x{x} range={s} published_range={?d}/{?d} " ++
                "slider_range={?d}/{?d} model_range={d:.4}/{d:.4} read_only={}", .{
                ids.progress,
                @tagName(progress.role),
                published,
                view.level,
                actions,
                flags orelse 0,
                if (progress.range != null) "present" else "absent",
                if (span) |s| s.min else null,
                if (span) |s| s.max else null,
                if (control_span) |s| s.min else null,
                if (control_span) |s| s.max else null,
                view.level_min,
                view.level_max,
                progress.states.read_only,
            }),
        );
    }

    // ── The read-only policy at the platform edge ──
    //
    // The indicator is announced with a name, a number and a range, and can be
    // driven with NONE of them. The proof is a DIFFERENTIAL, because a refused
    // write and a dead request look identical from the model alone: the very
    // same numeric write is aimed at the slider that shares the value, where it
    // applies and moves the model's own counter, and then at the indicator,
    // where the ring accepts it and the model records nothing. The first half
    // is what makes the second half mean anything.
    //
    // Both requests carry a number the MODEL holds inside its own bounds, so
    // no clamp or an out-of-range refusal could account for either outcome.
    // Both are checked for QUEUE acceptance and against the adapter's own drop
    // counter: a request the ring threw away would satisfy "applied = 0" for a
    // reason that has nothing to do with the node's policy.
    {
        const number_writes_before = view.number_writes;
        const dropped_before = h.adapter.droppedRequests();
        const control_written: f64 = @floatCast(view.level_max);
        const control_queued = h.adapter.enqueueRequest(.{
            .id = ids.slider,
            .action = @backingInt(semantics.Action.set_value),
            .data = .numeric_value,
            .number = control_written,
        });
        const control_applied = h.adapter.drain(first, &h.disp, h.scratch());
        const control_moved = control_queued and control_applied == 1 and
            near(@as(f64, @floatCast(view.level)), control_written) and
            view.number_writes == number_writes_before + 1;

        // The state the refused attempt has to leave exactly as it found it:
        // the number the platform was LAST told, and the model's own value
        // and counter. The announced number is deliberately not compared with
        // `view.level`: the slider write above moved the model, and the next
        // publish is what will carry that number over, so equating the two
        // here would measure a repaint this gate has not asked for.
        const announced_before = h.adapter.lastNumericValue(ids.progress);
        const held_level = view.level;
        const writes_after_control = view.number_writes;
        const dropped_after_control = h.adapter.droppedRequests();
        const refused_queued = h.adapter.enqueueRequest(.{
            .id = ids.progress,
            .action = @backingInt(semantics.Action.set_value),
            .data = .numeric_value,
            .number = control_written,
        });
        const refused_applied = h.adapter.drain(first, &h.disp, h.scratch());
        // The core names WHY it refused, which a count alone cannot: a node
        // that was absent, disabled or merely unwired reports a different
        // failure, and only `unsupported_action` is the read-only answer.
        const outcome = first.dispatch(.{
            .id = ids.progress,
            .action = .set_value,
            .number = control_written,
        }, &h.disp, h.scratch());
        const refused_for_policy = switch (outcome) {
            .ignored => |failure| failure == .unsupported_action,
            .applied => false,
        };
        // What the platform was last TOLD, read back after the attempt: the
        // refused write must have left the announced number exactly where the
        // last publish put it, not merely left the model where it was.
        const published_after = h.adapter.lastNumericValue(ids.progress);
        try checks.expect(
            report,
            "progress.native_value_write_is_refused",
            control_moved and refused_queued and refused_applied == 0 and
                refused_for_policy and
                dropped_after_control == dropped_before and
                h.adapter.droppedRequests() == dropped_before and
                view.number_writes == writes_after_control and
                view.level == held_level and
                announced_before != null and published_after != null and
                near(published_after.?, announced_before.?),
            checks.note("slider {d} queued={} applied={d} -> level={d:.4} number_writes={d} | " ++
                "progress {d} queued={} applied={d} refused_as_unsupported={} " ++
                "announced={?d}->{?d} | " ++
                "held level={d:.4} number_writes={d}->{d} dropped={d}->{d}->{d}", .{
                ids.slider,
                control_queued,
                control_applied,
                view.level,
                number_writes_before,
                ids.progress,
                refused_queued,
                refused_applied,
                refused_for_policy,
                if (announced_before) |before| before else null,
                if (published_after) |after| after else null,
                held_level,
                writes_after_control,
                view.number_writes,
                dropped_before,
                dropped_after_control,
                h.adapter.droppedRequests(),
            }),
        );
    }

    // A quarter-million-row list publishes a container, the rows its
    // viewport shows and the app's selection, so the row count stays a
    // RELATIONSHIP and not a node count.
    const set = h.adapter.lastSetPosition(ids.list);
    try checks.expect(
        report,
        "list.set_relationship",
        set != null and set.?.position == view.selected_row and set.?.size == view.rows,
        checks.note("list={d} set={s} position={d} size={d} want={d}/{d}", .{
            ids.list,
            present(set),
            if (set) |s| s.position else 0,
            if (set) |s| s.size else 0,
            view.selected_row,
            view.rows,
        }),
    );

    const first_row = try requireNode(selectedRowNode(first), "the published selected row");
    const first_key = first_row.row.?.key;
    try checks.expect(
        report,
        "row.identity_is_its_key",
        first_row.id == semantics.rowNodeId(ids.list, first_key) and
            first_key == @as(u64, @intCast(view.selected_row)) + 1 and
            first_row.relations.row_count != null and
            first_row.relations.row_count.? == view.rows and
            first_row.relations.member_of != null and
            first_row.relations.member_of.? == ids.list,
        checks.note("id={d} key={d} row_count={d} member_of={d} over {d} logical rows", .{
            first_row.id,
            first_key,
            first_row.relations.row_count orelse 0,
            first_row.relations.member_of orelse 0,
            view.rows,
        }),
    );
    try checks.expect(
        report,
        "row.member_of_list",
        (h.adapter.lastMemberOf(ids.row) orelse 0) == ids.list,
        checks.note("row={d} list={d} member_of={s}", .{
            ids.row,
            ids.list,
            present(h.adapter.lastMemberOf(ids.row)),
        }),
    );
    const row_set = h.adapter.lastSetPosition(ids.row);
    try checks.expect(
        report,
        "row.set_relationship",
        row_set != null and row_set.?.position == view.selected_row and
            row_set.?.size == view.rows,
        checks.note("row={d} set={s} position={d} size={d}", .{
            ids.row,
            present(row_set),
            if (row_set) |s| s.position else 0,
            if (row_set) |s| s.size else 0,
        }),
    );

    // The characters the user typed reach the platform on a node of their
    // own, and the published caret is a position in THAT node, so a screen
    // reader reads the caret back through the characters it can address.
    // Without the run the platform offers a text field no text at all.
    const run_value = h.adapter.lastValue(ids.run) orelse "";
    const run_lengths = h.adapter.lastCharacterLengths(ids.run) orelse &[_]u8{};
    try checks.expect(
        report,
        "text.run_carries_the_characters",
        publishedRole(h.adapter, ids.run) == @backingInt(semantics.Role.text_run) and
            std.mem.eql(u8, run_value, view.text()) and
            run_lengths.len == view.characters and
            (h.adapter.lastTextSelectionOwner(ids.field) orelse 0) == ids.run,
        checks.note("run={d} role={s} value_bytes={d} table={d} characters={d} " ++
            "selection_owner={d} want_run={d}", .{
            ids.run,
            roleName(publishedRole(h.adapter, ids.run)),
            run_value.len,
            run_lengths.len,
            view.characters,
            h.adapter.lastTextSelectionOwner(ids.field) orelse 0,
            ids.run,
        }),
    );

    // The rows the viewport shows are real, selectable nodes with the extent
    // the container draws them at, and nothing is claimed outside it. A row
    // the viewport scrolled past keeps no extent at all, which is the truth
    // rather than a copy of the container's box.
    const list_box = (first.node(ids.list) orelse return error.MissingSubjectNode).bounds;
    const list_bottom = list_box.y + list_box.h;
    var visible_rows: u32 = 0;
    var selected_rows: u32 = 0;
    var without_extent: u32 = 0;
    var past_the_box: u32 = 0;
    for (first.nodes) |entry| {
        const row = entry.row orelse continue;
        if (row.list != ids.list) continue;
        if (entry.states.selected) selected_rows += 1;
        if (entry.bounds.h <= 0) {
            without_extent += 1;
            continue;
        }
        if (entry.bounds.y < list_box.y or entry.bounds.y + entry.bounds.h > list_bottom) {
            past_the_box += 1;
        }
        visible_rows += 1;
    }
    try checks.expect(
        report,
        "list.publishes_selectable_visible_rows",
        visible_rows >= 2 and selected_rows == 1 and without_extent == 0 and
            past_the_box == 0 and h.adapter.lastActions(ids.row).? != 0,
        checks.note("visible={d} selected={d} without_extent={d} past_box={d} " ++
            "row_actions={d} over {d} logical rows", .{
            visible_rows,
            selected_rows,
            without_extent,
            past_the_box,
            h.adapter.lastActions(ids.row).?,
            view.rows,
        }),
    );

    // The published window IS the window this app paints, and every row in it
    // carries the extent the painter drew that row at. Both are read out of
    // the published tree rather than recomputed beside it, so a range the
    // annotator decided on its own shows up here as a logical index nobody
    // drew, a row published beside the window, or a target rectangle that
    // does not contain the pixels it points at.
    {
        const published = first.list(ids.list) orelse return error.MissingSubjectNode;
        const window = rowWindow(list_box, view.rows, view.selected_row);
        var in_window: u32 = 0;
        var beside: u32 = 0;
        var without_pixels: u32 = 0;
        var selected_extent: Rect = .{};
        for (first.nodes) |entry| {
            const row = entry.row orelse continue;
            if (row.list != ids.list) continue;
            if (entry.states.selected) selected_extent = entry.bounds;
            if (!window.holds(row.index)) {
                beside += 1;
                continue;
            }
            in_window += 1;
            if (!containsRect(entry.bounds, window.rowRect(row.index - window.first))) {
                without_pixels += 1;
            }
        }
        try checks.expect(
            report,
            "list.published_rows_are_the_painted_window",
            published.first_visible == window.first and
                (published.visible_rows orelse 0) == window.count and
                in_window == @as(u32, @intCast(window.count)) and
                beside == @as(u32, @intFromBool(!window.holds(view.selected_row))) and
                without_pixels == 0 and
                selected_extent.h == row_height,
            checks.note("published first={d} rows={s} | painted first={d} rows={d} " ++
                "in_window={d} beside={d} extent_without_pixels={d} " ++
                "selected_extent=[{d:.1},{d:.1} {d:.1}x{d:.1}] over {d} logical rows", .{
                published.first_visible,
                present(published.visible_rows),
                window.first,
                window.count,
                in_window,
                beside,
                without_pixels,
                selected_extent.x,
                selected_extent.y,
                selected_extent.w,
                selected_extent.h,
                view.rows,
            }),
        );
    }

    // ── A native action resolves a live owner and edits the model once ──
    // The row this click names is one the window above SHOWS and not the one
    // the app had selected, so a selection that lands on it is proof that the
    // published rows are real positions the model owns, not nodes published
    // beside the rows a person can see.
    const picks_before = view.row_picks;
    const clicked = try requireNode(rowNode(first), "the first published list row");
    const clicked_index = clicked.row.?.index;
    const row_queued = h.adapter.enqueueRequest(.{
        .id = clicked.id,
        .action = @backingInt(semantics.Action.click),
    });
    const row_applied = h.adapter.drain(first, &h.disp, h.scratch());
    try checks.expect(
        report,
        "row.native_activation_reaches_model",
        row_queued and row_applied == 1 and view.row_picks == picks_before + 1 and
            clicked_index != first_row.row.?.index and
            view.selected_row == clicked_index,
        checks.note("queued={} applied={d} clicked={d} logical {d} while {d} was " ++
            "selected; row_picks={d}->{d} selected={d}", .{
            row_queued,
            row_applied,
            clicked.id,
            clicked_index,
            first_row.row.?.index,
            picks_before,
            view.row_picks,
            view.selected_row,
        }),
    );

    const hits_before = view.button_hits;
    const click_queued = h.adapter.enqueueRequest(.{
        .id = ids.activate,
        .action = @backingInt(semantics.Action.click),
    });
    const click_applied = h.adapter.drain(first, &h.disp, h.scratch());
    try checks.expect(
        report,
        "control.native_activation_reaches_model",
        click_queued and click_applied == 1 and view.button_hits == hits_before + 1,
        checks.note("queued={} applied={d} button_hits={d}->{d}", .{
            click_queued,
            click_applied,
            hits_before,
            view.button_hits,
        }),
    );

    // A radio has no activation callback of its own, so the view's own
    // `?u32` is the ONLY counter a click can move. The gate therefore reads
    // the pointer back rather than trusting the ring's applied count alone:
    // a replay that never reached the widget leaves the pointer where it was.
    const radio_before = view.radio_choice;
    const radio_queued = h.adapter.enqueueRequest(.{
        .id = ids.radio_b,
        .action = @backingInt(semantics.Action.click),
    });
    const radio_applied = h.adapter.drain(first, &h.disp, h.scratch());
    try checks.expect(
        report,
        "radio.native_activation_reaches_model",
        radio_queued and radio_applied == 1 and view.radio_choice == 2,
        checks.note("queued={} applied={d} radio_choice {?}->{?} clicked={d}", .{
            radio_queued,
            radio_applied,
            radio_before,
            view.radio_choice,
            ids.radio_b,
        }),
    );

    // ── Text: the platform counts characters, the model counts bytes ──
    const field_run = (try requireNode(first.node(ids.field), label_text)).text.?;
    const lengths = h.adapter.lastCharacterLengths(ids.field) orelse &.{};
    try checks.expect(
        report,
        "text.character_table_published",
        lengths.len == view.characters and lengths.len != 0 and
            std.mem.eql(u8, field_run.value, view.text()),
        checks.note("field={d} characters={d} bytes={d} value=\"{s}\"", .{
            ids.field,
            lengths.len,
            view.text().len,
            view.text(),
        }),
    );

    const selection = h.adapter.lastTextSelection(ids.field);
    try checks.expect(
        report,
        "text.selection_is_character_indices",
        selection != null and selection.?.anchor == view.characters and
            selection.?.focus == view.characters and
            selection.?.cursor == view.characters and
            accessibility.characterIndexOf(field_run, view.caret) == view.characters,
        checks.note("selection={s} anchor={d} focus={d} cursor={d} " ++
            "model_caret_byte={d} characters={d}", .{
            present(selection),
            if (selection) |s| s.anchor else 0,
            if (selection) |s| s.focus else 0,
            if (selection) |s| s.cursor else 0,
            view.caret,
            view.characters,
        }),
    );

    // A platform selection in CHARACTERS edits the model at BYTE offsets.
    const anchor_byte = accessibility.byteOffsetOf(field_run, 1);
    const focus_byte = accessibility.byteOffsetOf(field_run, 3);
    const selection_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_selection,
        .anchor_index = 1,
        .focus_index = 3,
    });
    const selection_applied = h.adapter.drain(first, &h.disp, h.scratch());
    try checks.expect(
        report,
        "text.character_selection_edits_bytes",
        selection_queued and selection_applied == 1 and
            anchor_byte != null and focus_byte != null and
            view.anchor == anchor_byte.? and view.caret == focus_byte.? and
            view.anchor == 1 and view.caret == 4,
        checks.note("queued={} applied={d} characters 1..3 -> anchor_byte={d} focus_byte={d} " ++
            "\"{s}\" is {d} bytes and {d} characters", .{
            selection_queued,
            selection_applied,
            view.anchor,
            view.caret,
            view.text(),
            view.text().len,
            view.characters,
        }),
    );

    // A platform index past the end of the run names no byte offset, so the
    // request is refused rather than clamped into a wrong edit.
    const writes_before = view.text_writes;
    const caret_before = view.caret;
    const out_of_range_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_selection,
        .anchor_index = view.characters + 1,
        .focus_index = view.characters + 1,
    });
    const refused = h.adapter.drain(first, &h.disp, h.scratch());
    try checks.expect(
        report,
        "text.out_of_range_selection_refused",
        out_of_range_queued and refused == 0 and
            view.text_writes == writes_before and view.caret == caret_before,
        checks.note("queued={} index={d} over {d} characters: applied={d} " ++
            "text_writes={d}->{d} caret={d}->{d}", .{
            out_of_range_queued,
            view.characters + 1,
            view.characters,
            refused,
            writes_before,
            view.text_writes,
            caret_before,
            view.caret,
        }),
    );

    // A composed edit travels the same text path, and it composes against the
    // span the MODEL holds now. The caret is placed by a request of its own
    // first — a reader moves the caret before it types — so the span the
    // replacement edits is one this run asked for rather than one a stale
    // publication happened to advertise. Both requests ride one batch.
    const characters_before = view.characters;
    const caret_at_end_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_selection,
        .anchor_index = view.characters,
        .focus_index = view.characters,
    });
    const replace_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .value,
        .value = "X",
    });
    const replaced = h.adapter.drain(first, &h.disp, h.scratch());
    try checks.expect(
        report,
        "text.replace_selection_edits_model",
        caret_at_end_queued and replace_queued and replaced == 2 and
            std.mem.eql(u8, view.text(), "Grüße ✓X") and
            view.anchor == view.caret and view.caret == view.text().len and
            view.characters == 8 and view.characters != characters_before,
        checks.note("caret queued={} replace queued={} applied={d} value=\"{s}\" " ++
            "bytes={d} characters={d}->{d} caret={d} at the end={}", .{
            caret_at_end_queued,
            replace_queued,
            replaced,
            view.text(),
            view.text().len,
            characters_before,
            view.characters,
            view.caret,
            view.caret == view.text().len,
        }),
    );

    // One ring batch, two requests, ONE drain. The first replaces the span the
    // MODEL holds — the caret the batch above placed at its end — and the
    // second names characters 1..4 of the run the last publish committed,
    // which is eleven bytes old by the time it is replayed. A selection-only
    // request carries no characters, so the bytes the first request added
    // survive it: the "X" is still there after the second. Composing the
    // second against that published run instead would have replaced the
    // model's newer bytes with eleven stale ones, cut inside a character at a
    // boundary no reader could have named.
    const grown_writes = view.text_writes;
    const first_batch_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .value,
        .value = "€€",
    });
    const second_batch_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_selection,
        .anchor_index = 1,
        .focus_index = 4,
    });
    const batched = h.adapter.drain(first, &h.disp, h.scratch());
    try checks.expect(
        report,
        "text.stale_published_run_cannot_truncate_a_grown_edit",
        first_batch_queued and second_batch_queued and batched == 2 and
            std.mem.eql(u8, view.text(), "Grüße ✓X€€") and
            view.text_len == 18 and view.characters == 10 and
            std.unicode.utf8ValidateSlice(view.text()) and
            view.anchor == 1 and view.caret == 6 and
            view.text_writes == grown_writes + 2,
        checks.note("queued={}/{} applied={d} published_run={d} bytes now={d} " ++
            "characters={d} value=\"{s}\" anchor={d} caret={d} " ++
            "text_writes={d}->{d}", .{
            first_batch_queued,
            second_batch_queued,
            batched,
            field_run.value.len,
            view.text_len,
            view.characters,
            view.text(),
            view.anchor,
            view.caret,
            grown_writes,
            view.text_writes,
        }),
    );

    // ── Frame 2: the edits reach the platform with a re-measured table ──
    //
    // The value is the one the batch left in the model, including the "X" the
    // first request appended: the run the platform still had ends before it,
    // and a publication that dropped those newer bytes would tell a reader
    // about less text than the model really holds.
    _ = try h.headlessFrame(report, 2);
    {
        const second = try requireSnapshot(h);
        const second_ids = try Ids.capture(second);
        const second_run = (try requireNode(second.node(second_ids.field), label_text)).text.?;
        const second_lengths = h.adapter.lastCharacterLengths(second_ids.field) orelse &.{};
        try checks.expect(report, "text.republished_after_edit", second_lengths.len == view.characters and
            std.mem.eql(u8, second_run.value, "Grüße ✓X€€") and
            ids.stableExceptRow(second), checks.note("field={d} characters={d} value=\"{s}\" controls_stable={}", .{
            second_ids.field,
            second_lengths.len,
            second_run.value,
            ids.stableExceptRow(second),
        }));

        // The click above moved the app's own pointer, and this is where the
        // reader would see it: the option that was selected is no longer
        // marked, the clicked one is, and the group still holds exactly one.
        // Both node identities are unchanged, so a selection move replaced a
        // STATE and not a control.
        try checks.expect(
            report,
            "radio.selection_republished",
            selectedRadioCount(second) == 1 and
                checkedRadioCount(second) == 1 and
                second.node(second_ids.radio_a).?.states.selected == false and
                second.node(second_ids.radio_b).?.states.selected == true and
                second.node(second_ids.radio_a).?.states.checked == .off and
                second.node(second_ids.radio_b).?.states.checked == .on and
                second_ids.radio_a == ids.radio_a and second_ids.radio_b == ids.radio_b,
            checks.note("selected_options={d} checked_options={d} radio_a={d} selected={} checked={s} " ++
                "radio_b={d} selected={} checked={s} identities_stable={}", .{
                selectedRadioCount(second),
                checkedRadioCount(second),
                second_ids.radio_a,
                second.node(second_ids.radio_a).?.states.selected,
                @tagName(second.node(second_ids.radio_a).?.states.checked),
                second_ids.radio_b,
                second.node(second_ids.radio_b).?.states.selected,
                @tagName(second.node(second_ids.radio_b).?.states.checked),
                second_ids.radio_a == ids.radio_a and second_ids.radio_b == ids.radio_b,
            }),
        );
    }

    // ── A composition the platform never sees is still one composition ──
    //
    // The preedit is the input method's own record, and an edit made INSIDE
    // it does not end it: the core's erase path leaves the manager's record
    // alone, so an endpoint that dropped the mark on an erase would leave the
    // manager composing over a model that no longer says where. The update
    // that follows is then resolved against a collapsed caret and appends a
    // SECOND copy of the preedit, which the commit after it keeps.
    //
    // Every event here travels `App.handle`, the same seam the native window
    // hands a translated host event to, so the core's own manager drives this
    // field's endpoint and the gate edits nothing itself.
    const composed_writes = view.text_writes;
    // The run before the composition is eighteen bytes, so the preedit owns
    // bytes eighteen on: 18..21 for "abc", 18..20 for the "ab" that follows.
    try pressKey(h.app, .end, false);
    try composeText(h.app, .start, "abc");
    const started_writes = view.text_writes;
    try pressErase(h.app);
    const erased_mark = view.marked;
    const erased_value = std.mem.eql(u8, view.text(), "Grüße ✓X€€ab") and
        view.text_len == 20 and view.characters == 12;
    const erased_units = view.markedUnits();
    try composeText(h.app, .update, "ab");
    const updated_mark = view.marked;
    try commitText(h.app, "か");
    try checks.expect(
        report,
        "text.erase_keeps_the_composition_mark",
        started_writes == composed_writes + 1 and
            erased_value and
            erased_mark != null and erased_mark.?.start == 18 and erased_mark.?.end == 20 and
            erased_units != null and erased_units.?.start == 10 and erased_units.?.end == 12 and
            updated_mark != null and updated_mark.?.start == 18 and updated_mark.?.end == 20 and
            std.mem.eql(u8, view.text(), "Grüße ✓X€€か") and
            view.text_len == 21 and view.characters == 11 and
            // The commit replaced the preedit and left its caret after the
            // three bytes it wrote, so the caret is at the end of the value.
            view.anchor == 21 and view.caret == 21 and
            view.marked == null and
            view.text_writes == composed_writes + 4,
        checks.note("erase -> \"{s}\" bytes={d} mark={any} units={any} | " ++
            "update -> mark={any} | commit -> \"{s}\" bytes={d} characters={d} " ++
            "caret={d} marked={any} text_writes={d}->{d}", .{
            "Grüße ✓X€€ab",
            20,
            erased_mark,
            erased_units,
            updated_mark,
            view.text(),
            view.text_len,
            view.characters,
            view.caret,
            view.marked,
            composed_writes,
            view.text_writes,
        }),
    );

    // ── Frame 3: selection moves the visible row window ──
    view.selected_row = 7;
    _ = try h.headlessFrame(report, 3);
    var logical_bounds: nogui.widget.Rect = .{};
    {
        const third = try requireSnapshot(h);
        const third_ids = try Ids.capture(third);
        const third_row = try requireNode(selectedRowNode(third), "the published selected row");
        const box = (try requireNode(third.node(third_ids.activate), label_activate)).bounds;
        try checks.expect(
            report,
            "identity.stable_across_a_reorder",
            ids.stableExceptRow(third) and
                third_row.id != ids.row and
                third_row.id == semantics.rowNodeId(ids.list, @as(u64, 7) + 1) and
                selectedRowCount(third) == 1,
            checks.note("row {d} -> {d} (key {d} -> {d}) over {d} rows; " ++
                "controls_stable={} selected_rows={d}", .{
                ids.row,
                third_row.id,
                first_key,
                third_row.row.?.key,
                view.rows,
                ids.stableExceptRow(third),
                selectedRowCount(third),
            }),
        );
        logical_bounds = box;
    }

    // ── Frame 4: logical bounds cross as physical pixels ──
    h.setScale(2, 2);
    _ = try h.headlessFrame(report, 4);
    {
        const fourth = try requireSnapshot(h);
        const fourth_ids = try Ids.capture(fourth);
        const scaled = h.adapter.lastRect(fourth_ids.activate) orelse
            return error.MissingSubjectNode;
        const factor: f64 = 2;
        const want = [4]f64{
            @as(f64, @floatCast(logical_bounds.x)) * factor,
            @as(f64, @floatCast(logical_bounds.y)) * factor,
            @as(f64, @floatCast(logical_bounds.x + logical_bounds.w)) * factor,
            @as(f64, @floatCast(logical_bounds.y + logical_bounds.h)) * factor,
        };
        try checks.expect(
            report,
            "bounds.physical_at_the_native_edge",
            near(scaled[0], want[0]) and near(scaled[1], want[1]) and
                near(scaled[2], want[2]) and near(scaled[3], want[3]) and
                h.carried == fourth.count(),
            checks.note("logical=[{d:.1},{d:.1},{d:.1},{d:.1}] " ++
                "physical=[{d:.1},{d:.1},{d:.1},{d:.1}] scale={d:.2}x{d:.2} " ++
                "re-sent={d}/{d}", .{
                logical_bounds.x,
                logical_bounds.y,
                logical_bounds.x + logical_bounds.w,
                logical_bounds.y + logical_bounds.h,
                scaled[0],
                scaled[1],
                scaled[2],
                scaled[3],
                h.scale_x,
                h.scale_y,
                h.carried,
                fourth.count(),
            }),
        );
    }

    // ── An accessibility write during a composition keeps both records ──
    //
    // A screen reader moves the caret and replaces the whole value while an
    // input method is composing, and both arrive as ordinary semantic text
    // writes against the run the last publish advertised. The caret write
    // moves no byte, so it must leave the mark the manager is about to commit
    // over exactly where it was. The whole-value write replaces bytes the
    // composition itself replaced, so that composition has to end through the
    // manager's OWN cancel before the platform's value lands: a restore left
    // behind by a superseded composition would put its bytes into whatever the
    // field composed next, which is what the cancel below shows.
    //
    // The caret request names characters of the committed run; the whole-value
    // payload carries the field's ENTIRE new contents, which is what it is
    // written as. The field keeps the keyboard until the frame below takes it
    // away.
    const external_writes = view.text_writes;
    try pressKey(h.app, .home, false);
    try pressKey(h.app, .right, true);
    try pressKey(h.app, .right, true);
    try composeText(h.app, .start, "ka");
    const current = try requireSnapshot(h);
    const current_ids = try Ids.capture(current);
    const caret_queued = h.adapter.enqueueRequest(.{
        .id = current_ids.field,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_selection,
        .anchor_index = 0,
        .focus_index = 1,
    });
    const caret_writes = h.adapter.drain(current, &h.disp, h.scratch());
    // A caret write is not an edit: the value behind the preedit is the one
    // the composition wrote, and it is still there.
    const preedit_kept = std.mem.eql(u8, view.text(), "kaüße ✓X€€か") and
        view.text_len == 21 and view.characters == 11 and
        view.anchor == 0 and view.caret == 1;
    const caret_mark = view.marked;
    const contents_queued = h.adapter.enqueueRequest(.{
        .id = current_ids.field,
        .action = @backingInt(semantics.Action.set_value),
        .data = .value,
        .value = "kaüße ✓€€かX",
    });
    const contents_writes = h.adapter.drain(current, &h.disp, h.scratch());
    try composeText(h.app, .start, "Z");
    try h.app.textInputManager().cancelComposition();
    try checks.expect(
        report,
        "text.external_writes_keep_the_composition_mark",
        caret_queued and contents_queued and
            caret_writes == 1 and contents_writes == 1 and
            preedit_kept and
            caret_mark != null and caret_mark.?.start == 0 and caret_mark.?.end == 2 and
            std.mem.eql(u8, view.text(), "kaüße ✓€€かX") and
            view.text_len == 21 and view.characters == 11 and
            view.anchor == 21 and view.caret == 21 and
            view.marked == null and
            view.text_writes == external_writes + 6,
        checks.note("caret queued={} applied={d} value kept={} mark={any} | " ++
            "contents queued={} applied={d} | " ++
            "next composition cancelled -> \"{s}\" bytes={d} characters={d} " ++
            "caret={d} marked={any} text_writes={d}->{d}", .{
            caret_queued,
            caret_writes,
            preedit_kept,
            caret_mark,
            contents_queued,
            contents_writes,
            view.text(),
            view.text_len,
            view.characters,
            view.caret,
            view.marked,
            external_writes,
            view.text_writes,
        }),
    );

    // ── Frame 5: an authored modal, and the policy it implies ──
    //
    // The dialog subtree is published by the frame that mounts it. The
    // keyboard it takes is published by the frame AFTER that one, because
    // the App publishes the focus it holds when a frame commits.
    view.modal_open = true;
    _ = try h.headlessFrame(report, 5);
    {
        const fifth = try requireSnapshot(h);
        const dialog = try requireNode(nodeNamed(fifth, label_modal_confirm), label_modal_confirm);
        const dialog_flags = h.adapter.lastFlags(dialog.id) orelse 0;
        var carriers: usize = 0;
        for (fifth.nodes) |node| {
            const flags = h.adapter.lastFlags(node.id) orelse 0;
            if (flags & state_modal != 0) carriers += 1;
        }
        try checks.expect(
            report,
            "modal.flag_is_authored",
            publishedRole(h.adapter, dialog.id) == @backingInt(semantics.Role.dialog) and
                dialog_flags & state_modal != 0 and carriers == 1,
            checks.note("dialog={d} role={s} flags=0x{x} modal_bit=0x{x} carriers={d}", .{
                dialog.id,
                roleName(publishedRole(h.adapter, dialog.id)),
                dialog_flags,
                state_modal,
                carriers,
            }),
        );
        try checks.expect(
            report,
            "modal.hidden_control_leaves_the_tree",
            nodeNamed(fifth, label_list_add) == null and fifth.node(ids.list_add) == null,
            checks.note("list_add={d} present={} nodes={d}", .{
                ids.list_add,
                fifth.node(ids.list_add) != null,
                fifth.count(),
            }),
        );
        const remove_flags = h.adapter.lastFlags(ids.list_remove) orelse 0;
        const remove_actions = h.adapter.lastActions(ids.list_remove) orelse 1;
        try checks.expect(
            report,
            "modal.disabled_control_keeps_no_action",
            nodeNamed(fifth, label_list_remove) != null and
                remove_flags & state_disabled != 0 and
                remove_actions == 0 and
                publishedRole(h.adapter, ids.list_remove) == @backingInt(semantics.Role.button),
            checks.note("list_remove={d} flags=0x{x} disabled_bit=0x{x} actions=0x{x} role={s}", .{
                ids.list_remove,
                remove_flags,
                state_disabled,
                remove_actions,
                roleName(publishedRole(h.adapter, ids.list_remove)),
            }),
        );

        const adds_before = view.rows_added;
        const removes_before = view.rows_removed;
        const blocked_add_queued = h.adapter.enqueueRequest(.{
            .id = ids.list_add,
            .action = @backingInt(semantics.Action.click),
        });
        const blocked_remove_queued = h.adapter.enqueueRequest(.{
            .id = ids.list_remove,
            .action = @backingInt(semantics.Action.click),
        });
        const blocked = h.adapter.drain(fifth, &h.disp, h.scratch());
        try checks.expect(
            report,
            "modal.unreachable_controls_refuse_actions",
            blocked_add_queued and blocked_remove_queued and
                blocked == 0 and view.rows_added == adds_before and
                view.rows_removed == removes_before,
            checks.note("queued={}/{} applied={d} rows_added={d}->{d} " ++
                "rows_removed={d}->{d}", .{
                blocked_add_queued,
                blocked_remove_queued,
                blocked,
                adds_before,
                view.rows_added,
                removes_before,
                view.rows_removed,
            }),
        );

        const confirms_before = view.modal_confirms;
        const confirm_queued = h.adapter.enqueueRequest(.{
            .id = dialog.id,
            .action = @backingInt(semantics.Action.click),
        });
        const confirmed = h.adapter.drain(fifth, &h.disp, h.scratch());
        try checks.expect(
            report,
            "modal.native_activation_reaches_model",
            confirm_queued and confirmed == 1 and view.modal_confirms == confirms_before + 1,
            checks.note("queued={} applied={d} modal_confirms={d}->{d}", .{
                confirm_queued,
                confirmed,
                confirms_before,
                view.modal_confirms,
            }),
        );
    }

    // ── Frame 6: the keyboard the dialog took is published ──
    //
    // The app's own focus rule ran between frames 5 and 6, so frame 6 is the
    // one that carries it. That is the App's publication contract rather than
    // a second tree beside the first: the published focus sits inside the
    // dialog subtree, the field that gave up the keyboard is still published
    // and no longer focused, and the control that opened the dialog kept the
    // identity it was published under.
    _ = try h.headlessFrame(report, 6);
    {
        const sixth = try requireSnapshot(h);
        const dialog = try requireNode(nodeNamed(sixth, label_modal_confirm), label_modal_confirm);
        const field = try requireNode(sixth.node(ids.field), label_text);
        const opener_kept = nodeIs(sixth, label_modal, ids.modal);
        try checks.expect(
            report,
            "modal.focus_moves_into_the_subtree",
            sixth.focus == dialog.id and !field.states.focused and opener_kept,
            checks.note("snapshot_focus={d} dialog={d} field_focused={} opener_kept={}", .{
                sixth.focus,
                dialog.id,
                field.states.focused,
                opener_kept,
            }),
        );
    }

    // ── The publish is transactional, and refusals are explicit ──
    //
    // This one drives the publisher's OWN transaction instead of a frame's:
    // it stages the tree the App already committed, abandons the attempt, and
    // reads afterwards what the live snapshot says. The App's transaction is
    // the ordinary path above, where a frame that cannot be annotated aborts
    // its publication and the live tree stands.
    {
        const tree = h.app.tree_ptr orelse return error.MissingSubjectNode;
        const transaction_snapshot = try requireSnapshot(h);
        const before_generation = transaction_snapshot.generation;
        const before_count = transaction_snapshot.count();
        try h.publisher.stage(.{
            .tree = tree,
            .focus = h.app.focus_manager.current,
            .generation = before_generation + 1,
            .surface = h.logical,
            .window_name = window_name,
            .annotator = .{ .context = view, .annotate = annotate },
        });
        h.publisher.abort();
        const after = try requireSnapshot(h);
        const replayed = try h.adapter.publish(after, .{ .focused = true });
        try checks.expect(
            report,
            "publish.an_abandoned_stage_changes_nothing",
            after == transaction_snapshot and after.generation == before_generation and after.count() == before_count,
            checks.note("staged generation {d} -> published {d}; nodes {d} -> {d}; re-sent {d}", .{
                before_generation + 1,
                after.generation,
                before_count,
                after.count(),
                replayed,
            }),
        );

        const unknown_queued = h.adapter.enqueueRequest(.{
            .id = 0xDEAD_BEEF,
            .action = @backingInt(semantics.Action.click),
        });
        const unknown = h.adapter.drain(after, &h.disp, h.scratch());
        const unmodelled_queued = h.adapter.enqueueRequest(.{
            .id = ids.list,
            .action = 200,
        });
        const unmodelled = h.adapter.drain(after, &h.disp, h.scratch());
        try checks.expect(
            report,
            "publish.unmodelled_requests_are_dropped",
            unknown_queued and unmodelled_queued and unknown == 0 and unmodelled == 0 and
                h.adapter.droppedRequests() == 0,
            checks.note("unknown_node queued={} applied={d} | unmodelled queued={} " ++
                "applied={d} | ring_dropped={d}", .{
                unknown_queued,
                unknown,
                unmodelled_queued,
                unmodelled,
                h.adapter.droppedRequests(),
            }),
        );
    }

    // ── A whole value from the platform, over the ring, in one write ──
    //
    // This is the route a screen reader's SetTextContents takes: the wire
    // action that carries a whole value, with the field's new characters as
    // its payload, arriving on the same request ring every other native
    // action arrives on. The field's whole buffer becomes exactly those
    // characters — not a merge with what the model holds — the caret lands
    // after them, and the model records ONE write for one request.
    // The identity frame 1 captured: a node identity is stable across frames,
    // and the dialog that is open here only hides the two list mutators.
    const final = try requireSnapshot(h);
    const whole_writes = view.text_writes;
    const whole_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.set_value),
        .data = .value,
        .value = "Grüße ✓€",
    });
    const whole = h.adapter.drain(final, &h.disp, h.scratch());
    try checks.expect(
        report,
        "text.set_value_writes_the_whole_value_once",
        whole_queued and whole == 1 and
            std.mem.eql(u8, view.text(), "Grüße ✓€") and
            view.text_len == 14 and view.characters == 8 and
            std.unicode.utf8ValidateSlice(view.text()) and
            view.anchor == 14 and view.caret == 14 and
            view.marked == null and
            view.text_writes == whole_writes + 1,
        checks.note("queued={} applied={d} value=\"{s}\" bytes={d} characters={d} " ++
            "anchor={d} caret={d} marked={any} text_writes={d}->{d}", .{
            whole_queued,
            whole,
            view.text(),
            view.text_len,
            view.characters,
            view.anchor,
            view.caret,
            view.marked,
            whole_writes,
            view.text_writes,
        }),
    );

    // ── A whole value that IS the published run ──
    //
    // The payload above was a buffer of its own that happened to equal the
    // published bytes. This one is the published slice ITSELF. The run a
    // publish commits borrows the model's own buffer, so once the model has
    // grown past it, a whole value that starts with exactly those bytes at
    // exactly that address is a request any screen reader can drive, through
    // the same setter a selection arrives on, with the same length. What
    // `set_value` means therefore has to come from the REQUEST and not from
    // where the bytes happen to live.
    //
    // The matching half is already proved and is not repeated here. The batch
    // in `text.stale_published_run_cannot_truncate_a_grown_edit` moves a
    // selection against that same published run on a model which has already
    // grown, and the newer bytes survive it. A request that moves only a
    // selection must keep them; a whole write of those same bytes replaces
    // them.
    //
    // Grow the model from an independent input, then deliver a shorter whole
    // value whose payload aliases the live model rather than the snapshot.
    _ = try h.headlessFrame(report, 7);
    {
        const seventh = try requireSnapshot(h);
        const field = try requireNode(seventh.node(ids.field), label_text);
        const published = (field.text orelse return error.MissingSubjectNode).value;

        // Save the complete expected value before changing the model.
        var supplied: [model_text_bytes]u8 = undefined;
        @memcpy(supplied[0..published.len], published);
        const supplied_len = published.len;
        var grown: [model_text_bytes + 1]u8 = undefined;
        @memcpy(grown[0..view.text_len], view.text());
        grown[view.text_len] = 'X';
        const grown_len = view.text_len + 1;
        const borrowed_characters_before = view.characters;
        const borrowed_writes_before = view.text_writes;
        _ = view.writeWholeText(grown[0..grown_len], null);
        const writes_after_append = view.text_writes;
        const after_append = view.text();
        const appended = writes_after_append == borrowed_writes_before + 1 and
            view.text_len == grown_len and
            supplied_len <= after_append.len and
            std.mem.eql(u8, supplied[0..supplied_len], after_append[0..supplied_len]);

        const outcome = seventh.dispatch(.{
            .id = ids.field,
            .action = .set_value,
            .text = view.text()[0..supplied_len],
        }, &h.disp, h.scratch());
        try checks.expect(
            report,
            "text.a_whole_value_is_a_whole_write_even_when_the_payload_aliases_the_model",
            outcome == .applied and appended and
                std.mem.eql(u8, view.text(), supplied[0..supplied_len]) and
                view.text_len == supplied_len and
                view.characters == borrowed_characters_before and
                view.anchor == supplied_len and view.caret == supplied_len and
                view.marked == null and
                view.text_writes == writes_after_append + 1 and
                std.unicode.utf8ValidateSlice(view.text()),
            checks.note("appended={} outcome={s} payload={d} bytes " ++
                "model now \"{s}\" bytes={d} characters was={d} now={d} " ++
                "caret={d} " ++
                "text_writes={d}->{d}", .{
                appended,
                @tagName(outcome),
                supplied_len,
                view.text(),
                view.text_len,
                borrowed_characters_before,
                view.characters,
                view.caret,
                writes_after_append,
                view.text_writes,
            }),
        );
    }

    // ── A borrowed whole value, delivered while an input method composes ──
    //
    // `writeWholeText` ends the composition through the manager's OWN cancel
    // BEFORE it copies the incoming bytes, and that cancel restores through
    // THIS endpoint into THIS buffer. A payload that borrows those bytes is
    // therefore rewritten before the copy can take it.
    //
    // The evidence is an INDEPENDENT copy of the payload taken before the
    // dispatch: under that defect the payload and the model move together,
    // so comparing the model with the payload reports agreement either way.
    //
    // Focus first, through the app's own routes: the dialog's opener is
    // clicked — that IS the app's own toggle — and the platform's own `focus`
    // action names the field. The App binds a text endpoint only to the
    // FOCUSED widget, so the frame after them binds it again.
    const alias_start = try requireSnapshot(h);
    const alias_closed_queued = h.adapter.enqueueRequest(.{
        .id = ids.modal,
        .action = @backingInt(semantics.Action.click),
    });
    const alias_closed = h.adapter.drain(alias_start, &h.disp, h.scratch());
    const alias_focused_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.focus),
    });
    const alias_focused = h.adapter.drain(alias_start, &h.disp, h.scratch());
    const alias_field_key = view.fieldWidgetId();
    const alias_holds_keyboard = alias_field_key != null and
        h.app.focus_manager.current != null and
        h.app.focus_manager.current.?.eql(alias_field_key.?);
    _ = try h.headlessFrame(report, 8);
    const alias_bound = h.app.textInputManager().focusedId() != null;

    // The value as it stood BEFORE the composition, copied out: the mark is
    // measured against that, never against the bytes the preedit wrote.
    var alias_before: [model_text_bytes]u8 = undefined;
    const alias_before_len = view.text_len;
    @memcpy(alias_before[0..alias_before_len], view.text());
    const alias_pre_writes = view.text_writes;
    try pressKey(h.app, .home, false);
    try pressKey(h.app, .right, true);
    try pressKey(h.app, .right, true);
    const alias_old_low = @min(view.anchor, view.caret);
    const alias_old_high = @max(view.anchor, view.caret);
    try composeText(h.app, .start, "漢字");
    const alias_composed_writes = view.text_writes;
    const alias_mark = view.marked;
    const alias_mark_bytes: []const u8 = if (alias_mark) |m|
        view.text_buf[m.start..m.end]
    else
        &[_]u8{};
    const alias_mark_characters = std.unicode.utf8CountCodepoints(alias_mark_bytes) catch 0;
    const alias_replaced = alias_before[alias_old_low..alias_old_high];
    const alias_replaced_characters = std.unicode.utf8CountCodepoints(alias_replaced) catch 0;
    const alias_replaced_two = alias_mark != null and
        alias_replaced_characters >= 2 and
        alias_mark_characters >= 2 and
        !std.mem.eql(u8, alias_replaced, alias_mark_bytes);

    // The incoming whole-value payload aliases the composing model. The
    // committed snapshot owns an independent copy.
    _ = try h.headlessFrame(report, 9);
    const alias_snapshot = try requireSnapshot(h);
    const alias_payload = view.text();
    var alias_expected: [model_text_bytes]u8 = undefined;
    @memcpy(alias_expected[0..alias_payload.len], alias_payload);
    const alias_expected_len = alias_payload.len;
    const alias_expected_characters = try std.unicode.utf8CountCodepoints(
        alias_expected[0..alias_expected_len],
    );

    const alias_writes_before = view.text_writes;
    const alias_outcome = alias_snapshot.dispatch(.{
        .id = ids.field,
        .action = .set_value,
        .text = alias_payload,
    }, &h.disp, h.scratch());
    // Read the state the whole write leaves AT ONCE: the composition below
    // must not stand in for it, and a note printed after it would mislabel
    // both states.
    const alias_writes_after_whole = view.text_writes;
    var alias_whole: [model_text_bytes]u8 = undefined;
    @memcpy(alias_whole[0..view.text_len], view.text());
    const alias_whole_len = view.text_len;
    const alias_whole_characters = view.characters;
    const alias_whole_anchor = view.anchor;
    const alias_whole_caret = view.caret;
    const alias_whole_marked = view.marked;
    // The whole write is one write; the restore the cancel makes before it
    // is a legitimate rollback, so the count is a floor and not an exact one.
    const alias_whole_kept = alias_outcome == .applied and
        alias_whole_len == alias_expected_len and
        std.mem.eql(u8, alias_whole[0..alias_whole_len], alias_expected[0..alias_expected_len]) and
        alias_whole_characters == alias_expected_characters and
        std.unicode.utf8ValidateSlice(alias_whole[0..alias_whole_len]) and
        alias_whole_anchor == alias_expected_len and
        alias_whole_caret == alias_expected_len and
        alias_whole_marked == null and
        alias_writes_after_whole >= alias_writes_before + 1;

    // The composition that follows is the cancel-survivor: a restore record
    // that outlived the first cancel would put its bytes back over whatever
    // the field composes next.
    try composeText(h.app, .start, "ZQ");
    const alias_second_mark = view.marked;
    try h.app.textInputManager().cancelComposition();
    const alias_resurrected = !std.mem.eql(u8, view.text(), alias_expected[0..alias_expected_len]) or
        view.text_len != alias_expected_len or
        view.characters != alias_expected_characters or
        view.marked != null;
    try checks.expect(
        report,
        "text.a_borrowed_whole_value_outlives_the_cancel_that_ends_a_composition",
        alias_closed_queued and alias_focused_queued and
            alias_closed == 1 and !view.modal_open and
            alias_focused == 1 and alias_holds_keyboard and alias_bound and
            alias_composed_writes == alias_pre_writes + 1 and
            alias_replaced_two and
            alias_whole_kept and
            alias_second_mark != null and
            !alias_resurrected and
            // Three writes are the floor: the whole value, the composition
            // that follows it, and the cancel that ends that one.
            view.text_writes >= alias_writes_before + 3,
        checks.note("modal closed queued={} applied={d} field_focus queued={} " ++
            "applied={d} field_focused={} endpoint={} | " ++
            "preedit replaced {d} chars (bytes {d}) with {d} chars (bytes {d}) | " ++
            "supplied=\"{s}\" {d} bytes {d} chars | outcome={s} whole -> \"{s}\" " ++
            "{d} bytes {d} chars caret={d} marked={any} | cancel -> \"{s}\" " ++
            "{d} bytes marked={any} resurrected={} | writes {d}->{d}->{d}", .{
            alias_closed_queued,
            alias_closed,
            alias_focused_queued,
            alias_focused,
            alias_holds_keyboard,
            alias_bound,
            alias_replaced_characters,
            alias_replaced.len,
            alias_mark_characters,
            alias_mark_bytes.len,
            alias_expected[0..alias_expected_len],
            alias_expected_len,
            alias_expected_characters,
            @tagName(alias_outcome),
            alias_whole[0..alias_whole_len],
            alias_whole_len,
            alias_whole_characters,
            alias_whole_caret,
            alias_whole_marked,
            view.text(),
            view.text_len,
            view.marked,
            alias_resurrected,
            alias_pre_writes,
            alias_composed_writes,
            view.text_writes,
        }),
    );

    // ── Positioned edits address the LIVE value's scalars ──
    //
    // Every edit above travelled as a whole value or as a selection. A
    // positioned request is a third shape: it names SCALARS of the bytes the
    // model holds NOW, so neither endpoint may be resolved against the run
    // this frame published. The whole value below fixes what the model holds
    // first, and the two positioned requests after it are stated against
    // those bytes rather than against anything a reader was told earlier.
    const seeded_writes = view.text_writes;
    const positioned_snapshot = try requireSnapshot(h);
    const seeded_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.set_value),
        .data = .value,
        .value = "Grüße ✓€€",
    });
    const seeded = h.adapter.drain(positioned_snapshot, &h.disp, h.scratch());
    try checks.expect(
        report,
        "text.a_whole_value_seeds_the_live_text",
        seeded_queued and seeded == 1 and std.mem.eql(u8, view.text(), "Grüße ✓€€") and
            view.text_len == 17 and view.characters == 9 and
            view.anchor == 17 and view.caret == 17 and
            view.text_writes == seeded_writes + 1,
        checks.note("queued={} applied={d} value=\"{s}\" bytes={d} characters={d} " ++
            "anchor={d} caret={d} text_writes={d}->{d}", .{
            seeded_queued,
            seeded,
            view.text(),
            view.text_len,
            view.characters,
            view.anchor,
            view.caret,
            seeded_writes,
            view.text_writes,
        }),
    );

    // Two positioned requests, ONE ring batch and ONE drain: the second
    // resolves against the bytes the first left, not against the seventeen
    // the model held when the batch began. The delete takes out the "ü" and
    // the insert puts a character that is four bytes, two UTF-16 code units
    // and exactly ONE scalar back where it stood — which is the whole reason
    // a positioned request counts scalars rather than characters or bytes.
    const positioned_writes = view.text_writes;
    const delete_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .text_range,
        .value = "",
        .anchor_index = 2,
        .focus_index = 3,
        .anchor_node = ids.field,
        .focus_node = ids.field,
    });
    const insert_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .text_range,
        .value = "𝔘",
        .anchor_index = 2,
        .focus_index = 2,
        .anchor_node = ids.field,
        .focus_node = ids.field,
    });
    const positioned = h.adapter.drain(positioned_snapshot, &h.disp, h.scratch());
    try checks.expect(
        report,
        "text.a_positioned_edit_resolves_live_scalars_in_one_batch",
        delete_queued and insert_queued and positioned == 2 and
            std.mem.eql(u8, view.text(), "Gr𝔘ße ✓€€") and
            view.text_len == 19 and view.characters == 9 and
            std.unicode.utf8ValidateSlice(view.text()) and
            view.anchor == 6 and view.caret == 6 and
            scalarOffset(view.text(), 3) == view.caret and
            view.marked == null and
            view.text_writes == positioned_writes + 2,
        checks.note("queued={}/{} applied={d} value=\"{s}\" bytes={d} " ++
            "characters={d} " ++
            "anchor={d} caret={d} scalar3_byte={any} marked={any} " ++
            "text_writes={d}->{d}", .{
            delete_queued,
            insert_queued,
            positioned,
            view.text(),
            view.text_len,
            view.characters,
            view.anchor,
            view.caret,
            scalarOffset(view.text(), 3),
            view.marked,
            positioned_writes,
            view.text_writes,
        }),
    );

    // A whole value the field cannot store is REFUSED, and it is refused
    // before anything moves: this payload is one byte longer than the 96 the
    // buffer holds, so no byte of the model is replaced, the caret stays
    // where the positioned edit left it, and the model records no write at
    // all. Storing the 96 bytes that DO fit would be a different value than
    // the one that was asked for, presented as if it were this.
    const overflow_writes = view.text_writes;
    const oversized: [model_text_bytes + 1]u8 = @splat('x');
    const overflow_queued = h.adapter.enqueueRequest(.{
        .id = ids.field,
        .action = @backingInt(semantics.Action.set_value),
        .data = .value,
        .value = &oversized,
    });
    const overflowed = h.adapter.drain(positioned_snapshot, &h.disp, h.scratch());
    try checks.expect(
        report,
        "text.a_whole_value_past_the_buffer_changes_nothing",
        overflow_queued and overflowed == 0 and
            std.mem.eql(u8, view.text(), "Gr𝔘ße ✓€€") and
            view.text_len == 19 and view.anchor == 6 and view.caret == 6 and
            view.text_writes == overflow_writes,
        checks.note("queued={} applied={d} payload={d} bytes into a {d}-byte " ++
            "buffer | value=\"{s}\" bytes={d} anchor={d} caret={d} " ++
            "text_writes={d}->{d}", .{
            overflow_queued,
            overflowed,
            oversized.len,
            model_text_bytes,
            view.text(),
            view.text_len,
            view.anchor,
            view.caret,
            overflow_writes,
            view.text_writes,
        }),
    );

    // The two edits reach the platform as ONE republication: the run, its
    // character table and its selection are all measured from the bytes the
    // batch left, and the caret the positioned insert chose is published at
    // the character index that same value gives it.
    _ = try h.headlessFrame(report, 10);
    {
        const tenth = try requireSnapshot(h);
        const tenth_field = (try requireNode(nodeNamed(tenth, label_text), label_text)).id;
        const tenth_run = (try requireNode(tenth.node(tenth_field), label_text)).text.?;
        const tenth_lengths = h.adapter.lastCharacterLengths(tenth_field) orelse &.{};
        try checks.expect(
            report,
            "text.the_positioned_result_republishes_with_its_own_table",
            std.mem.eql(u8, tenth_run.value, "Gr𝔘ße ✓€€") and
                tenth_lengths.len == view.characters and
                // The caret sits after "Gr𝔘": three CHARACTERS, even though
                // the same offset is six bytes.
                accessibility.characterIndexOf(tenth_run, view.caret) == 3,
            checks.note("field={d} value=\"{s}\" table={d} characters={d} " ++
                "caret_byte={d} caret_character={d}", .{
                tenth_field,
                tenth_run.value,
                tenth_lengths.len,
                view.characters,
                view.caret,
                accessibility.characterIndexOf(tenth_run, view.caret),
            }),
        );
    }

    try report.emit("check: passed={d} failed={d}\n", .{ checks.passed, checks.failed });
    if (checks.failed != 0) return error.HeadlessCheckFailed;
}

// ── The native gate ─────────────────────

/// The native gate: one real toplevel, published through the real adapter,
/// PAINTED through the public frame adapter, and held open for an external
/// AT-SPI client. Everything about the published tree comes from the shared
/// harness; only the device, the frame source and the hold loop belong to
/// this mode.
fn runNative(
    h: *Harness,
    report: *Reporter,
    hold_ms: u64,
    ppm: ?[]const u8,
    ring: bool,
    synthetic: bool,
    require_active: bool,
) !void {
    const gpa = h.gpa;
    const io = h.io;
    const app = h.app;

    const application = try gpa.create(Application);
    // Only the allocation is owned before `init` returns. An `init` that
    // refuses — an SDL driver that will not start — must not run `deinit`
    // over a struct no constructor ever filled, so the host's own release is
    // armed only once there is a constructed host to release.
    errdefer gpa.destroy(application);
    application.* = try Application.init(gpa, h.session, .{
        .app_id = "dev.nogui.w21atspi",
        .restart = .never,
    });
    errdefer application.deinit();

    const title: [:0]const u8 = "w21-atspi-smoke";
    const handle = try application.openWindowWithApp(app, .{
        .title = title,
        .width = 520,
        .height = @intFromFloat(headless_surface.height),
        .resizable = false,
        .visible = true,
        .gpu_surface = true,
    });
    const managed = try application.getWindow(handle);

    // The device, the surface and the public frame adapter. The window is
    // open first because the surface is created over the window the platform
    // really gave this process.
    // SAFETY: `init` fills the whole struct, and the release defer below reads
    // it only when `native_live` says that call returned.
    var native: NativeHalf = undefined;
    var native_live = false;
    defer if (native_live) native.deinit(gpa);
    try native.init(gpa, io, managed);
    native_live = true;

    // The App measures its layout through the engine that rasterizes the
    // glyphs, so a measured label and a painted glyph are one measurement.
    // The endpoint is the adapter's own, so the tree's paint is recorded
    // against the same heap the adapter's blit samples.
    app.measure = native.adapter.measurer();
    try app.attachGpu(native.adapter.gpuEndpoint());
    var gpu_attached = true;
    defer if (gpu_attached) app.detachGpu();

    // The window's OWN observed scale, given to the semantic edge before the
    // first frame and again on every frame after it, so a published
    // coordinate is physical pixels at the ratio this window really has.
    const first_scale = try managed.observed.pixelScale();
    h.setScale(first_scale.x, first_scale.y);
    try report.emit("window: title=\"{s}\" observed={d}x{d} pixels={d}x{d} video_driver={s}\n", .{
        title,
        managed.observed.size.width,
        managed.observed.size.height,
        managed.observed.pixels.width,
        managed.observed.pixels.height,
        sdl3.video.getCurrentDriverName() orelse "<null>",
    });

    // The ONE shaped measurement the field's pixels and the field's published
    // geometry both read. The view holds it so the annotator, which runs on
    // the publish path, and the painter, which runs inside the frame, meet at
    // the same value instead of two that happen to agree today.
    //
    // The paint helpers live IN the window, so their addresses stay valid for
    // as long as it does and neither is ever copied.
    var window: Window = .{
        .harness = h,
        .application = application,
        .handle = handle,
        .native = &native,
        .synthetic = synthetic,
        .shaper = Shaper.init(gpa, native.adapter.textEngine()),
        .runs = RunCache.init(gpa, native.adapter.textEngine()),
        // SAFETY: the painter borrows this struct's own shaper and run cache, so
        // it is assigned on the next line, once this struct has its address.
        .painter = undefined,
    };
    window.painter = .{
        .harness = h,
        .engine = native.adapter.textEngine(),
        .shaper = &window.shaper,
        .runs = &window.runs,
    };
    // The guards above owned the half while it was being built. This struct is
    // whole now, so it owns them, and they hand over: one owner, one release,
    // and no outer flag that has to remember a half it no longer holds.
    native_live = false;
    gpu_attached = false;
    window.live = true;
    defer window.releaseNative();
    h.view.shaper = &window.shaper;

    try report.emit("adapter: linked={} scale={d:.3}x{d:.3} paint=NativeFrame\n", .{
        accessibility.linked,
        h.scale_x,
        h.scale_y,
    });

    application.setHooks(.{
        .context = &window,
        .on_frame = Window.onFrame,
        // The host sends no input to an App on its own, so the window hands
        // every translated event over. Without this the field owns a text
        // endpoint that no key and no committed text could ever reach.
        .on_event = Window.onEvent,
        .on_quit_request = Window.onQuitRequest,
        // The GPU half is retired here, while the window still exists.
        .on_before_close = Window.onBeforeClose,
    });
    try application.start();

    // ── The bell ─────────────────────────────
    // The adapter is bound to the window this run ACTUALLY opened, not to a
    // stand-in, so the capability report below is a fact about this display.
    // Binding is a lifetime statement and rings nothing by itself.
    try h.adapter.bindSystemBell(application, handle);
    const bell_available = h.adapter.capability().bell;
    try report.emit("bell: bound=true available={} video_driver={s}\n", .{
        bell_available,
        sdl3.video.getCurrentDriverName() orelse "<null>",
    });
    // One ring, only because it was asked for. `rung` means the platform took
    // the request; nothing in this process can hear the answer, so no sound is
    // claimed here.
    if (ring) {
        const outcome = h.adapter.bell();
        try report.emit("bell: request={s} available={}\n", .{
            @tagName(outcome),
            bell_available,
        });
        var checks: Checks = .{};
        // A backend that reports it can ring must accept the request, and one
        // that reports it cannot must say so. A transport failure, a closed
        // window and a wrong thread are all reported as themselves and none
        // of them passes as a working bell.
        try checks.expect(
            report,
            "bell.request_honoured",
            switch (outcome) {
                .rung => bell_available,
                .unsupported => !bell_available,
                .provider_failed, .window_closed, .wrong_thread => false,
            },
            checks.note("driver={s} available={} result={s}", .{
                sdl3.video.getCurrentDriverName() orelse "<null>",
                bell_available,
                @tagName(outcome),
            }),
        );
        if (checks.failed != 0) return error.NativeBellCheckFailed;
    }

    // ── The gate ───────────────────────────
    // Publish, drain, repaint, republish, until the deadline. A reader
    // attaches from OUTSIDE this process, so the loop must stay live for the
    // whole hold.
    try report.emit("holding {d} ms for an external AT-SPI client\n", .{hold_ms});
    if (!synthetic) try report.emit(
        "synthetic: disabled by --no-synthetic, so nothing inside this process moves " ++
            "the model and every counter below is an external client's call\n",
        .{},
    );
    const deadline = sdl3.timer.getMillisecondsSinceInit() + hold_ms;
    while (sdl3.timer.getMillisecondsSinceInit() < deadline) {
        if (!try application.step()) {
            window.host_running = false;
            break;
        }
        // A platform can close this window from inside that step, and the host
        // hook retires the GPU half before SDL destroys it. Nothing below this
        // point may touch what was just released, so the hold ends here rather
        // than reporting through a retired shaper.
        if (!window.live) {
            try report.emit("holding: the window was retired mid-hold\n", .{});
            break;
        }
        try window.pump(report);
        try Io.sleep(io, Io.Duration.fromMilliseconds(4), .real);
    }

    // The pixels of the last presented frame, read back out of the target the
    // two passes wrote. This is what the window showed, not a re-render.
    //
    // A platform that closed the window during the hold already retired the
    // frame adapter through the hook, so the surface that held those pixels is
    // gone. The run says so instead of reaching into a released adapter.
    if (!window.live) {
        try report.emit(
            "pixels: the window was retired during the hold, so the surface " ++
                "that held the last presented frame is gone and there are no " ++
                "pixels to read\n",
            .{},
        );
    } else if (window.frames_committed != 0) {
        try window.census(report);
        if (ppm) |path| try window.writePpm(report, path);
    } else {
        try report.emit("pixels: no frame was presented, so there are no pixels to read\n", .{});
    }

    // Read the adapter while it is whole, or the copy taken at retirement once
    // it is gone. `rects` is what this window PAINTED and
    // `published_generation` is what the semantic publisher actually
    // committed; neither is a second name for a presented frame.
    const stats = window.frameStats();
    const target = window.frameTarget();
    const published = h.publisher.snapshot();
    try report.emit(
        "holding: frames={d} presented={d} retries={d} rects={d} published_generation={d} " ++
            "host_running={} state={s}\n",
        .{
            window.frames_committed,
            stats.frames_presented,
            window.retries,
            window.painted.rects,
            if (published) |snapshot| snapshot.generation else 0,
            window.host_running,
            @tagName(h.adapter.stateOf()),
        },
    );
    try report.emit(
        "frame: committed={d} presented={d} resizes_requested={d} swapchains_recreated={d} " ++
            "extent_mismatches={d} present_out_of_date={d} scale_changes={d} target={d}x{d}\n",
        .{
            stats.frames_committed,
            stats.frames_presented,
            stats.resizes_requested,
            stats.swapchains_recreated,
            stats.extent_mismatches,
            stats.present_out_of_date,
            stats.scale_changes,
            target.width,
            target.height,
        },
    );

    // ── The window this run painted, and the one it published ──
    if (window.frames_committed != 0) {
        var checks: Checks = .{};
        try window.checkListAgreement(report, &checks);
        try report.emit("check: passed={d} failed={d}\n", .{ checks.passed, checks.failed });
        if (checks.failed != 0) return error.NativeListCheckFailed;
    } else {
        try report.emit(
            "check: no frame was presented, so there is no painted window to " ++
                "compare the published one against\n",
            .{},
        );
    }

    // ── The approved acceptance gate ───────────────
    //
    // Off unless `--require-accessibility-active` asked for it. A plain
    // `--native` run is a frame proof and keeps being one: the list-window
    // agreement above is its verdict and nothing below changes that. When the
    // flag IS set, the run has a real screen reader on a real accessibility bus
    // and may therefore insist that one attached and that the published tree
    // carries the roles, relations, marks and values it claims to.
    if (require_active) {
        // Introspection reads the last ABI update, which is normally a delta.
        // Encode the committed snapshot for complete ABI checks. This does
        // not publish or prove native readback; the external AT-SPI client
        // observes the real SDK tree separately.
        const snapshot = try requireSnapshot(h);
        _ = try h.adapter.encodeFullSnapshot(snapshot, .{ .focused = true });
        var checks: Checks = .{};
        try checkAdapterActive(h, report, &checks);
        try checkPublishedTree(h, report, &checks);
        try report.emit("check: passed={d} failed={d}\n", .{ checks.passed, checks.failed });
        if (checks.failed != 0) return error.NativeAccessibilityCheckFailed;
    } else {
        try report.emit(
            "check: --require-accessibility-active was not passed, so this run " ++
                "proves the painted window and nothing more\n",
            .{},
        );
    }

    // ── Clean shutdown ─────────────────────
    // The explicit close goes through the host, so the hook retires the GPU
    // half while the window is still alive. Nothing here reaches past the
    // adapter: the census above already read the pixels, and the report below
    // reads the copy that retirement left behind.
    //
    // A window the platform already closed needs no close here. Asking again
    // would resolve a handle that no longer names anything, and the hook has
    // run either way.
    if (window.live) {
        const closed = try application.closeWindow(handle);
        _ = try application.step();
        try report.emit("close: released={} window_count={d} host_running={}\n", .{
            closed,
            application.window_count,
            application.isRunning(),
        });
    } else {
        try report.emit(
            "close: the platform closed this window during the hold\n",
            .{},
        );
    }
    const retired = window.frameTarget();
    try report.emit(
        "retire: surface_before_window={d} frames_at_retire={d} target={d}x{d}\n",
        .{
            window.retirements,
            window.frameStats().frames_presented,
            retired.width,
            retired.height,
        },
    );

    // The App is the last thing this mode owns. The host closed the window that
    // borrowed it, so the Session no longer knows that registration, and only
    // now does the App release its own arenas and its mount.
    app.deinit();
    h.app_live = false;
    try application.requestQuit();
    application.deinit();
    gpa.destroy(application);
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    // The window is opt-in. A run with no `--native` never initializes SDL's
    // video, never creates a toplevel and never touches the compositor, so
    // the default is safe to run on a machine with no desktop at all.
    var native = false;
    // The ring is opt-in for the same reason the window is: it makes a sound.
    var bell = false;
    // The synthetic batches are opt-out for the same reason: an external client
    // needs counters nothing else moved, or its own calls cannot be told apart
    // from this process's.
    var synthetic = true;
    // Opt-in for exactly one caller: an approved acceptance run, which has a
    // real screen reader on a real accessibility bus and therefore may demand
    // that one attached. Every other `--native` run leaves it off.
    var require_active = false;
    var hold_ms: u64 = default_hold_ms;
    // Where to write the last presented frame's pixels. Borrowed from the
    // argument buffer, which outlives the run.
    var ppm: ?[]const u8 = null;
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            native = true;
        } else if (std.mem.eql(u8, arg, "--hold-ms")) {
            hold_ms = try std.fmt.parseInt(u64, args_it.next() orelse return error.MissingHoldMs, 10);
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            ppm = args_it.next() orelse return error.MissingPpmPath;
        } else if (std.mem.eql(u8, arg, "--no-synthetic")) {
            synthetic = false;
        } else if (std.mem.eql(u8, arg, "--bell")) {
            bell = true;
        } else if (std.mem.eql(u8, arg, "--require-accessibility-active")) {
            require_active = true;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }

    // A ring needs a window this process actually owns. Accepting the flag
    // without one and reporting nothing would be a run that looks like it
    // rang something.
    if (bell and !native) {
        std.log.err("--bell needs --native: the headless run owns no window", .{});
        return error.BellWithoutWindow;
    }

    // Synthetic requests are driven from the window's hold loop, so without a
    // window there is nothing for the flag to switch off.
    if (!synthetic and !native) {
        std.log.err("--no-synthetic needs --native: the headless gate has no hold", .{});
        return error.SyntheticWithoutWindow;
    }

    var report: Reporter = .{ .io = io };
    try report.emit("W21 AT-SPI smoke\n", .{});

    const session = try gpa.create(Session);
    session.* = try Session.init(gpa);

    const app = try gpa.create(App);
    app.* = try App.init(gpa, session);
    const view = try gpa.create(PanelView);
    view.* = .{ .app = app };
    // The component registry does not run a component `init`, so the view's
    // own one is called here. Without it the field publishes an empty
    // character table and the whole byte/character conversion is untested.
    view.init();
    try app.mountRoot(PanelView, view);

    // The field's text model. The endpoint holds a WEAK handle on it and this
    // run holds the strong one, so the shutdown below can retire the model
    // while the App is still whole. The TEXT stays in `view`: this model
    // records which carrier the endpoint is bound under and nothing else, and
    // the bytes an AT-SPI edit writes are the same bytes a committed native
    // key inserts into.
    var field_token: FieldModel = .{};
    view.field_model = try session.create(FieldModel, &field_token);

    // The bridge keeps a raw pointer to the adapter for its whole lifetime, so
    // it is heap-allocated here, never a stack temporary.
    const adapter = try gpa.create(accessibility.Adapter);
    adapter.init(gpa, io);

    var harness: Harness = .{
        .gpa = gpa,
        .io = io,
        .session = session,
        .app = app,
        .view = view,
        .adapter = adapter,
        .disp = makeDispatcher(view),
        .publisher = semantics.Publisher.init(gpa),
    };

    // The App publishes every tree it builds, inside the frame transaction
    // that built it: one publisher, one window name and one annotation
    // context, configured once and never changed. A frame it cannot annotate
    // aborts its own attempt, so a failed frame cannot advance the published
    // tree, and nothing else in this run stages one.
    app.semantic_publication = .{
        .publisher = &harness.publisher,
        .window_name = window_name,
        .annotator = .{ .context = view, .annotate = annotate },
    };

    // ── Shutdown ─────────────────────────
    // One block, in dependency order, so the success path and an error path
    // release the same things the same way. The App is the one object with
    // two possible owners: the window half must deinit it BEFORE the GPU
    // device goes away, so it reports that it did and this block leaves it
    // alone.
    defer {
        adapter.deinit();
        gpa.destroy(adapter);
        // The App's borrow of the publisher ends before the publisher dies,
        // and only while the App is still live: the native half releases it
        // and poisons the struct on its way out.
        if (harness.app_live) app.semantic_publication = null;
        harness.publisher.deinit();
        // The endpoint borrows the field's model weakly, so the run retires
        // it in that order: the registration goes first, then the model. A
        // borrow that arrives after this fails as a lost model instead of
        // editing bytes that are about to be freed with the view.
        if (harness.app_live) app.textInputManager().clear();
        if (view.field_model) |*model| {
            session.release(FieldModel, model) catch |err| std.debug.panic(
                "W21 field model release failed: {s}",
                .{@errorName(err)},
            );
        }
        if (harness.app_live) app.deinit();
        gpa.destroy(app);
        gpa.destroy(view);
        const deinit_result = session.deinit();
        gpa.destroy(session);
        // stdout is still live in here: the `Io.Threaded` that backs it was
        // registered before this block, so it outlives every release above.
        report.emit("shutdown: session_deinit={s}\n", .{
            if (deinit_result) |_| "ok" else |err| @errorName(err),
        }) catch |err| std.debug.panic("W21 shutdown report write failed: {s}", .{@errorName(err)});
    }

    if (native) {
        try runNative(&harness, &report, hold_ms, ppm, bell, synthetic, require_active);
    } else {
        try runHeadless(&harness, &report);
    }

    try harness.reportSummary(&report);
    try report.emit("adapter: linked={} state={s} dropped={d} pending={} bell={s}\n", .{
        accessibility.linked,
        @tagName(adapter.stateOf()),
        adapter.droppedRequests(),
        adapter.hasPending(),
        @tagName(adapter.bell()),
    });
    try report.emit("W21 AT-SPI smoke done\n", .{});
}

test "api-w21 semantic text maps a full-capacity value without a terminator slot" {
    // The view names the App it belongs to, so the test builds the same pair
    // `main` builds — a real session and a real app, released in the same
    // order. The text path never reaches through the app, but a fabricated
    // pointer is a lie the next reader would copy.
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    var view: PanelView = .{ .app = &app };
    var full: @TypeOf(view.text_buf) = undefined;
    @memset(&full, 'x');
    _ = view.writeWholeText(&full, null);
    try std.testing.expectEqual(full.len, view.text().len);
    try std.testing.expectEqual(full.len, view.characters);
    for (view.char_lengths[0..view.characters]) |length| {
        try std.testing.expectEqual(@as(u8, 1), length);
    }
    _ = view.writeWholeText("é😀", null);
    try std.testing.expectEqualSlices(u8, &.{ 2, 4 }, view.char_lengths[0..view.characters]);
}
