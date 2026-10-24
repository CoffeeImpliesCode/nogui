# nogui API guide

The [README](../README.md) lists products and build commands.
[`src/v7/root.zig`](../src/v7/root.zig) defines the core exports.
The [standalone consumers](../examples/consumers/README.md) show complete dependency builds.

## Sessions, models, and roots

[`Session`](../src/v7/session.zig) owns persistent typed values independently of frame arenas and individual windows.
It is UI-thread-only. Deliver worker results through the task service before accessing models.
Read, update, and listener callbacks borrow pointers only until callback return.
Transaction guards do not synchronize threads.

Create the Session before its Apps. Destroy each App before the Session.
`App.init(allocator, &session)` registers a window identity.
`mountRoot(T, &view)` borrows a view. Keep it alive through App shutdown and readable prior-frame snapshots.
`replaceRoot` replaces the mounted view.

`session.create(T, &value)` moves a value into a model.
`app.mountModelRoot(ModelType, ViewType, model, &view)` retains a separate strong ticket.
Retain and release tickets explicitly. Copying handle bits does not acquire ownership.
`WeakModel(T)` upgrades only while a strong owner remains. Use weak edges to avoid cycles.
`reserve` and `insert` support construction without exposing uninitialized values.

`Session.read` and `Session.update` expose guarded callback-scoped pointers.
Conflicting borrows fail. A callback error does not undo completed model writes.
`ctx.state` shallow-copies local state between frame arenas and does not own resources.
Its value resets after the component leaves a committed frame.

`Session.deinit` rejects live Apps, models, reservations, or borrows.
It first attempts task shutdown with a 100 ms bound.
`UnfinishedWork` leaves the Session, executor, and buffers alive for a later retry.

## Frame publication and identity

[`App`](../src/v7/app.zig) builds each `WidgetTree` in one of two frame arenas.
Draw, layout, GPU hooks, JSON, mounts, focus, and semantics publish as one frame transaction.
Failure keeps the last committed output and re-arms consumed redraw demand.

| Value | Lifetime |
| --- | --- |
| `FrameOutput.tree` | Survives the next frame attempt. After a newer commit, another attempt can reset its arena. |
| `FrameOutput.prev_tree` | Expires at the next frame attempt, including a failed attempt. |
| Model callback pointer | Expires when the callback returns. |
| Widget `value` pointer | Caller must retain its target through both readable trees. |
| `GpuFrame` | Valid only during the component lifecycle call. |

Tree storage is postorder. Each container follows its descendants.
`FrameNodeId` is a dense frame index. `WidgetId` carries owner, slot, and generation.
`App.widgetIdForKey(scope, key)` finds a committed control.
`WidgetTree.frameNode(id)` resolves a stable handle in that frame.
Removed handles cannot dispatch to replacement controls.

Components and interactive controls use explicit parent-scoped keys.
Duplicate sibling keys fail the frame. Labels and captions do not define identity.
`WidgetNode.rect` is a border box relative to its parent's content box.
Use `widget.absoluteRect` for absolute coordinates.
Layout, input, scrolling, and caret geometry use logical window units.
`geometry.PixelScale` describes the logical-to-device boundary.

`App.swapRoot` flushes shortcut replay before retiring root GPU resources.
A refused flush leaves the published root live for retry.
GPU resource retirement also requires command cancellation or submitted-work completion.
Frame-arena lifetime alone does not protect GPU work.

## Notifications, globals, and tasks

`Context.read` and `Context.global` record successful reads as window dependencies.
A successful frame replaces that window's read set. Failure retains the previous set.
`Session.update`, `updateGlobal`, and root replacement invalidate dependent windows.
`takeRedraw(window)` consumes coalesced redraw demand.

`observe`, `observeRelease`, `subscribe`, and `observeGlobal` return cancellation tokens tied to weak model owners.
`emit`, `deferOwned`, `deferRetained`, and `putGlobal` move payloads on success.
Owned members can provide `deinit(*T, *Session)`.
Effects drain FIFO after the outermost update, active borrows, and frame publication.
`deferRetained` holds its own strong ticket until delivery or drop.
Do not mutate a Session from draw, measure, prepaint, or paint callbacks.

| API | Source | Rule |
| --- | --- | --- |
| `task.Service.scheduleUi/spawnWorker/wait/cancel/detach/drain/shutdown` | [task.zig](../src/v7/task.zig) | Workers own immutable inputs. They must not retain frame pointers or mutate models directly. |
| `task.Service.setWake/nextDeadline/pending/snapshot` | [task.zig](../src/v7/task.zig) | Unregister the host wake callback before task shutdown. |
| `frame_demand.FrameDemand.take/finish/pending/waitMilliseconds` | [frame_demand.zig](../src/v7/frame_demand.zig) | `finish(false)` re-arms consumed demand. Hidden windows report no pending work. |
| `animation.Registry.start/interrupt/transition/sample/demand/framePresented` | [animation.zig](../src/v7/animation.zig) | Channels use a widget owner and lane. Prune removed owners. |
| `App.startAnimation/animationDemand/framePresented/setReducedMotion` | [app.zig](../src/v7/app.zig) | Reduced motion ends decorative loops and requests the final frame. |

## Widgets, custom elements, and input

`DrawCtx` provides containers, labels, buttons, sliders, checkboxes, switches, radios, progress indicators, and separators.
Bound controls borrow caller-owned state through both readable frame trees.
Radios share a `*?u32` selection and distinct option values.
Progress indicators take a read-only value snapshot.
Pointer release activates a valid press once. Pointer-down alone does not activate.
Focused Enter/Space uses the same activation route.

`elementLeaf(T, value, options)` and `elementContainer` store payloads in the frame arena.
Optional `T.PhaseState` uses the same lifetime. Borrowed resources must survive both trees.
`measure(*const T, element.MeasureInput)` must be pure.
Optional layout, prepaint, paint, and semantics hooks run before publication.
Paint hooks emit bounded records through `element.PaintWriter`.
A `.late_scope` container can append a bounded query or list subroot after initial layout.
It cannot resize an already laid-out ancestor.

`.visibility = .hidden` retains geometry but suppresses paint, input, focus, and semantics.
`.display = .none` also excludes layout geometry.

| API | Source | Rule |
| --- | --- | --- |
| `action.Registry.register/bind/listen/inspect/dispatch/unbind/unlisten` | [action.zig](../src/v7/action.zig) | Bindings and listeners live until removal. Dispatch returns handled, disabled, or unavailable. |
| `keymap.Keymap.add/keyDown/keyUp/textInput/focusChanged/tick/nextDeadline` | [keymap.zig](../src/v7/keymap.zig) | Inject a clock. Limits are 8 chord steps, 32 pending events, and 256 input bytes. |
| `key_context.Path.init/next` | [key_context.zig](../src/v7/key_context.zig) | Borrows one committed tree and walks outward from focus. |
| `App.attachShortcuts/detachShortcuts/tickShortcuts` | [app.zig](../src/v7/app.zig) | Keymap and action registry must outlive attachment. Detach before App teardown. |
| `input.hitTest/hitActionable/hitStable` | [input.zig](../src/v7/input.zig) | Only `hitStable` returns a stable `WidgetId`. |
| `focus.Manager`, `App.focusObserver` | [focus.zig](../src/v7/focus.zig) | Use the App observer to route focus changes and reconcile text endpoints. |

## Text and editing

[`text.TextStyleOverride`](../src/v7/text.zig) resolves fields individually.
Component `default_text`, inherited container fields, and explicit widget fields form the text style.
An authored font family without a handle clears the inherited handle.
A weaker default cannot restore it.
`publishNodeText` stores the resolved request for the renderer.

[`TextService`](../src/v7_text/root.zig) provides font registration, metrics, layout, and node layout.
`TextLayout` owns its allocation and pins shaped runs. Release layouts before the service.
`TextMeasurer` owns a service and retained scratch arena. `NodeMeasurer` borrows them.
Keep their addresses fixed while a `layout.MeasureSource` uses them.

[`shaping.Cache`](../src/v7_text/shape_cache.zig) retains at most 256 runs and 4 MiB of payload.
Keep cache storage and immutable font resources alive while leases exist.
Release each lease. Oversized or fully pinned admissions use transient owned runs.
Cache hits allocate and shape nothing.

| Layer | Offset unit |
| --- | --- |
| Core text and semantic snapshots | UTF-8 byte offsets at valid boundaries |
| `text_input.Utf16Range`, selection, and marked text | UTF-16 code units |
| Endpoint motion and erase | Grapheme, word, line, or document |
| AccessKit/AT-SPI | Character indices converted through `character_lengths` |

[`text_input.Manager`](../src/v7/text_input.zig) registers endpoints and routes editing, clipboard, and composition operations.
Its `Call.borrow` keeps the focused endpoint alive. Released endpoints return `EndpointReleased`.
Read-only cut and paste refuse before clipboard lookup.
Normalization folds CRLF into one break. A normalized empty paste does not erase selection.

`Native.set_area` is fallible. `Manager.caretGeometry` caches geometry only after successful publication.
`Window.setTextInputArea` rejects non-finite areas and offsets before SDL calls.
`Window.candidate_publication` records the accepted logical rectangle, offset, and generation.
Display content scale and device pixel scale can differ. Do not multiply candidate coordinates by display scale.

### Semantic names and visible captions

`treeToJson` exposes semantic names and optional `accessible_label` values.
`renderAscii` paints visible captions.
A button's generated label child owns its visible caption.
Without that child, the button uses `widget.buttonVisualLabel`.
An empty `visual_label` hides the caption without discarding the semantic name.

Slider captions use the same resolved text path and `widget.sliderVisualLabel`.
`text_overflow` and `max_width` affect layout and scene text.
The slider's default white foreground yields to inherited or authored foregrounds.
The scene paints slider chrome before caption glyphs.

## Paint and frame rendering

| API | Source | Ownership and limits |
| --- | --- | --- |
| `paint.PaintList.addRect/addPath/addImage/deinit` | [paint.zig](../src/v7/paint.zig) | Owns records through the supplied allocator. A record ceiling returns `PaintCapacity`. |
| `path.Builder`, `path.tessellate`, `path.contains` | [path.zig](../src/v7/path.zig) | Deinitialize the command list. Tessellation writes caller scratch. Capacity and invalid-path errors remain distinct. |
| `v7_render.lowerPaint`, `Lowered` | [renderer.zig](../src/v7_render/renderer.zig) | CPU-only. Preflights scratch capacity. Returned prefixes borrow caller scratch until reuse. |
| `v7_render.Renderer.init/prepare/preparePaint/draw` | [renderer.zig](../src/v7_render/renderer.zig) | Needs a GPU and three SPIR-V modules. Limits include 64 clip rectangles and 1 MiB of paint data. |
| `SceneScratch.beginFrame/nextFrameSlot`, `buildFrameScene`, `recordFrameScene` | [scene.zig](../src/v7_frame/scene.zig) | Begin the scratch frame before lowering. `FramePaint` borrows records until `deinit`. |
| `TextEngine.emitLayout/emitNodeText/setPixelScale` | [text_gpu.zig](../src/v7_frame/text_gpu.zig) | Borrows the text service. Release layout leases before engine teardown. Material capacity is 4096. |
| `BindlessHeap.register/registerExternal/unregisterExternal/release` | [heap.zig](../src/v7_frame/heap.zig) | External textures release their own slots in `deinitGpu`. Freed indices can be reused. |
| `Offscreen.beginFrame/submitRead/resize/deinit`, `writePpm` | [offscreen.zig](../src/v7_frame/offscreen.zig) | No native window or surface. Readback pixels expire on submission, resize, or teardown. |
| `NativeFrame.beginFrame/buildScene/recordScene/present/cancelFrame/deinit` | [native.zig](../src/v7_frame/native.zig) | Out-of-date surfaces return `false` from `beginFrame`. Teardown drains submitted GPU work. |

Render intermediate colors in Oklab. The final blit and `writePpm` convert to sRGB.
Use `.transparent = true` for no background.
An alpha-zero `.fill` alone does not suppress a container or button's default surface.
Paint transforms do not change committed hit boxes.

Keep the injected Vulkan loader alive through `Offscreen.deinit`.
`beginFrame` borrows caller command/frame storage until submission or cancellation.
A failed `NativeFrame.present` closes recording, preserves the backend error, and leaves `GpuFrame.recording` failed.
Do not attempt a second cancellation of that terminal recording.
Release native surfaces in `Application.Hooks.on_before_close`, before SDL destroys the window.

## Assets, images, and external frames

| API | Source | Rule |
| --- | --- | --- |
| `AssetKey`, `AssetState`, `AssetError` | [asset_types.zig](../src/v7/asset_types.zig) | Keys include source, path, scale, and generation. Stale generations return an error. |
| `ImageSequence.frameAt/nextDeadlineNs`, `FrameRequests.publish/demand/retire` | [image_types.zig](../src/v7/image_types.zig) | Requests borrow sequence storage. Retire the widget request before freeing storage. |
| `FrameDescriptor.release` | [image_types.zig](../src/v7/image_types.zig) | Release external planes once, before slot reuse. |
| `ImageView.requestFrameAt/measure/paint` | [image_view.zig](../src/v7/image_view.zig) | Borrows a host texture slot pinned for every in-flight frame. |
| Host assets, image, SVG, and frame sources | [host root](../src/v7_host/root.zig) | Loaders produce core asset records. Missing SVG libraries report unavailable support. |
| `SvgRasterCache.put/pin/unpin` | [svg.zig](../src/v7_host/svg.zig) | Successful insertion moves the image. Refusal retains caller ownership. Pinned entries cannot be replaced. |

## Lists, scroll, and overlays

| API | Source | Rule |
| --- | --- | --- |
| `list.State`, `uniform_list.State` | [list.zig](../src/v7/list.zig), [uniform_list.zig](../src/v7/uniform_list.zig) | Variable lists retain measured heights through an allocator. Uniform lists need none. |
| `virtual_list.uniformList/variableList` | [virtual_list.zig](../src/v7/virtual_list.zig) | Build rows through bounded late subroots. |
| `container_query.query` | [container_query.zig](../src/v7/container_query.zig) | Selects a subroot from the container's resolved width. |
| `App.scrollHandle/scrollSnapshot/scrollTo/scrollBy/revealRect` | [scroll.zig](../src/v7/scroll.zig) | Resolve handles against the committed tree. Missing owners do not redirect scrolling. |
| `overlay.Frame.stage/commit`, `overlay.ModalFocus`, `DrawCtx.attachOverlay/place` | [overlay.zig](../src/v7/overlay.zig) | Failed frames preserve committed placement and routing. |
| `drag_drop.Manager`, `PayloadView.get(T)` | [drag_drop.zig](../src/v7/drag_drop.zig) | Cancel per pointer. Checked downcasts return null for a different type. |
| `tooltip.Manager`, `tooltip.Deadline` | [tooltip.zig](../src/v7/tooltip.zig) | Inject the host clock. Stale expiry tokens cannot close newer tooltips. |

## Host windows and native services

[`Application`](../src/v7_host/application.zig) owns SDL lifetime and registered windows.
Keep it alive until every window closes. The caller drives polling, timing, and rendering.
`step` handles one nonblocking batch. `nextWaitMilliseconds` supplies the external loop's idle bound.
`openWindow` publishes a window only after complete initialization.
Close and quit vetoes retain resources. Expired quit vetoes do not remain pending.

`Window.clientExtent` reads logical and device sizes for one routed event.
`ManagedWindow.refreshAt` publishes that reading, and `Window.translate` uses it.
Old native events and stale window handles cannot address reused windows.
Destroy host windows and call `Application.deinit` before `Session.shutdownTasks`.

| Service | Source | Rule |
| --- | --- | --- |
| Clipboard | [clipboard.zig](../src/v7_host/clipboard.zig) | Owns offered data until teardown. PRIMARY selection requires an X11 or Wayland driver. |
| File/message dialogs and path reveal | [dialogs.zig](../src/v7_host/dialogs.zig) | Require caller approval. Keep callback contexts alive through parent closure. Drain workers before SDL teardown. |
| External URLs and schemes | [open_url.zig](../src/v7_host/open_url.zig) | Require approval. Invalid URLs, unregistered schemes, and unsupported hosts are distinct results. |
| Menus | [menus.zig](../src/v7_host/menus.zig) | Enablement, check state, and dispatch use the same action registry. Native menu capabilities vary by platform. |
| Desktop preferences and paths | [preferences.zig](../src/v7_host/preferences.zig) | Unobserved signals return null. Allocated paths belong to the caller. SDL base paths remain borrowed. |
| Notifications | [notifications.zig](../src/v7_host/notifications.zig) | Reserve tracking before provider submission. Providers deliver callbacks later through polling. |
| Credentials | [credentials.zig](../src/v7_host/credentials.zig) | Values wipe their storage on teardown and format as redacted text. Locked, denied, canceled, and provider-failed results remain distinct. |
| Screen capture | [capture.zig](../src/v7_host/capture.zig) | The Session borrows its backend. `deinit` refuses while frames remain borrowed. Portal permission requires interactive approval. |
| Popups and layer surfaces | [Linux host](../src/v7_host/linux) | Native grabs require a current seat serial. Protocol availability depends on the compositor. |
| Platform adapters | [macOS](../src/v7_host/macos), [Windows](../src/v7_host/windows), [mobile](../src/v7_host/mobile) | Target applicability differs from runtime capability. Off-target calls return typed unavailable errors. |

Clipboard mutation, dialogs, external launch, notifications, credential access, and capture can affect the user's desktop or data.
Obtain approval for the requested action and scope. A capability query does not grant approval.
Drain credential work before releasing the provider. Keep provider failure distinct from a missing credential.

### Linux D-Bus transport

[`Connection.call`](../src/v7_host/linux/dbus.zig) matches replies by outgoing serial.
Unrelated signals and replies remain buffered in arrival order.
Release owned frames with the connection allocator, including after disconnect.
`callWithFd` borrows the descriptor and attaches it once, even during partial sends.
UNIX_FD negotiation must succeed before descriptor transfer.
Outgoing credential buffers and owned replies are wiped before release.

## Accessibility

Configure `App.semantic_publication` with a stable caller-owned `semantics.Publisher` and optional annotator before producing frames.
The App stages semantics and commits them with the tree and focus.
`FrameOutput.semantic_snapshot` borrows the committed snapshot.
Clear the configuration before destroying the publisher or annotator.

Staging copies text values, placeholders, and character tables into the publishing slot.
Absent text and present empty text are distinct across the C ABI.
Progress indicators publish a read-only range and no mutation actions.
Hidden nodes advertise no actions. Disabled nodes do not publish enabled state or custom actions.

`semantics.Dispatcher.set_text` takes an optional text slice plus `TextSelection`.
A nonnull slice replaces the full value, including an empty value.
A null slice changes selection only and preserves text and marked composition.
Offsets use UTF-8 bytes. Dispatch borrows payloads synchronously until callback return.

[`accessibility.Adapter`](../src/v7_host/accessibility.zig) stages owned bridge data before crossing the C ABI.
Custom actions carry signed IDs and UTF-8 names. The SDK copies names during the update.
`lastValue` reads the text channel. `lastNumericValue` reads an optional numeric value, preserving zero as present.
These methods inspect submitted bridge data, not platform readback.
Limits include 32768 nodes, 64 queued actions, and 8192 payload bytes.

`linked` describes the compiled bridge. Runtime adapter state and screen-reader activation are separate values.
Without the bridge, the adapter reports unavailable support.
The pinned Unix adapter implements whole-value `EditableText.SetTextContents`.
Other positioned editing operations return `org.freedesktop.DBus.Error.NotSupported`.
Whole-value editing does not imply native composition support.

`bindSystemBell` borrows a window and rings nothing. Unbind it on the same thread.
`bell()` returns rung, unsupported, provider_failed, window_closed, or wrong_thread.
A rung result means the platform accepted the request, not that it produced audible sound.
Bell capability is independent of AccessKit activation.

## Inspection and deterministic tests

| API | Source | Rule |
| --- | --- | --- |
| `inspection.captureFrame`, `FrameSnapshot`, `InspectHandle` | [inspection.zig](../src/v7/inspection.zig) | Snapshots own copied frame data. Handles reject stale generations. |
| `inspection.BoundedCollector(T)`, `CollectorSink` | [inspection.zig](../src/v7/inspection.zig) | Fixed-capacity collectors report saturation. Disabled sinks compile recording away. |
| `perf_counters.Counters`, `Snapshot`, `CounterSink` | [perf_counters.zig](../src/v7/perf_counters.zig) | Build option `v7-perf-counters` controls instrumentation. Overflow is an error. |
| Host `Inspector`, `diagnostics.queryGpu` | [inspector.zig](../src/v7_host/inspector.zig), [diagnostics.zig](../src/v7_host/diagnostics.zig) | Detach action listeners and release snapshots at teardown. GPU queries report device data. |
| `nogui_test.Context`, queries, replay, virtual clock | [context.zig](../src/v7_test/context.zig) | Keep the Context address stable. Queries expire after a new committed frame. Clock time cannot move backward. |
| `nogui_test.TextContext(Cpu)` | [text_context.zig](../src/v7_test/text_context.zig) | Uses production CPU text measurement. Release layouts and caller models before teardown. |
| `nogui_test.OffscreenContext(Frame, Render)` | [offscreen_context.zig](../src/v7_test/offscreen_context.zig) | Owns a real GPU without SDL. Returned pixels expire at the next render or teardown. |
| `treeToJson`, `renderAscii`, `layoutFingerprint`, `parseEvent` | [headless.zig](../src/v7/headless.zig) | All describe committed state. `ParsedEvent` owns storage until `deinit`. |

`Context.runUntilIdle` drains only work eligible at the current virtual time.
If teardown closes the App but returns `LiveModels`, release retained models and retry teardown.
The closed App cannot resume rendering.
Read GPU timestamps only after submission completes. Associate results with frame IDs, not recycled query slots.
