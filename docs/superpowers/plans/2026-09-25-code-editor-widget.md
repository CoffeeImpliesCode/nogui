# Code Editor Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a usable, focusable code editor to nogui. A private Neovim process owns edits, while nogui paints its monospace cell grid.

**Architecture:** A persistent `Session` model owns one embedded Neovim process, a bounded MessagePack-RPC channel, and the last complete grid snapshot. The public widget is a W08 custom element leaf: `DrawCtx.codeEditor` is a thin wrapper over the existing `DrawCtx.elementLeaf`, so the editor adds no widget kind, no layout/paint dispatch family, and no second focus identity. Input arrives as ordinary W09 events, is translated by the component that created the leaf, and reuses the W12 text protocol and the W18 clipboard service. nogui paints the cell grid with W13 paint records through the existing noapi scene renderer. One editor session owns one Neovim UI and one buffer, and the model handle — not the window — owns the session lifetime.

**Tech Stack:** Zig 0.16.0, SDL3, the `nogui` core module plus `nogui_host`, `nogui_text` and `v7_render`, and an external `nvim` executable. The installed `nvim --version` reports **0.12.5**. Implement the small required MessagePack-RPC subset in Zig; do not add a package dependency.

## Reconciliation status (2026-09-30)

- This document is a **plan**. No code editor exists: a repository-wide search for `nvim`, `codeEditor`, `code_editor`, `EditorView` and `GridSnapshot` under `src/` returns nothing. Every name in [Proposed contract](#proposed-contract-not-implemented) is a target, never a description of present behavior.
- The [GPUI API parity plan](2026-09-26-gpui-api-parity.md#existing-plan-reconciliation) supersedes this document's earlier infrastructure instructions, not its product goal. GPUI supplies no built-in code editor, so this widget is **not** part of GPUI parity and is not added to that plan's work graph.
- Infrastructure now comes from the parity packages, never from a second implementation. The private RPC codec, grid model, process isolation, recovery mirror and save protocol remain this plan's own work and are unchanged.
- The original "Verified integration seams" list was a source baseline, and several of its statements are no longer true. It is replaced by [Dated source baseline](#dated-source-baseline), which separates what the tree contains from what this plan proposes.

### Reconciliation rule mapping

| # | Superseded instruction (2026-09-25 revision) | Rule this plan now follows |
| --- | --- | --- |
| 1 | Add `.code_editor` to every closed `WidgetKind` switch | `DrawCtx.codeEditor` wraps the W08 custom element descriptor. `WidgetKind` keeps one extension arm; explicit cell-grid measurement, post-layout resize, clipping and the semantic role stay. No second layout or paint dispatch family. |
| 2 | `FocusTarget { control: Id, editor: ComponentId }` | One stable W02/W09 `WidgetId` for controls and editor leaves. Editor **session** identity (the model handle) is separate from the leaf's **view** identity (its widget key). |
| 3 | Editor-specific modifiers, composition offsets, direct SDL routing | Reuse W09 events and the W12 text protocol. Preedit selection is UTF-8 bytes relative to the preedit string. An ordinary field and Neovim are distinct focused consumers. |
| 4 | `font_id: u8` and a private demo grid painter | Validated W11 font resolution and metrics plus W13 paint records. Grid cells may still use fixed advances and editor-owned highlight data. |
| 5 | Editor-owned clipboard and independent worker delivery | The W18 system clipboard service, with a bounded editor RPC adapter on W05 scheduling and completion. RPC backpressure, child isolation, recovery and save requirements are preserved. |
| 6 | Surface-pixel mouse conversion before editor coordinates | W02/W07 logical window coordinates, then cell conversion. Device conversion happens only at the host and render boundaries. |
| 7 | Root explicitly owns the session and immutable grid snapshots | A persistent model owns them. RPC buffers and the grid never live in frame state. The two live frame trees and GPU completion govern snapshot retirement. |

The public leaf, input and paint integration consumes W02, W03, W05, W08, W09, W11, W12, W13 and W18. Do not ship the old and new focus or text runtimes together as the shipped interface; there is no compatibility alias for a removed type.

## Global constraints

Kept from the original plan:

- Keep GPU access behind noapi. Keep intermediate colors in Oklab and use the existing final sRGB blit. Convert authored sRGB to Oklab once, at the paint boundary.
- Do not use a terminal emulator, a PTY, Neovim's legacy grid events, direct Vulkan handles, or `nvim --embed --headless`.
- One UI capability set: `rgb=true`, `ext_linegrid=true`, and no `ext_multigrid` or externalized command line, messages, popup menu, or tab line. The single grid includes Neovim's ordinary chrome.
- Do not add silent native-editor or legacy-UI fallbacks. A missing executable, an unsupported feature, an invalid protocol, or unavailable required isolation must produce a visible, typed failure.
- Do not treat an optional component `deinit` entry as an automatic unmount hook. The owner stops `EditorSession` explicitly, before renderer and App teardown.

Replaced, because the parity packages now own them:

- **Frame ownership.** Frame arenas own frame data only. The child process, RPC buffers, the cell grid and the recovery text live in a `Session` model. The element payload borrows a committed snapshot; `DrawCtx.state` and frame arenas are never the owner.
- **Geometry.** Widget rectangles stay parent-relative. Pointer and IME math start in logical window coordinates (`geometry.WindowPoint`), use the node's visual content box, and convert to cells last. DPI conversion belongs to the host and render boundaries.
- **Snapshot lifetime.** A committed snapshot stays valid while any live frame tree can still read it, and any GPU-attached resource is released only after `GpuEndpoint.waitForRetirement` completes for the retirement batch. There is no fixed slot count and no manual ring.
- **Focus and input routing.** One `WidgetId` per interactive leaf. The editor's owning component handles routed events and calls `preventDefault` for keys Neovim owns. The demo's own shortcuts are already gated on `App.last_input_default_prevented`, so a focused editor cannot lose a keystroke to them.

## Dated source baseline

Observed by reading the tree on **2026-09-30**. These are facts, not proposals, and each claim below was re-checked against the named file rather than remembered from the 2026-09-25 draft.

Core (`nogui` = `src/v7/root.zig`):

- `src/v7/widget.zig`: `WidgetKind` is a closed union whose single extension arm is `element: *element.Frame`. There is no code-editor arm, and adding one is not required.
- `src/v7/element.zig`: `element.Operations` is the W08 table — `measure`, `layout`, `prepaint`, `paint`, `semantics`, `build_late`, `commit`. `element.Frame` holds `payload`, `phase`, `ops`, `revision`, `late_scope`, `component_scope`, `paint_records` and `semantic`. `element.Geometry` carries `border` and `content` boxes in **logical window coordinates**. `PaintWriter` bounds work with `max_records = 256`, `max_path_commands = 4096`, `max_shadows = 64`. `Operations.commit` is documented as publishing staged persistent state only after the App commits the frame.
- `src/v7/drawctx.zig`: `elementLeaf` and `elementContainer` are the only element constructors. `elementLeaf` binds a `WidgetId` when opts carry `key`; `interactiveWidgetId` returns `error.MissingWidgetKey` without one. `setInteractionOptions` reads `disabled`, `focusable`, `tab_index` and `tab_group`. There is no `codeEditor` method.
- `src/v7/focus.zig`: `focus.Manager.current` is `?WidgetId`. `defaultDescribe` treats only `.button`, `.slider`, `.checkbox`, `.switch_control` and `.radio` as focusable built-ins; every other kind, including `.element`, must set `interaction.focusable`. `reconcile` cancels captures and moves focus when a keyed owner disappears.
- `src/v7/identity.zig`: `WidgetId` is a `{owner, slot, generation}` handle registered per component scope and key, with `DuplicateWidgetKey` and `IdentityCollision` errors and a per-frame `commitFrame`/`abortFrame` pair.
- `src/v7/app.zig`: `handle` routes `key_up`, `text_input` and `composition` to the focused node first and only then to the W12 field manager. `key_down` also reaches the focused node first, and the resulting `default_prevented` flag is what the W10 keymap receives, so a key the focused consumer handled never reaches a global binding; the App's own `handleKey` defaults run last (`.tab` steps focus, `.escape` blurs). A mouse press focuses a `focusable` hit target. Routed events reach the component that owns the node through `Component.vtable.on_routed_event`, resolved by `node.owner`. `FrameOutput.focus` carries the stable focus identity, and `FrameOutput.tree` and `prev_tree` expose the current and previous committed trees.
- `src/v7/geometry.zig`: `WindowPoint`, `WindowRect`, `DevicePoint`, `PixelScale` and the named logical/device conversions.
- `src/v7/session.zig`: `Session` owns models (`create`, `reserve`, `insert`, `retain`, `release`, `read`, `update`, `WeakModel`) and the task service (`startTasks`, `spawnWorker`, `scheduleUi`, `drainTasks`, `shutdownTasks`, `setTaskWake`, `waitForTaskWake`).
- `src/v7/text.zig`: renderer-neutral `FontRequest`, `FontRequestOverride`, `FontHandle`, `FontMetrics`, `TextStyle`, `TextStyleOverride`, `LayoutRequest` and `Color` as sRGB components.
- `src/v7/text_input.zig`: `Endpoint`/`Ops`/`Policy` for an application-owned buffer, `Manager` with `register`/`clear`/`invalidateGeometry`, the `Native` port (`start`, `stop`, `set_area`, `clear_composition`), `NativeStatus`, and `ClipboardRead` keeping `unavailable`, `empty` and `failed` distinct.
- `src/v7/clipboard.zig` and `src/v7/paint.zig`: `Item`/`Offer`/`Format`/`Selection` with owned bytes, and `paint.Color` as `palette`/`srgb`/`oklab` with a single validated conversion boundary.
- `src/v7/headless.zig`: `FrameOutput.tree` stays readable during the next frame attempt, even when that attempt fails, and a newer commit may reset its arena. `FrameOutput.prev_tree` is readable only until the next frame attempt starts, whether that attempt succeeds or fails. A readable previous snapshot can never dispatch input again.

Host and services:

- `src/v7_host/window.zig`: `translateEvent` already converts SDL pointer, wheel and button coordinates into `geometry.WindowPoint` before `App.handle`; `Window.nativeTextInput()` returns a `nogui.text_input.Native` bound to SDL text input, composition and candidate-area calls. Native pointer conversion to device pixels does not exist on this path and is not needed.
- `src/v7_host/clipboard.zig`: `Clipboard.setText`, `readText`, `readItem`, `clear`, plus primary-selection access guarded by `error.UnsupportedCapability`.
- `src/v7_frame/scene.zig`: `buildSliceRects` lowers `.label` and control captions through the host `TextEngine` (`emitText`, `emitTextWithWidth`, `emitTextFlow`) and lowers element paint records separately. A `.element` node is **not** on the label text path, so an element paint hook cannot emit glyphs today. `GlyphMaterialCeiling` is 1024 and `FrameMaterialSlots` is 768 per frame. `src/v7_render/render_9slice.zig` caps clips at `max_clip_rects = 64`.
- `src/v7_text/measure.zig`: `TextService.resolve`, `fontHandleForId`, `metrics`, `hasGlyph` and `layout` return validated handles, `text.FontMetrics` and immutable layouts.
- `build.zig`: `-Dtest-filter` feeds every registered test root; `zig build test` builds the core, `nogui_test`, per-product library tests and one `exe_tests` root over `src/v7_demo/main.zig`, whose `test` block lists every scene file whose tests it runs. `zig build v7 -- <args>` runs the demo.

The dated baseline keeps its original identifiers. The current scene constants are
`glyph_material_ceiling` and `frame_material_slots`.

## Proposed contract (not implemented)

Names below are the target. Nothing here exists yet.

### Value types (`src/v7/editor_view.zig`)

Value-only, no SDL, no process, no GPU, exported from `src/v7/root.zig`:

```zig
// Modifiers, keys, pointers, wheels and composition are the W09 `event`
// types themselves. This module declares no editor-specific event or
// modifier type.
pub const DefaultColors = struct { foreground: ?u24, background: ?u24, special: ?u24 };
pub const Highlight = struct {
    id: u32,
    foreground: ?u24 = null,
    background: ?u24 = null,
    special: ?u24 = null,
    reverse: bool = false,
    bold: bool = false,
    italic: bool = false,
    strikethrough: bool = false,
    underline: bool = false,
    undercurl: bool = false,
    underdouble: bool = false,
    underdotted: bool = false,
    underdashed: bool = false,
    altfont: bool = false,
    dim: bool = false,
    blink: bool = false,
    conceal: bool = false,
    overline: bool = false,
    blend: ?u8 = null,
    url: ?[]const u8 = null,
};
pub const GridCell = struct {
    text: []const u8, // persistent UTF-8 payload; empty on a wide-glyph continuation
    attr_id: u32,
    continuation: bool,
};
pub const CursorShape = enum { block, horizontal, vertical };
pub const GridCursor = struct {
    row: u16,
    col: u16,
    shape: CursorShape,
    cell_percentage: ?u8,
    attr_id: u32,
    blinkwait_ms: u32,
    blinkon_ms: u32,
    blinkoff_ms: u32,
};
pub const GridSnapshot = struct {
    cols: u16,
    rows: u16,
    cells: []const GridCell, // row-major, index = row * cols + col
    defaults: DefaultColors,
    highlights: []const Highlight, // sorted by Neovim ID; lookup by ID, never by index
    cursor: ?GridCursor, // null while busy_start hides the cursor
    mode: []const u8, // persistent mode name from mode_change
    generation: u64,
};
pub const EditorFailure = enum {
    executable_unavailable, unsupported_api, invalid_protocol, process_exited,
    sandbox_unavailable, grid_too_large, glyph_capacity_exceeded,
    clipboard_unavailable, stale_recovery_mirror, unsupported_ui_attribute,
    file_too_large, line_too_large, file_changed_during_save, filesystem_error,
};
pub const EditorStatus = union(enum) {
    starting, ready, busy, stopped,
    degraded: EditorFailure, // recoverable renderer, clipboard and host-file errors
    failed: EditorFailure, // process, protocol or unsupported-API failure
};
pub const RecoveryStatus = union(enum) { available, stale: EditorFailure };
pub const EditorFiletype = enum {
    zig, c, cpp, rust, python, javascript, typescript, lua, json, markdown, text,
};
/// Cell metrics measured through the W11 service in logical window units.
pub const CellMetrics = struct { advance: f32, line_height: f32, baseline: f32 };
/// The frame payload. Copies value state and borrows one committed snapshot.
pub const EditorView = struct {
    snapshot: *const GridSnapshot,
    status: EditorStatus,
    recovery: RecoveryStatus,
    filetype: ?EditorFiletype = null,
    metrics: CellMetrics,
    requested: [2]u16, // cols, rows staged from the last layout phase
    generation: u64,
};
```

### Element descriptor and draw wrapper

```zig
/// W08 payload: declares `measure`, with optional `prepaint`/`paint`,
/// `semantics` and `commit`. No GPU handle, no process, no worker.
pub const CodeEditor = struct {
    view: EditorView,

    pub fn measure(value: *const CodeEditor, input: element.MeasureInput) element.Error!widget.Size;
    pub fn prepaint(value: *const CodeEditor, phase: *anyopaque, geometry: element.Geometry) element.Error!void;
    pub fn paint(value: *const CodeEditor, phase: *anyopaque, geometry: element.Geometry, writer: *element.PaintWriter) element.Error!void;
    pub fn semantics(value: *const CodeEditor, phase: *anyopaque, geometry: element.Geometry) element.Error!?element.Semantic;
    pub fn commit(value: *const CodeEditor, phase: *const anyopaque) void;
};

/// Proposed convenience wrapper. Not present today.
pub fn codeEditor(
    self: *DrawCtx,
    view: EditorView,
    opts: anytype, // key, width/height/focusable/tab_index/tab_group as normal style
) !FrameNodeId;
```

`codeEditor` only marshals options: it calls `DrawCtx.elementLeaf(CodeEditor, .{ .view = view }, opts)` and requires `key`, because a leaf without a key gets no `WidgetId` and therefore no focus. Width, height, `focusable`, `tab_index` and `tab_group` travel through the normal typed style and interaction options; there is no `font_id` field on this call. Duplicate keys surface as the existing `error.DuplicateWidgetKey`, so `EditorBuildError` is not a new error set.

### Session model (private, not core)

`EditorSessionModel` lives in `src/v7_demo/editor_session.zig` and is created through `Session.create`; components obtain it with `Session.read`/`update` and weak handles. It owns the child process, pipes, decode queues, the working and committed grid, the recovery mirror, the snapshot pins, and the bounded input queue. It holds no frame pointer and no `FrameNodeId`.

Snapshot retention replaces the old fixed three-slot ring:

- A frame that captured a snapshot holds one pin, and the pin follows that tree's documented lifetime: the current tree's pin survives a failed next attempt, while a previous-tree pin is released when the next attempt resets that arena.
- A snapshot is freed only when no live frame tree references it **and**, if the frame attached GPU-backed glyph or decoration resources for it, `GpuEndpoint.waitForRetirement` has completed for the batch that used them.
- `Operations.commit` is the only place that publishes staged per-frame state (a new snapshot pointer, a pending cell-count request) to the model, so an aborted frame leaves no published change.

### Input adapter (private)

`EditorInput` is a private value union, not a core type. It is built in the component's `onRoutedEvent` from W09 events, so no SDL type and no editor-specific key enum exists:

```zig
pub const EditorInput = union(enum) {
    key: struct { named: event.Key, logical: event.LogicalKey, physical: ?event.PhysicalKey, modifiers: event.Modifiers, repeat: bool },
    text: []const u8, // committed UTF-8, validated before enqueue
    composition: event.CompositionEvent, // preedit stays a host overlay and never mutates the remote grid
    pointer: struct { action: enum { press, move, drag, release }, button: ?event.MouseButton, row: u16, col: u16, modifiers: event.Modifiers },
    wheel: struct { delta_x: f32, delta_y: f32, row: u16, col: u16 },
};
```

`enqueue` copies borrowed text into the bounded queue before returning and reports a typed error when it cannot; the component then shows `status = .busy`. A dropped input is never reported as accepted.

The editor registers a W12 endpoint through `App.registerTextEndpoint`; the manager owns focus, native start and stop, the preedit record and candidate geometry, while the endpoint's operations read the session's authoritative grid and caret and queue committed edits. An operation the shared endpoint cannot express is an explicit W12 prerequisite, not a reason to add a private focus, IME or input runtime.

## Protocol and frame rules

1. Start one local child per session with argv `nvim --embed --clean --noplugin`. Do **not** add `--headless` or an external TCP listener. The owner holds stdin/stdout as binary RPC pipes, captures bounded stderr diagnostics, and reaps the child. The [startup manual, `*--clean*`, `*--noplugin*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/starting.txt) explains the config and plugin effects. Before UI attach, issue only fixed host commands `nvim_command("filetype on")` and `nvim_command("syntax enable")`. After attach, call `nvim_get_current_buf`, set its `filetype` only from the host-selected `EditorFiletype` enum through `nvim_set_option_value`, then attach its buffer mirror. Never form an executable command from file content, a path, or a user string.
2. Decode MessagePack-RPC request `[0,id,method,args]`, response `[1,id,error,result]`, and notification `[2,method,args]`. Match replies by ID. Service incoming clipboard requests even while host requests are pending; Neovim specifies message order and reverse-order responses to nested requests [API, `*msgpack-rpc*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api.txt). Never block the UI thread waiting for RPC: the reader is a W05 worker, and its results are delivered through the task service.
3. Before attach, request `nvim_get_api_info`. Check `ui_options` for `ext_linegrid`, and `functions` for `nvim_ui_attach`, `nvim_ui_try_resize`, `nvim_input`, `nvim_input_mouse`, `nvim_paste`, `nvim_get_current_buf`, `nvim_buf_attach`, `nvim_buf_get_changedtick`, `nvim_buf_set_lines`, `nvim_set_option_value`, and `nvim_command`. Reject a missing required function or extension with its name. Reject an API prerelease unless that exact level has an explicit compatibility test. Do not assume all 0.12 installations match this machine [API metadata and `nvim_get_api_info()`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api.txt). `nvim_ui_set_focus` is optional; if absent, expose reduced focus reporting instead of calling it [API, `*nvim_ui_set_focus()*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api.txt).
4. Attach `nvim_ui_attach(cols,rows,{rgb=true,ext_linegrid=true})` only when the reader can handle redraws. It resumes startup [API, `*nvim_ui_attach()*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api.txt). Confirm `option_set` does not turn off `ext_linegrid`. Keep other `ext_*` options false; the default grid must include Neovim's command line, messages, and popup menu [UI options, `*ui-ext-options*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api-ui-events.txt). Hold user input until the first `flush` and recovery mirror attachment.
5. Decode each `redraw` notification as an **ordered array** of event names, each followed by one or more parameter tuples. Apply `grid_resize`, `default_colors_set`, `hl_attr_define`, `grid_line`, `grid_clear`, `grid_cursor_goto`, `grid_scroll`, `mode_info_set`, `mode_change`, `mouse_on/off`, `busy_start/stop`, and `flush`. Keep working and committed copies of cells, defaults, highlights, cursor, and mode. Commit all of them only on `flush`, even if several notifications precede it. Reuse bounded persistent buffers and copy state at redraw boundaries, not at video frames. Ignore unknown future event names and extra trailing fields, but fail visibly for a malformed required event [UI events, order and flush](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api-ui-events.txt).
6. Grid 1 is the only enabled grid. `grid_line` has zero-based row and column, an optional highlight ID inherited within that **one event call**, and a repeat count. The empty-string right cell is a wide-glyph continuation. Preserve partial-line contents. `grid_scroll` copies an overlapping **cell rectangle** and is not a request to change `ScrollState`; honor end-exclusive edges and wait for Neovim's new lines. `grid_cursor_goto` sets the visible cursor; mode events select its shape and blink timing [line-grid events, `*ui-event-grid_line*`, `*ui-event-grid_scroll*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api-ui-events.txt).
7. `hl_attr_define` supplies RGB colors, absent and default color sentinels, reverse, bold, italic, underline variants, strike, conceal, dim, blend, and related flags. Keep defaults separate so `default_colors_set` can recolor existing cells. Key highlight records by their explicit Neovim ID; do not index them by ID or assume IDs are dense. Draw each supported decoration; a visible style the painter cannot represent sets a named unsupported-attribute status. Retain URL attributes for status, but never open a URL from cell text. Convert 24-bit sRGB to normalized floats and convert to Oklab exactly once, at the paint boundary, as an authored `paint.Color` the scene lowers. Resolve reverse before conversion, and never convert an Oklab value twice [line-grid highlight events, `*ui-event-hl_attr_define*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api-ui-events.txt).
8. Bound decoded message size to 8 MiB, each string to 1 MiB, nesting to 32, grid size to 256 × 128 cells, and combined grid text to 8 MiB. Use checked multiplication, validate UTF-8 and indices, reject a repeat that overruns a row, and keep protocol errors typed. Drain oversized buffer-update payloads without allocation, mark recovery stale, and keep the UI channel alive. The reader owns queues of at most 8 MiB inbound and 256 KiB outbound, plus one coalesced resize and pointer-motion event. Never coalesce text, keys, button transitions, clipboard, or paste. When full, stop accepting input and show `busy`; resume only after capacity returns. Keep at most 64 outstanding RPC requests. Never report discarded input as accepted.

## Input, clipboard, recovery, and security rules

- **Focus and identity:** The editor leaf opts into focus with `focusable = true` and a stable `key`, so it participates in the same W02/W09 identity as every other control: `FrameOutput.focus` and the focus ring are unchanged, and a same-kind sibling insertion or removal cannot move focus to a different logical control. Clicking the clipped visual box focuses it through the ordinary pointer default. `focus.Manager.step` tab traversal includes it in visual tab order; `focus.Manager.reconcile` clears focus when the keyed leaf disappears. The owning component routes focused keys before control actions, and it calls `preventDefault` for keys Neovim owns, so plain Tab and Escape reach Neovim instead of `App`'s focus traversal and focus-clear defaults, while Ctrl+Tab leaves to the next app control. Notify Neovim about window focus changes if `nvim_ui_set_focus` exists. The model-backed session stays open if its leaf is conditionally hidden; only an explicit close or root teardown stops it. Do not add a second focus field or a second focus runtime.
- **Keys and text:** Consume `Event.key_down`/`key_up` in the component's `onRoutedEvent` and translate `LogicalKey`, `PhysicalKey` and `Modifiers` into `nvim_input` notation. Encode key notation (`<CR>`, `<Esc>`, `<C-x>`) only for real special keys and escape a literal `<` as `<LT>`. `Event.text_input` is committed UTF-8 and is the only path that inserts printable characters, so one press plus its commit inserts once; validate UTF-8 at the platform boundary. `nvim_input` can accept fewer bytes than sent: retain the suffix, in order, until accepted [API, `*nvim_input()*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api.txt). A key the focused route handles sets `default_prevented`, which is the flag the W10 keymap is given, so an editor-handled key never triggers a global binding; resolve any rebound W10 action before translating to Neovim notation.
- **IME:** The editor is a focused consumer of the **one** W12 text runtime, never a second input path. Register it through `App.registerTextEndpoint`, so `text_input.Manager` owns focus, native `start` and `stop`, the preedit record, cancel-on-blur and candidate geometry; the component must not drive `text_input.Native` itself. Neovim keeps document authority: the endpoint's operations read authoritative state through the session — the committed grid snapshot, the RPC queue's accepted count, and the cursor cell that gives caret and candidate geometry — and express committed edits as queued RPC input. Preedit is a clipped host overlay anchored at the committed Neovim cursor in the node's visual content box; it never mutates the remote grid, and a commit reaches Neovim exactly once. If one of those queries cannot be expressed through the shared endpoint, that gap is an explicit extension prerequisite owned by W12, not a private focus, IME or input runtime here. Keep preedit selection offsets as UTF-8 bytes relative to the preedit string, never document offsets. Treat a composition with no valid cursor as a visible error rather than guessing its location. Replay scripts must be able to drive commit and cancel transitions.
- **Mouse and scroll:** Pointer events already arrive in logical window units. Subtract the leaf's visual content origin (`widget.visualContentRect`, or `element.Geometry.content` inside the paint hook) and convert to a zero-based cell row and column with bounded floor and clamp. Use `nvim_input_mouse(button,action,modifier,0,row,col)` for press, drag, release, and wheel, and send mouse interaction only while Neovim reports `mouse_on`. W09 pointer capture already keeps the press target alive after the pointer leaves the widget, so a drag cannot stick; do not add a second capture mechanism. A wheel over the editor goes to Neovim and must not also scroll an ancestor: prevent the W09 wheel default, which is the only consumer of that default. Outside the editor, retain the current app behavior [API, `*nvim_input_mouse()*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api.txt).
- **Resize, DPI and cell metrics:** Derive cell metrics from the W11 service: convert the node's font selector with `TextService.fontHandleForId`, read `TextService.metrics`, and measure one representative cell for the fixed advance. Never hardcode a font index or reuse a private demo constant. Recompute metrics and the visual box after layout, pixel-size changes, font-size changes, and parent layout or scroll changes; bump the element revision so measurement is not reused. Compute columns and rows **after layout** from the visual content box: exclude partial cells, paint the remaining pixels as gutter, and stage the request in the layout phase. Send `nvim_ui_try_resize(cols,rows)` only when the integer cell count changes, never each frame, and publish the new count through `Operations.commit`. Delay UI attach while fewer than two columns or rows fit and show `starting` instead of a zero-size attach. Limit the initial grid to 256 × 128; report `.failed(.grid_too_large)` beyond that. Wait for `grid_resize` before showing the new grid, keep the old committed grid clipped during a pending resize, and put an explicit resize state in diagnostics [API, `*nvim_ui_try_resize()*`, `*ui-event-grid_resize*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api.txt) [UI grid events](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api-ui-events.txt). A parent may scroll the whole widget, but only Neovim scrolls the text inside it.
- **Clipboard:** Neovim has no direct system clipboard; its `+` and `*` registers use a provider [clipboard provider, `*provider-clipboard*`, `*g:clipboard*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/provider.txt). Configure a host-owned `g:clipboard` provider only for explicit copy and paste actions, and read and write through the W18 clipboard service rather than a second clipboard implementation. Its Lua callbacks use `vim.rpcnotify` for copy and `vim.rpcrequest` for paste [Lua RPC](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/lua.txt). The RPC worker services a nested paste request on the W05 worker path while the UI thread never waits on itself, and no thread blocks on a completion that needs that same thread. Keep ordinary yanks internal by default: do not set `clipboard=unnamedplus`. For large pasted text use bounded `nvim_paste(data,false,-1)` or phases 1, 2 and 3; check its boolean result and API errors, and never send a multiline paste as many keys [API, `*nvim_paste()*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api.txt). An unavailable service, an empty payload and a provider failure stay distinct outcomes, and a failure is visible rather than pasted as empty data.
- **Text recovery:** Attach to the active buffer with `nvim_buf_attach(buf,true,{})` before accepting input. Keep a host-owned line mirror from ordered `nvim_buf_lines_event`s. Ignore display-only events with a null `changedtick`, and apply multipart changes as one logical update. Cap the mirror at 32 MiB. On overflow, keep the live UI but set `recovery = .stale(.stale_recovery_mirror)` and disable save and restart restore. Detect detach and disable editing until reattached. This mirror supports recovery and explicit host save, not live editing [API, `*api-buffer-updates*`, `*nvim_buf_attach()*`](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api.txt). On EOF or crash, freeze the last complete grid, show the exit reason, mark queued-but-unconfirmed input as **uncertain**, and do not replay it. Restore only a confirmed mirror; if the mirror is stale or input may have applied without confirmation, ask the user to restore or discard. A new process restores text only, and must report that cursor mode and undo history reset.
- **File access:** The editor starts with an unnamed buffer. Host open and save APIs require an explicit path choice and trust decision. For open, the host reads the file, rejects buffers over 32 MiB or lines over 1 MiB, and sends `nvim_buf_set_lines` batches no larger than 128 KiB; hold input until the final buffer-change tick reaches the mirror. For save, pause new input and drain the queue; after the last accepted input, wait for a later redraw `flush` to confirm it before using the mirror, and do not write if confirmation misses a deadline. Capture an available mirror and its tick, query `nvim_buf_get_changedtick`, stage a temporary file, query the tick again, and atomically replace the approved target only if both queries still match the captured tick; otherwise discard the temporary file and report `file_changed_during_save`. A stale mirror stays unavailable; do not claim recovery or silently rebuild it. These host APIs are **not** a security boundary in trusted mode: Neovim can still run `:edit`, `:write`, `:!` or Lua file and process APIs. Only sandbox-required mode enforces that it cannot reach other host files. No autosave, no workspace discovery, no hidden writes, and never user configuration or workspace plugins [startup and initialization](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/starting.txt).
- **Process isolation:** Start with a sanitized environment, private 0700 runtime, home and temp directories, a private cwd, closed unrelated file descriptors, no TCP listener, bounded stderr, and a dedicated child process group. Place any default Neovim RPC socket under the private runtime directory and verify its permissions. On Linux, sandbox-required mode uses Bubblewrap with a private mount namespace, `--unshare-net`, read-only executable, dependency and runtime mounts, and only private writable temp; it fails `sandbox_unavailable` when Bubblewrap or OS enforcement is unavailable. Other platforms fail closed until they have an implemented sandbox. Trusted mode requires explicit confirmation before spawn and a persistent warning: Neovim can read and write host files and execute commands through Vim or Lua, even with `--clean --noplugin`. `EditorSession.start` requires a selected sandboxed or trusted-after-confirmation mode and has no default; never silently switch modes. Pass executable argv and paths separately, never shell-interpolated strings. On close, close pipes, wait with a deadline, terminate the whole child process group and reap the child.

## Ordered implementation tasks

Each task is a future red/green checkpoint. Add the named behavioral tests **before** the implementation and verify the specific path after it. These are instructions for implementation, not checks completed in this planning session. Run the targeted filter, then the project's own gate; do not weaken a check to obtain a pass.

Test-registration rule for this repository: `zig build test -Dtest-filter=<name>` already filters every registered root, and `src/v7_demo/main.zig` owns the `test` block that lists which scene files `exe_tests` runs. Add a new demo test file to that block instead of adding a parallel test binary, so a dropped import fails the build rather than silently dropping tests.

### Task 1 — Private MessagePack-RPC codec and line-grid model

**Files:** create `src/v7_demo/editor_rpc.zig`, `src/v7_demo/editor_grid.zig` and `src/v7_demo/editor_test.zig`; add the new test file to the `test` block in `src/v7_demo/main.zig`. No package dependency, and no public nogui API in this task.

**Produces:** a codec for a MessagePack-RPC byte stream without an outer length frame, plus `GridModel.applyRedraw`/`GridModel.committed` for one grid. Complete MessagePack objects parse across arbitrary pipe read boundaries and concatenated message order is preserved. Highlights and cells live in bounded persistent memory, and the renderer only ever reads committed state.

- [ ] Write parser tests from literal protocol-shaped arrays: RPC messages split across arbitrary read boundaries and several concatenated messages; request, response and notification dispatch; repeated `grid_line` cells; sparse highlight IDs; inherited highlight ID; UTF-8 combining and wide continuation; partial line; overlap scroll up and down; changed default colors; resize; cursor and mode; an unknown future event; extra trailing arguments; malformed bounds; and two redraw notifications whose only `flush` arrives in the second.
- [ ] Run `zig build test -Dtest-filter=editor`. Expect the new parser and model tests to fail before implementation.
- [ ] Implement bounded decode and encode with ordered staging. Apply scroll as an overlap-safe cell copy. Publish no intermediate state before `flush`, and return typed errors for malformed required events or capacity violations.
- [ ] Run `zig build test -Dtest-filter=editor`. Expect the atomic-flush and every grid boundary case to pass with no network and no GPU.

### Task 2 — Session model, child process, mirror, recovery and save

**Files:** create `src/v7/editor_view.zig` (the value types above, plus its `root.zig` export) and `src/v7_demo/editor_session.zig`. Modify `src/v7_demo/window.zig` only to pump notifications and to stop the session on the owner thread before renderer and App teardown.

**Produces:** an `EditorSessionModel` created through `Session.create`, with `start`, `pump`, `restart` and `close`, the stable `EditorView`, snapshot pins, and bounded input and decode queues. The pipes, the decode queue and the working grid are owned by the model; a W05 worker reads the pipes and delivers results through the task service, and `pump` on the owner thread drains queued messages in order, applies redraws, and publishes at most one latest `flush` snapshot per frame. It never blocks UI or GPU work and never receives a frame pointer. Accepted input is tracked until a later `flush`; save and recovery stay blocked while input is unconfirmed. `start` checks API metadata and requires an explicit sandboxed or trusted-after-confirmation process mode before attach, and waits for the first `flush` and a buffer mirror. `restart` is explicit and never replays uncertain input. `close` is explicit and runs before App and renderer teardown.

- [ ] Write integration tests against a real `nvim --embed --clean --noplugin` child for API discovery, attach and flush, one edit plus the buffer-change mirror, partial input acceptance, bounded-queue overload, bad protocol bytes, abrupt child exit, clean shutdown and reap, mirror overflow without UI loss, stale-mirror rejection, save with queued or unconfirmed input, an explicit changedtick conflict on save, and restart with confirmed text but reset undo and mode. Test bounded file-open batches and the changedtick race before atomic save. Test sandbox-required failure with injected conditions, a missing executable with an injected absent path, and the absence of any implicit fallback to trusted mode. Test snapshot retirement across the two live frame trees, including an aborted frame that must not publish or free a snapshot. If `nvim` is absent, skip only the live-child tests and keep the protocol and failure tests running.
- [ ] Run `zig build test -Dtest-filter=editor`. Expect the child integration tests to fail before the session exists.
- [ ] Implement worker-owned pipes, matched request IDs, bounded queues, explicit startup and exit timeouts, and verified process policy. Stop intake on overload and surface `busy`. Release the model explicitly; do not rely on a component `deinit` hook for teardown.
- [ ] Run `zig build test -Dtest-filter=editor`. Expect one live-process session to edit and mirror text, terminate cleanly, and fail with a named reason on each fault.

### Task 3 — Custom element leaf, focus, geometry and post-layout resize

**Files:** extend `src/v7/editor_view.zig` with the `CodeEditor` element descriptor and the `DrawCtx.codeEditor` wrapper; extend `src/v7/root.zig` with the export; create `src/v7_demo/editor_leaf.zig` for the owning component. Touch no layout switch: `WidgetKind` needs no new arm, because `.element` already measures through the custom element path.

**Produces:** a value-only editor leaf with explicit cell-grid intrinsic measurement, a visual clip, an optional semantic role, and a staged post-layout cell-count request. Status and geometry serialize in headless JSON; the buffer does not.

- [ ] Write tests for a duplicate widget key rejected by the identity registry, focus by click and by Tab, focus surviving a same-kind sibling insertion and correctly clearing when the keyed leaf disappears, Tab and Escape reaching the owner instead of the App defaults, wheel over the editor not scrolling an ancestor, a zero-size leaf being unfocusable, intrinsic sizes in flex, grid and block layout, clipping, and the session surviving a conditionally hidden leaf.
- [ ] Run `zig build test -Dtest-filter=editor`. Expect the new leaf tests to fail before the descriptor exists.
- [ ] Implement `measure`, `prepaint`, `semantics` and `commit`: measure the preferred 80 × 24 cell box, stage the cell request in the layout phase, publish only through `commit`, and defer attach while fewer than two columns or rows fit.
- [ ] Run `zig build test -Dtest-filter=editor`. Expect the focus, lifetime, geometry and headless tests to pass.

### Task 4 — Input, IME, clipboard and resize ownership

**Files:** modify `src/v7_demo/editor_leaf.zig` and `src/v7_demo/editor_session.zig`; add the windowed editor root in `src/v7_demo/editor_demo.zig` and register `--editor` in `src/v7_demo/main.zig`. No new core input type and no new host event adapter.

**Produces:** key, chord, text and composition handling through W09 events; one W12 focused text endpoint on editor focus, registered with the App's text-input manager; W18 clipboard copy, cut and paste; mouse and cell mapping; and cell-count resize requests. No demo debug shortcut consumes a focused editor keystroke, because prevention already gates them.

- [ ] Write headless event and focus tests for one UTF-8 commit, preedit update and cancel, editor Tab and Escape behavior, Ctrl and Alt mapping, a release captured outside the viewport, wheel over the editor versus wheel over the parent, and cell coordinates under parent scroll and DPI. Add a real-child test for paste and clipboard callback request ordering, and for a clipboard that is unavailable, empty or failing.
- [ ] Run `zig build test -Dtest-filter=editor`. Expect the new input tests to fail.
- [ ] Translate W09 events in the component's `onRoutedEvent` and call `preventDefault` for keys and the wheel default Neovim owns. Register the editor as a focused text endpoint through `App.registerTextEndpoint` so the W12 manager owns native start and stop, the preedit record and candidate geometry, draw the preedit overlay from the visual content box, and send `nvim_input`, `nvim_input_mouse` and `nvim_paste` through the session queue. Compute the size from the laid-out visual content box and resize only when the integer cell count changes.
- [ ] Run `zig build test -Dtest-filter=editor`. Expect the focus, IME, clipboard, coordinate and resize cases to pass.

### Task 5 — Monospace cell scene

**Open prerequisite, not decided by this plan:** an element paint hook emits W13 `PaintRecord` values — rect, path and image — and the scene lowers label and control captions through the host text engine, but a `.element` node is not on that text path today. Drawing cell glyphs therefore needs one of two changes owned by the parity packages: a W13 text paint record, or a W11 and W13 host seam that accepts an element-owned fixed-advance run. This plan does not choose between them and does not keep the demo-private `TextEngine.emitCell` route. Task 5's gate cannot close until that decision lands, and the decision belongs to the W13 and W11 owners, not to this feature.

**Files:** the paint half of `src/v7/editor_view.zig`; the cell-run half at whichever seam the prerequisite lands; `src/v7_demo/editor_test.zig` for CPU scene tests.

**Produces:** cell backgrounds, highlight decorations, the cursor, and the preedit overlay inside one inherited editor clip, in a stable order, with each cell's paint kept inside its column span.

- [ ] Write CPU scene tests for run-coalesced backgrounds across a two-cell span, every underline style, default and reverse color, cursor shape and blink timings over a wide glyph, an ancestor clip, the 64-clip budget, the record budget, measured cell widths at two DPI scales and two font sizes, and a missing glyph or glyph-pool exhaustion while the editor process and grid stay responsive.
- [ ] Run `zig build test -Dtest-filter=editor`. Expect the new cell-scene tests to fail.
- [ ] Emit coalesced same-attribute runs instead of one record per cell, keep each cell's paint inside its column span, and raise no shared capacity silently: an exhausted record or material budget is a named status with the committed grid still painted. Convert authored sRGB to Oklab once, at the paint boundary.
- [ ] Run `zig build test -Dtest-filter=editor`. Expect the non-glyph scene and color cases to pass. The glyph half stays open until the prerequisite above lands, and this plan must not be marked complete while it is open.

### Task 6 — End-to-end acceptance and documentation

**Files:** modify `src/v7_demo/main.zig`, `src/v7_demo/window.zig` and `README.md` to document the widget, the Neovim executable requirement, the trust policy, the controls and the failure modes. Do not change those files during this planning task.

- [ ] Run `zig build test -Dtest-filter=editor`, then `zig build test fixture layout-check lint`. Expect the existing project checks to remain green. Do not update a snapshot or weaken a check to obtain a pass.
- [ ] Run `zig build v7 -- --editor` on a real SDL and noapi window. Verify the initial grid with its status and command line, focus by pointer and tab order, plain Tab inside Neovim and Ctrl+Tab out of it, Unicode and a literal `<`, select, move, undo, redo and search, copy and paste, explicit host file open and save, syntax color, IME commit and cancel, wheel, a resized window and HiDPI, cursor shape and blink, and a clipped parent scroll. Verify edits and cursor movement in the **rendered surface**, not only in RPC logs.
- [ ] Close the editor and verify its child exited. Force a child failure and verify a visible stopped state, no partial redraw, retained confirmed recovery text, and an explicit restart that restores text but warns about lost undo and mode. Try an absent `nvim` and sandbox-required mode without an OS sandbox; both must fail with named reasons and leave no child. Confirm that launch never silently falls back to trusted mode, and test the explicit trusted-mode confirmation and its persistent warning.
- [ ] Record, per scenario, what actually ran: a replay, a real child, a real window. A headless replay is not evidence of candidate-window placement, native IME, a real clipboard round trip, or a sandboxed child.

## Acceptance matrix for reviewers

| Risk | Observable check |
| --- | --- |
| Real editing rather than a static text widget | Type, select, undo, redo, search and paste in the running editor; the visible grid follows Neovim state. |
| No partial redraw | Split one redraw across notifications; the visible snapshot changes only at `flush`. |
| Correct cells | Test repeats, partial updates, Unicode combining, wide continuations, reverse and default colors, the cursor, and overlap scroll. |
| Focus and scroll ownership | One stable widget identity, tab and shortcut policy, parent scroll, editor wheel, pointer drag and release, IME, and demo shortcut collisions all have targeted tests, and no second focus field exists. |
| Coordinates and DPI | Cell mapping is derived from logical window coordinates and the visual content box, with a test at 1×, 1.25× and 2×. |
| Lifetime and retirement | A snapshot stays readable while a live frame tree can read it, an aborted frame publishes nothing, and GPU-attached resources wait for retirement. |
| Lifecycle and backpressure | Missing `nvim`, a full queue, invalid RPC, a child crash, reaping, a mirror mismatch, restart, focus removal and explicit close each have state or error checks. |
| Security | No user config or plugins by default, no unapproved host file operations, a private child I/O and runtime path, sandbox-required mode fails closed when unavailable, and trusted mode requires explicit confirmation with a persistent warning. |
| Infrastructure reuse | The editor adds no widget kind, no focus runtime, no text runtime, no clipboard implementation, no font-id contract, and no surface-pixel conversion. |

**Official protocol sources checked while drafting:** [UI events and startup](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api-ui-events.txt), [RPC/API and buffer updates](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/api.txt), [startup flags](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/starting.txt), [clipboard provider](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/provider.txt), and [Lua RPC callbacks](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/lua.txt).
