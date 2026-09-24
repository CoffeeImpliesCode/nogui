# nogui API guide

This is the authoritative API guide for `nogui`. Each table names the public entry points a consumer calls, the source that declares them, and the ownership or limit rule that same source states. The tables cover the implemented work packages from W05 through W26.

The W01–W04 contracts stay in the [README](../README.md): module boundaries in [v7 module](../README.md#v7-module), identity and coordinates in [Core invariants](../README.md#core-invariants), session and model ownership in [Session and root ownership](../README.md#session-and-root-ownership), and notifications and globals in [Notifications and window dependencies](../README.md#notifications-and-window-dependencies). [`src/v7/root.zig`](../src/v7/root.zig) remains the full export list for the core module.

Everything outside the tables also stays in the README rather than here: build commands in [Build and run](../README.md#build-and-run), the recorded native and windowless proofs in [Work-package smoke steps](../README.md#work-package-smoke-steps), the runnable external packages in [External consumers](../README.md#external-consumers), the caller-supplied approvals in [Point-of-risk actions](../README.md#point-of-risk-actions), and the source-level gaps in [Open findings](../README.md#open-findings).

## Lifetime and thread boundaries

[`Session`](../src/v7/session.zig) is UI-thread-only. Marshal worker completions through the task service before accessing models.
Read/update/listener callback pointers are borrowed only for the synchronous call.
The core's transaction guards are not thread synchronization.

[`FrameOutput`](../src/v7/headless.zig) gives its two tree pointers different lifetimes:

| Value | Borrow ends |
| --- | --- |
| `tree` | It survives the next frame attempt, including failure. After a newer commit, another attempt can reset its arena. |
| `prev_tree` | The next frame attempt, whether it succeeds or fails. |
| A model callback pointer | The callback return. Copy retained data into caller-owned storage. |
| A widget's borrowed `value` pointer | Keep the target alive through both readable trees. See [core invariants](../README.md#core-invariants). |

`Session.deinit` returns `LiveApps` or `LiveModels` while consumers or active model operations remain.
It first gives task shutdown a 100 ms bound.
`UnfinishedWork` leaves the Session, executor and buffers alive for a later shutdown retry.
Do not force retirement after that refusal.

`App.swapRoot` flushes pending shortcut replay before retiring the mounted root's GPU resources. A refused flush leaves the published root live and permits a retry; the regression reproduced premature retirement before repair. The final Linux suite covers that refusal and retry. The actual private-X11 `zig build v7 -- --gpu-remount-smoke` also completed its three-frame GPU lifecycle and reused Mandelbrot slot 2 after one hidden frame, exit 0; that native run is not the refused-flush reproduction.


## Actions, keymaps and focus

| Entry points | Source | Ownership or limit |
| --- | --- | --- |
| `action.Action`, `action.Registry.init/register/registerAlias/bind/listen/unbind/unlisten/inspect/dispatch`, `action.Result`, `action.Availability` | [`src/v7/action.zig`](../src/v7/action.zig) | `Registry.init` takes the `Session`. A binding and an observer live until `unbind`/`unlisten`. `dispatch` answers `handled`, `disabled` or `unavailable`, and `inspect` reads the same availability out of a committed tree. |
| `keymap.Keymap.init/add/remove/clearSource/setLabel/keyDown/keyUp/textInput/focusChanged/tick/nextDeadline`, `keymap.Decision`, `keymap.Error` | [`src/v7/keymap.zig`](../src/v7/keymap.zig) | `max_steps` is 8, `max_pending_events` 32, `max_input_bytes` 256. `init` takes an injected `Clock` and a chord timeout in nanoseconds, so the host supplies the clock it also renders against. |
| `key_context.Scope`, `key_context.Path.init/next` | [`src/v7/key_context.zig`](../src/v7/key_context.zig) | `Path.init` borrows the committed tree and walks outward from the focused widget; it is a view of one frame. |
| `App.attachShortcuts/setShortcutContexts/tickShortcuts/nextShortcutDeadline/nextShortcutWaitMilliseconds/detachShortcuts` | [`src/v7/app.zig`](../src/v7/app.zig) | Attach before dispatching input and detach before `App.deinit`. The keymap and the action registry must outlive the attachment. |
| `input.hitTest/hitActionable/hitStable/isEnabled` | [`src/v7/input.zig`](../src/v7/input.zig) | The first two return a dense `FrameNodeId` valid only for the current frame; only `hitStable` returns a `WidgetId` that survives a reorder. |
| `focus.Manager.set/blur/contains/step/press/captured/release/cancel/reconcile/reset`, `focus.Cancellation`, `App.focusObserver` | [`src/v7/focus.zig`](../src/v7/focus.zig), [`src/v7/app.zig`](../src/v7/app.zig) | Capture carries moves and release/cancel outside the box. Pass `app.focusObserver()` when writing the App's focus manager or using `overlay.ModalFocus`: it routes focus-in/out, reconciles the text endpoint and reports the change. A null observer changes only the stored value. |

`zig build w09-controls-smoke -- --native --ppm PATH` publishes committed
control coordinates and bounded input steps for an external controller.
Real release-away, valid click, out-and-back slider capture, held/discrete
Space and field commits passed on private X11. The saved presented image
showed the same final counter, slider, Todo and field state as the model.

Native X11 keyboard/cursor evidence (2026-10-01): the mapped `w10-keyboard-smoke` exited 0 on a private Xvfb. Real pointer enter and motion exercised visibility and hide-until-move. Changing that server from US to German delivered one native layout callback, advanced generation 0→1 and changed physical scancode 28/29 labels from Y/Z to Z/Y. Layout name/identifier slices borrow the keyboard's mutable buffers; copy them before retaining a before-change comparison across a native update.

`zig build v7 -- --shortcut-native --shortcut-pixels=PATH` mounts the same Todo
scene and registry on a real host. It publishes the owned X11 window ID and
each required key sequence. An external controller must supply those keys.
The default shortcut replay retains its injected clock and opens no window.
The native run verified precedence, disabled suppression, one timeout action
and one activation per suffix replay. Its captured image and model agreed.

## Typed text, editing and native candidate publication

| Entry points | Source | Ownership or limit |
| --- | --- | --- |
| `text.TextStyle.resolve`, `text.TextStyleOverride.resolve/restricted`, `text.TextOrigins.merge`, `text.resolveNodeText`, `text.publishNodeText` | [`src/v7/text.zig`](../src/v7/text.zig) | Overrides apply field by field, and an authored font family without a handle clears the inherited handle. `publishNodeText` records the resolved text once per frame for the renderer to read after publication. |
| `text_input.Endpoint`, `text_input.Adapter(Model)`, `text_input.Manager.init/register/handle/copy/cut/paste/cancelComposition/invalidateGeometry` | [`src/v7/text_input.zig`](../src/v7/text_input.zig) | The Manager holds the focused endpoint's borrow through `Call.borrow`, and a hook that outlives its endpoint sees `error.EndpointReleased`. `utf8ToUtf16`, `utf16ToUtf8`, `utf16Length` and `isUtf8Boundary` reject an offset in the middle of a scalar. |
| `text_input.Manager.caretGeometry`, `text_input.Native.set_area`, `Window.setTextInputArea`, `Window.candidate_publication` | [`src/v7/text_input.zig`](../src/v7/text_input.zig), [`src/v7_host/window.zig`](../src/v7_host/window.zig) | Candidate rectangles and caret offsets are logical window units. `setTextInputArea` refuses a non-finite rectangle or offset before SDL runs; `candidate_publication` is the record SDL accepted, including the wrapping generation. |
| `TextService.addFont/resolve/metrics/layout/layoutIn/nodeLayoutIn/shapeCount`, `TextMeasurer.init/source/measure/deinit`, `NodeMeasurer.init/source`, `shaping.Cache.acquire/acquireWith`, `shaping.Lease.release` | [`src/v7_text/root.zig`](../src/v7_text/root.zig) | A `TextLayout` owns its allocation and pins the runs it used, so release every layout before `TextService.deinit`. The cache retains at most 256 runs and 4 MiB, `Cache.init` returns by value into storage the caller keeps stable while leases are live, and a cache hit allocates and shapes nothing. |
| `DrawCtx.slider`, `widget.sliderVisualLabel`, `widget.sliderThumbRect`, `widget.slider_rail_height`, `widget.slider_thumb_width` | [`src/v7/drawctx.zig`](../src/v7/drawctx.zig), [`src/v7/widget.zig`](../src/v7/widget.zig) | `slider` copies the label into the frame arena and retains the caller's `*f32`, which must outlive both readable trees. The kind's own `value.color` (opaque white) is a default foreground, not authorship: an ancestor style, a component `default_text`, an authored `.color` or `text_style.foreground` outranks it, and it never shadows an inherited foreground. `text_overflow` and `max_width` are applied through the same text-option path every other text-bearing constructor uses, before interaction options, so a declared cap bounds and truncates the caption in layout and in the scene text pass alike. `sliderVisualLabel` falls back to `label` and treats an explicitly empty `visual_label` as no visible text while the semantic label stays queryable. A caption-less slider measures to a fixed 100 wide by `slider_rail_height` high, and the paint-only `sliderThumbRect` does not enlarge the control's pointer box. The slider's measurement entry points live in [`src/v7/layout/context.zig`](../src/v7/layout/context.zig) and are reached by the layout dispatcher rather than exported for a consumer to call. |

The text layers use different offset units. Convert at their boundaries rather than copying numeric offsets.

| Layer | Unit |
| --- | --- |
| Core text and semantic snapshots | UTF-8 byte offsets |
| `text_input.Utf16Range`, selection and marked text | UTF-16 code units |
| Endpoint motion and erase | Grapheme, word, line or document |
| AccessKit/AT-SPI boundary | Character indices through the adapter's `character_lengths` conversion |

The [text protocol](../src/v7/text_input.zig) validates encoding boundaries.
The model-owned endpoint resolves grapheme snapping and preserves selection direction.


The external `offscreen` consumer uses ordinary `DrawCtx.label` calls to verify centered paragraph alignment, exact two-line clamp and start/middle/end truncation with `~~` against submitted glyph geometry and real GPU pixels. Its current 2026-10-02 windowless run passed 1,016 checks; after a changed three-line frame commits, it rereads the original frame's records and layout. The inspected image is 640×640.

The same consumer's `zig build run -- --empty-font-registry` arm opens no GPU or window. It passed 32 checks: the ordinary caption returned `FontUnavailable`, committed no tree or generation and shaped nothing; adding the pinned primary and fallback faces then measured that caption through the same App and text service, including style, fallback, notdef policy, cache reuse and font-size scaling.

The same pinned-font state scenario runs through `zig build run-parity-state-pair -- --ppm PATH` and `zig build run-parity-state-pair-native -- --ppm PATH`. Both routes exited zero with identical values for 64 model, focus, selection, semantic and geometry fields and all 12 character-pen/advance values. Both 320×220 GPU images were inspected. The native route presents through `Application` and starts its text adapter, but its scenario input is explicitly synthetic; it is not native IME evidence. Independent pen, advance and rectangle mutations each failed the comparison. Missing required/native shaders and an unavailable native video backend returned their original errors without leaking partial owners.

An owned Niri/Xvfb two-window run drove a real output scale change from 1× to 1.25×. Actual SDL pointer motion reached the committed probe before and after the change; raw and production-routed motion counts agreed. The logical extent stayed 900×620 while device pixels became 1125×775, the published candidate used the committed generation, and presentation reported zero extent mismatches. The candidate-area acceptance is not evidence that an IME candidate window was visible.

The complete private X11/IBus scenario passed again on the current 2026-10-03 consumer: 35 accepted items, zero refusals and both candidate windows proved.
It committed UTF-16 marked range `11:13`, corresponding to UTF-8 bytes `11..17`, once and collapsed selection to `13:13`.
Wrapped/scrolling geometry, hidden-caret suppression, real blur cancellation and composition after focus return passed.
Both attributed native candidate windows passed, and their captures were inspected.

The same scenario ran on **2026-10-05** against a freshly approved owned output whose scale is a server-side fact: Xvfb `-dpi 120` with `Xft.dpi: 120` merged onto the owned server's root `RESOURCE_MANAGER` and read back with `xrdb -query`. The consumer reported `display_scale=1.2500` beside `pixel_scale=1.0000x1.0000` over a 640×360 pixel extent for a 640×360 logical window, and the controller accepted **36 items, zero refusals, 2/2 candidate windows**. The caret area `(154,40 0x28)` was published as SDL's stored `(154,40 1x28)@0`, which with the window origin `(480,828)` gives the root anchor `(634,868 1x28)`; the XIM server carried a SPOT at `(634,896)`, the stored rectangle's bottom edge, and the candidate window appeared exactly there — **370×69 at (634,896)**, `distance_from_the_anchor=0,0`. After the real focus round trip: **336×69 at (753,952)** against anchor `(740,952)`. Both captures were inspected and are real `libpinyin` lists.

The scaling result is the reason that run matters. SDL3's X11 backend reads the platform's content scale but does **not** scale the window's pixels by it, and it hands the XIM server the text-input rectangle unscaled. Logical window units, X root pixels and device pixels are therefore one space on X11 at **any** reported display scale, which is why a non-1× display scale alone is not evidence of a scaled candidate anchor. A consumer that multiplied its caret rectangle by `display_scale` before publishing would be wrong on this backend; one that publishes logical units unchanged is correct, and the candidate window follows the anchor with zero offset. Two consequences follow for callers: the `display_scale` a backend reports and the scale a window's pixels are actually drawn at are separate numbers and both are worth measuring, and a mid-run scale transition that a running client observes is not available on the X11 text-input path at all.

The separately approved current private-X11 clipboard run passed thirteen numbered steps and five consumer checks: selected multibyte paste once, independent copy/cut byte readback and complete CLIPBOARD/PRIMARY restore. No user clipboard was touched. Other display/backend mutations still need exact approval. See the [W12 record](superpowers/plans/2026-09-26-gpui-api-parity.md#w12--general-editable-text-ime-and-edit-actions).

The editable-field example borrows the App's own text-input manager for endpoint registration and edit actions. Its scripted memory clipboard binds only when that manager has no service; it does not replace an installed W18 provider. The current `api-w12` gate passes 52/52 total tests, including routed cut, restore and selected astral-range replacement with a three-byte paste. The windowless and private-X11 routes agree on the model, directional semantics and pinned-font geometry; the native route presents four frames and refuses SDL candidate readback that differs from the committed shaped caret. This paired example establishes publication and scripted editing; the separate W12 native clipboard and IME consumers above supply real service acceptance.

Read-only cut refuses mutation before looking up clipboard availability, matching paste. Normalization folds only CRLF into one break; CR followed by VT, FF, another CR, or an independent LF/CR pair keeps two breaks (spaces for single-line fields, newlines for multiline fields). Both boundary regressions failed before repair. The 2026-10-03 standalone protocol run passed 26/26; the integrated `api-w12` build passed 53/53 total tests before the editable-field ownership cutover and 52/52 after it, which is the current figure. An actual standalone Session/model/Manager consumer exercised eight independent pairs, two CRLF pairs and read-only cut with no clipboard or no writer, with exact text/result checks. This is protocol and consumer evidence, separate from native clipboard and IME observations.

Paste whose normalized payload is empty returns `.empty` before replacement, so control-only clipboard bytes cannot erase a selection. SDL preedit selection clamps code-point ranges with saturating addition before converting them to byte offsets. `Consumer.policy` in the editable-field example and `Ink.policy` in the native IME consumer let callers select multiline or read-only behavior before registering the endpoint; registration copies that policy.

The 2026-10-03 actual shaped-field consumer selected multiline and read-only policies through `Consumer.policy`, then registered the shipped endpoint. Control-only paste retained exact text and selection; CRLF paste produced `x\ny`; read-only paste and cut changed neither selected text nor clipboard bytes. The run passed 21/21 build steps, exit 0, using the real pinned font and CPU text service with an in-memory clipboard only. Evidence: `/tmp/nogui-shipped-field-policy-proof-20261003.json`. This is not a native IME policy-mode claim.

The user kept embedded-editor work separate on 2026-10-03.
Neovim committed-text queueing, host preedit overlay and RPC clipboard integration
remain in the separate editor plan, not W12/W18 ordinary-field parity.
The shared text and clipboard services above do not require a Neovim process.




## Paint, canvas and renderer-neutral records

| Entry points | Source | Ownership or limit |
| --- | --- | --- |
| `paint.PaintList.init/addRect/addPath/addImage/deinit`, `paint.RectPaint/PathPaint/ImagePaint/Color/Fill/Gradient/Pattern/Shadow/Stroke` | [`src/v7/paint.zig`](../src/v7/paint.zig) | Records carry sRGB or Oklab color, gradients, patterns, borders, shadows and strokes, and never a GPU handle. `PaintList.init` takes the caller allocator, a palette and a record ceiling; exceeding it returns `error.PaintCapacity`. |
| `path.Builder.init/moveTo/lineTo/quadraticTo/cubicTo/arc/close/path`, `path.tessellate`, `path.contains`, `path.FillRule` | [`src/v7/path.zig`](../src/v7/path.zig) | The builder owns its command list and frees it in `deinit`; `max_commands` is the ceiling that returns `error.PathCapacity`. `tessellate` writes into the caller's `[]Quadratic` scratch and returns the used prefix, and `PathCapacity`, `TessellationCapacity` and `InvalidPath` are distinct failures. |
| `element.PaintWriter.addRect/addPath/addImage/rect`, `element.MeasureInput`, `element.LateScope`, `element.Semantic`, `element.make` | [`src/v7/element.zig`](../src/v7/element.zig) | A custom element's paint hook emits bounded records through the writer. `max_semantic_bytes` is 4096. A `.late_scope` container may append a bounded subroot after its first layout. |
| `v7_render.Scene/SceneRect/ClipRect/PaintScene/PaintMaterial/MaterialRange/Lowered/PaintTarget`, `v7_render.lowerPaint` | [`src/v7_render/root.zig`](../src/v7_render/root.zig), [`src/v7_render/renderer.zig`](../src/v7_render/renderer.zig) | `lowerPaint` is the pure CPU entry point: it writes three caller scratch slices, allocates nothing, and preflights every material and scene slot before writing output. Its return type is `v7_render.Lowered`, exported by the root, so a consumer can name it. `Lowered.rects`, `.materials` and `.curves` are BORROWED prefixes of that same scratch: they stay valid exactly as long as the caller's scratch is untouched, and the next `lowerPaint` call overwrites it. Keep the scratch alive for as long as any field of the result is read. |
| `v7_render.Renderer.init/prepare/preparePaint/draw/nextFrameSlot`, `v7_render.max_clip_rects` | [`src/v7_render/renderer.zig`](../src/v7_render/renderer.zig) | `Renderer.init` takes a `*noapi.Gpu` and three SPIR-V modules, so this type is GPU-bound even though `PaintScene` is not. `max_clip_rects` is 64; `preparePaint` refuses a stale frame slot, an out-of-range material slot, too many clips, and a paint buffer over 1 MiB. |
| `v7_render.sweeper.Curve/StrokeEdge/GlyphMaterial/glyphExtent/buildFillBands/buildStrokeBands` | [`src/v7_render/sweeper.zig`](../src/v7_render/sweeper.zig) | Both band builders take only an allocator and slices. `GlyphMaterial` is a 56-byte GPU buffer record; the band records are CPU-only. |
| `DrawCtx` style and paint options, `style.StyleOverride`, `style.PaintStyleOverride`, `style.PaintStyle.resolve` | [`src/v7/drawctx.zig`](../src/v7/drawctx.zig), [`src/v7/style.zig`](../src/v7/style.zig) | Every `DrawCtx` constructor takes an anonymous options value, and two private resolvers read it field by field with `@hasField`, so an absent field keeps the component default instead of authoring a zero. `column`, `row`, `grid`, `elementLeaf`, `elementContainer`, `label`, `button`, `slider`, `checkbox`, `switchControl`, `radio`, `progress`, `separator` and `spacer` all resolve the same paint set: `fill` or `paint_fill`, `border_color` or `border_colors`, `border_styles`, `radius` or `radii`, `shadows`, `opacity`, `transform`, `transparent`, `clip`, `texture` and `layer`. `component` takes only a `key` and supplies its own `ComponentDefaults` instead. **`.transparent` is honoured for containers, not only for buttons.** [`src/v7/drawcmd.zig`](../src/v7/drawcmd.zig) gives `.column`, `.row` and `.button` one rule: `transparent` suppresses the fill entirely, and it is tested before the authored fill, so it also overrides an explicit `.fill`, `.paint_fill` or `.texture`. `grid` creates a `.column` node and therefore inherits that rule. Every other kind synthesizes no palette fill and never consults the flag. `progress` is the only constructor with its own value rules: a non-finite `value`, `min` or `max`, or `max <= min`, is `error.InvalidStyle`. |
| `drawcmd.DrawCmd`, `drawcmd.requiredCapacity`, `drawcmd.collectDrawCmds/collectDrawCmdsInto` | [`src/v7/drawcmd.zig`](../src/v7/drawcmd.zig) | The frame's draw records are allocated from the frame arena and sized by `requiredCapacity(tree)`. |

`zig build w13-canvas-smoke -- --exercise-capacity` passed 443 checks on a 640×560 windowless framebuffer; `--native --exercise-capacity` passed 482, including a changed second frame and live previous-frame path/dash/shadow ownership. Both GPU images were inspected. Each route refused an 836-record frame with `MaterialCapacity`, canceled it without submission, then rendered the ordinary specimen using the same material-ring slot and target. Independent probes cover 0.25/0.75 gradient stops, two distinct shadow lobes, palette/sRGB colors and render-only transforms whose committed hit boxes stay unchanged. Original tolerances remain; evidence is Vulkan on one GPU at 1×, not cross-platform pixel identity.

**A fully transparent fill is not an explicit fill.** [`src/v7/drawcmd.zig`](../src/v7/drawcmd.zig) decides whether a node owns its background with an alpha test, not with "was anything authored": `explicit_fill = authored.fill[3] > 0 or authored.paint_fill != null or authored.texture != null`. For `.column`, `.row` and `.button` the resolved surface is `if (authored.transparent) null else if (explicit_fill) authored.fill else palette.container` (`.button` falls back to `palette.button`). So `.fill = .{ 0, 0, 0, 0 }` is NOT explicit and does not suppress the framework default; the node is painted the fallback surface instead. `{0,0,0,0}` is the natural way to write "no fill", and it loses silently. To mean "no background", set `.transparent = true`, which is tested before the authored fill and is the only spelling that removes the surface. The alpha-0 spelling loses twice: [`src/v7/style.zig`](../src/v7/style.zig) `PaintStyle.resolve` still lets `local.fill` overwrite an inherited component default fill and clear `paint_fill`/`texture`, so a zero-alpha `.fill` discards a real inherited surface and then falls back to the palette one. Every demo scene that hand-writes a transparent colour is exposed to this.


## The frame engine, assets, images and external frames

| Entry points | Source | Ownership or limit |
| --- | --- | --- |
| `v7_frame.scene.SceneScratch.beginFrame/nextFrameSlot`, `buildFrameScene`, `recordFrameScene`, `FramePaint.records/deinit` | [`src/v7_frame/scene.zig`](../src/v7_frame/scene.zig) | `SceneScratch` retains its capacity across frames. `buildFrameScene` requires `beginFrame` first so lowering and recording cannot disagree about the frame slot, and `FramePaint` borrows its records until `deinit`. |
| `v7_frame.TextEngine.init/deinit/emitLayout/emitNodeText/setPixelScale/setGlyphSlotLimit/measurer/materialBuffer`, `v7_frame.max_materials` | [`src/v7_frame/text_gpu.zig`](../src/v7_frame/text_gpu.zig) | `max_materials` is 4096 and `setGlyphSlotLimit` refuses a limit below the next live slot. `emitLayout` never reshapes, so the `TextService` must outlive the engine. |
| `v7_frame.BindlessHeap.init/register/registerExternal/unregisterExternal/release/runtimeRegistry` | [`src/v7_frame/heap.zig`](../src/v7_frame/heap.zig) | `register` is idempotent. External component textures free their own slots in `deinitGpu`; a freed index is reusable by any later registration. |
| `v7_frame.Offscreen.init/deinit/resize/beginFrame/submitRead/endpoint/heap/target/extent`, `v7_frame.writePpm` | [`src/v7_frame/offscreen.zig`](../src/v7_frame/offscreen.zig) | `init` takes the injected loader and makes no window or surface. `beginFrame` borrows caller command and frame storage until `submitRead` or cancellation, `resize` runs only between recordings, and the Oklab slice from `submitRead` dies on the next submission, resize or deinit. |
| `v7_frame.NativeFrame.beginFrame/buildScene/recordScene/present/cancelFrame/readTarget/deinit`, `v7_frame.SystemVulkanLoader.open/options/close` | [`src/v7_frame/native.zig`](../src/v7_frame/native.zig), [`src/v7_frame/loader.zig`](../src/v7_frame/loader.zig) | `NativeFrame` is the only surface-bearing path, and `beginFrame` returns `false` on an out-of-date surface. `present` closes adapter recording on success or backend failure; failure leaves `GpuFrame.recording` terminally `.failed` and preserves the original error rather than attempting cancellation again. `deinit` drains submitted GPU work before releasing shaders, descriptors or buffers; a failed drain is fatal rather than freeing resources still in use. Retire the frame, surface and GPU before destroying the platform window. The system loader stays open until every GPU made from `options()` is destroyed. |
| `asset_types.AssetKey.init/parse/withScale/withGeneration/eql/hash`, `asset_types.AssetState`, `asset_types.AssetError` | [`src/v7/asset_types.zig`](../src/v7/asset_types.zig) | A key names source kind, path, scale and generation. State is `pending`, `ready`, `error_state` or `invalidated`, and a stale generation is `error.StaleGeneration`, not a silent reuse. |
| `image_types.ImageSequence.init/frameAt/nextDeadlineNs/isComplete/totalDurationNs`, `image_types.FrameRequests.publish/demand/retire/clear/count`, `image_types.FrameDescriptor.release/totalBytes` | [`src/v7/image_types.zig`](../src/v7/image_types.zig) | `FrameRequests` is caller-owned and scoped to one window. It borrows sequence storage until replacement or `retire(WidgetId)`; removal must retire the request before freeing that storage. It does not prune a tree automatically. Merge `demand(now_ns)` into the existing host loop. An external frame releases its own planes once, before slot reuse. |
| `image_view.ImageView.requestFrameAt/measure/paint/semantics` | [`src/v7/image_view.zig`](../src/v7/image_view.zig) | Publish a request from the current draw and clock. The view never owns pixels or a graphics handle: it borrows a host bindless texture slot pinned for every in-flight frame, and a ready slot from another generation is stale. |
| `nogui_host.assets.EmbeddedSource/FileSource`, `nogui_host.image.DecodedImage`, `nogui_host.svg.SvgEngine.isAvailable/unavailableReason`, `nogui_host.frame_source.FrameSource.pushFrame`, `FormatNegotiator.negotiate` | [`src/v7_host/root.zig`](../src/v7_host/root.zig) | Host-side loaders produce the same `AssetKey`, `FrameDescriptor` and `ImageSequence` records the core names. A host I/O failure becomes `AssetError`, and an absent `librsvg`/`libcairo` is reported as an `Unavailable` reason rather than a silent blank. |
| `nogui_host.svg.SvgRasterCache.put/pin/unpin` | [`src/v7_host/svg.zig`](../src/v7_host/svg.zig) | A successful `put` transfers the decoded image; any refusal leaves it caller-owned. A pin's address stays valid across admissions and map growth. Replacing a pinned key returns `EntryPinned`. Allocation or budget refusal leaves admitted images unchanged. Unpin before destroying the cache. |

The reusable SVG surface is `nogui_host.svg` — [`src/v7_host/svg.zig`](../src/v7_host/svg.zig) — and nothing else. [`src/v7_demo/svg.zig`](../src/v7_demo/svg.zig) is demo-side: it re-exports `DecodedImage`, `SvgEngine`, `isAvailable`, `rasterize` and `max_viewport_edge` from that module and adds only the demo's own float4-per-pixel upload writer `writeFloats`, its `pixelCount` helper, and the `coverageMask` colour map that drops hue and keeps alpha. No product publishes it and it is not reachable from an external consumer, which is the demo's intended boundary rather than a capability awaiting promotion.

Native image proof on 2026-10-02: `w14-asset-smoke` passed 102 checks on private X11/Vulkan. Three deadline frames rendered their authored colors, followed by zero idle commits. Owner removal retired its request and left demand idle. The 160×68 SVG specimen passed all 11 CPU and GPU probes, including Q/T and C/S, groups, transforms, arcs, local `use` and transparency; the CPU-only arm passed 43 checks. Current `api-w14` passes 80/80, including mapper-refusal release accounting, stable pins, pinned replacement and atomic allocation/budget refusal.


A private Niri 26.04 early-close run on the GTX 1660 Ti, with `VK_LAYER_KHRONOS_validation`, rendered and presented one 520×640 frame, then closed during a 600,000 ms hold without readback. It exited 0 with `surface_before_window=1` and `session_deinit=ok`, and the complete log contained no VUID. Before the drain, the same early-close path emitted five `VUID-vkDestroyShaderEXT-shader-08482` errors. Before the noapi indirect-read fix, startup also emitted `VUID-VkMemoryBarrier2-dstAccessMask-03900`; `draw_arguments` hazards now include the indirect-command read stage in their destination scope.

Terminal-error proof (2026-10-03): an owned private-X11 consumer on the GTX 1660 Ti began a real frame, then passed a second owned window's idle surface to `present`. The real backend returned `FrameNotActive`. Before repair, cancellation replaced it with an abort. After repair, all three checks passed: the typed error remained, the GPU frame stayed `.failed`, and adapter recording closed. Cancellation and complete device/window teardown returned normally, exit 0. This exercises the backend-error catch, not a driver submission failure; `/tmp/nogui-present-terminal-proof-20261003.json` records both runs. The temporary consumer flag was removed after proof.

## Lists, queries, scroll, overlays, drag and tooltips

| Entry points | Source | Ownership or limit |
| --- | --- | --- |
| `list.State.init/setOffset/setViewport/followEnd/reveal/visible/visit/measure/splice/reset/reviseEstimate/takeFocusChange`, `uniform_list.State` | [`src/v7/list.zig`](../src/v7/list.zig), [`src/v7/uniform_list.zig`](../src/v7/uniform_list.zig) | `list.State.init` takes an allocator because it retains measured heights; `uniform_list.State.init` does not. Both clamp through `checkedExtent`, `checkViewport` and `clampOffset`, and `exact_coordinate_limit` bounds the `f64` coordinate space. |
| `virtual_list.uniformList`, `virtual_list.variableList`, `virtual_list.AllocationCounter.allocator/totals/reset` | [`src/v7/virtual_list.zig`](../src/v7/virtual_list.zig) | Both build rows through the same late-subroot contract. `AllocationCounter` wraps a caller allocator and counts the real `alloc`, `free` and `remap` calls that reach the heap, so "bounded by the viewport" can be stated in memory rather than inferred. |
| `container_query.query` | [`src/v7/container_query.zig`](../src/v7/container_query.zig) | The branch depends on the container's own resolved width and appends a bounded subroot after layout. |
| `scroll.resolve/scrollTo/scrollBy/revealRect`, `App.scrollHandle/scrollSnapshot/scrollTo/scrollBy/revealRect` | [`src/v7/scroll.zig`](../src/v7/scroll.zig), [`src/v7/app.zig`](../src/v7/app.zig) | A `Handle` resolves through the committed tree; a target no longer in that tree resolves to `null` rather than scrolling something else. |
| `overlay.Frame.init/add/beginFrame/commit/stage/resolve/records/placement/paintInfo/hitTest`, `overlay.ModalFocus.open/close`, `DrawCtx.attachOverlay/place` | [`src/v7/overlay.zig`](../src/v7/overlay.zig), [`src/v7/drawctx.zig`](../src/v7/drawctx.zig) | `stage` records this frame's overlay content against the tree and viewport, and `commit` runs at the same non-fallible point the tree is published, so a frame that fails after `stage` leaves the last committed routing untouched. `InvalidGeometry`, `DuplicateContent` and `OverlayFrameNotAttached` are distinct refusals. |
| `drag_drop.Manager.begin/setPreview/pointerMove/pointerRelease/cancel/reconcile/deinit`, `drag_drop.PayloadView.get` | [`src/v7/drag_drop.zig`](../src/v7/drag_drop.zig) | `cancel` ends one pointer's drag. `PayloadView.get(T)` is a checked downcast that answers `null` for a different payload type rather than reinterpreting the bytes. |
| `tooltip.Manager.hover/pointerMove/expire/leaveOwner/cancel/deadline/descriptionFor/visible/reconcile`, `tooltip.Deadline` | [`src/v7/tooltip.zig`](../src/v7/tooltip.zig) | The manager owns a deadline taken from the `Clock` passed to `init`, so a test clock and a host clock drive it the same way. `expire` takes the token and refuses a stale one, so a hover that moved cannot close a newer tooltip. |

Current overlay paint proof (2026-10-01): the real Vulkan offscreen consumer passed 170 checks across 11 cases, including reversed builder order, equal-priority registration, text/control/custom interiors, nested placement and dormant registered-but-unplaced content. The committed tree's paint, total hit-testing, focus and semantics agree; dormant content loses placement metadata but does not acquire an overlay band. `api-w16` core passed 26/26. Native focus-loss, drag and tooltip acceptance is separate from this pixel proof.

## Animation, frame demand and tasks

| Entry points | Source | Ownership or limit |
| --- | --- | --- |
| `animation.Registry.start/interrupt/transition/sample/framePresented/demand/setReducedMotion/removeOwner/pruneDead/clear`, `animation.Key` | [`src/v7/animation.zig`](../src/v7/animation.zig) | A key is an owner `WidgetId` plus a lane, so several animations on one widget stay independent. `demand(now_ms, interval_ms)` is the host's redraw bound and `framePresented` releases it. `setReducedMotion` ends decorative loops, and `pruneDead(IdentityRegistry)` drops entries whose owner left the tree. |
| `App.startAnimation/interruptAnimation/animationDemand/framePresented/setReducedMotion/reducedMotion` | [`src/v7/app.zig`](../src/v7/app.zig) | The App owns the registry and `reducedMotion` is its only reader, so the desktop preference and the registry cannot hold two answers. An in-flight channel snaps to the endpoint its spec author wrote and requests exactly one further frame; lowering the gate resumes live channels from their own clock and never rewinds a parked one. |
| `frame_demand.FrameDemand.invalidateLayout/invalidatePaint/requestPresentation/setVisible/setContinuous/setDeadline/pending/waitMilliseconds/take/finish` | [`src/v7/frame_demand.zig`](../src/v7/frame_demand.zig) | `take` consumes one unit of work and `finish(success)` re-arms after a failure. `pending` answers `false` while the window is not visible, so continuous demand on a hidden window produces no work. A deadline comes from the caller's own clock, and a due deadline is consumed only after the corresponding frame succeeds. |
| `task.Service.scheduleUi/spawnWorker/wait/snapshot/nextDeadline/pending/cancel/detach/drain/shutdown`, `task.Service.initDeterministic` | [`src/v7/task.zig`](../src/v7/task.zig) | `setWake` installs the host's wake callback and `shutdown` returns only after every task has left. `initDeterministic` is the path `nogui_test` drives. `Session.deinit` first calls `shutdownTasks` under a 100 ms bound and reports `error.UnfinishedWork` without retiring anything, so a later retry still finds the executor and Session live. |

## Native services, accessibility and platform limits

| Family | Entry points | Source | Limit the source states |
| --- | --- | --- | --- |
| Clipboard and primary selection | `Clipboard.init/set/setText/clear/has/read/readItem`, `supportsPrimarySelection`, `getPrimaryText/setPrimaryText/clearPrimary` | [`src/v7_host/clipboard.zig`](../src/v7_host/clipboard.zig) | Primary selection is read from the live SDL driver name and holds only for `x11` and `wayland`; every other driver returns `error.UnsupportedCapability`. `Clipboard` owns its offer and releases it in `deinit`. |
| File and message dialogs | `DialogManager.setWorker/showFile/showMessage/onWindowClosed/deinit`, `revealPath`, `FileOutcome`, `MessageOutcome`, `dialogs.PointOfRiskApproval`, `FileOptions.filters`, `Filter.match` | [`src/v7_host/dialogs.zig`](../src/v7_host/dialogs.zig) | Both dialog calls require approval before a provider runs. The caller supplies the worker. Keep callback context alive through parent destruction. Parent closure delivers `parent_closed` once and drops later callbacks, including after manager teardown. Drain worker work and SDL completions before destroying SDL or the allocator. `unsupported`, cancellation and failure remain distinct. **Filters.** `FileOptions.filters` is empty by default, and an empty list opens the dialog unfiltered; it is never refused. Each `Filter` is a `name`, a `;` separated `pattern`, and the `match` mode that reads it. `extension` (the default) is the extension list SDL's own `SDL_DialogFileFilter.pattern` takes; `glob` is the whole-name glob list the xdg-desktop-portal FileChooser matches, where `*.txt` is the pattern a real chooser answers. `*` alone means every file in either mode, and reaches a portal chooser as a filter with no patterns rather than as the file named `*`. `validate()` refuses, before any native call, what no chooser can answer: an empty name, an empty pattern, an empty `;` part, a NUL byte, a byte the mode does not allow, and — in `glob` mode — a part with no `*`, which is the exact-name shape that produced "Folder is Empty" against the GNOME/Nautilus portal. On an SDL-backed host a `glob` filter that is not a `*.<extension>` list is refused with `error.InvalidFilter` rather than sent as a narrower filter. |
| External URL and launch | `UrlDispatcher.openExternal/registerSchemeHandler/handleLaunch`, `isValidUrl`, `extractScheme`, `SchemeRegistry` | [`src/v7_host/open_url.zig`](../src/v7_host/open_url.zig) | `openExternal` takes the same approval. An invalid URL, an unregistered scheme, and a host with no portal are three different answers, and the last is `.unsupported`. |
| Menus | `MenuActionBridge.init/isItemEnabled/isItemChecked/dispatchItem/evaluate`, `SystemAction.actionName`, `action.Registry.bindCheck/inspectCheck`, `hasNativeGlobalMenu`, `hasDockMenuSupport`, `RecentDocumentsManager` | [`src/v7_host/menus.zig`](../src/v7_host/menus.zig), [`src/v7/action.zig`](../src/v7/action.zig) | A system action is an ordinary W10 action wearing the native ordinal: enablement, tick mark and dispatch all resolve through the same registry under `SystemAction.actionName` (`system.quit`, `system.hide`, `system.minimize`, ...). A row whose focused context owns no binding is greyed, claims no mark, and answers `unavailable`; a name the app never registered is no row a click can reach. `MenuItem.explicit_checked` is an optional static override; otherwise the registry reads the focused weak model's live check state without dispatch. Disabled actions can stay checked. Query callbacks may compact bindings; the selected binding is retained by value. Both native `has…` answers are `false` off macOS and Windows; no in-app replacement is implied. `evaluate` returns an `EvaluatedMenuBar` that owns every string it carries — menu titles, item labels, shortcuts, action names, payloads, and the rows of nested submenus — in its own arena, so the caller's `MenuBar` may be scratch storage that is rewritten or freed as soon as the call returns; the snapshot stays valid until its `deinit` and nothing it points at is released separately. `dispatchItem` borrows the row it is handed for that call only, so a consumer that keeps a row past the call — the Windows route table does — keeps its own text alive. **Now observed, on the dummy driver:** the W18 run at source `89D8` passed **13 of 13** steps with `zig build w18-dialog-smoke -- --native-observations` under SDL's `dummy` driver, and model state-derived title, label and shortcut snapshots stayed readable after the caller's buffer was released. Four real typed dispatch outcomes were handled distinctly: `handled41`, `unavailable_otherctx`, `disabledNotNow` and `handledQuit`. The covering regression is `api-w18 an evaluated menu still routes and reads after the caller's text is retired`. **What this still is not:** no external URL, no clipboard mutation, no Secret Service and no native Windows or Cocoa menu was involved, so it is not desktop-menu acceptance. |
| Desktop preferences and paths | `preferences.getSystemTheme/getTitlebarButtonLayout/getScrollbarPreferences/getThermalState/getCompositorInfo/getReducedMotion/applyReducedMotion/getUserFolder/getBasePath/findAuxiliaryExecutable` | [`src/v7_host/preferences.zig`](../src/v7_host/preferences.zig) | Unobserved native signals remain optional. Reduced motion may be application-configured; `applyReducedMotion` bridges it to the App. Allocated paths belong to the caller; SDL's cached base path remains SDL-owned. The owned-X11 smoke verified compositor/driver agreement, truthful null signals and filesystem-backed path lookup without changing desktop settings. **2026-10-04 source repair:** `getTitlebarButtonLayout` returns `null` with an explicit comment that no supported backend observes this signal, and the fabricated undocumented `NOGUI_BUTTON_LAYOUT` value together with its native getter branch was removed rather than left implying an observation. The declaration is its only reference, so no native caller migrated. The public `parseButtonLayout` parser is kept deliberately as a pure parser, independent of that signal. **Now observed, and reported truthfully as absent:** the same 13-of-13 W18 dummy run read `getTitlebarButtonLayout` as **`null`** rather than fabricating a value, with `NOGUI_BUTTON_LAYOUT=minimize,maximize:close` present in the environment. So the fabricated getter is gone and the signal is honestly absent on this driver; a native desktop observation of it is still owed. |
| Notifications | `NotificationsService.submit/replace/dismiss/handleProviderDisconnect/pump/getCapabilities`, `Capabilities.none`, `SubmitOutcome`, `DismissOutcome` | [`src/v7_host/notifications.zig`](../src/v7_host/notifications.zig) | Tracking capacity is reserved before the provider can accept; a tracked replacement reuses its old slot. Provider `submit` must not mutate the service or deliver callbacks inline; later responses arrive through `poll`. Unprobed capabilities are all false, `dismiss` is `.unsupported` with no provider, and disconnect clears capabilities. |
| Secure credentials | `CredentialsService.read/write/delete/refuseCalls/shutdown`, `CredentialValue.init/initOwned/deinit/clone/format`, `ReadResult`, `WriteResult`, `DeleteResult`, `ProviderError`, `CancellationToken` | [`src/v7_host/credentials.zig`](../src/v7_host/credentials.zig) | `CredentialValue.deinit` runs `secureZero` before it frees, and `format` writes only `[REDACTED SECRET]`, so a formatted value can never carry the secret. The three operations answer three separate unions — `ReadResult`, `WriteResult` and `DeleteResult` — and each one carries `locked`, `prompt_dismissed`, `denied`, `canceled`, `provider_failed` and `unsupported` rather than one undifferentiated failure. They keep their own operation arms on top of that shared set: `ReadResult` answers `found` or `not_found`, `WriteResult` answers `success`, and `DeleteResult` answers `success` or `not_found`. `provider_failed` carries a typed `ProviderError`, so a transport fault is named rather than collapsed into a boolean. |
| Screen capture | `capture.Session.begin/stop/state/failure/acquireLatest/releaseFrame`, `capture.SessionState`, `isTerminal`, `isActive`, `capture.FailureReason`, `capture.Capabilities`, `classifyFailure`, `linux_capture.capabilities`, `linux_capture.Provider` | [`src/v7_host/capture.zig`](../src/v7_host/capture.zig), [`src/v7_host/linux/capture.zig`](../src/v7_host/linux/capture.zig) | `capabilities()` is a pure environment read: a missing session bus, an absent display server, or an unloadable `libpipewire-0.3` each fill `unavailable_reason` with a sentence. `begin` on an unavailable provider returns `error.CaptureUnsupported`, the session does not own its backend, and `deinit` refuses with `error.FramesStillBorrowed` while a frame is out. **States.** `SessionState` has eight values and a session reaches at most one of them: `idle`, the three active `selecting`, `starting` and `streaming` that `isActive` names, and the four terminal `canceled`, `denied`, `stopped` and `failed` that `isTerminal` names. The four terminal answers stay distinct: a chooser the user closed is `canceled`, a refusal is `denied`, an ordered stop is `stopped`, and a provider or platform fault is `failed`. **Unsupported is not one of them.** `unsupported` is a `FailureReason`, not a state, so "this machine has no capture provider" is never reported as a user refusal; `classifyFailure` is the single mapping from a provider error to that reason. |
| Native accessibility | `accessibility.Adapter.init/stateOf/capability/publish/drain/bindSystemBell/unbindSystemBell/bell/systemBellAvailable`, `accessibility.linked`, `State`, `Capability`, `Bell`; `Application.bindSystemBell/unbindSystemBell/ringSystemBell/systemBellAvailable` | [`src/v7_host/accessibility.zig`](../src/v7_host/accessibility.zig), [`src/v7_host/application.zig`](../src/v7_host/application.zig), [`src/v7_host/system_bell.zig`](../src/v7_host/system_bell.zig) | `linked` is a comptime build fact. Without the bridge the adapter reports `State.unavailable` and every tree call is a no-op. The published tree is bounded by `max_nodes` 32768, `max_queue` 64 and `max_payload_bytes` 8192. The bell is a WINDOW call: a bind succeeds on a platform with no bell at all, `unbindSystemBell` is `!void` and a refused release keeps the whole binding, and `Capability.bell` is measured from the bound window rather than from `State` — see [the accessibility bell](#the-accessibility-bell). |
| Native popups and layer surfaces | `linux.popup.NativePopup.init/reposition/requestGrab/ackConfigure/commit/dismiss/teardown` (state contract); `linux.popup_real.NativePopup.create/show/grab/grabStatus/grabHeld/takeX11Press/waitForConfigure/ackLatestConfigure/reposition/pump/onParentClose/dismiss/deinit`; `ParentInput.create/pump/takePress/onParentLost/deinit`; `linux.layer_shell.LayerSurface.init/ackConfigure/commit/teardown`; `linux.decorations.DecorationsManager.hitTest/startMove/startResize` | [`linux/popup.zig`](../src/v7_host/linux/popup.zig), [`linux/popup_real.zig`](../src/v7_host/linux/popup_real.zig), [`linux/native_input.zig`](../src/v7_host/linux/native_input.zig), [`linux/layer_shell.zig`](../src/v7_host/linux/layer_shell.zig), [`linux/decorations.zig`](../src/v7_host/linux/decorations.zig) | Either native grab requires approval. X11 uses a mapped popup and a separate XCB connection to SDL's actual display; `takeX11Press` reads that popup's server event and `onParentClose` ungrabs immediately. Wayland consumes a genuine owned-parent press before the initial commit. Each delivered configure is acknowledged once; `waitForConfigure` will not return an already-acknowledged answer after reposition. `ParentInput` owns its queue/seat/pointer and borrows the API mapping and SDL parent. Private X11 grab/outside dismissal/parent-close and Wayland real-serial grab/reposition/compositor `popup_done` were observed on 2026-10-03. Layer reservation, transformed input, output resize/configure/ack/buffer and terminal events were observed on owned Niri/Sway; owned GPU-capable Weston proved `LayerShellUnsupported` with a working ordinary toplevel. Wayland-only APIs refuse other drivers; model `mapped` alone is not buffer or visibility proof. |
| Display and window capabilities | `display.hasGlobalPosition/hasWindowMinimized/hasWindowHierarchy`, `Application.capabilities` | [`src/v7_host/display.zig`](../src/v7_host/display.zig), [`src/v7_host/application.zig`](../src/v7_host/application.zig) | All three are runtime driver-name probes, not build assumptions. Wayland publishes no global position, and the `dummy` driver publishes no window hierarchy, so a menu or tooltip window there has no parent relationship left to observe. |
| Desktop preferences and paths | `preferences.getSystemTheme/getTitlebarButtonLayout/getScrollbarPreferences/getThermalState/getCompositorInfo/getReducedMotion/applyReducedMotion/getUserFolder/getBasePath/findAuxiliaryExecutable` | [`src/v7_host/preferences.zig`](../src/v7_host/preferences.zig) | Unobserved native signals remain optional. Reduced motion may be application-configured; `applyReducedMotion` bridges it to the App. Allocated paths belong to the caller; SDL's cached base path remains SDL-owned. The owned-X11 smoke verified compositor/driver agreement, truthful null signals and filesystem-backed path lookup without changing desktop settings. **2026-10-04 source repair, not proof:** `getTitlebarButtonLayout` now returns `null` with an explicit comment that no supported backend observes this signal, and the fabricated undocumented `NOGUI_BUTTON_LAYOUT` value together with its native getter branch was removed rather than left implying an observation. The declaration is its only reference, so no native caller migrated. The public `parseButtonLayout` parser is kept deliberately as a pure parser, independent of that signal. That closes the fabricated getter, **not** the preference: its native observation is still owed, and the later stable-union native run is what will settle it. |
| Other platform adapters | `macos.available`, `macos.capabilities`, `windows.isApplicable`, `windows.accessibilityAvailable`, `mobile.native.platform`, `mobile.native.available` | [`src/v7_host/macos/root.zig`](../src/v7_host/macos/root.zig), [`src/v7_host/windows/root.zig`](../src/v7_host/windows/root.zig), [`src/v7_host/mobile/root.zig`](../src/v7_host/mobile/root.zig), [`src/v7_host/mobile/native.zig`](../src/v7_host/mobile/native.zig) | `macos.available`, `windows.isApplicable` and `mobile.native.platform` are `comptime` facts about the target, separate from any runtime fact. Off target every one of these modules still compiles, `macos.capabilities()` answers all-false because its fields default to false, and an entry point returns `error.ShimUnavailable`, `error.NotWindows` or `error.Unsupported` rather than fabricating support. Two of the listed readings are narrower than "a fact about the target": `windows.accessibilityAvailable` is still a build fact, but it also requires the AccessKit bridge to be linked, and on macOS `capabilities()` fills `native_dialogs` from the live SDL driver name and `accessibility_trusted` from a main-thread trust read, so those two fields are runtime observations. The directories themselves are: macOS carries `window`, `application`, `services`, `text`, `menus`, `keychain`, `notifications`, `dialogs`, `pixel_buffer`, `accessibility` and `preferences`; Windows carries `app_identity`, `jump_list`, `window_interop`, `menus`, `credentials`, `notifications`, `capture` and `accessibility`, and deliberately re-exports the shared SDL clipboard and dialogs rather than implementing a second one; mobile carries `native`, `lifecycle`, `sdl_mobile` and `accessibility`. |
| Application and window lifetime | `Application.Hooks.on_close_request/on_before_close/on_quit_request/on_frame`, `closeWindow`, `requestQuit/resolveQuit`, `ManagedWindow`, `ManagedWindow.refresh/refreshAt`, `Window`, `Window.ClientExtent`, `Window.clientExtent`, `Window.translate` | [`src/v7_host/application.zig`](../src/v7_host/application.zig), [`src/v7_host/window.zig`](../src/v7_host/window.zig) | A close veto destroys nothing, and a quit veto that times out expires. `on_before_close` runs while the platform window is still alive; `on_closed` is too late to release a surface. `step` returns one nonblocking batch and then task delivery, and `nextWaitMilliseconds` is the idle bound an external loop honors. **Transactional open.** `openWindow` publishes nothing unless every step succeeds, so a failure after the title copy or the native window releases exactly what that window took and leaves every other window registered, addressable and framing; a direct `closeWindow` caller still receives its typed refusal. **A declined close is not a failed dispatch.** A `window_close_requested` for a window with an open child popup is a refusal like a veto, so it yields no event and does not end the caller's loop. **One measurement per event.** `clientExtent` reads the client box in both spaces once, `refreshAt` publishes that reading as `observed`, and `translate` converts against it, so pointer, IME and render coordinates for one routed event all describe the same window; any event that re-reads a window arms layout whatever tag carried it. **Slot and native-id reuse.** A stale native event is dropped by the `created_ns` comparison and a reused slot answers the old handle with `StaleWindow`. |

The public host `accessibility.Adapter` read-back surface is
`lastRole`, `lastLabel`, `lastValue`, `lastNumericValue`, `lastRect`, `lastFlags`,
`lastActions`, `lastCharacterLengths`, `lastTextSelection` and
`lastTextSelectionOwner`, plus `lastWasFullTree`. `lastValue` is the TEXT channel
only — it returns the node's published character bytes, so a numeric range never
arrives through it. `lastNumericValue(id)` is the numeric channel and returns an
optional `f64`: `null` for an absent node, and `null` for a present node that
published no numeric value, while a numeric zero stays a **present** `0.0` rather
than collapsing into absence. Read a progress or slider range with
`lastNumericValue` and a text field's characters with `lastValue`; the two are not
interchangeable. These say what the adapter handed AccessKit, never what a
platform echoed back.


SDL failure proof (2026-10-03): the isolated real consumer first selected an impossible video driver, then `dummy` in the same process. Before repair the second call retried and initialized SDL. After repair both calls returned `SdlInitFailed`, neither held a session, and SDL video remained down; 12/12 build steps, exit 0. Initialization and refcount transitions are serialized. Successful sessions still quit on their last release; only initialization refusal is sticky. Evidence: `/tmp/nogui-sdl-sticky-failure-proof-20261003.json`.

The current W18 owned-X11 process exercised the public menu bridge after the system-action cutover: focused enable/check reads dispatched nothing, the explicit observe and quit actions each dispatched once, another context was unavailable, and the disabled row invoked nothing. It also delivered one queued synthetic launch and refused an unapproved external launch; 13/13 steps, exit 0. Linux has no native global menu here, so this is running registry/bridge evidence, not an observed desktop menu.

The 2026-10-03 private native credential consumer separately proved unexpected
transport loss during an unanswered `SearchItems`: the pending read completed
once as `provider_failed/io_error`, with zero late completions, `busy=false` and
worker join before provider release. This differs from the separately observed
`disconnected` refusal after explicit local shutdown. Only a new missing synthetic
namespace was read; the transcript contains no write, delete, Unlock or Prompt,
the private store remained empty and all owned processes retired. Evidence:
`/tmp/nogui-w19-inflight-loss-scanned-env-20261003/evidence/summary.json`.
Locked-store prompts and other-target credentials remain unverified.


The scoped W22 no-press run announced readiness before waiting, then returned `NoRealParentPress` without a signal, allocator fault or surviving child. Its own niri compositor still answered the output query; fixture teardown left zero owned or unattributed survivors. Together with the retained real-press proof, this verifies both paths after the `ParentInput` consumer lifetime repair. Evidence: `/tmp/nogui-w22-no-press-final-20261003/niri/runtime/w22-no-press-result.json`. No input was injected in the negative run.

The scoped stale-seat run answers the other side of that pair. A private
`wl_pointer` button delivered a real serial **11** on the owned parent's own main
surface, at the point the compositor itself reported for that window. With that
serial withdrawn, the production grab path refused with `MissingSeatSerial` rather
than sending `xdg_popup.grab`: `shared_display_error=0`, `pending=false`, the grab
never became held, and the parent close then released the role with
`dismiss_reason=parent_closed`, `has_grab=false`, `x11_grab_held=false` and a
subsequent `AlreadyClosed` refusal on dismiss. `Application.deinit` and
`Session.deinit` were accepted and the native process exited 0 with no signal. The
withdrawal itself is **simulated by the fixture**: no compositor
`wl_registry.global_remove` for the seat was observed, and none is claimed. What
this establishes is the missing-serial refusal and the production native guard on a
real connection, which is what the package asks for; it is not a demonstration of a
compositor-driven seat loss, and nothing requires that of this path. Evidence:
`/tmp/nogui-w22-stale-seat-final-20261003/evidence.json` and its
`scenario-popup-wayland.txt`; the no-press counterpart is
`/tmp/nogui-w22-no-press-final-20261003/evidence.json`.


Capture runner evidence (2026-10-02): `w20-capture-smoke` defaults and `--help` exit without a portal selection or PipeWire stream. Native options without authorization return `NativeOptionWithoutAuthorization`; an authorized arm without a cursor policy returns `NativeArmNeedsCursorPolicy` before provider calls. The reported `api-w20` 81/81 run selected provider/contract tests, not the eleven runner regressions then named `w20-capture-smoke`. It does not prove those runner deadlines, validation or teardown branches. Live capture is still **unobserved**, and a CLI authorization flag never substitutes for interactive permission at the portal prompt. It is no longer unapproved in the abstract: the user approved exactly one first capture on 2026-10-03, bounded to one owned private Niri/Xvfb `:6` session with clipboard sharing disabled, one monitor and one stream, 30 frames, a 15 000 ms post-approval budget, one PPM, and a source a person chooses manually. No capture, provider, chooser or portal request has been started; the approved `:6` viewer window is preparation, not that capture.

Capture protocol repair (2026-10-03): the focused `api-w20` gate exited 0 after failing-before regressions for wire layout, result ownership and optional dictionary metadata. Linux uses `CreateSession(a{sv})`, `SelectSources(oa{sv})`, `Start(osa{sv})` and `OpenPipeWireRemote(oa{sv})`. Cursor policies map to portal bits 1/2/4, `multiple` is a D-Bus boolean and persistence uses `persist_mode`. The reply serial and its handle index determine descriptor ownership; every unselected descriptor is closed.

`capture.Request` has no application-ID override. The portal attributes the caller through its D-Bus connection. Portal response strings remain owned until `Outcome.deinit`; repeated strings replace or clear the prior copy without leaking, including allocation failure. Stream `size` is a compositor-space `(width,height)`, not the delivered frame's pixel extent. Owned socket tests contacted no capture provider; interactive selection, live preview and applicable X11 capture remain unproved.

Capture runner repair (2026-10-03): the serial `api-w20` build passed 106/106 tests, including thirteen runner regressions now selected by that filter. A window-class frame answering a monitor-only request failed before repair and now returns `mismatch`; an explicitly reported empty class also refuses, and a mixed request permits a reported subset. Unknown source metadata prints `<unproved>`, not a guessed class. The structural-zero post-stop probe was removed: an empty application queue cannot prove provider-thread retirement. Actual default runs still capture nothing. Live chooser, preview and provider shutdown evidence remain open.

Provider-free capture-fixture fault modes (2026-10-03): the private capture fixture's own failure handling was driven with no provider, chooser, portal request or frame involved. Bounded consumer retire is `GREEN` at exit 0 (`/tmp/nogui-w20-fault-green-20261003/consumer-retire-report.json`), the exited-leader group-descendant mode is `OK` at exit 0 (`/tmp/nogui-w20-fault-green-20261003/group-descendant-report.json`), the no-approval consumer is `GREEN` at exit 0 (`/tmp/nogui-w20-fault-green-approval-v3-20261003/consumer-retire-report.json`), and the foreign-birth unknown-group mode is `REFUSED` at exit 0 (`/tmp/nogui-w20-fault-green-unknown-v2-20261003/unknown-group-report.json`). That last state is the correct green answer: after the owned pid, pgid, session and start time were swapped with a stranger, the guard recorded that the group was not this run's to signal, signalled nothing, and the stranger's group settled with `zero_surviving_members`. A separate later-than-15 s timing fault is recorded at `/tmp/nogui-w20-approval-wait-proof-1791051478197/result.json`: the timing protocol arrived at 17.5 s with `childAliveUntilAnswer: true` and no premature retirement, and a refusal ended waiting without granting approval. That file states `nativeProvidersStarted: false`, `captureOccurred: false` and `realApprovalEstablished: false`. These are harness faults, not capture.

Runtime library resolution (2026-10-03): `std.DynLib.open("libpipewire-0.3.so.0")`
names a SONAME, and a 2026-10-03 fixture arm checked the one library the consumer
will actually load without starting anything: it resolved
`/nix/store/h06qaqbc0llyr2vpqrj9ia2dpwgw120m-pipewire-1.6.8/lib/libpipewire-0.3.so.0`
out of a declared provider's store output rather than the operator's
`LD_LIBRARY_PATH`, and confirmed the file's own ELF `SONAME` matches, at
1,126,128 bytes, SHA-256
`12131ad16fac5d978266c15243b3a307e70e915af404074fb156447fa1c80430`, with
`DT_NEEDED libc.so.6`. 14 of 16 declared providers resolved; the chooser and
portal front-end each have two installed matches and are named with
`--chooser-bin` and `--portal-bin`, a conservative fixture choice rather than
missing information. This is neither chooser nor capture evidence: no provider was
started, no chooser appeared, no frame was captured and no permission was requested
or granted. `capabilities()` reading `unavailable_reason` for a missing
`libpipewire-0.3` remains a separate, already documented outcome.

First private setup (2026-10-04): Xvfb `:6` accepted the run's cookie client
(exit 0) and refused a cookieless client (exit 1). Niri then exited 101 on
missing `libXcursor.so.1` in the filtered runtime, before any viewer, chooser,
ScreenCast or stream. All seven owned process groups retired completely and
their PIDs were re-observed absent. The Node wrapper nevertheless timed out
after 600 seconds.
Evidence: `/tmp/nogui-w20-private-capture-WetkjW/fixture.json`.
No capture or permission acceptance follows from this setup.

Current provider-free checks resolve all six required compositor SONAMEs from the declared runtime list.
After a real FD-leak RED, a SONAME-scan refusal releases all owned directory descriptors.
The real-child lifecycle smoke drains naturally at Node `beforeExit`, without a forced success exit.
All 19 safety cases held across 20 fresh module instances, with all instances retired.
The final audit found no live owners, zombies or unobservable processes.
Evidence: `/tmp/nogui-w20-runtime-lifecycle-fd-green-20261004/result.json` and
`/tmp/nogui-w20-viewer-current22-20261004/result.json`.
Those provider-free checks do not establish viewer or capture acceptance.

Native setup repair (2026-10-04): the real backend crashed when Niri supplied
no DRM device. The declared `xdg-desktop-portal-wlr` patch preserves the
shared-memory path and now reaches readiness on the private compositor.
The frontend also acquired its private bus name.
`weston-color` required unavailable `wp_color_manager_v1`.
The declared `weston-image` client now paints an owned static scene image.
The private compositor screenshot was inspected, and two still witnesses matched.

Evidence: `/tmp/nogui-w20-private-capture-lUUPJb/fixture.json`.
All 19 fixture-owned process groups retired completely.
The parent viewer authenticated but lacked a verified compositor window witness.
It exited 0 after fixture retirement.
No viewer acknowledgement, ScreenCast request, chooser, stream or captured frame occurred.
*(Superseded 2026-10-04: that attempt started no capture. The run below did issue a
real `CreateSession` and `SelectSources`.)*

The first actual capture request (2026-10-04): evidence
`/tmp/nogui-w20-private-capture-1RLlCp/fixture.json`. This run consumed the one
approved first capture, and it did not produce a stream.

- The consumer really reached the portal. `capture.Session.begin` issued
  `CreateSession` and `SelectSources` with `types=1`, `multiple=false`,
  `cursor_mode=2` and `persist_mode=0`, against a backend that advertised
  exactly `AvailableSourceTypes=1` and `AvailableCursorModes=3` (hidden and
  embedded). The same run reported `capabilities: available=true
  platform=wayland backend=portal_pipewire`, `multiple_streams=true` and
  `requires_user_approval=true`.
- The private viewer half is now proved rather than assumed. The viewer process
  `3764550` (start ticks `30773721`) was identified on the private X server:
  niri reported window `295` with relay pid `4315`, which is the XWayland
  satellite rather than the viewer, and `xprop` on XID `0x1400005` returned that
  exact viewer pid together with its caption and `WM_CLASS`. The private server
  was pid `3762235` (start ticks `30771058`). The secure acknowledgement was
  exactly 108 bytes, mode `0600`, uid `1000`, `nlink` 1, and carried this run's
  own nonce with the same server identity, so it is a real handshake rather than
  a self-written file. `HOME` and every `XDG_*` variable pointed inside the
  private root, the viewer ran with `-AcceptClipboard=0 -SendClipboard=0
  -SendPrimary=0 -SetPrimary=0` against a server started with `-nosel
  -noprimary -nosetprimary -noclipboard -nosetclipboard`, and `-FullScreen=0`
  with `-RemoteResize=0`. The real private pixels were read and saved, and the
  still-witness pair taken after the resize matched.
- The chooser witness still did not arrive, and the first reason was the
  harness's own parser. The chooser really did run: a `slurp` process spawned by
  the portal backend produced a 198-line `WAYLAND_DEBUG` trace of which 119 are
  protocol lines, but the parser's prefix did not accept
  libwayland-client's `[hh:mm:ss.uuuuuu] {Default Queue} -> iface#id.method(...)`
  form, so nothing was extracted and the 240 000 ms attribution bound expired
  with `found=false`. The prefix is now optional-aware; replaying that same
  captured trace through the corrected parser yields shell 5, layer-shell 10,
  surface 3, output 9, xdg-output 11, the winit surface, the selection and
  configure/ack 201 in protocol order, with the raw lines retained.
  That is a replay of a real trace, not a live witness: the corrected parser has
  not yet been exercised against a fresh chooser, so the chooser clause stays
  unproved.
- The consumer's own result is a refusal. `w20-capture-smoke.log` reads
  `begin: state=denied failure=rejected returned=CaptureDenied chooser=279771 ms`,
  `stop: state=denied outstanding=0 after 18 ms`, and `verdict: the capture half
  did not observe a validated stream; exit=3`. No stream was validated and no
  production PPM was written. The fixture wrapper itself exited 22 after
  345.68 s.
- Retirement is real but not entirely clean. All 23 owned process groups were
  observed empty, with zero owned survivors, zero unresolved ownership, zero
  observation failures, zero unsettled reaps and zero still-open pipes. **The six
  `invalid_pidfd_reply` refusals are now classified in source rather than
  unexplained**, and that classification is not a live witness: the old caller
  allowed 2000 ms and then sent its own `SIGTERM` before the helper's own 5000 ms
  budget, all six helper stdouts were empty and carried `SIGTERM`, and the collector
  now declares a 20 s startup contract of 5 + 2. No fresh capture produced that
  explanation and no earlier component proof explains it. Source-repaired and still
  not live-witnessed, so the run is not called clean as a whole. Separately, the
  post-run final retirement outcome is repaired in source: the old code emitted a
  verdict with no exit status while the consumer's own log recorded exit 3, so that
  run has no final at all, and the source now records the status instead of dropping
  it, and both follow-on units are done: a named export of that code exists, and a driver
  takes an actual owned child pidfd through the fixture helper. The parent then ran the
  owned-kernel closure at exit 0 in 17.76 s, durable JSON at
  `/tmp/nogui-w20-owned-kernel-closure-EhJ1NX/owned-kernel-closure.json` under a mode-700
  root: an actual owned member syscall pinned to its start ticks and sent `TERM`, an actual
  gone-and-reaped kernel refusal with the genuine helper answer intact, and an actual
  `TERM`-ignoring owned child carried through the wait boundary, `TERM`, grace and `KILL`
  to a real reap, with the consumer's retirement refreshed from teardown and its exit 22
  preserved. That last case is a standalone process, so no capture consumer and no genuine
  `Deny` claim comes from it. No bus, display or capture was involved: this is corrected
  collector and root-owned-child behaviour, not native proof, and the seven original W20
  full-fixture acceptance items stay blocked.
- The private bus denied all five accessibility names
  (`org.a11y.Bus`, `org.a11y.atspi.Registry`, `org.a11y.atspi.DeviceEventController`,
  `org.a11y.Registry`, `org.a11y.Status`), so this run was capture-only and
  could not have produced a11y evidence.

Live capture, the validated stream, the preview, stop/owner-loss and native
resource retirement all remain unproved. No second capture is approved; a
further attempt needs renewed point-of-risk approval at the time it is made.

### Linux D-Bus transport

[`linux/dbus.zig`](../src/v7_host/linux/dbus.zig) correlates `Connection.call` replies by the outgoing serial. Unrelated signals and replies stay in the bounded inbound buffer in arrival order; notification polling can still consume them after a synchronous call. An owned frame is released with the connection's allocator, including after disconnect, rather than with the provider's allocator.

Raw Linux syscalls use `std.os.linux.errno`, including when libc is linked. `std.posix.errno` then follows libc's `-1` convention and cannot decode a kernel `-errno` return. The libc-linked regression failed before repair with an out-of-bounds length from `EBADF`; all seven standalone transport tests now pass with typed read/write failures.

The authenticated connection negotiates UNIX_FD before `BEGIN`. `Connection.callWithFd` borrows one descriptor, emits header field 9 as count 1 and attaches `SCM_RIGHTS` only once, including on a partial send; the caller keeps its descriptor. An unnegotiated peer returns `UnixFdUnsupported`. An actual isolated no-activation D-Bus broker relayed `/dev/null`; the receiver resolved and read it, the sender's borrowed descriptor remained open, and the own-serial result was 42. This contacted no desktop provider.

Portal `ShowItems` and appearance reads now use the same own-serial reply path. `OpenURI` waits for its Request decision: success, user cancellation and failure remain distinct, including a decision arriving before the method reply. Per the [portal specification](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html), local `file://` targets use `OpenFile(sha{sv})` and directory requests use `OpenDirectory(sha{sv})`, with a real descriptor at index 0, not a URI masquerading as `h`. The 2026-10-03 `api-w18` gate passed 70/70 total tests; real external opening, revealing and desktop scheme association remain approval-gated.

Private Wayland W18 proof (2026-10-03): on an owned private Niri/Xvfb `:4` fixture with private buses and private HOME, the clipboard phase reported `observed`. One item offered three MIME formats — text, a 1×1 PNG of exactly 67 bytes and a JSON metadata blob of exactly 37 bytes — both non-text formats read back at those exact lengths, the whole item was restored, and PRIMARY was a separate selection whose capability read `true` and whose independent `wl-paste --primary` reader agreed; PRIMARY was absent before and absent again after, so the restore is independent rather than self-confirming. Three real GTK chooser endings were then observed separately: a synthetic selection, a real Cancel mnemonic (Alt+C) producing `outcome=cancelled`, and a live parent close. Escape is the backend's own `aborted` result and is deliberately not remapped to cancellation; only the fixture's driving side was corrected to use the real mnemonic, and no production result enum changed. The first parent-close attempt failed correctly because no buffer was mapped on the SDL parent and no chooser appeared within 30 000 ms; after the noapi mapped-parent fix the parent-close phase presented a real 320×180 noapi parent buffer, the owned compositor's close action produced `native parent close observed` with `parent-closed rounds=125 deliveries=1` and `Session.deinit=<accepted>`, exit 0. A final confirmation ran selected, Cancel and parent-close in **one** invocation against that same current mapped-parent executable: all three verdicts `observed`, controller exit 0, `/proc` argv readback matching the request, and zero survivors. Every fixture retired with zero surviving owned or unattributed processes. An earlier start-time crash with an ELF entry point of `0` was a cached tooling placeholder, not a clipboard or chooser defect. Evidence: `/tmp/nogui-w18-approved-wayland-runs/2026-10-03T17-16-05Z/result.json`, `…17-28-56Z/result.json`, `…17-35-45Z/result.json`, `…18-40-35Z/result.json`, `…18-44-24Z/result.json`.

Malformed chooser results release URI vectors and every already-decoded URI even when parsing returns the typed `.failed` outcome. That outcome is a successful function return, so error-only cleanup did not cover it; the late-field regression reproduced two allocator leaks before repair and passed afterward. Empty-slice `Allocator.free` is already a no-op in the pinned Zig allocator and was not the defect. A selected outcome alone takes ownership of the decoded paths.

Secret Service method waits use that correlated path. Prompt acknowledgements have no return arguments; `Prompt.Completed` is a separate signal and may arrive before the acknowledgement. The credential provider wipes request bodies and owned replies before release. `Connection.call` also wipes its exact-size outgoing wire buffer before freeing it with the builder's allocator. Optimized allocator-residue and loopback cases cover these paths without reading a user's credential store.

Real locked-store acceptance also needs a working Secret Service UI agent. `devenv.nix` declares GCR 3 and exposes its actual `gcr-prompter` wrapper as `NOGUI_GCR_PROMPTER`; GCR 4 is not a replacement for this executable. The installed agent and a successful preflight do not prove `Unlock`, `Prompt.Completed`, or a person's answer. That proof remains approval-gated and must use a fresh private bus, HOME, synthetic keyring, authenticated private display and human viewer; it must not use the operator's keyring, password or session settings.

Linux process-environment discovery streams `/proc/self/environ` into caller-owned storage. A key and its NUL-terminated value may span reads or follow a large unrelated record. A value that exceeds the supplied storage, or lacks its terminator, returns `null`; an empty or exactly fitting value remains valid. A real private-bus consumer connected from an 87,362-byte environment and completed owner queries, `AddMatch` and `RequestName` while preserving `NameAcquired`. Boundary fixtures passed 1,201 split offsets, large preceding records, exact fit, overflow, empty, missing and prefix-name cases.

Linux `Notify` and `CloseNotification` classify transport allocation failure as `.out_of_memory`, connection loss as `.disconnected`, malformed frames as `.protocol_error`, and other transport faults as `.io_error`. An isolated CLI consumer exercised service-capacity refusal before any provider call and real socket round-trips for memory pressure and connection loss; no session bus or desktop notification was used. The host's `api-w19` regressions also cover replacement routing and creator-allocator cleanup.

### The accessibility bell

The bell is a windowing-system request, so it belongs to a WINDOW rather than to the semantic tree. AccessKit's Unix adapter exposes no bell entry point and AT-SPI defines no portable one, so [`src/v7_host/system_bell.zig`](../src/v7_host/system_bell.zig) asks each platform the way its own primary source documents the request, and no platform is emulated by another: Linux X11 borrows SDL's own Xlib display, takes the XCB connection inside it and sends the core `Bell` request at percent 0, which is the protocol's "ring without changing the volume" the user selected; Linux Wayland binds the compositor's advertised `xdg_system_bell_v1` on a **private event queue of its own**, so the discovery never disturbs the queue SDL pumps, and sends `ring` from it; macOS calls `NSBeep` and Windows calls `MessageBeep(MB_OK)`. A provider owns exactly what it allocated — the shared-library mappings, that private queue and the bound proxy — and never closes the SDL window, the Xlib display, the XCB connection, the `wl_display` or the `wl_surface`. `Provider.init` neither fails nor traps: an inapplicable platform and an applicable backend that could not be reached are both values, `available()` is `false` for both, and `ring()` reports which of the two it was as `unsupported` or `provider_failed`.

The public surface is a lifetime, a capability and a result, and those are three separate facts.

- `accessibility.Adapter.bindSystemBell(host, window)` is a **lifetime** statement. It rings nothing by itself, it succeeds on a platform with no bell at all, a second bind on the same adapter is refused with `error.BellAlreadyBound`, and a window another observer already owns is refused with `error.BellObserverBound` rather than displacing that observer. Every refusal happens before any platform work, and a bind from a thread that does not own the windows is `error.WrongThread`.
- `unbindSystemBell()` is `!void` and belongs to the thread that made the binding. A release from another thread is refused with `error.WrongThread` and the **whole binding stays**: the host, the handle and the thread are cleared together and only after the host accepted. Everything else is an idempotent success — a handle that no longer names this window, a window with no observer, and an observer that has already been replaced all release nothing, because there is nothing left to release. `Adapter.deinit` refuses to run off the binding thread rather than dropping the binding quietly.
- `bell()` returns `accessibility.Bell`, which is `system_bell.Result`: `rung`, `unsupported`, `provider_failed`, `window_closed` or `wrong_thread`. The refusals are ordered so the cheapest fact wins — a closed window is named closed rather than blamed on the platform, an unbound adapter is `unsupported`, and a foreign thread is `wrong_thread`. `rung` means only that the platform accepted the request: the Wayland protocol itself lets a compositor answer a ring with a sound, with a visual cue or with nothing at all, so nothing here claims an audible result.
- `Capability.bell` is `systemBellAvailable()` for the bound window, measured at run time. It is `false` with no binding, after that window closed, where the backend found no bell at all, and for a query from a thread that does not own the window — in which case the caller gets the conservative answer and the window keeps its real one for the thread that drives it. A bind that succeeded says nothing about it. It is **independent** of `State` and of `screen_reader`: a linked bridge and a working bell are two different measurements. The mobile adapter reports `bell=false` and `.unsupported` on purpose, because a mobile host owns its window through the platform framework rather than through the desktop `Application`, so there is no window there for a system bell to belong to.

What is proved on this Linux host, both from the window the run actually opened: X11 answered `available=true` and `request=rung` while the adapter `State` was `inactive` and `screen_reader` was `false`, and a compositor advertising no `xdg_system_bell_v1` answered `available=false` and `request=unsupported`. The second is a real negative capability read off that compositor, not proof that the Wayland bell path works; no compositor on this host advertises the protocol. There is no `NSBeep` or `MessageBeep` runtime evidence here, and nobody heard the X11 bell: `rung` is what the platform reported, not an audible result. The runs are recorded in the [companion plan](superpowers/plans/2026-09-26-gpui-api-parity.md#w21--semantics-and-native-accessibility).

### Native tree publication and selection

Configure `App.semantic_publication` with a stable caller-owned `semantics.Publisher`, optional window name and annotator before producing frames. `App.frame` stages semantics before retiring the previous tree and commits it with the tree and reconciled focus. `FrameOutput.semantic_snapshot` borrows that committed snapshot. During annotation, `App.widgetIdForKey` resolves keyed owners in the candidate tree; outside annotation it resolves the committed tree. Keep the publisher and annotator context alive while configured, and clear the configuration before destroying them. A null configuration performs no semantic publication.

`semantics.Text` annotation slices must survive `Publisher.stage`. Staging copies
the complete value, placeholder and three character tables into the publishing
slot; published slices follow the snapshot's lifetime, not the mutable model's.
The C ABI distinguishes absent text (`value == NULL`) from present empty text
(`value != NULL`, `value_len == 0`). Numeric values use their separate channel.
An empty text run can address the collapsed caret at zero without a character
table; a nonempty tableless run still cannot address a caret.

The 2026-10-03 standalone public consumer passed first-frame annotation, failed-frame retention, recovery with stable identity and focus fallback across generations 1, 2 and 3; 13/13 build steps, exit 0. Evidence: `/tmp/nogui-semantic-transaction-proof-20261003.json`. The AT-SPI, Windows and mobile consumers now take the App-committed snapshot; `Adapter.publish` remains the explicit native edge. This core proof activates no native adapter and adds no screen-reader or other-SDK acceptance.

A keyed `DrawCtx.progress` publishes a read-only numeric range: the node is role `progress_indicator`, its `value` is the authored `value`, its `range` carries `min`, `max` and the normalized `percent`, and `states.read_only` is set. It enables no action, so a `set_value` dispatched at it is `unsupported_action` and the model value never moves. Its key, not its caption, defines its semantic identity: a caption that changes between generations keeps the same published node. The default node advertises no mutation or focus actions. Built-in radios publish `checked=on/off` alongside `selected`, including deselection to `null`.

`semantics.Draft.read_only` adds read-only policy; `false` cannot clear an
intrinsic read-only state. The dispatcher refuses string and numeric
`set_value`, numeric increment/decrement and selected-text replacement before
calling the model setter, even when authored actions advertise the mutation.
Readback, focus and selection remain governed by their own advertised actions.

`semantics.Dispatcher.set_text` takes
`?*const fn (*anyopaque, WidgetId, ?[]const u8, TextSelection) bool`.
A nonnull value replaces the entire contents, including an empty value or one
that borrows published/model bytes. A null value changes only the selection and
preserves character bytes, character tables and marked composition. Selection
offsets are UTF-8 bytes: whole-write offsets address the supplied value;
selection-only offsets are validated against the published run before delivery.
The callback applies them to its live model. Payloads are borrowed until callback
return; dispatch is synchronous. Do not replace the active publisher during a
callback. A missing callback or `false` returns `Failure.no_handler`.

The linked `api-w21` core run after this callback cutover passed 90/90 tests
across 63/63 build steps, including forced-action read-only slider refusals and
writable controls. The migrated headless W21 program passed 38/38 checks,
including stale-selection preservation, published-alias whole writes and active
preedit cancellation followed by a new composition/cancel.
These are core/model results, not native speech or other-target SDK acceptance.

The 2026-10-03 core `api-w21` run passed 41/41 tests across 13/13 build steps. A separate public App/Publisher consumer passed three generations with progress 60→85, fraction 0.5→0.75 and stable identity after a Unicode caption change. Ordinary radio activation changed selection 1→2, then explicit deselection published both options unchecked. Evidence: `/tmp/nogui-progress-radio-proof-20261003.json`. These runs activated no native adapter or screen reader.

Hidden nodes advertise no actions, including focus and blur. A failed `Publisher.stage` clears the pending-stage flag and leaves the published snapshot intact. Set cardinality uses `Relations.row_count`; unsupported duplicate `set_size` and unimplemented `popup_for` fields were removed rather than exposed as inert capabilities.

The migrated W21 consumer now reads the candidate tree during annotation and measures current field geometry before publishing it. Its first-frame headless run passed 27/27 checks. The actual owned-X11/GTX 1660 Ti run committed and presented five frames at 520×640, generations 1–5, with five visible rows over 250000 logical rows and a zero caret-geometry delta. The captured frame was inspected: field, selected row and modal confirmation matched the published/model state. Adapter state stayed inactive and screen-reader state false; no AT-SPI launcher or Orca was enabled. Evidence: `/tmp/nogui-semantic-native-final-OGx50Z/frame.png`.

`accessibility.Adapter.publish` stages an incremental snapshot before it crosses the owned C ABI. The SDK update factory selects a complete snapshot under the same lock that protects activation. A late activation therefore cannot receive a delta without its initial tree declaration. The host reserves all storage first. The synchronous supplier allocates nothing, calls no native API and retains no borrowed pointer. Accepted updates commit hash history. Quiet frames remain incremental.

Named actions cross that boundary as their own borrowed record.
`nogui_accesskit_custom_action` is `{ int32_t id; const char* name; size_t name_len; }`
and every node carries `custom_actions` plus `custom_actions_len`. The name bytes
are borrowed UTF-8 for the duration of the update call and **the SDK owns its
copy**, which is why `Adapter.reserve` counts every node's descriptors before
any pointer is handed out: descriptors are reserved first, so a growth during
node append cannot move a buffer a descriptor already points into. The action
request carries that exact signed `int32_t` back through
`nogui_accesskit_action_request.custom_action`, so a platform round trip is not
answered by re-deriving an index. Hidden and disabled nodes publish none.

The locally pinned same-version `accesskit_atspi_common` 0.20.0 patch is what
makes those records reach a screen reader at all. Upstream 0.20.0 published a
single `click` action and sent `Action::Click` for index 0 whether or not the
node was clickable. The patch publishes `click` at index 0 **only** for a
genuinely clickable node, so a custom-only action list legitimately starts at
index 0; it publishes every `Node::custom_actions` entry with its own exact
signed id; and it stops reporting `Enabled | Sensitive` for a disabled node, so
a disabled control publishes its real state. That last change is a real defect
repair, not a widening: the recorded native run showed the old behaviour
directly, where a disabled node still claimed `Enabled`/`Sensitive` and the
`Disabled` clause became unsatisfiable.

The changed union has focused checks: Core `api-w21` **95/95**, the locked
all-features Rust workspace **22 SDK + 22 bridge tests**, and the rebuilt
linked CLI **38/38**. The parent first reproduced the former named-list-owner
routing failure, then verified the correction. Use `cargo test --workspace
--all-features --locked --offline --manifest-path
src/v7_host/accesskit_bridge/Cargo.toml` to include the provider's tests and
its otherwise dormant `simplified` module. **Renewed native acceptance has run
since, and it is recorded below; it is not closed.** The earlier 93/93, bridge-only 22/22 and CLI 38/38 figures
predate this cutover. The pinned `Value` setter still acknowledges
asynchronously; an `UnknownObject` reply is not evidence of read-only state.

Selection capability and selection value are separate. A click-selectable virtual row publishes `selected=false` when unselected, not a missing selection property. Otherwise the SDK refuses `Selection.SelectChild` without reaching the model. Non-selectable rows omit the selection property.

The 2026-10-01 private Linux client passed 67 checks through the real AT-SPI registry. It proved UTF-8 character/byte selection conversion, invalid-index refusal, caret editing, exactly-once virtual-row selection and four complete reactivation cycles. Five published rows represented 250000 logical rows. All 15 object IDs, names and parent relationships survived each cycle. The run used `--no-synthetic`, private buses and an owned X11 display. Orca stayed off. The pin that run used exposed `Text` but no `EditableText`; the current pin is coherent — `accesskit` 0.25.0, `accesskit_unix` 0.23.0 with `accesskit_atspi_common` 0.20.0, `accesskit_macos` 0.27.0 and `accesskit_windows` 0.35.0 — and the locked Rust suite for those pins actually passed 19/19 on a tree that predates the current public setter callback change. Composition and speech remain unproved, but for want of observed native proof rather than for want of the interface.

### What the renewed W21 approval has and has not produced

The latest native run is
`/tmp/nogui-w21-approved-2026-10-04T14-09-07-151Z/evidence/result.json`: exit 1,
`full_acceptance: false`, 18 of 22 required items established. Its main client
exited 0 with zero failures and its named-policy client exited 0 with 23/23
checks. Both signed named list actions publish under their own names
(`Negative Edge`, `Min Edge`), index 0 is a named action and not a click, the
source records two named-list activations with zero clicks, and each blocked
node offers no `Action` at all — established by enumerating that node's own
interfaces, not by catching an exception. The typed consumer is retired before
the reader starts, every owner is retired after it, and the operator setting
reads `false` before and after.

Stock Orca 50.2 handled `Insert+ctrl+Left` as `Left` (113) after 102 ms and
presented `[progress bar: 'W21 Progress']`. The application model moved nothing,
the keyboard stayed on `W21 Slider`, and the indicator stayed `focusable=false`
and was never focused. Four criteria stay unestablished: progress value with
real audio, progress name through stock object navigation, reader object
navigation leaving the application untouched, and six-role audio at 0/6. The
reader debug log is 14,563 CRLF lines carrying 102 `SPEECH OUTPUT` lines with 0
proved fragments; the capture is a real 4,140,114-byte clock-paced monitor
(871 intervals, 870 growing, median 44,039 bytes/s against a declared 44,100),
and real synthesis is proved separately from that attribution. Raw and index
agree with 0 disagreements, 42 of 51 wire submissions joined, and the 9 that did
not were refused because the daemon added its own `__spd_0` index mark to a
payload that did not carry it. The reader's grab agreement could not be read
out of its own CRLF log, so the untouched-navigation criterion is not
established even though no model key moved. Whole-value `SetTextContents` and
keyboard proof against exact model counters hold; native IME composition does
not. The CRLF ingress fix is source-only and its replay has not run, so no
regenerated result and no new native full pass are claimed here.

The reader-origin observer hooks the original stock Orca and SSIP code objects through
`sys.setprofile` alone, with no stock patch, no wrapper and no added import, and emits one
stable event contract: common version, process and thread identity, presentation/fragment/
route/attempt sequence numbers, the connection epoch, an explicit `lineage` of `owned`,
`orphan` or `unbalanced`, and a `native_reply_witness` for the real inner response tuple.

The stock SSIP UID component on its own is a narrower fact than speech, and it is kept as its
own record rather than folded into the native result below: a genuine stock-SSIP run exited 0
in 19.03 s with report `/tmp/nogui-w21-native-uid-wt3c2jw9/report.json` — 87,144 bytes, SHA-256
`21e950ed…`, mode 0600, link count 1, under its own mode-0700 root — reading a real SPEAK UID 1
and the inner `send_command` UID 2 with the stock code unchanged, one connection epoch and the
outer CHAR answering `None`, while **every row is `ORPHAN`**. That standalone component is
superseded for speech purposes by the real-stack run recorded below; it is retained here as
history and is not credited with the speech that came later.

The earlier UID attempts remain historical reds and are not rewritten: the genuine-UID smoke
`/tmp/nogui-w21-native-uid-smoke.py` under root `/tmp/nogui-w21-native-uid-rwohalnm` exited 1
with readiness unproven — 40 s of log showing only the starting state — leaving the client UID
and the module identity unknown, so it was **not** a UID extraction proof; and the passive
genuine-components proof `/tmp/nogui-w21-reader-origin-component-proof.py` exited 1 with c1
and c2 passivity passing but all four harness children ended by `SIGTERM` rather than natural
reap, and c3 profile precedence, c4 threads and the footer unproven. A later run's sole
failure was a malformed two-field readiness `CLIENT_NAME`, since repaired to the stock
three-field form. None of them spent new native approval.

The profiler aggregate is red and no profiler pass is claimed: one proof failed six aggregate
clauses because CPython 3.14 installs monitoring tool 2 for `cProfile` — 24,607 events — so
`sys.getprofile` reads `None`, which the old source helper's hook-only guard misses. That
proof's other results stand: all four children exited naturally 0 and all 11 native
thread-identity birth checks passed, with no UI, daemon or native UID in it.

The located-PCM helper proof is 14/14 inside its own scope only, and the legacy consumer's
current PCM integration run exercised 10 of 10 cases with 0 failures and 17 unexercised in
564.45 s, integration-only
(`/tmp/nogui-w21-located-pcm-proof-2026-10-04T21-25-54-565Z-1451831.json`, journal
`/tmp/nogui-w21-located-pcm-proof-journal-aUZ0gJ/cases.jsonl`). AFTER-unlink, AFTER-directory
and a third AFTER-truncate all passed with `unknown`, `spoken=false` and null across all ten
metrics, and the first eligible legacy row 6/1 read its real before flags, reference 55618B,
13 chunks and the unique `[118112,173730]` window over a 4,256,050-byte whole. The historical
19/7 subject is still absent and was not retargeted, and the 11 helper cases are excluded
because the mode is integration-only, so this is **not** a full 27-pass. UID provenance remains
LEGACY_ORDINAL and unsafe: the native causal UID is unknown and the old root is not credited.
The measured cost was a 301,024 ms `bound_subject_forward_pass` against 32,780 ms baseline bind,
30,981 ms AFTER-unlink, 43,138 ms AFTER-directory and 64,307 ms AFTER-truncate, which leaves
the 64 KB pipe hypothesis **unproven**; the bounded-IO item is closed, no approved evidence
changed, no process was started and no fresh approval was involved.

- **A full real native stack now produces genuine speech.** Three real-stack runs are on record,
  all on a real Xvfb `:90`, a real session bus, real dconf with `screen_reader_enabled` read back
  true, the real AT-SPI bus and registryd with `ScreenReaderEnabled=true`, a real
  speech-dispatcher with the espeak-ng module and module observer all owned and pinned, real
  Orca 50.2 attached and alive, a real focused window, a real XTEST keyboard, a real AT-SPI
  client, and a real PCM monitor capture on the LIBAO NULL no-hardware backend. `bg355` and
  `bg357` exited 1 with no synthesis, the second after the owner-gate repair below. `bg367` ran
  after that repair **and** the reader-hook restructure and is the one that speaks: **0
  tracebacks, a 372-row reader trace, `spoken_utterances=9`, `synthesized=true`**, the evidence
  gate `ok`, and PCM genuinely read and clock-paced. Attribution in that run: **50 native
  utterances, every one lineage `owned`, on the real reader thread**; **35 carrying message
  ids**; **37 distinct `frag_seq`, each with its own ACSS**; **100 `reader_text` rows beside 100
  `ssip_argument` rows**; **waveform identity proved for 9** by exact-once PCM location, with
  **41 unproved and explicitly not credited**; wire paired **35/35, zero unpaired, zero
  disagreements**. **PASS:** `screen_reader_attached`, `published_roles`, the radio group
  relation and its check marks, the progress value equal to the model value, native actions
  reaching the model, a whole-value multilingual write through the real interface, every
  keyboard path, both settings landing, the terminal owned and registered, and the operator's
  own accessibility setting untouched. **FAIL, recorded as unclaimed rather than pending:**
  progress announced with real audio; progress name through navigation; reader navigation
  leaving the application untouched, with **0 chords delivered** in that run; and six roles
  spoken with real audio at **4/6**, the button role mismatched and progress unannounced.
- **Reader attached and roles published is not reader announced.** The nine utterances above are
  observed with real audio and are claimed; everything beyond them is not — not the 41 unproved
  waveforms, not progress, not the two missing roles.
- **Native full acceptance stays 18/22 and is not granted.** The four remaining native items —
  progress name/state binding and progress identity credit — plus two reader dispatch/retirement
  branches, five provenance partials needing native faults or a fragment extension, and five
  Windows/macOS menu items needing a non-Linux runtime, are **blocked with named prerequisites**.
  They are not pending and not reachable.
- **Two real product defects were found by these runs and fixed, each with before/after proof.**
  `correlateSpeech()` read its evidence-owner gate from the 4th positional argument while the
  finalised owner list was passed *inside* the reader-identity object in the 3rd, so the gate
  always received `null`, saw all three required owners missing, and refused to read any PCM or
  credit any utterance **even though finalisation had succeeded**. Fixed by passing the finalised
  list positionally; the re-run flips `evidence_owners.ok` from `false` to `true` with all three
  owners recorded `established=true missing=[]` and 6,646,888 bytes read at `clock_paced=true`.
  The closure-order proof had already shown that gate refusing correctly, so the repair fixes the
  real run's inability to ever *use* it. Separately, the reader dispatch hook **crashed on a
  `None` target**: its guard was gated on `_pending`, letting unbound frames dispatch `None` once
  binding had completed, and the error path itself dereferenced `None`, killing Orca 50.2 at
  startup before any presentation. It is restructured so a still-`None` target always returns,
  verified by zero tracebacks, the 372-row trace and 9 spoken utterances. Both reader proofs
  stayed green through every hook revision.
- **The reader proofs are green against the current helper.** Compatibility **111/111**, verdict
  `proven`, 0 failures; failure proof **226/226**, verdict `proven`, 0 failures. The helper is
  `nogui_reader_origin.py`, **SHA-256**
  `4ecc9fcf5dfa704c97cfb758b7dad16a8ac0dcf36118f7aa48491bb0953ea271`, measured by the parent with
  `sha256sum /tmp/nogui-w21-reader-origin/nogui_reader_origin.py` and reproducible with that exact
  command. Two earlier digests are prior states only: `b8d38931…` from the cleanup round and
  `1d0605a4…` from before it. Two limits on the failure proof stand: the source `MAX` bounds remain
  **unexercised**, with the real `RLIMIT` 32768 exercising only the common failure path, and the
  induced `direct_hook` bind `BaseException` is labelled not a natural nested monitor. Five bad
  witnesses were fixed in the harness and **not** by weakening helper behaviour.
- **Gates.** The full Python `unittest` suite passes **175 tests** with Ruff clean. Zig lint
  reports **0 errors and 0 warnings across 258 files**; Debug check is **89/89**; ReleaseSafe
  check is green in 133 s with **1959/1959** tests passed. The ReleaseSafe leg became green after
  a concrete fix rather than a lucky rerun: `w23_windows_smoke.zig` shadowed its top-level
  `refusal()` function with a local `refusal` bool, and renaming that local to
  `duplicate_refused` removed the only compile failure. Formatting is clean after touching one
  file. The fixture gate passes **5,524** with 0 failed and 0 unsupported, the layout golden
  matches **581 rows**, the build passes **25 of 25** steps, and the vendored noapi tests pass
  **3/3** steps with **66/66** tests. All six external dependency consumers pass — `core`, `text`,
  `renderer`, `host`, `test_support` and `offscreen`, the last with its CPU arm at 32 checks;
  that is consumer and packaging evidence, not native OS evidence.
- **The W21 headless and W19 portable scopes stand as they were.** The current W21 headless source
  passes **42/42** — typed positioned composition, live sequential selection, an 8192-byte storage
  refusal, ring whole-value 4096×2 plus overflow and the exact published state — core and headless
  evidence with no native adapter, bus or reader involved. The device-free private W19 kernel
  proof passes **28 of 28** with 0 skips, descriptors balanced at 16 → 16 and every private owned
  child gone, and it **earns no native credit**; `NOGUI_W19_CONTROLLER_MAIN=1` refuses with exit 2
  before any import. The cached-GI off-bus check proved **6 of 8** claim slots and stops there,
  overall `not_established`: real `Object.app` assignments raise `RuntimeError`, no populated app
  chain exists, and nothing corroborates an identity or memory offset. The AT-SPI type-library
  version reads as **2.0** through the library's own `get_version`, with no ctypes bypass.
- **W19 keeps two honest unknowns.** The canonical controller source is unchanged at `A71E` with
  every item already fixed in source, but the **native 11 fields and 2 kernel branches remain
  unknown** — source-fixed is not observed — and no UI approval was used. **GCR 3 preparation is
  done and is preparation only:** the inert unlock-plan run is source-ready against real
  providers, the gcr3 41.2 prompter wrapper and two `Exec` service cross-checks, on a private
  `:90` X11 display with a fresh root, but **no child service, GUI, keyring or prompt was
  started, nothing was observed, and no native approval was used**. `Unlock` itself stays blocked
  on fresh consent, so the earlier locked-store statement in this guide still holds.
- **The lifecycle closure proof is green:** exit 0, no missing claims, `unexpected_programs`
  empty, no re-signal, zero live owned groups and every owned pid gone. Earlier failed lifecycle
  attempts are prior states, not results.
- **Metadata C is green:** 9 cases, **115 PASS / 0 FAILED / 1 UNEXERCISED**, the single
  unexercised case being the named mid-call symlink swap needing an in-window adversary. Both
  independent birth references agree exactly and exactly one field is plausible; the `EMFILE` is
  real and kernel-level. The metadata fragment is 7,246 bytes. Root
  `/tmp/nogui-native-metadata-kernel-final-failed-92c0d0c5-1d4c-4f1e-9b6a-63e3f4d3e0ba` — *the
  directory name predates the repair round; the run it holds is the green one.*
- **The reader helper is proved against a real kernel peer.** A `SO_PEERCRED` socketpair reports
  PID 2469773, UID 1000 and GID 100, each matching that process's own `getpid`, `getuid` and
  `getgid`; the socket is unconnected and closed with no peer, and descriptors are balanced at
  8 → 8. A peer-credential mechanism result, not a presentation or audio result.
- **The first-phase native `Action` describe and `TextSelection` steps remain source-complete and
  native-unexercised.** The native unknown and refusal branches have never run: the retained real
  act answered everything and recorded no query refusal. Both stay **blocked** on a fresh
  approved private AT-SPI fault provider or query refusal — not on a refused mock echo, not on a
  source assertion, and not on rerunning the unchanged boundary proof.
- **Cocoa and Windows are source-typed, with no native claim.** Six real `C struct`
  `@property(copy)` errors were reproduced against the real `nogui_macos.h` and corrected at
  source, and the portable GNUstep ARC syntax passes. **Full AppKit SDK, the shim and native
  Cocoa remain unexercised.** Windows source is type-checked, cross-compilation reached link and
  the native ReleaseSafe gate is green; an actual Windows or Cocoa menu run still needs that
  runtime.
- **The tracker is closed:** 838 items, 751 done and 87 explicitly blocked with a named
  prerequisite, zero open.

A fresh canonical serial gate on the same day reached every leg, including this
program's linked headless arm at exit 0 with 38 passed and 0 failed — among them
`publish.an_abandoned_stage_changes_nothing` and the borrowed-text cancel
whole-value case — with the native adapter inactive and the screen reader false.
It printed no aggregate Zig test count, so none is restated here, and the
default mobile probe reported its platform unavailable rather than naming a
device. That gate is source and tooling evidence and is not native acceptance.
Root isolation and the viewer component both settled green after their
preserved reds, with the bounded scope of each recorded in the plan and the
README. Neither is a native acceptance result, and nothing above is closed by
that gate.

**Repository-wide gate re-verification (2026-10-05).** Every house gate leg was re-run
on the landed tree and recorded rather than restated. `zig fmt --check src build.zig
build.zig.zon` exits 0, and the same check over the 22 first-party example sources and
over `src/v7_host/credentials.zig` exits 0; a bare walk of `examples/` additionally lists
11 files, all of them generated `zig-pkg` dependency copies that the gate does not cover.
`zig build test` exits 0 at `63/63 steps succeeded; 1966/1966 tests passed`, `zig build
check` exits 0, `zig build layout-check` exits 0 matching all 581 golden rows, and `zig
build test check -Doptimize=ReleaseSafe` exits 0 at `106/106 steps succeeded; 1966/1966
tests passed`. `zig build fixture` exits 0 with `{"passed":5524,"failed":0,
"unsupported":0}` over 5/5 steps, `zig build --build-file vendor/noapi/build.zig test
-Denable-tracy=false` exits 0 at 3/3 steps and 66/66 tests, and `python3 -m unittest
discover -s tools -p 'test_*.py'` exits 0 with 175 tests OK. That 175 splits as 116 in
`test_run_v7_perf.py`, 10 in `test_import_taffy_v013_fixtures.py` and 49 in
`test_speech_module_observer.py`.

`zig build lint` was the one red leg on the first pass and is green now. `zlint -S
--deny-warnings` reported one `unsafe-undefined` warning at
`src/v7_demo/w23_windows_smoke.zig:4580`, where `var second: windows.Menus.Subclass =
undefined;` carried no `SAFETY:` line. The parent added that comment and the step exits 0
with 0 errors and 0 warnings across 258 files; `ziglint` over the same six source trees
reported 0 errors and 0 warnings throughout. The repair is a comment and changes no
behaviour. The `0 errors and 0 warnings across 258 files` bullet above is therefore no
longer contradicted, and its dated 1959/1959 ReleaseSafe figure stays as that run's own
result.

One reporting artifact is recorded rather than hidden. Five `failed command:
.../test --listen=-` lines appear on stderr in each `zig build test` invocation — five in
Debug and five in ReleaseSafe — each preceded by a `+- run test w` tree and carrying no
test count. Neither build fails on them: both exit 0 and report every step and every test
as passed. One of those binaries, run outside the build system without `--listen=-`,
printed `All 1118 tests passed` and exited 0, so the lines are a runner reporting artifact
and not a failing suite.

The W20 private capture fixture's 25 of 25 provider-free checks are reported by that slice
and were not re-run here. The full `fixture --execute` flow stays approval-gated, and no
native acceptance is claimed by this paragraph.

The 11:16 run of the same day, kept as dated history, is at
`/tmp/nogui-w21-approved-2026-10-04T11-16-02-453Z/evidence/result.json`: it had
no main-client failures and established 17/21 fixture criteria. A real GI
`Atspi.Value.set_current_value` write moved the slider 25→60 with exactly one
model number write. A real in-range Progress write to 75 was acknowledged by
IPC but left both native and model values at 60 and added zero writes across
15 seconds of readback. That is an observed mutation refusal, not an inference
from an absent `READ_ONLY` state. Single selection returned the requested logical
row once despite viewport recentering. The modal hid Add and published disabled
Remove without Enabled/Sensitive, actions or model mutation. Its five client
failures are the ones its own run recorded: four unreadable Action-absence checks
and an incorrect two-click expectation. Native audio acceptance also stayed open
there: independent raw/index agreement failed on multiline index marks, and a
genuine stock-reader completion marker reached the buffered file too late for
the live wait. The eight main-client failures further below describe neither run
above; they remain historical evidence, not current limitations.

The earlier approved private renewal, retained as a dated baseline below, at
`/tmp/nogui-w21-approved-2026-10-04T04-54-32-795Z/evidence/result.json`
used real Orca, speech-dispatcher, PulseAudio, AT-SPI and an owned `:90` display.
The native smoke exited 0; the client and complete fixture exited 1. All 32 owned
pids are gone, with no own survivor, and the normal accessibility setting was
`false` before and after. No normal accessibility setting was changed.

Dated core and source results from that period are *not* evidence of speech,
and this guide does not read them as such: the headless W21 smoke at 32/32
checks on 2026-10-03, the core `api-w21` filter at 41/41 tests across 13/13
build steps, and the three-generation public App/Publisher progress/radio
consumer. All three are core and source-level results. The progress/radio
consumer is what makes `lastNumericValue` worth documenting above — it reads
the published numeric value back out of the adapter's own buffers — but
reading the adapter's own buffer is the near side of the bridge.
It says what AccessKit received; it says nothing about whether a platform
announced it, and nothing at all about speech.

The real `EditableText.SetTextContents` route held all three required writes:
the complete 35-byte/21-character Unicode value, empty text, and the original
11-byte/7-character value. The platform's `Text` interface read each complete
value back with caret 21, 0 and 7 respectively, zero selections and exactly one
model text write per setter. Frame-owned values and tables removed the native
SDK panic; present-empty serialization preserved the empty text run. This is
whole-value proof, not native IME composition. **This does not meet the
composition criterion.** Positioned native `EditableText` composition through
the published semantic model is what the audit still requires, and neither
whole-value `SetTextContents` nor an SDL-side IME run closes it, however broadly
the W21 Gate is worded. **The wire facts are now derived from the pinned source,
not guessed.** `org.a11y.atspi.EditableText` has six members — `SetTextContents`,
`InsertText`, `CopyText`, `CutText`, `DeleteText` and `PasteText` — and the two
names an earlier revision recorded, `insertTextAtPosition` and
`deleteTextBySelection`, exist on no wire, in no specification and nowhere in this
repository; that seven-name enumeration was wrong and is withdrawn. The pinned
adapter wires only `SetTextContents`; the other five answer
`org.freedesktop.DBus.Error.NotSupported`, so the refusal is a loud D-Bus error
rather than a silent `false`. Inside one call the wire mixes units:
`InsertText.position` is a character offset while `InsertText.length` is a **byte
upper bound** on how much of `text` to insert, not a character count and not a
delete count. No `EditableText` member carries a spec-mandated caret result — that
is verified silence in the specification, not an omission here. The obstacle is in
the pinned dependencies rather than in this repository: no AccessKit `ActionData`
variant pairs a text offset with text bytes, one request carries exactly one such
variant, and `accesskit_unix` is checksum-locked and not vendored. **None of this
downgrades the criterion.** Positioned composition stays owed; the source work
comes first and a fresh native approval follows it.

Native keyboard button activation held for both Space and Return, and slider
keys, radio movement, printable text and caret movement all reached the model
through the real key path. Real synthesis and clock-paced capture are proved
independently: `parec` recorded 8,079,086 bytes over 183,199 ms of
`s16le 22050 Hz mono` from the private null sink's monitor, 1,741 observed
intervals of which 1,740 grew, median 44,039 bytes/s against a declared 44,100,
so `clock_paced` is true and the daemon's own "server audio is not supported"
error is attributable to no module at all rather than to the configured one.
That is a real sink, not a log line.

Name-plus-state audio nevertheless remains **0/6**. The six required roles are
button, check, progress, radio B, slider and text; each one was really reached
and focused where focusable, and each utterance's own capture window never
advanced across it, so no line owns audio and no role is credited. The client's
own view of speech is the utterance list, which is not audio, and that
distinction is kept rather than collapsed.

The stock reader's object navigator is the one route that reaches the read-only
indicator, and it worked as designed. The indicator is published
`read_only=true`, `focusable=false`, `actions=0x0`, so the FOCUS route and the
keyboard cannot reach it. From `W21 Slider` at sibling 7 under `[<window>]`, one
`Orca+Control+Left` stock "previous sibling" command reaches `W21 Progress` at
sibling 6; the reader's own log then runs `_generate_progress_bar` with
`formatType: unfocused` and produces `_generate_accessible_name: [W21 Progress]`,
`_generate_progress_bar_value: [30 percent.]` and the final
`Results: [W21 Progress, 30 percent.]`. No model key moved across that chord, so
the reader's extra modifier never reached the application as a mutation. The
client still records this clause as unestablished, because the required item
demands real owned audio for that control and the attribution window is still
zero-width; the spoken form is recorded here as an observation, not as closure.

Eight non-text client steps failed, and each has a named cause rather than a
category label:

- `slider:set-value` — the client's own `Value` setter call never reached the
  model.
- `progress:is-read-only-and-cannot-be-driven` — a bogus gate. The indicator
  really is read-only and non-focusable, and the run never attempted a mutation,
  so this failure does not describe a product defect.
- `list:the-selection-interface-reads-back-what-was-asked` — the comparison
  treated a `selected_count` of 1 and an `index` of 2 as though they were two
  child counts.
- `list-add:custom-action` — the `Add` named action was absent from the tree.
- `modal:disabled-control` and `modal:hidden-left-the-tree-and-disabled-stayed-in-it`
  — a real SDK bug: a disabled node still published `Enabled | Sensitive`, which
  also made the `Disabled` gate impossible to satisfy from the platform side.
- `list-add:works-again-after-the-dialog-closed` and
  `list-add:republished-and-drivable` — the absent reactivation named action.

The complete acceptance stays false; successful whole-value editing does not
erase these failures. Missing final client JSON does not prove that no action
ran. The private fixture keeps each required write's outcome `null` when its
report is unavailable; model counter changes remain separate evidence of
effects.

The nullable callback distinguishes whole-value and selection-only intent.
The current linked CLI smoke passed 38/38 checks, including active-preedit
whole writes followed by another composition and cancel. The earlier mobile
unfiltered model suite passed 4/4 and Windows passed 7/7; both portable smoke
targets compiled. Those results are model checks, not other-target runtime proof.

Mobile model proof covers empty clear, character-table edits, refused-frame
retention and a whole write from overlapping model storage, which previously
crashed in memcpy.
Windows' overlapping whole write likewise changed from a real memcpy abort to
exact `😀Ωtail`, six characters and UTF-16 caret 7, with one edit and no staging.
The active-preedit alias changed from corrupted bytes to exact preservation:
`漢字üße ✓€`, 18 bytes, eight characters and end caret 18, with no stale restore
after another composition/cancel. Only a marked overlapping payload is staged,
in the existing 96-byte stack bound; ordinary caller payloads are not copied.
Before the named-action cutover, the Rust bridge suite passed 22/22 and
unlinked `api-w21` passed 93/93. The changed-union focused results are recorded
above; six-role speech acceptance remains unestablished.


## Inspector, timings and bounded records

| Entry points | Source | Ownership or limit |
| --- | --- | --- |
| `inspection.captureFrame`, `FrameSnapshot.pick/pickNode/pickResult/resolve/findByFrameNodeId/findNode/children/writeJson`, `InspectHandle.isValidFor` | [`src/v7/inspection.zig`](../src/v7/inspection.zig) | A snapshot copies the frame it describes. A handle from an older frame resolves to `error.StaleHandle` instead of naming another control, and `NotFound`, `InvalidGeometry` and `CapacityExceeded` are separate answers. |
| `inspection.BoundedCollector(T).init/initBuffer/record/latest/copyChronological/writeJsonl`, `FrameRecord`, `TaskRecord`, `ActionRecord`, `CollectorSink(T, enabled)` | [`src/v7/inspection.zig`](../src/v7/inspection.zig) | Every collector has a fixed capacity and saturates instead of growing, so a saturated run is visible rather than silent. `CollectorSink(T, false)` compiles the recording away entirely. |
| `perf_counters.Counters.add/reset/snapshot`, `Snapshot.value/writeJson`, `CounterSink` | [`src/v7/perf_counters.zig`](../src/v7/perf_counters.zig) | `CounterSink` is `Sink(v7_options.perf_counters)`, so a build without `-Dv7-perf-counters` compiles `add` to nothing. A snapshot that would overflow returns `error.CounterOverflow`. |
| `nogui_host.inspector.Inspector.init/setPickMode/setOverlayFrame/select/resolveSelection/taskObserver/attachActionRegistry`, `nogui_host.diagnostics.queryGpu` | [`src/v7_host/inspector.zig`](../src/v7_host/inspector.zig), [`src/v7_host/diagnostics.zig`](../src/v7_host/diagnostics.zig) | `deinit` detaches the action registry and frees both retained snapshots, the source map and the three bounded collectors. A captured snapshot keeps its own copies, so detaching the overlay frame never invalidates a retained one. `queryGpu` reports what the device actually answered. |

`zig build w24-inspector-smoke -- --gpu-timing --ppm PATH` drives the complete
headless inspection scenario and saves submitted pixels; `--native --gpu-timing
--hold-ms 0` presents it. The 2026-10-01 private X11 run covered overlay
pick/routing agreement, stale handles, resolved style/clip/semantic relationships
and focus/capture transitions. It presented 33 frames and attached all 31
completed GPU query results to their frame IDs. The headless arm attached all
32 results and its 520×520 sRGB image was inspected. Input in this smoke is
synthetic `App.handle` input, not compositor pointer ingress.

Read timestamps only after submission completes. Keep the device's timestamp
period and valid-bit mask with each query stream; a query ring slot is not a
frame ID. Collector saturation remains bounded and does not change the frame
whose result is attached. These observations are not a speed or FPS claim.
Release a native surface from `Application.Hooks.on_before_close`; keep the
borrowed App/view/inspector live through host closure, then retire the GPU.

## Deterministic test support

| Entry points | Source | Ownership or limit |
| --- | --- | --- |
| `nogui_test.Context.create/deinit/dispatch/dispatchJson/flushFrame/handleForKey/queryKey/query/focused/focusesKey/runUntilIdle/requireClean` | [`src/v7_test/context.zig`](../src/v7_test/context.zig) | Allocate the `Context` at a stable address: its task clock borrows the virtual clock until shutdown completes. `requireClean` returns `error.LiveModels` rather than dropping a model, and `runUntilIdle` drains only work eligible at the current virtual time. |
| `nogui_test.TextContext(Cpu).create/deinit` | [`src/v7_test/text_context.zig`](../src/v7_test/text_context.zig) | Pass `nogui_text` as `Cpu`. `Options.fonts` and `default_size` configure the production CPU text measurer; `base` exposes the ordinary deterministic `Context`. Fonts are copied by `TextService`. Release layout leases and caller-owned models before teardown. |
| `nogui_test.OffscreenContext(Frame, Render).create/render/deinit` | [`src/v7_test/offscreen_context.zig`](../src/v7_test/offscreen_context.zig) | Pass `v7_frame` and `v7_render` explicitly. Creation owns a real noapi device, fonts, renderer and fixed-size target, with no SDL window, surface or swapchain. `render` returns the committed `FrameOutput` and borrowed Oklab RGBA pixels; pixels expire on the next render or teardown. The caller owns any returned JSON. |
| `QueryHandle`, `NodeSnapshot`, `RunReport`, `VirtualClock.advanceTo/advanceBy/advanceToMs` | [`src/v7_test/context.zig`](../src/v7_test/context.zig), [`src/v7_test/clock.zig`](../src/v7_test/clock.zig) | A query handle is valid for the last committed frame only: a different window or generation is `error.StaleFrame`, a missing frame is `error.NoFrame`, a vanished widget is `error.StaleWidget`. `NodeSnapshot.label` borrows the frame arena, and the clock refuses to move time backward. |
| `headless.treeToJson/treeToJsonWith`, `FrameOutput`, `parseEvent`, `ParsedEvent.deinit`, `renderAscii`, `layoutFingerprint`, `verifyLayout` | [`src/v7/headless.zig`](../src/v7/headless.zig) | The JSON tree, the ASCII tree and the layout fingerprint all describe the same committed frame. `parseEvent` owns its allocation until `ParsedEvent.deinit`. |

`nogui_test` imports only the core module, so a deterministic run needs no window, GPU or sleep. The runnable packages built on it are listed in the README under [External consumers](../README.md#external-consumers).

### The packaged consumers were also run cold

Those six consumer packages were not only built in this checkout. On 2026-10-03
the repository was fetched as a package and extracted into a private root, and
every consumer was built and run from that extraction with its own empty local and
global caches and with `DISPLAY`, `WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS` and
`ZIG_GLOBAL_CACHE_DIR` cleared. All six passed: `core_only: OK`, `text_only: OK`
with `FontUnavailable` and `UnknownFont` still distinct, `renderer: OK
rects=3 materials=2`, `test_support: OK` plus its own `zig build test`, `host: OK
session_window=1 idle_frames=1 worker_frames=2 wakes=1` under the dummy video
driver, and both `offscreen` arms — 32 CPU checks refusing `FontUnavailable` with
no GPU, then 1,016 windowless GPU checks writing a real 640×640 image on the GTX
1660 Ti. The extracted archive also carries README, both MIT grants and all four
bundled-font notices, with no undeclared and no missing declared path. Those four
notice files were separately compared byte for byte against their upstream sources
without normalizing whitespace, and all four matched exactly; evidence:
`/tmp/nogui-font-notice-byte-proof-20261003.json`.

The canonical package name and archive size identify **that** clean-cache proof.
They are historical evidence of the archive as extracted on 2026-10-03, not a
digest of the current tree, and the 2026-10-03 documentation reconciliation
changed no declared package content that would restate them.

What the fetch did not measure is the checkout itself. That run recorded
`repo_untouched: true`, and a read-only re-derivation on 2026-10-04 shows what
that check covered: the generated `src/v7_host/accesskit_bridge/target` tree is
absent from the package and present in the checkout, and the one exact checkout
path `zig-pkg/<that package hash>` is absent. The checkout also carries a
`.tmp-6d5594940322ddbf` directory, so the record does not establish that nothing
in the checkout changed. The same re-derivation measured 1,874 files and
37,799,789 bytes in the filtered fetch package, equal to the extraction recorded
before any consumer built; the extraction directory now holds 24,561 entries
because the six consumers built in it, and that is post-build output, not the
archive's contents. Evidence: `/tmp/nogui-w26-provenance-proof.json`.

One detail belongs to that record: the harness that drove those runs stopped on an
incidental wording mismatch in one expectation (`refused=error.FontUnavailable`
against a correctly printed `refused=FontUnavailable`, with the consumer itself
exiting 0 and all 32 of its checks passing). That incidental wording gate was
removed rather than repinned, and a continuation kept every successful cold-cache
command and ran only the remaining GPU arm. The `offscreen` cold-cache guard was
established by the original controller before its own first CPU command, not by the
continuation; no consumer was re-run to present a single clean invocation, and none
was skipped. The requirement is that the consumers be packaged and run clean, which
the six cold-source results are; one uninterrupted controller invocation is not, so
no rerun is pending. The exact commands, per-consumer exit codes and the
continuation's own record are in the
[companion plan](superpowers/plans/2026-09-26-gpui-api-parity.md#w26--distribution-and-full-acceptance).

The optional contexts do not add font or GPU dependencies to core-only imports.
`zig build run-parity-test-context` measures keyed `iii` and `WWW` labels through
both contexts and checks matching widths on a real windowless GPU frame. The
current NVIDIA run measured 10.172 and 42.078 logical units and verified a
changed background from Oklab L 0.35 to 0.55.

`Context.deinit` checks pending tasks before closing its App. If a retained
caller model then causes `LiveModels`, the App is closed but the Session and
optional font/device owners remain alive for release and retry. Further
offscreen rendering returns `ContextClosed`; a refused teardown is not a
resumable App.

Presented consumers must release caller-held `TextLayout` leases before
`NativeFrame.deinit` retires its text cache. Detach the App first and release
the native surface before closing its platform window. The editable-field
example uses `Application.Hooks.on_before_close` for that order, including
platform-initiated close, and keeps the borrowed App/model alive through host
closure. Its partial-construction cleanup has one owner.

### Semantic names and visible captions

A button carries two names, and the headless outputs split them deliberately. `treeToJson` publishes the semantic name: the button `label` stays in JSON, with `accessible_label` added when the caller supplied one. `renderAscii` paints the visible caption instead, and that caption has exactly one owner. `DrawCtx.button` emits a visible caption as a GENERATED LABEL CHILD, so the map draws it once at that child's own laid-out position, and the parent button node draws nothing itself in that case. A button with no generated child, which is what an empty `visual_label` or an icon-only control leaves behind, falls back to painting `widget.buttonVisualLabel` ([`src/v7/widget.zig`](../src/v7/widget.zig)) at the button's own rect, so an explicitly empty `visual_label` still draws no caption and a button with an icon and no override defaults to no text. A `visual_label` wins over `label` in both paths. Layout measures that same caption ([`src/v7/layout/context.zig`](../src/v7/layout/context.zig)), and `verifyLayout` checks text fit through `visualText`, where a button answers `null` because `DrawCtx` emits its visible text as a generated label child. The map's exact cell columns, glyph spacing and parent/child ordering are an artifact of how the map rasterizes text at 2 px per cell; the contract is one caption at the child's own layout position, not a particular offset.

That split keeps a localized or icon-only control honest in a headless review: the semantic name stays queryable in JSON while the ASCII map shows only what a person would see. The regression evidence is the registered `renderAscii` tests in [`src/v7/headless.zig`](../src/v7/headless.zig), including `renderAscii: visible button caption never exposes its semantic label` and `renderAscii: a button caption paints once, never its semantic name`, the latter driving the real `Session`, `App` and `DrawCtx` path and asserting that the map's entire alphabetic glyph sequence is the visible override exactly once while both semantic names stay in the frame JSON. This note adds no new executable gate and claims no target SDK, compositor or assistive-technology proof; a headless ASCII map is not a rendered window.

A slider caption is verified in rendered pixels, not only in a headless map. [`src/v7_frame/scene.zig`](../src/v7_frame/scene.zig) paints slider progress and thumbs before glyphs so a thumb never covers the visible label, and it selects the same bytes through `widget.sliderVisualLabel`. The external windowless consumer [`examples/consumers/offscreen`](../examples/consumers/offscreen/main.zig) exercises that path through the public API on a real GPU, and its 2026-10-01 run exited 0 with 930 checks and three visibly different captions: an unauthored one, one truncated to its declared 118 px cap, and an uncapped twin. The consumer keeps only the scene's glyph quads that land on one of its own pen origins, so no test-only layout export was added. The README records the run under [External consumers](../README.md#external-consumers) and the [GPUI API parity roadmap](superpowers/plans/2026-09-26-gpui-api-parity.md) holds the full counts. This is a windowless read-back frame rather than a physical window or a sound check.