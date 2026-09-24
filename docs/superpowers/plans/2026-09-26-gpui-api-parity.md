# GPUI API Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` for independent work packages or `executing-plans` for sequential execution. Implement and review one package at a time. Check only work with acceptance evidence.

**Goal:** Close every confirmed reusable-API deficiency in the [capability audit](2026-09-26-gpui-api-audit.md), with concrete native adapters where the capability applies. Keep nogui's immediate-mode design instead of cloning GPUI's Rust interfaces.

**Architecture:** One shared `Session` owns persistent models, effects, tasks and application services. Each window has its own `App`, two frame arenas, input/focus state and GPU mount state. A reusable host owns SDL windows and adapters. Typed frame records connect custom elements, text layout, painting and semantics. Headless use remains independent of native window creation.

**Tech Stack:** Zig 0.16.0, SDL3, noapi, FreeType, HarfBuzz, current layout engine and Tracy. Linux-first adapters use the declared Nix/devenv environment. Planned additions: Fontconfig/FriBidi for Linux font discovery and bidi, librsvg/Cairo for complete SVG documents, and an optional C-ABI bridge to AccessKit for accessibility.

## Global constraints

1. **Implementation in progress.** Complete all 26 work packages and 66 audited gaps. Source baseline and evidence limits are recorded in the audit.
2. Preserve Oklab intermediate colors, final sRGB conversion, noapi-only GPU work, relative parent-content border boxes, and two live frame arenas. No raw Vulkan access.
3. Keep transient, copyable local state cheap. Persistent models, tasks, text buffers, assets and native resources must not live in a frame arena. Do not heap-allocate an entity for every widget.
4. A capability is not complete when its type compiles. Its implementation, callers, errors, documentation, regression scenarios and running consumer must work. A silent no-op or universal `Unsupported` adapter does not close a gap.
5. Change each public contract and all its callers together. Remove replaced fields, adapters and demo-private implementations; no compatibility aliases or duplicate runtimes. Use `jj`, not raw Git. Do not discard unrelated working changes.
6. Source observations are not reproduced bugs. Reproduce a suspected defect before fixing it. Test consumer-visible lifetime, ordering, errors and state transitions, not symbol wiring or copied source text.
7. Native support is explicit per backend. `Unsupported`, permission denial, user cancellation, provider failure, stale handles and empty results are different outcomes. Unsupported on an inapplicable platform is valid; it is not proof of implementation on the applicable platform.
8. Native permissions, credential writes, notifications, external URLs, registrations and filesystem changes require explicit operator approval in live verification. Use synthetic test data and private test directories. Never accept a provider permission prompt automatically.
9. Each work package updates the affected API guide and examples after its smoke proof. Implementation must not leave documentation until the end of the program.

## Decision: extend the immediate core, extract the host

| Option | Result | Decision |
| --- | --- | --- |
| Copy GPUI's entity/element/runtime structure literally | Familiar GPUI vocabulary, but Rust ownership patterns and persistent widget objects spread through a Zig immediate renderer. | Reject. Capability parity does not require source/API spelling parity. |
| Keep adding features to `v7_demo/window.zig` | Small local changes initially; no reusable service ownership, duplicated input/text/asset routes and growing demo coupling. | Reject. This preserves the main API deficiency. |
| Add persistent application services and a custom-element seam around the existing frame pipeline | Reuses layout, arenas, rendering and replay; adds ownership only where state must survive frames. | **Choose.** |

Target modules:

| Module | Responsibilities | Must not own |
| --- | --- | --- |
| `nogui` → `src/v7/root.zig` | Session/model/effect contracts, per-window App, tree/layout/input, value-only text/paint/semantic descriptors | SDL windows, font-library objects, HTTP connections, native dialogs |
| `nogui_text` → new `src/v7_text/root.zig` | CPU font resolution, Unicode segmentation/bidi, shaping and cached text layout | Window event loop or application text buffers |
| `v7_render` → existing `src/v7_render/root.zig` | noapi scene submission, paint lowering, glyph/image materials, resource retirement | App model mutation or native service policy |
| `nogui_host` → new `src/v7_host/root.zig` | Session/SDL window ownership, native services, assets, text/render adapters, wake/present | A second widget tree, focus router, task runtime or shape cache |
| `nogui_test` → new `src/v7_test/root.zig` | Deterministic Session/App driver, controllable clock/tasks, queries and replay | Implicit native initialization or wall-clock sleeps |
| `src/v7_demo/` | Todo, Spotify, calculator, GPU experiments and performance consumers | The only implementation of a public GUI capability |

Existing core GPU lifecycle hooks remain an explicit optional integration seam. Merely importing a value type must not initialize or link an SDL/font/XML runtime in a core-only consumer. Renderer and host dependencies are resolved only for selected build products.

## Shared contracts to settle before parallel implementation

These names describe the **proposed contract**, not declarations available today. W01–W05 establish them before consumers are split among workers.

### Identity, ownership and access

- `Model(T)` is a typed handle with store identity, slot and generation. `WeakModel(T)` upgrades only while the model exists. Erased model/view handles carry checked type identity. Reservation is explicit and cannot read an uninitialized value.
- Zig ownership is explicit: retaining a handle increments ownership; copying its bits does not. Release tokens are not silently duplicated. Default listener/task owner capture is weak; a strong capture is an explicit lifetime choice.
- `Session.read/update` callbacks are scoped. Reject wrong-store, stale-generation, wrong-type and conflicting mutable access. An update cannot leak a model borrow into an effect, task or frame. Reentrant mutation uses deferred effects rather than an unchecked alias.
- `App.mountRoot` binds a caller-owned view once; `App.mountModelRoot` binds a separately retained model with a caller-owned typed view. `App.handle(Event)` and frame production no longer repeat the root type and pointer. `replaceRoot` and `replaceModelRoot` revoke old callbacks transactionally, but the caller still owns old view memory through any readable snapshots. `DrawCtx.frame_info` replaces magic writes into user fields.
- Existing `DrawCtx.state` remains transient value state. Document that it shallow-copies and resets after absence. Borrowed fields must remain valid for both live trees; resource-owning state uses a model. Do not promise a generic compile-time proof that an arbitrary Zig struct has no ownership.
- `FrameNodeId` remains a dense tree index. `WidgetId` is stable within a window, derived from component identity and an explicit sibling key, with full-key collision checking and generation-aware mount records. Text, translated phrases and localization message keys are never widget identity.
- A persistent model may be shown in several windows. Focus, capture, view mount state and GPU state remain per window/endpoint. A model's last-rendered window may be queried as an optional convenience; operations with effects on a specific window take an explicit `WindowHandle`.

### Frames, coordinates and effects

- Build/layout/prepaint/paint-description/semantics form one frame transaction. Publish tree, hit-order index and semantic snapshot together only after success. On failure keep the last committed output and undo newly created frame mounts/resources. Shared model updates made before drawing are not magically rolled back.
- Previous-tree data remains valid through the next build. GPU resources and external snapshots are pinned separately until both frame references and submitted GPU work release them. Two frame arenas are not a GPU fence.
- Keep stored `WidgetNode.rect` and clip ABI layout unchanged. New boundaries use named logical-window, parent-relative, scroll-adjusted visual and device-pixel values. Layout uses logical UI units; the host performs explicit DPI conversion at input, raster, IME and accessibility boundaries. At scale 1 existing layout goldens remain unchanged.
- `notify` coalesces dirty models/windows within an outer update. Typed events and deferred effects retain FIFO order and own their payloads. Drain after the outermost update, not during a borrow or draw callback. Self-unsubscribe is safe; a newly added subscriber does not receive an event already being delivered.
- Drawing is read-only with respect to shared model mutation. Local frame builders may write frame data. Requests for persistent changes are queued for the next update; measurement may run more than once and has no external side effects.

### Tasks, native services and errors

- One injected `Clock` and task service supplies timers, worker work, UI completion and deterministic testing. Background jobs own immutable/copyable inputs; they never retain frame pointers or mutate Session models directly.
- Cancellation is a state transition, not premature freeing. Queued work can be removed; running work must acknowledge completion/cancellation before its storage is destroyed. Cancelled or stale-window results cannot mutate a replacement owner.
- `FrameDemand` distinguishes dirty layout/paint, presentation-only work, animation deadline and explicit continuous mode. All task, animation, input and native events use the same no-lost-wakeup route. Hidden/minimized windows need not render continuously.
- Native services return typed outcomes and state/capability changes. WM requests are requests, not guarantees of the observed state. Borrowed event/clipboard bytes have a documented call lifetime; queued consumers copy or retain an owned object.
- Error groups include allocation/capacity, stale/wrong owner, conflicting access, invalid text/range, unavailable capability, denial/cancellation and provider failure. Do not invent one generic success fallback.

### Text, rendering and interaction

- Core text offsets are UTF-8 byte offsets at valid code-point boundaries; shaped caret queries use cluster/grapheme boundary policy. Native UTF-16 conversion happens only at the adapter edge. Preedit selection offsets are UTF-8 bytes relative to the preedit string, not the document.
- `TextStyle` and `TextStyleOverride` are typed and fieldwise. Component defaults → inherited container style → explicit widget/run override. The same resolved style and layout supply measurement, painting, caret and range geometry.
- One `TextService` resolves fonts and returns immutable `TextLayout` handles/snapshots. Cache keys include content generation, font/features/fallback, script/direction, style and wrap constraints. Ordinary editable text stays in the application model; Neovim keeps its own document authority.
- Authored sRGB and scene Oklab colors are distinct types. Convert once at the paint boundary. Retain GPUI's two-stop gradient capability with angle/positions; do not silently add sRGB intermediate interpolation.
- Custom elements emit renderer-neutral paint records; render-only affine transforms do not change layout/hit geometry. Opacity multiplies primitive alpha; this plan does not promise isolated offscreen group compositing or arbitrary path masks.
- Route events root-to-target capture, target, then bubble. `stopPropagation` and `preventDefault` are distinct. Default scroll/focus/control behavior runs only if permitted. The demo uses this same route.
- Semantic activation uses one action path for pointer click, keyboard and accessibility. **Intentional cutover:** default click activates after a valid press/release, not mouse-down. Expose raw pointer-down for consumers that need it; do not keep an undocumented legacy timing mode. Slider capture continues outside the box and always receives release/cancel.

## Work-package graph

W numbers are stable references, not a requirement to serialize independent work. The dependency column is authoritative. Integrate through one owner of `root.zig`, `App`, `WidgetNode` and build changes; workers must not invent competing contract types.

| Package | Purpose | Depends on |
| --- | --- | --- |
| W01 | Module boundaries and reusable host extraction | — |
| W02 | Stable identity, coordinate boundaries, frame transaction | W01 |
| W03 | Session/models/context/root and state lifetimes | W02 |
| W04 | Subscriptions, globals and effect queue | W03 |
| W05 | Tasks, clocks, invalidation and wakeups | W04 |
| W06 | Deterministic public test context | W05 |
| W07 | Application lifecycle, multiwindow and display host | W05 |
| W08 | Custom elements, measurement and visibility | W03 |
| W09 | Event router, focus and pointer lifecycle | W04, W08 |
| W10 | Actions, keymaps, cursors and keyboard layout | W07, W09 |
| W11 | Font/text style, shared layout and Unicode units | W08 |
| W12 | Editable-text protocol, IME and edit actions | W09, W10, W11, W18 |
| W13 | Canvas, paths, colors, effects and transforms | W08 |
| W14 | Assets, images, SVG and external frames | W05, W07, W13 |
| W15 | Scroll handles, container queries and virtual lists | W05, W08, W09 |
| W16 | Overlays, drag-and-drop and tooltips | W05, W09, W10, W13 |
| W17 | Animation timeline and reduced motion | W05, W08 |
| W18 | Clipboard, dialogs, menus, URLs and preferences | W07, W10 |
| W19 | Notifications and secure credentials | W07, W18 |
| W20 | Native screen capture | W07, W14 |
| W21 | Semantic tree and native accessibility | W07, W09, W11, W12, W16 |
| W22 | Linux popup/layer-shell/native-window extensions | W07, W16 |
| W23 | Conditional native extensions and target adapters | W12, W14, W18, W19, W20, W21 |
| W24 | Inspector and reusable diagnostics | W06, W08, W10, W13 |
| W25 | Reusable real-text/offscreen consumers and examples | W06, W11, W12, W14, W15, W16, W17, W21, W24 |
| W26 | Distribution, documentation and full parity gate | W19, W20, W22, W23, W25 |

Recommended execution order:

1. **Foundation gate:** W01–W06. No editor/list/overlay implementation before the relevant lifetime seam exists.
2. **Application API gate:** W07 and W08; then W09, W11, W13, W17 can progress independently once their contracts are fixed. W10 and W18 unblock W12.
3. **Rich UI gate:** W12, W14–W16 and W21; W24 in parallel after its dependencies.
4. **Native capability gate:** W19, W20, W22 and the applicable W23 adapters. Linux is first; other-target acceptance remains explicitly open until run on that target.
5. **Consumer gate:** W25–W26. These do not defer ordinary caller migrations, which happen in each package.

Each numbered checkbox below is a reviewable change boundary, not an instruction to create a commit without permission. Before the first mutation, inspect current references and adjust source ranges for intervening user work.

## Detailed work packages

### W01 — Extract reusable module boundaries

**Coverage:** supports D02/D05 and all host-dependent gaps. **Depends on:** none.

**Files:** modify `build.zig`, `build.zig.zon`, `src/v7/root.zig`, `src/v7_demo/main.zig`, `src/v7_demo/window.zig`; create `src/v7_host/root.zig`, `src/v7_host/application.zig`, `src/v7_host/window.zig`, `src/v7_text/root.zig` and their package entry points. Move implementation only when its public seam is usable; do not create empty exported modules.

**Produces:** reusable host initialization/drive seam, CPU-text module boundary, selected-product dependency graph. Existing GPU hook types remain explicit rather than hidden host globals.

- [x] Extract SDL/window/event-loop ownership from the demo without changing event timing, geometry or paint output. Keep benchmark policy and scene selection in the demo.
- [x] Separate core-only, text-only, render, host and test build products. Defer SDL/FreeType/HarfBuzz/XML/native-service dependency resolution until a product requires them; preserve current commands.
- [x] Compile and run a throwaway external core-only consumer and the existing six-frame headless demo. Verify core-only operation initializes no SDL window/GPU and does not link the demo font/XML libraries. Compare existing headless state transitions, not source copies.

**Gate:** existing `zig build v7` and an external `zig build run` consumer; current graphical Todo and Spotify still open through the extracted host. Document module ownership before adding Session services.

**Verified W01 (2026-09-26):**

- `zig build test check fixture layout-check lint -j4 --summary all`: 61/61 steps, 1,106 tests, 5,524 fixtures, and the unchanged 581-row golden passed. Both linters passed across 82 active files.
- Each `-Dproduct=core|text|render|host` compile-only check passed. The standalone noapi suite passed all 58 tests with Tracy disabled.
- An external core-only package consumer passed with display variables unset and new local/global caches. It activated a checkbox across two frames and retained the previous tree. Its executable has no dynamic section.
- All six headless trees matched the pre-extraction output exactly, including state, IDs, and geometry. Todo and Spotify GPU shots matched their baselines byte for byte.
- Native Todo and Spotify windows opened, resized, rendered, and closed with exit code 0. Compositor screenshots were inspected. Spotify reported its absent local music directory, so playback was not verified.
- README documents module and resource ownership. Core exports in `src/v7/root.zig` remain unchanged because the extracted services are separate modules.

**W01 recheck (2026-09-30):** `env -u DISPLAY -u WAYLAND_DISPLAY
zig build run` in `examples/consumers/core_only` exits 0 (`core_only: OK`);
`file zig-out/bin/core_only` identifies a statically linked ELF, with no
dynamic SDL/font/XML linkage. `env -u DISPLAY -u WAYLAND_DISPLAY zig build v7`
exits 0 and emits six headless frames. Parsing those frames shows the counter
advance from 0 to 1 at frame 3, completed todos from 0/2 to 1/2 at frame 4,
and todo count from 2 to 3 at frame 5. Module exports and demo host delegation
still match the ownership documented above. The recorded 2026-09-26 GPU-shot
and compositor checks remain the native/pixel evidence; this headless recheck
does not replace them.

**Test-graph coalescing (2026-09-28):** `zig build test` built thirteen test
binaries, and seven of them were duplicates. `src/v7_demo/main.zig` already
imports every scene file, so the `exe_tests` binary already ran all of their
test blocks; `perf_tests`, `v7_text_tests`, `v7_ui_tests`, `v7_spotify_tests`,
`v7_calculator_tests`, `v7_svg_tests` and `v7_window_tests` linked and ran the
same 116 blocks again. Those seven artifacts are removed and the demo's
coverage is listed explicitly in the `test` block of `main.zig`, so a dropped
import fails the build instead of silently dropping tests. Six artifacts
remain: core, `nogui_test`, the three per-product library tests, and the demo.

SDL video, events and the clipboard are process-global, so `sdl_session.zig`
reference counts them: the first `Application` initializes, the last one
quits. Before this change every `Application.deinit` called `sdl3.quit`
unconditionally, so a second host lost its window and event state when the
first was released, and each host test paid a full driver init, an evdev
probe, and a teardown.

### W02 — Identity, coordinate boundaries and frame publication

**Coverage:** C08, I05, L04. **Depends on:** W01.

**Files:** modify `src/v7/{id,key,widget,drawctx,app,input,headless}.zig` and host window conversion; create `src/v7/identity.zig`, `src/v7/geometry.zig` only for the new logical-identity and boundary contracts.

**Produces:** stable `WidgetId`, dense `FrameNodeId`, window/visual/device conversion helpers, committed-frame generation and rollback ownership.

- [x] Add explicit widget keys within component scopes, a collision-checked mount registry, duplicate-key errors and per-frame stable-ID lookup. Migrate every interactive control and demo lookup; captions and localization slugs never substitute for keys.
- [x] Stage new tree/hit records and new mount resources, commit once, and unwind the staged mounts on draw/layout failure. Retire previous data by arena generation and external GPU completion independently.
- [x] Keep stored relative rectangles/clip ABI; name coordinate spaces at public boundaries and convert DPI once. Test nested padding/border/scroll at 1×, 1.25× and 2×.

**Acceptance:** insert/reorder/remove same-kind siblings without moving focus/capture to another logical control; reject duplicate keys; failed frame preserves previous tree/state and cleans new mounts once; old/current snapshots remain readable for their documented lifetime. These are regression tests for plausible alias/lifetime failures, not a claim those failures were already reproduced.

**Gate:** `zig build test -Dtest-filter=api-w02`, `zig build fixture`, `zig build layout-check`; smoke a keyed list that reorders while focused. 1× layout golden changes need a specific intended reason.

**Verified W02 (2026-09-27):**

- A focused same-kind insertion test first failed because dense ID reuse transferred keyboard activation. After the cutover, `zig build test -Dtest-filter=api-w02 -j4 --summary all` passed 36/36: keyed insertion/reorder/removal, generation retirement, duplicate collisions, frame failure/rollback, external scroll restoration, GPU init cleanup, and fractional coordinate boundaries.
- `zig build test fixture layout-check lint -j4 --summary all` passed 57/57 steps, 1,143/1,143 tests, 5,524/5,524 fixtures, the unchanged 581-row layout golden, and both linters with zero warnings after the formatting pass. `zig fmt --check src build.zig build.zig.zon` passed. Standalone noapi tests passed 61/61.
- `zig build v7 -- --keyed-reorder-smoke` printed `keyed-reorder-smoke: OK` after a real Todo click, item reorder, stable focus, and Space activation. The six-frame headless demo and `zig build v7 -- --frames 3` ran. `--gpu-remount-smoke` reported the Mandelbrot slot reused after its hidden frame.
- Native Todo, Spotify, tiger, and stroke shots rendered and were inspected at 1×; the live Todo window was captured from the compositor after the desktop capture API reported Wayland capture unavailable. Non-1× GPU pixel comparison remains unobserved; CPU boundary and shader-footprint regressions cover those scales.
- README describes stable handles, transaction/abort ownership and logical/device units; the audit records dated implementation evidence without rewriting its source baseline.

### W03 — Session, typed models and scoped contexts

**Coverage:** C01, C02, C03. **Depends on:** W02.

**Files:** create `src/v7/{session,model,context}.zig`; modify `app.zig`, `component.zig`, `callback.zig`, `state.zig`, `drawctx.zig`, `root.zig`, all App construction/registration/frame callers and demos.

**Produces:** model store, strong/weak/erased handles, reservations, scoped read/update, typed model/view listeners, one-time root mount/replacement and `FrameInfo`.

- [x] Implement model allocation/retention/release, type/store/generation checks and borrow guards. Define destruction order and allow reservation-based cycles only through weak edges; unfinished reservations cannot be observed as values.
- [x] Bind root identity once; remove repeated `T, root` arguments and magic `frame_count` mutation in the same cutover. Give a model explicit view adapters so shared state can back more than one window without sharing GPU mount storage.
- [x] Keep value-state copying, exact-type checks and absence reset. Document persistent resource ownership and migrate persistent demo state to Session or explicitly retained caller ownership at a declared boundary.

**Acceptance:** shared model update reaches two views, wrong-store/type/stale access fails, conflicting mutation fails deterministically, weak upgrade fails after final release, cleanup runs once, root replacement cannot mix old callbacks with a new root, transient state resets only on documented unmount.

**Gate:** `zig build test -Dtest-filter=api-w03`; headless two-App/shared-model smoke, then Todo/Spotify/GPU-remount scenarios. No owned model or GPU object survives Session shutdown accidentally.

W03 gate (2026-09-27): `zig build test -Dtest-filter=api-w03 -j4 --summary failures` and the complete `zig build test fixture layout-check lint -j4 --summary failures` passed. The corpus matched 5,524/5,524 fixtures, the 581-row golden was unchanged, and both linters reported zero warnings across 88 files; `zig fmt --check src build.zig build.zig.zon` passed. Native Spotify rendered three GPU frames; Todo's keyed-reorder and GPU-remount smokes passed, with Mandelbrot slot 2 reused after one hidden frame. Two-App shared-model tests exercise updates and separate view receivers. Wrong-store/type/stale/borrow, reservation aliasing, reentrant destruction, old/candidate model conflict, mounted-child GPU aliasing, root callback replacement, and Session shutdown have regression coverage.

### W04 — Notifications, subscriptions and globals

**Coverage:** C04, C05. **Depends on:** W03.

**Files:** create `src/v7/{effects,subscription,globals}.zig`; modify `session.zig`, `context.zig`, `callback.zig`, `app.zig`, `root.zig`.

**Produces:** typed `emit/observe/subscribe`, cancellation tokens, release listeners, scoped globals, `defer` and coalesced notification effects.

- [x] Make payload/token ownership explicit; weak-bind owner listeners by default. Cancellation, owner release and self-unsubscribe remove future delivery without invalidating the current dispatch iterator.
- [x] Drain FIFO effects after the outer update, track model-read window dependencies, and coalesce redraw notifications without coalescing distinct typed events. Allow global changes through the same scoped update path.
- [x] Route existing direct callback effects through typed contexts where persistence/reentrancy requires it; preserve cheap synchronous callbacks when their borrow lifetime is explicit.

**Acceptance:** nested updates produce a documented deterministic event order; unsubscribe/release prevents later delivery; an event enqueued during delivery runs afterward; global changes notify dependent windows once; no mutation escapes a failed borrow.

**Gate:** `zig build test -Dtest-filter=api-w04`; two-view counter smoke with an observer that removes itself and a deferred model update. No callback sees a partially built frame.

**Verified W04 (2026-09-29):**

- `zig build test -Dtest-filter=api-w04` passed 22/22, exit 0: FIFO delivery of each owned event after the outer borrow, self-unsubscribe and owner release inside a dispatch without invalidating the current iterator, per-Session tokens that cannot leak listeners, committed window dependencies that coalesce while an aborted read stays private, a rejected borrow that emits nothing, and the two-`App` self-unsubscribing counter with a deferred update that this Gate names.
- `zig build lint` reported 0 errors and 0 warnings across 190 files over the new effect, subscription and globals modules, and the full suite passes 1413/1413 across 34/34 steps with 0 leaks.

### W05 — Tasks, clocks and frame demand

**Coverage:** C06, C07. **Depends on:** W04.

**Files:** create `src/v7/{task,clock,frame_demand}.zig`, host worker/wakeup adapter; modify Session/App and `src/v7_demo/FramePacer.zig` integration without duplicating its pacing policy.

**Produces:** owned task handles, weak-owner completion, UI/worker scheduling, timers/timeouts, scoped completion, invalidation and wait/wakeup contract.

- [x] Use Zig 0.16 I/O/worker facilities through one service. Expose background priority classes with documented queue ordering and FIFO within a class; foreground delivery remains ordered UI work. Define cancellation-before-start, cancellation-while-running, detach and shutdown drain. Do not block the UI thread on a completion that needs that thread.
- [x] Add per-window dirty/layout/paint/presentation state and deadlines. Deliver worker completion to the UI update queue. Synchronize wait registration and wake publication so no completion is lost between drain and sleep.
- [x] Preserve explicit continuous mode for Mandelbrot/performance workloads. Stop idle frames and completed animations; bound shutdown waiting and report unfinished work rather than freeing live buffers.

**Acceptance:** canceled work cannot update a reused model/window slot; timed work runs at the injected deadline; a completion racing sleep wakes the host; hidden windows do not spin; explicit continuous mode still advances GPU frames. Priority is promised only where implemented, not inferred from GPUI's ignored foreground parameter.

**Gate:** `zig build test -Dtest-filter=api-w05`; live worker-loaded view plus idle/wake and shutdown smoke. Record frame counts during an idle interval and after one completion.

**Verified W05 (2026-09-29):**

- `zig build test -Dtest-filter=api-w05` passed 27/27, exit 0: a timer and an early worker result delivered at their injected deadlines after frame publication, FIFO order within each priority class with `detach` releasing a queued job exactly once, cancellation before start and while running with a stale owner unable to reuse a slot, a completion arriving between snapshot and sleep waking the host, and the `FrameDemand` policies that stop idle frames, keep explicit continuous mode advancing and retry a failed animation deadline.
- The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Live host gate (2026-09-30): `env -u DISPLAY -u WAYLAND_DISPLAY zig build run` from `examples/consumers/host` exited 0 with `host: OK session_window=1 idle_frames=1 worker_frames=2 wakes=1`. A real worker slept 25 ms, set the shared model revision to 7 on delivery, and woke the externally driven SDL dummy host. Twenty 5 ms idle steps before completion and ten after produced no extra frames or deadline; closing the window, unregistering the wake callback, and then `shutdownTasks` completed cleanly. An initial run exposed that `shutdownTasks` before `Application.deinit` makes the latter's wake unregister fail; the consumer now enforces the valid teardown order. This covers the previously unrun gate half, with the recorded `api-w05` cases covering cancellation, timed work, hidden-window demand, and continuous mode.

### W06 — Deterministic test context

**Coverage:** D01. **Depends on:** W05.

**Files:** create `src/v7_test/{root,context,clock,dispatcher}.zig`; modify `build.zig`, `src/v7/headless.zig` and demo replay adapter.

**Produces:** one headless Session/App harness, virtual time, reproducible task interleavings, explicit frame flush and stable-key/tree queries.

- [x] Wrap the production service seams rather than fork Session semantics. Expose key/text/pointer dispatch, focus/state queries and run-until-idle with bounded progress diagnostics.
- [x] Keep direct Event and JSON replay on one parser/dispatcher contract. Queries use stable keys and current semantic data; previous-frame query handles fail instead of returning a replacement node.
- [x] Add seed replay for task ordering and explicit cleanup checks. Keep real-concurrency benchmarks separate from this deterministic scheduler.

**Acceptance:** identical event/clock scripts through direct and JSON drivers yield identical observable model/focus/selection transitions; canceled tasks leave no pending work; advancing time does not execute future deadlines early.

**Gate:** `zig build test -Dtest-filter=api-w06`; run an actual JSON replay through `zig build v7 -- --sim <script>` and compare parsed state, not only harness mocks.

**Verified W06 (2026-09-29):**

- `zig build test -Dtest-filter=api-w06` passed 11/11, exit 0: identical model, focus and selection transitions through the direct `Event` driver and the JSON driver on one parser, stable-key queries where a previous-frame handle fails with `error.StaleFrame`, a seeded replay bounded by a progress limit that resumes without losing work, and cleanup checks for canceled jobs, worker deadlines and retained owners.
- The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- CLI gate (2026-09-30): `env -u DISPLAY -u WAYLAND_DISPLAY zig build v7 -- --sim testdata/sim/todo-increment.jsonl` exited 0. Its three JSON dumps parsed as frames 1/2/3: focus `0/46/46`, `Counter: 0/0/1`, and `0 of 2 done` throughout. The saved script sends six Tab key-down events to focus the `inc` button and Enter to update the real Todo model. This exercises the command-line reader, parser, dispatch, focus and render path; the recorded `api-w06` test separately compares direct and JSON drivers for selection, text and virtual-clock transitions.

### W07 — Application and multiwindow host

**Coverage:** P01–P04. **Depends on:** W05.

**Files:** host `application.zig`, `window.zig`, new `display.zig`, core window handle/options contracts, build and demo callers; adapt existing noapi surface management without accessing raw Vulkan handles.

**Produces:** owned run loop and externally driven host, generational windows, root replacement, displays/options, lifecycle callbacks, observed window state and explicit frame/presentation requests.

- [x] Implement launch-once, activate/hide, reopen/incoming-launch events, system-wake notification, quit with asynchronous bounded hooks and explicit restart policy. Recompute frame/timer demand after system resume. Last-window-close and app quit are separate decisions.
- [x] Create multiple windows transactionally with independent App/arenas/input/GPU mounts. Support parent/display, bounds/minimum size, visibility/focus, window kind, titlebar/decorations/background/app ID options where native capability permits. Close veto cannot leave a half-destroyed window.
- [x] Provide display IDs, primary/work/full bounds and scale-change events. Keep unavailable Wayland global positions optional. Distinguish requested title/size/maximize/fullscreen/attention from observed compositor state.

**Acceptance:** two windows show one model, close one during queued work, reuse a native/window slot without misdelivery, veto a close, change DPI/display and keep pointer/IME/render coordinates aligned; failed second-window creation leaves the first usable.

**Gate:** `zig build test -Dtest-filter=api-w07`; real Linux X11 and Wayland two-window runs, resize/minimize/restore/close and external-loop embedding. A headless pass cannot substitute for these host checks.

**Verified W07 (2026-09-29):**

- `zig build test -Dtest-filter=api-w07` passed 18/18, exit 0: one model rendered through two isolated native windows with independent `App` frames, a close veto that retains mounts, a reused slot that rejects the old handle and its queued native events, failed second creation leaving the first window usable, and launch-once, quit-preflight and explicit restart under the SDL dummy video driver.
- The `sdl_session.zig` reference count recorded under W01 is what lets a second `Application` keep its window and event state. The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Native session, through the new smoke binary `src/v7_demo/w07_host_smoke.zig` and step `zig build w07-host-smoke`, added because every existing demo mode is single-window. Live niri Wayland desktop: `XDG_SESSION_TYPE=wayland`, `WAYLAND_DISPLAY=wayland-1`, `XDG_CURRENT_DESKTOP=niri`, `DBUS_SESSION_BUS_ADDRESS` set, `grim` available and `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache` required. `DISPLAY=:0` is XWayland only, SDL selected native Wayland, and the app reported `video driver: wayland` with `global position capability: false`.
- Two real windows cleared their swapchains to two distinct authored colours and both were visible in one `grim` capture at `/tmp/w07_wayland_final_both.png`: left sRGB (89,179,225) with 486932 counted pixels and right sRGB (231,160,97) with 973042, swapchain format `b8g8r8a8_srgb`. One `Session` model rendered in both windows across three frames and both windows observed revision 2; a later explicit resize was honoured exactly; a close veto held the window and releasing it retired the session window; `Session.deinit()` succeeded instead of returning `LiveApps` or `LiveModels`; the process exited 0.
- The compositor did not honour the requested initial size. 480x360 and 520x380 were requested and niri granted 954x1044 to both windows on first configure, so requested size and observed size are demonstrably different values on this backend; only the later explicit resize was honoured.
- Minimize is a measured limitation, not a pass. `requestMinimize` set `requested.minimized = true`, but after a 3000 ms pump the window was never observed minimized: `observed.visible` stayed true, the observed size was unchanged, and a `grim` capture taken while the request was outstanding still showed the window painted. SDL3's Wayland backend never sets `SDL_WINDOW_MINIMIZED` for `xdg_toplevel.set_minimized` because niri does not advertise the xdg-shell MINIMIZE capability, so the request is unobservable on this stack.
- That run changed a public contract: `ObservedState.minimized` is now `?bool`, with a matching `Application.Capabilities.minimized` derived from `display.hasWindowMinimized()`, so a platform that cannot observe minimization reports `null` instead of a false reading. The test that pins the honest contract is `src/v7_host/w07_contract_test.zig`.
- The X11 half of this gate was attempted against XWayland's `DISPLAY=:0` and cannot complete on this host, for two independent causes that both sit outside this repository. This is a negative result about the host's X11 surface, not a nogui defect, and the W07 box stays unticked because the gate above names X11 as well as Wayland. There is no working X11 combination here at all: one would need both a non-NVIDIA ICD and a Mesa newer than 26.2.3, and no such combination is installed.
- The Wayland half is complete under both Vulkan ICDs on this host. `zig build w07-host-smoke` exits 0 with the default NVIDIA ICD and exits 0 again with the Mesa lavapipe ICD, and the two runs report identical observable values: `video driver: wayland`, `global position capability: false`, minimize reported unobservable, both windows opened with requested 480x360 and 520x380 but observed at 954x1044, three frames committed and presented in each window, model revision 2 seen by both windows, an explicit resize to 900x620 honoured with the peer unmoved at 954x1044, a close veto that held the window and then released it, last-window-close firing once with decision `keep_running` while `Application.isRunning` stayed true, `requestQuit` returning `approve` and `isRunning` false, `window_count 0`, `host_running false`, `Gpu.deinit` ok and `Session.deinit` ok. The workaround available today is therefore to run this gate on Wayland, which validates the host behaviour in full.
- X11 cause one is the default NVIDIA ICD, which kills the process. Six runs aborted with `signal ABRT` and the kernel journal carries the same fault every time: `NVRM: Xid (PCI:0000:01:00): 31, ENGINE GRAPHICS GPC2 GPCCLIENT_PROP_0, FAULT_PRIV_VIOLATION ACCESS_TYPE_VIRT_WRITE @ 0x1_22184000`, the identical address in all six. Three controls place the fault outside this repository: the Wayland W07 run passed under the same GPU load, `w24-inspector-smoke` on X11 passed, and `w22-popup-smoke` on X11 passed.
- X11 cause two is the Mesa lavapipe software ICD, the only non-NVIDIA Vulkan driver present. A gdb 17.2 batch backtrace on the already-built binary puts every frame inside `/nix/store/...mesa-26.2.0/lib/libvulkan_lvp.so`, on a lavapipe rasterizer worker thread and not the main thread: `util_fill_rect`, `util_fill_box`, `lp_rast_clear_color`, `rasterize_scene`, `thread_function`, `impl_thrd_routine`. The faulting instruction is a `rep stos` in Mesa's 32-bit row-fill fast path, `src/gallium/auxiliary/util/u_surface.c:146` calling the inlined `util_memset32` at `src/util/u_memset.h:35`, reached from `lp_rast.c:171`. The live values at the fault put the fill origin outside the surface: destination stride 1920 gives a 480-wide surface and layer stride 691200 gives a 360-high one, while the fill rect origin is x = 576 in one run and 704 in another at y = 320 with size 64x64, so x passes 480 and 320 + 64 passes 360 and the store runs about 46 KB past the end of the single X11 shared-memory window image into an unmapped gap. The origin differs between runs, so it is not a constant this repository supplies, and it cannot come from this repository's render area either: the area passed here is (0,0,480,360), which is in range, bins to tile (0,0) and so cannot produce tile column 9 or 11, and no swapchain blit is issued at all. Mesa 26.1.6, 26.2.0, 26.2.2 and 26.2.3 all reproduce it identically, each reporting `GPU: llvmpipe (LLVM 21.1.8, 256 bits)`.
- The observed contrast that isolates the lavapipe fault: on X11 with lavapipe the one-window `w24-inspector-smoke` completes, and on Wayland with lavapipe the two-window `w07-host-smoke` completes, so the fault needs X11 and the two-window path together. The two were not fully separated, because a single-window run of w07 itself was not possible and the binary exposes no single-window flag. `w22-popup-smoke` is not a usable control here: on X11 with lavapipe it exits 0 but prints a null video driver, meaning it never opened a Vulkan window.
- Both faults are worth reporting upstream with this evidence. Not run regardless: minimize observation, for the platform reason above, DPI and display change, and external-loop embedding. No box in this package is closed.

- The two-window smoke was rebuilt and rerun on the same session after this round's host changes, and it now completes end to end. `zig build w07-host-smoke` opened two real Wayland windows, drove them through an external loop, and shut down with `noapi Gpu.deinit: ok`, `Session.deinit: ok` and no leak.
- Two windows, one model, observed: `opened left: handle slot=0 session_window=1 ... observed_at_open=954x1044`, `opened right: handle slot=1 session_window=2 ... observed_at_open=954x1044`, and after one `Session.update` the shared model read `session=2 settled=true` with `revision left: saw=2` and `revision right: saw=2`; both windows then committed and presented three frames each.
- Resize with a peer that must not move: `resize left: requested=900x620 observed=900x620 pixels=900x620 settled_within_timeout=true divergence=none`, and `peer right: before=954x1044 after=954x1044 moved=false`. The compositor resized the left window to the requested size and the right window never moved.
- Requested-versus-observed reporting, on the same run: each opened window reports `divergence=size` with `borders=unobservable` and `minimum=<none> maximum=<none>`, and after the resize the divergence is `none`. Minimization is reported as `observed.minimized=unobservable ... (unconfirmed: this platform cannot observe minimization)` rather than as a false observation, which is the capability the run states up front: `minimized observation capability: false`, `window hierarchy capability: true`, `global position capability: false`.
- Four refusals, each asserted by name against its exact error and each leaving the live windows alone: `MissingParent`, `InvalidWindowSize`, `InvalidMaximumSize`, `UnsupportedGlobalPosition`, all with `matched=true window_count=2 (was 2)`, then `after refusals: window_count=2 survivor_live=true session.hasWindow=true`.
- Scoped close and the two-decision split: `close left (vetoed): closeWindow=false getWindow_ok=true session.hasWindow=true hook_calls=1` — a veto consumed nothing — then `close left (released): closeWindow=true getWindow_err=StaleWindow session.hasWindow=false on_closed_calls=1 tasks_settled=true drained=1` with `queued work for the closed window: ran=true delivered=0` against `queued work for the surviving window: ran=true delivered=1`. That is the scoped-close claim observed: the worker aimed at the retired window ran and its delivery was refused, the peer's landed, and `drained=1` rather than 2. The last close reported `last-window-close: calls=1 decision=keep_running Application.isRunning=true quit_hook_calls=0`, and only then did an explicit `requestQuit` produce `decision=approve Application.isRunning=false`, so the two decisions stayed separate.
- The run also fixed a real smoke defect. Its window tracker never dropped a closed window, so the step that closes "the rest" walked a slot the host had already released, and the last-window-close path was never reached at all — the run aborted with the Session reporting live models. The tracker now marks a closed slot and every present-reporting and close loop skips it, which is what lets the run reach `pre-shutdown: window_count=0 host_running=false`.
- What this run does not add: the compositor still cannot report a window's global position on this driver, so `position=unobservable` and the `UnsupportedGlobalPosition` refusal is this stack's answer rather than a capability difference; and the two windows were driven on Wayland only, so nothing here is X11 two-window evidence.

**W07 recheck (2026-09-30; supersedes the 2026-09-29 X11 diagnosis above):**

- Source review found a real consumer-side ordering violation: the smoke destroyed its SDL window before `noapi.Surface.deinit`, leaving the swapchain and `VkSurfaceKHR` attached to a freed platform window. `Application.Hooks.on_before_close` already runs before `SDL_DestroyWindow`; the smoke now releases its noapi surface there and asserts that every tracked surface was released before the owning App. This is a correctness fix, **not proof** that the prior NVIDIA Xid or lavapipe rasterizer faults had that cause.
- After the fix, `SDL_VIDEODRIVER=x11 DISPLAY=:0 zig build w07-host-smoke -- --windows 1` and `--windows 2` both exited 0 with the NVIDIA ICD. The same single/dual matrix with `VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json` exited 0 with Mesa lavapipe 26.2.3. Each dual run reached three presented frames in both windows, model revision 2 in both views, left-only 900×620 resize, close veto, clean Session/GPU teardown, and `surface teardown: released_before_window=2 slots=2`. The one-window controls reached the same clean teardown with count 1. The Wayland NVIDIA dual run also exited 0 with count 2.
- The smoke previously treated a task wake counter as proof of delivery; that is false when another event wakes the host. A release gate now holds two real worker results until after the first window closes. The smoke drains until no task is pending and rejects any delivery to the retired window or loss of the peer. The X11 NVIDIA and lavapipe dual runs report `ran=true delivered=0` for the closed window and `ran=true delivered=1` for the surviving window. A temporary native window reopened in the freed host slot as generation 2 while the old generation-1 handle was rejected; it was then retired without a GPU surface.
- `--present-frames 1` now submits one additional command buffer with `endFrame(null)` per window instead of leaving an active frame open. An X11 lavapipe dual run exited 0 with `committed=2 presented=1 without_present=1` per window, `present_path=held-after-commit`, and clean teardown. It is a fault discriminator, not a shared-model acceptance run: the held windows cannot render revision 2.
- Still unverified for full W07 acceptance: an actual change of display or DPI (all observed displays had scale 1.0), and an observed native minimize transition (Wayland reports it unobservable; X11 on this niri/XWayland desktop reported `not-minimized` after the request). Pointer/IME coordinates across a **live** scale change remain unproven. The X11 half is now exercised; do not attribute an external-only graphics-stack blocker to this package or tick its acceptance on the strength of a stable 1× run.

**Private scale and pointer acceptance (2026-10-02):**

- The current two-window binary and private Niri/Xvfb controller exited **0** with every check passing. The output changed **1→1.25** and was restored to **1**. Logical size held **900×620** while device size became **1125×775**.
- Seven raw scale events reached the polling boundary; the production host routed two scale events and two display-geometry events. Both candidate publications were committed and platform-accepted; the settled candidate and App generations matched at **26**. No native text input was started in this geometry-only arm.
- Real platform motion hit the committed probe at both scales. Each phase drove four points and correlated three new raw/routed motions. The measured output-to-App factors were **1.0** and **0.8**; confirming hits were `(450.0,25.0)` and `(450.4,25.4)`. The two earlier synthetic translation probes stayed separately labelled, with **zero unaccounted motion**.
- Swapchain rebuilds changed **0→2**, the Oklab target **1→3**, and presentation extent mismatches stayed **0** across **119** presented frames. The smoke's `--fail-after-open 2` arm also reached two real windows and returned `InjectedConstructionRefusal` without a reported leak.
- The current `api-w07` filter passed **44/44** across **57/57** build steps. This supersedes the dated no-DPI/no-pointer evidence above. An actual IME candidate window has since been observed and inspected at 1× under W12 — the final candidate measured **306×65 at (753,951)** beside anchor **(740,951)** — so it is no longer missing here. A candidate transition at a scale other than 1× has since been observed on a freshly approved owned fixture and is recorded under W12 below; other-target runtime remains separate under W23. CJK is the caller's font mechanism rather than bundled coverage, so it opens no new CJK scope here.
- The current owned Openbox/X11 run also exited **0**: actual minimize changed `minimized=true, visible=false`, restore changed `minimized=false, visible=true`, both within deadline. Left-only resize held the peer at 520×380. Its external loop took nine steps and never called `Application.run`; scoped stale-window work delivered **0**, surviving-window work **1**, slot generation advanced **1→2**, two GPU surfaces retired before their windows, and Session/GPU deinit both succeeded. This supersedes the dated no-minimize/no-external-loop evidence above.


### W08 — Custom element phases, measurement and visibility

**Coverage:** L01–L03. **Depends on:** W03.

**Files:** create `src/v7/element.zig`; modify `component.zig`, `widget.zig`, `drawctx.zig`, `layout/{context,dispatch,root}.zig`, relevant layout leaf switches, `drawcmd.zig`, `input.zig`, `headless.zig`.

**Produces:** static custom-element operation tables, arena-owned payload/phase state, pure intrinsic measure, bounded prepaint/paint/semantic hooks, custom containers and visibility.

- [x] Add one extension kind rather than one kind/switch family per new widget. Measurement takes known dimensions/available-space modes and read-only payload; cache identity includes payload revision or the leaf opts out.
- [x] Define a bounded late-subroot builder: layout/prepaint may build children only inside an explicit query/list subroot. Finalize postorder and parent/child indices once before publishing. Ordinary prepaint cannot arbitrarily mutate an already laid-out ancestor.
- [x] Implement hidden visibility that preserves layout/scroll extent but suppresses paint, hit testing, focus eligibility and semantics throughout the hidden subtree. Keep `display.none` distinct.

**Acceptance:** custom leaf measures correctly under min/max/definite constraints; custom container composes built-ins; changed revision invalidates measurement; phase payload survives both live frames; illegal phase reentry fails; hidden and display-none produce different geometry as specified.

**Gate:** `zig build test -Dtest-filter=api-w08`, layout corpus/golden; live custom ruler/canvas consumer with non-text intrinsic dimensions. No host GPU handle enters the core descriptor.

**Verified W08 (2026-09-29):**

- `zig build test -Dtest-filter=api-w08` passed 26/26, exit 0: intrinsic measurement obeying min, max and definite size in each available-space mode, a revision change that invalidates cached geometry without reusing old payload, one postorder finalization per late subroot, rejection of unbounded child construction and of measure-phase reentry, and hidden versus display-none diverging in geometry, scroll contribution, hit, paint, focus and semantics.
- `zig build fixture` passed 5,524 and `zig build layout-check` matched all 581 golden rows, which is where the layout and visibility changes surface; `zig build lint` reported 0 errors and 0 warnings across 190 files.
- The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- The previously unrun ruler consumer ran on 2026-09-30: `env -u DISPLAY -u WAYLAND_DISPLAY zig build v7 -- --ruler-smoke --shot /tmp/nogui-w08-ruler.ppm` exited 0 through the windowless noapi GPU path. The inspected 954×1044 image shows the custom ruler's line and regularly spaced ticks above the font specimen. `CustomRuler.measure` supplies non-text intrinsic dimensions 240×18; parent stretch supplies the final width. The descriptor contains no GPU handle. The companion `--ruler-smoke --layout /tmp/nogui-w08-layout.txt` command exited 0.
- Current headless recheck: `env -u DISPLAY -u WAYLAND_DISPLAY ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test fixture layout-check -Dtest-filter=api-w08 -j4 --summary all` passed 56/56 build steps, 27/27 tests (20 named W08 cases plus seven anonymous module tests), 5,524 fixtures with zero failures/unsupported, and the unchanged 581-row layout golden. Together with the rendered ruler, this closes the W08 gate; it does not establish native display/DPI coverage.

### W09 — Unified input, focus and pointer capture

**Coverage:** I01, I02, I06, I07, I10. **Depends on:** W04, W08.

**Files:** `event.zig`, `input.zig`, `app.zig`, `component.zig`, `headless.zig`, new `focus.zig`, host SDL event adapter, all direct control and demo input consumers.

**Produces:** complete key/modifier/pointer/scroll vocabulary, dispatch context, stable focus/capture and semantic activation.

- [x] Translate native key down/up/repeat, physical/logical identities, pointer buttons/click count/cancel, scroll units/phases and touch IDs. Add text/composition values now; W12 supplies focused text consumers. Preserve unsupported native gesture distinctions.
- [x] Implement capture/target/bubble and independent propagation/default control, including component handlers. Route wheel once to a consumer or the nearest scrolling default; prevent demo shortcuts from bypassing focused consumers.
- [x] Implement focus/blur/containment, focus notifications, tab groups/index/custom leaves and removal fallback. Capture pointer transitions to a stable target until release/cancel; default click fires once on valid release. Keyboard/a11y activation uses the same action, not synthetic mouse events.

**Acceptance:** nested handlers observe phase order; preventing wheel default stops ancestor scrolling; same-kind reorder preserves owner; removed owner receives cancellation; slider drag out-and-back releases; disabled/hidden controls cannot activate; key-up reaches the consumer; repeat cannot create duplicate text. For touch, test raw lifecycle/cancel and start-target capture; do not advertise an unimplemented recognizer suite.

**Gate:** `zig build test -Dtest-filter=api-w09`; headless press/move/release/cancel replay and actual Todo controls. Update README and old down-activation tests for the explicit semantic change; delete tests of incidental wording rather than re-pin it.

**Verified W09 (2026-09-29):**

- `zig build test -Dtest-filter=api-w09` passed 30/30, exit 0: SDL key, pointer, touch and text translation that keeps physical and logical identity, repeat and committed text distinct, touch IDs surviving cancel without mouse duplication, capture-target-bubble phase order, independent `stopPropagation` and `preventDefault`, exactly one wheel default, focus, tab groups, blur and removal fallback, slider drag out-and-back, and one activation path shared by release, keyboard and accessibility.
- The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Not run: the Gate's actual Todo controls. Every scenario here is a headless or synthesized-event replay.

**Native Todo acceptance (2026-10-01):**

- The mapped `w09-controls-smoke --native --step-ms 6000` completed every external-controller step on owned private X11. No synthetic SDL event or desktop setting change was used.
- Release away from `inc` left the counter at zero. A valid click changed it to one. Slider capture followed an out-of-track move to zero, returned to 0.2503 and stopped after release.
- One held Space delivered one key-down, 19 platform-marked repeats, one key-up and one toggle. Two later discrete presses delivered two key-downs and two key-ups, with one toggle each.
- A real field click bound its own text endpoint. Two native commits inserted exactly `"ok"` into the model and painted label. The run presented 52 frames at 1400x1800, with no retries, resize rebuilds or extent mismatches.
- The controller exited zero after all 19 steps. The surface retired before the platform window, the field's shaped/model owner released, and no allocator or Vulkan validation error was reported. This is X11 input and GPU evidence at 1×, not an Orca or native IME-composition claim.

**Native invocation and image check (2026-10-01):**

- The build step initially discarded caller arguments: `zig build w09-controls-smoke -- --bogus` ran the headless arm and exited 0. It now forwards arguments; the same invocation reaches `main` and exits 1 with `UnknownArgument`.
- `--native --ppm PATH` now saves the presented scene's GPU readback. The fresh external-controller run passed all 19 steps with 50 presentations, zero retries, rebuilds or extent mismatches, two `"ok"` commits, counter 1 and volume 0.2503.
- The parent inspected `/tmp/nogui-w09-native.png`: the focused field contains `ok`, the counter reads 1, the slider is at one quarter and both Todo rows are unchecked. The surface retired before the platform window and `window_count` reached zero.


### W10 — Actions, bindings and keyboard/cursor services

**Coverage:** I03, I04, P09. **Depends on:** W07, W09.

**Files:** create `src/v7/{action,keymap,key_context}.zig`, host `keyboard.zig`/`cursor.zig`; modify App/dispatch, demo shortcut handlers and headless events.

**Produces:** comptime action descriptors with stable names/typed payloads/schema/aliases, dynamic keymap, availability/discovery and layout-aware presentation.

- [x] Register actions once, decode/validate parameters, expose availability and listeners, resolve aliases without cycles, and dispatch through focused context then application scope. Native menus and inspector use this registry.
- [x] Specify binding precedence: user binding over built-in at equal context specificity, nearest eligible context first, latest explicit override at equal rank. Disabled bindings suppress the matching default. Chords use W05 time; timeout/unmatched suffix replay must not lose or duplicate keys/text.
- [x] Expose keyboard-layout name/ID/change, logical shortcut labels and cursor selection/visibility/hide-until-move. Avoid US-layout assumptions; global shortcuts only receive unconsumed events.

**Acceptance:** context overrides and disabled bindings select the documented action, aliases decode the same typed payload, malformed parameters fail, ambiguous chords wait/resolve/replay correctly, layout changes update labels without changing physical-key bindings.

**Gate:** `zig build test -Dtest-filter=api-w10`; live alternate keyboard-layout and cursor smoke, plus configurable Todo shortcut replay.

**Verified W10 (2026-09-29):**

- `zig build test -Dtest-filter=api-w10` passed 40/40, exit 0: aliases and canonical names decoding identical typed payloads, parameter and unknown-field rejection, the nearest eligible context winning while a disabled context blocks fallback, binding precedence, chord timeout and unmatched-suffix replay that neither loses nor duplicates key or text input, SDL reporting a layout change without a native layout name, a physical shortcut label read from the active layout instead of a US key table, and per-window cursor visibility and hide-until-move.
- The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Not run: the Gate's live alternate-keyboard-layout and cursor smoke. The host service tests run under the dummy video driver, which reports a layout change but no real layout name, identifier or cursor.

**Native X11 keyboard and cursor evidence (2026-10-01):**

- The actual `w10-keyboard-smoke` found an inverted native status check: `XkbGetState` returns zero for success. `linux/keyboard_layout.zig` now refuses nonzero status rather than successful reads.
- The consumer now waits for actual SDL pointer-enter and pointer-motion events rather than asserting global cursor state before its window owns pointer focus. Its before-change layout strings are copied into bounded stack storage because `Keyboard.layout()` borrows buffers replaced by the next native update.
- Parent-owned Xvfb `:3`, X11, mapped window: `--video-driver x11 --show-window --expect-identifier us --wait-ms 15000` exited **0**. The private controller moved only that exact owned window's pointer and ran `setxkbmap -layout de` only on that private server. Pointer focus, hide/show and hide-until-move all passed.
- The real layout change delivered exactly **one** callback after 840 ms, generation **0→1**, identity `pc+us+inet(evdev)`/`us` → `pc+de+inet(evdev)`/`de`, and physical scancode **28/29** labels **Y/Z → Z/Y**. No synthetic SDL event was pushed and no user desktop setting changed.
- This establishes the Linux X11 layout/cursor scenario. Configurable Todo shortcuts and other-target native acceptance remain separate.

**Native configurable Todo acceptance (2026-10-01):**

- `direnv exec . taskset -c 3,4 bun /tmp/nogui-w10-native-controller.mjs ./zig-out/bin/v7-demo` exited 0 on owned Xvfb `:4`, X11, GTX 1660 Ti, Vulkan 1.4 and validation layers. The consumer command is `zig build v7 -- --shortcut-native --shortcut-pixels=PATH`.
- Real keys reached the mounted Todo scene through `Application`. Six Tab presses focused `inc`. Context priority, application fallback, user precedence, disabled suppression and override removal produced their exact registered actions.
- The host resolved the 2,000 ms chord at 2,088 ms with no new key. The fallback fired once. Two unmatched suffix rounds incremented the counter once each, then `g h` removed one row.
- Final state: counter 6, two unchecked rows, toggles 2, additions 1, resets 2 and removals 1. The run reported 37 committed/presented frames, 23 balanced down/up pairs, no repeats, text events, retries or overflow.
- The parent inspected the actual 1400×1800 GPU image at `/tmp/nogui-w10-native.png`. The surface retired before the window; close released every window. The complete run reported no validation error.
- This closes the Linux X11 W10 gate with the earlier keyboard-layout/cursor and 40/40 contract evidence. Native OS menus remain W18/P08. Other-target acceptance remains W23.


### W11 — Shared typography and shaped text layout

**Coverage:** T01–T04, T06. **Depends on:** W08.

**Files:** new core `text.zig` contracts; extend `src/v7_text/measure.zig` and `shape_cache.zig` extracted in W01; extract the remaining reusable CPU parts of demo `text.zig`; modify `widget.zig`, `style.zig`, `drawctx.zig`, layout measure and renderer/host text adapter; declare Fontconfig/FriBidi in `devenv.nix` and build where required.

**Produces:** font request/resolution/add/list/metrics, typed inherited style/runs/highlights, immutable shaped layout, paragraph policies and Unicode range conversions.

- [x] Replace untyped two-font IDs with validated font handles/requests. Include weight/style/features/fallback and per-run resolution. Reuse existing HarfBuzz/FreeType cache/storage; add script itemization, bidi ordering and fallback rather than claiming RTL from box writing-direction alone.
- [x] Resolve inherited `TextStyle` and run overrides once. Implement backgrounds/decorations, line height, glyph alignment, no-wrap/flow, clamp and start/middle/end truncation with an explicit suffix. Measurement and paint consume the same shaped result.
- [x] Expose byte↔position, caret affinity and range bounds across wrapped lines; define invalid boundary handling. UTF-16 offsets inside a surrogate pair return an invalid-range error; navigation moves on grapheme boundaries rather than bytes. Interactive ranges use the normal event/action route.

**Acceptance:** multistyle line wraps without losing style; font feature/weight/fallback changes invalidate the right cache entry; RTL mixed text and combining/ZWJ sequences shape and map without splitting encodings; range bounds cover wrapped selection; centered glyphs, middle truncation and exact two-line clamp agree with measured size. Missing font/glyph policy is visible, not an out-of-range table access.

**Gate:** `zig build test -Dtest-filter=api-w11`; real-font headless measurement and offscreen/live text specimen with pinned fonts. Preserve existing cache reuse for unchanged Latin text; do not claim cross-platform pixel identity.

**Verified W11 (2026-09-29):**

- `zig build test -Dtest-filter=api-w11` passed 25/25, exit 0: validated font handles, requests and metrics with an explicit missing-glyph policy, fieldwise overrides that inherit family and fallback, multistyle wrapping that keeps font and decoration, a cache that reuses unchanged Latin and separates generation, weight, features and direction, bidi and extended-grapheme byte/UTF-16 boundaries, RTL start alignment and soft-wrap affinity, and clamp plus start/middle/end truncation with an explicit suffix.
- `zig build fixture` passed 5,524 and `zig build layout-check` matched all 581 golden rows, which is the measurement path this package changes; `zig build lint` is clean across 190 files.
- The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Not run: the Gate's pinned-font offscreen and live text specimen. These tests validate the shaped model, cache policy and boundary conversions, not rendered glyph pixels, and no cross-platform pixel identity is claimed.

**Integration close-up (2026-09-30; acceptance still open):**

- Registered the component tests in the core suite, added the `default_text` hook, and kept root defaults active through `T.draw` rather than only the setup block. Nested scopes restore their caller's defaults.
- Fixed default font resolution field by field. Defaults fill unauthored fields, preserve an authored handle, and cannot revive a handle cleared by an authored family. The two `default_text` regressions and three component-default font regressions failed before the fixes and now pass. The focused commands were `zig build test -Dproduct=core -Dtest-filter=default_text -j1 --summary all` (4/4 including module tests) and `zig build test -Dproduct=core '-Dtest-filter=component default' -j1 --summary all` (10/10 including module tests).
- `zig build run -j1 --summary all` in `examples/consumers/core_only` exited 0 with `core_only: OK`, exercising real App frames, button dispatch and teardown.
- The full current core command, `zig build test -Dproduct=core -j1 --summary all`, failed: 13/15 steps and 1,066/1,071 tests passed. The five failures are two W21 visible-row bounds cases, nested flex baseline propagation, grid baseline alignment, and the complete pinned fixture corpus. These failures were recorded, not investigated or classified as pre-existing, before the halt.
- The external offscreen consumer compiled and initialized the NVIDIA GeForce GTX 1660 Ti, but `env -u DISPLAY -u WAYLAND_DISPLAY zig build run -j1 -- /tmp/nogui-w11-ordinary-caption.ppm` failed during ordinary mixed-script caption measurement with `InvalidWrapWidth`. A temporary diagnostic observed a small negative width where the caption authored only `wrap = .no_wrap`; the cause remains unresolved. The diagnostic was removed. No completed rendered-caption or pixel evidence is claimed.
- Both read-only reviews stopped at the user's request. Their source-derived text-width/ownership and SDL-surface findings remain deferred; none were reproduced or fixed in this close-up. Work is temporarily halted. Do not resume this plan without a direct user instruction.

**Resumed repair evidence (acceptance still open):**

- The unchanged fixture corpus passes 5,524/5,524. The core suite passes 1,080/1,080, and the layout golden matches all 581 rows.
- The external windowless consumer passes 902 checks on the NVIDIA GeForce GTX 1660 Ti. Ordinary caption ink covers 2,513 pixels, with 10 glyph quads and two explicit missing-glyph boxes. The completed image is `/tmp/nogui-native-repair-caption.ppm`.
- The external host consumer reports one idle frame, one worker wake, two total frames, then returns to idle and shuts down. Its macOS adapter reports `ShimUnavailable` on Linux. This is not macOS runtime evidence.
- Host protocol tests pass 436/436. GPU text tests pass 39/39 without the former probe-layout leaks. The complete Python suite passes 126/126 after the noapi provenance digest update.
- The intermediate combined gate passed 1,759/1,762 tests. Calculator display lookup, per-drag snapshot accounting, the W12 smoke selection, W17 compilation, and lint findings still required integration. Passing sub-suites do not close the complete gate.
- Source review found no defect in the surface-adoption ownership chain or successful-only candidate publication. Native presentation, real IME composition, candidate-window placement, and unavailable target runtimes remain unproved. Orca stays off.

**Slider caption repair evidence (2026-10-01):**

- `DrawCtx.slider` now resolves its caption through the widget kind's own default foreground, exactly like every other text-bearing kind: `kindDefaultForeground` returns the slider payload's `color`, which [`src/v7/widget.zig`](../../../src/v7/widget.zig) declares as opaque white. That layer is a DEFAULT and not authorship — an ancestor style, a component `default_text`, an authored `.color` or `text_style.foreground` outranks it, and it never shadows an inherited foreground.
- The same constructor now applies the caller's `text_overflow` and `max_width` through the shared `setTextOptions` before `setInteractionOptions`. A slider caption wider than its control is therefore bounded and truncated instead of wrapping onto a second baseline, and that policy reaches layout and the scene text pass together. Layout measures the same bytes through `widget.sliderVisualLabel` and `LayoutContext.measureSliderContentCached`, so the measured size and the painted one agree.
- Parent run, actual and reproducible: `env -u DISPLAY -u WAYLAND_DISPLAY taskset -c 3,4 zig build run -j1 -- /tmp/nogui-offscreen-slider-green.ppm` in `examples/consumers/offscreen` exited 0 on a real NVIDIA GeForce GTX 1660 Ti under Vulkan 1.4 and reported **930 checks**. Totals: `ink_pixels=88959 glyph_slots=60 rects=42 runs=9 graphemes=41 shapes=15 caption_quads=10 caption_notdef=2`.
- The three sliders on one row report as follows. The ordinary one authors no `.color`, no text option and no component `default_text`, so the kind's own foreground is the only layer that gives its caption a record; it published 21 pens, 19 glyph quads, one baseline and one chrome rectangle. The bounded one declares `.text_overflow = .ellipsis` with `.max_width = 118` over bytes far wider than that cap: 17 glyph quads against its uncapped twin's 28, one baseline each, with its own node box no wider than the declared cap and its painted span inside it.
- The consumer derives all of that independently: it rebuilds each caption from the node's own visual label and published text request through the public `TextService.nodeLayoutIn` seam, keeps only the scene's glyph-slot rectangles that ride that node's own clip and layer at one of its pen origins, and excludes the control chrome (progress and thumb rectangles) from the ink surface, so caption ink is counted inside the boxes the caption's own glyph quads claimed rather than inside a band the audit picked. Solid rectangles are checked at their pixel centres. NO test-only layout export was added to the library for this scenario, and nothing in the audit is re-ticked by it.
- The parent converted the PPM to PNG with `magick` and inspected the actual 640x400 pixels: `Speaker output volume` is visible for the ordinary slider, `Normalization o...` is truncated for the bounded one, and `Normalization output gain level` runs unbounded for the uncapped twin.
- What this evidence is not: it is a windowless frame read back from a real GPU, not a physical window and not an audible result. W11 and W21 acceptance stay open, and no slider is verified through a screen reader. The accessibility bell named in W21's second box is a separate window call with its own implementation and its own native run, recorded below; nothing in this slider evidence says anything about it either way.

**Paragraph pixel and two-frame evidence (2026-10-01):**

- The expanded external `offscreen` consumer exited 0 with **1,016 checks** on the GTX 1660 Ti: `env -u DISPLAY -u WAYLAND_DISPLAY taskset -c 3,4 zig build run -j1 -- /tmp/nogui-w11-paragraph-expanded.ppm`. The parent inspected the actual 640×640 image.
- Ordinary `DrawCtx.label` calls render a centered paragraph clamped to exactly two lines and start, middle and end truncation with the explicit suffix `~~`. The consumer associates each node's own published pens, clip and layer with its submitted glyph quads and readback ink; it does not count unrelated control chrome.
- The clamp published two baselines, 41 quads and a measured height of 44 at line height 22 and wrap width 320. Its ink bounds were `(30,144,261,39)`. The three truncated layouts remained within width 150: 144.02, 147.69 and 142.72; their suffix occupied the first, middle and final layout run respectively.
- A changed second frame renders three clamped lines. After that commit, the consumer rereads the previous frame's original records and layout. The final totals were `ink_pixels=175359 glyph_slots=83 rects=42 runs=9 graphemes=41 shapes=21 caption_quads=10 caption_notdef=2`.
- This is actual windowless GPU evidence. Other-target typography and native editing remain separate acceptance requirements.
- The optional `-Dnative=true run-native -- PPM` arm subsequently passed **1,023 checks** on owned private X11 through `Application`, `noapi.Surface.initSdl` and `NativeFrame`. The exact logical/device extent was 640x640 at 1×; first presentation reported zero acquire retries, resizes, rebuilds or extent mismatches. The same paragraph, mixed Hebrew/combining/ZWJ fallback, captions and second-frame lifetime oracles ran in both arms, and the actual mapped-mode GPU image was inspected.
- Its first compiled runtime exposed a consumer shader lifetime bug: block-scoped defers freed the blit words before `NativeFrame.init` used them. Those words now remain alive through initialization and teardown. The unchanged default arm was run again after the facade changes and passed **1,016 checks**, without a window, surface or SDL dependency.

**Missing-font and current repeat (2026-10-02):** the external CPU-only `--empty-font-registry` arm passed **32 checks** without SDL, a window or GPU: `FontUnavailable` published no tree/generation and shaped nothing; adding the pinned faces recovered through the same App/text service. The current windowless GPU specimen again passed **1,016 checks**, its image was inspected, and `api-w11` passed **40/40**. Native document editing remains separate; missing configured fonts is no longer untested.



### W12 — General editable text, IME and edit actions

**Coverage:** T05, T07, T08. **Depends on:** W09, W10, W11, W18.

**Files:** create core `text_input.zig`; modify focus/dispatch, host text-input adapter, replay parser and a small application-owned input example. Reconcile the existing editor plan as specified below; do not start a Neovim process for an ordinary field.

**Produces:** focused text endpoint, selection/marked range/replacement, native input conversion, caret/candidate geometry and copy/cut/paste actions.

- [x] Register the endpoint from the current committed focused element using stable identity and weak model ownership. Read text/selection and apply replacement through the owning model; App does not acquire its own text buffer.
- [x] Separate physical keys from committed text so printable characters insert once. Implement preedit update/commit/cancel and directional selection. Start/stop native text input on focus, and invalidate candidate bounds after layout/scroll/DPI changes.
- [x] Use W18 clipboard for edit actions; distinguish unavailable/empty/error. Let each consumer choose multiline and read-only policy.

**Acceptance:** paste replaces a selected multibyte range once; preedit replacement/commit/cancel does not duplicate insertion; focus loss clears preedit and stops input; candidate rectangle tracks a wrapped/scrolled caret; ordinary input works without `nvim`.

**Gate:** `zig build test -Dtest-filter=api-w12`; actual Linux IME composition, cancellation, clipboard and focus-switch smoke. A replay alone cannot prove candidate-window placement or native IME behavior.

**Verified W12 (2026-09-29):**

- `zig build test -Dtest-filter=api-w12` passed 32/32, exit 0, two of them in the public-API consumer `examples/parity/text_field.zig`: a physical key inserting nothing while its commit inserts once, preedit commit, cancel and placement inside a selection, read-only and single-line policy, clipboard unavailable, empty and failed kept distinct, per-generation candidate geometry, and native input starting once per focus and stopping on blur.
- The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Not run: actual Linux IME composition, native candidate-window placement and a real clipboard round trip. No X11/Wayland session and no input method were available, so the native adapter is exercised only through its injected driver and the committed-text path.

**Current dummy protocol and clipboard proof (2026-10-01):**

- `zig build w12-ime-smoke -j1 --summary all` exited 0: 28/28 build steps and 88 checks with zero failed.
- The ordinary model-owned field separated physical keys from commits, replaced marked text once, cancelled preedit on focus loss, stopped/restarted SDL input once per focus and published wrapped/scrolled caret rectangles. Foreign-window and unfocused commits left the model unchanged.
- The corrected UTF-16 selection copied exactly six bytes (`" world"`). The real W18 SDL-dummy port pasted and cut that range once each; final text was `"hello worldd愛!"`, with six model replacements and zero calls through the refusing clipboard guard.
- SDL dummy emitted unsupported-touchscreen diagnostics at startup. No window was mapped and no other process's clipboard changed. This is current protocol/ownership evidence, not real input-method composition, candidate-window or shared-clipboard acceptance.

**Complete private native IME proof (2026-10-02):**

- The twelve-phase X11/IBus controller accepted **35 items, zero refusals and 2/2 candidate-window observations**.
- One owned Xvfb/Openbox display, two private buses and one focused XIM context isolated the run. Orca remained off.
- One explicit `libpinyin` engine setter preceded real preedit. A real selection committed `"你好"` once into the ordinary model-owned field.
- UTF-16 marked range `11:13` corresponded to UTF-8 bytes `11..17`. The caret and collapsed selection ended at `13:13`.
- Wrapped text, visible scrolling, hidden-caret suppression and restoration passed. A real owned pointer press cancelled preedit and stopped native input.
- A second real press restored focus and native input. Another composition and attributed candidate window appeared through the same input context.
- The final candidate measured **306×65 at (753,951)** beside anchor **(740,951)**. The parent inspected its own capture and the full field.
- Strict pointer ownership used recursive `XQueryPointer`, not xdotool's window-manager ancestor. The controller restored the original pointer.
- Removing an extra diagnostic Tab preserved the required composition-bearing focus cycle. No acceptance predicate, engine selection or source adapter was weakened.
- Evidence: `/tmp/nogui-w12-real-ime-resume-20261002-focus-cycle/log/`, including `controller.log`, `dbus-monitor.log`, `app.report.log` and `probe-phase11.png`.
- Shared clipboard acceptance remains approval-gated. This run touched neither the user clipboard nor the user input method.

**Read-only/newline boundary repair (2026-10-03):**

- The standalone `zig test src/v7/w12_contract_test.zig --test-filter api-w12` run first failed in read-only cut with an absent clipboard and in CR followed by VT/FF. After repair all **26/26** protocol tests pass; the fixture resets both text and selection between independent cases.
- Cut checks read-only policy before clipboard availability, matching paste. Only CRLF folds into one break. CR+VT, CR+FF, LF+CR and CR+CR retain two breaks for both single-line and multiline consumers.
- A separate actual Session/model/Manager CLI passed all eight independent-pair cases, both CRLF cases, and read-only cut with no clipboard or no writer. `/tmp/nogui-boundary-and-fd-broker-proof-20261003.json` records its exact command and output; it opened no window or GPU and used no native clipboard or IME.
- The serial `w12-ime-smoke w18-dialog-smoke test -Daccesskit-bridge=false -Dtest-filter=api-w12 -j1 --summary all` build passed **73/73 steps and 53/53 total tests**. The freshly compiled W12 dummy consumer passed **88 checks, zero failures**. Native clipboard/IME evidence is recorded separately, not inferred from these counts.

**Current approved private native consumers (2026-10-03):**

- Both controllers used the freshly compiled `486fb11bc9d038e1a2a4e20f6d77e240/w12-ime-smoke`, with owned Xvfb `:4`, private HOME/XDG/buses and Orca/AT-SPI off.
- `node /tmp/nogui-w12-native-clipboard-controller.mjs --i-approve-private-x11-clipboard-source-and-restore --app <binary> --display :4 --title w12-ime-smoke --evidence /tmp/nogui-w12-current-native-clipboard-20261003 --hold-ms 180000`, inside `/tmp/nogui-private-x11-run.mjs`, passed all thirteen numbered steps and five consumer checks. A real selected multibyte paste produced `abX愛Ygh` once; another process read the copy and exact `abX` cut bytes. CLIPBOARD and PRIMARY matched their pre-run baselines after restore and process retirement. The actual consumer capture was inspected.
- `node /tmp/nogui-w12-real-ime-controller.mjs --binary <binary> --display :4 --root /tmp/nogui-w12-current-real-ime-20261003 --hold-ms 300000`, under the same isolated launcher, accepted **35 items, zero refused, 2/2 candidate windows proved**. Real composition, selected multibyte commit, wrapped/scrolling geometry, blur cancellation and composition after focus return passed. Both candidate crops and the final whole-field capture were inspected.
- The initial candidate was **334×65 at (634,895)**; after the real focus round trip it was **306×65 at (753,951)** beside anchor **(740,951)**. The field reports missing-glyph boxes for CJK not present in the pinned face; these runs prove native editing/candidate placement, not a CJK font-coverage claim.

**Scaled non-1× native candidate run (2026-10-05, freshly approved owned fixture):**

- One owned Xvfb `:4` at `1600x2000x24`, `-dpi 120`, with `Xft.dpi: 120` merged onto the owned server's own root `RESOURCE_MANAGER` and read back with `xrdb -query`. The scale is a SERVER-side property the application observes; no environment scale variable and no pushed SDL event was involved.
- The consumer now reports both scales it was missing: `driver: x11 window=2 visible=true observed=640x360 pixels=640x360 display_scale=1.2500 pixel_scale=1.0000x1.0000 image=640x360`. The platform reports **1.25×** and the window's own pixels stay **1:1** with its logical extent.
- `NOGUI_FIXTURE_DPI` refuses a whole-number scale by NAME, because SDL3's X11 backend zeroes `window->scale` for one (`SDL_x11toolkit.c:441-448`) and keeps the window 1:1 with its pixels. An owned display at `192dpi` therefore measures 1.0 in every observable, which a first probe here did measure before the check existed.
- `node /tmp/nogui-w12-real-ime-controller.mjs --binary <binary> --display :4 --root /tmp/nogui-w12-scaled-real-ime-20261005 --hold-ms 240000`, under the scaled owned launcher, exited **0**: **36 accepted items, 0 refused, 2/2 candidate windows proved**. Evidence: `/tmp/nogui-w12-scaled-real-ime-20261005/log/`.
- Anchor arithmetic at 1.25×: caret `(154,40 0x28)` logical → SDL stored `(154,40 1x28)@0` → root anchor `(634,868 1x28)` from window origin `(480,828)`. The XIM server sent a **SPOT** at `(634,896)`, which is the stored rectangle's bottom edge (`40+28`), and the candidate window appeared at exactly that point: **370×69 at (634,896)**, `distance_from_the_anchor=0,0`, `placement=below the anchor`. After the real focus round trip: **336×69 at (753,952)** against anchor `(740,952)`, `distance_from_the_anchor=13,0`.
- Both candidate captures were inspected and both are real libpinyin lists: `ni hao` → 你好/你好吗/你/尼/呢, and after the round trip `ni` → 你/尼/你们/呢/泥. Commit replaced UTF-16 marked range `11:13` (UTF-8 bytes `11..17`) exactly once; a real pointer press cancelled the preedit and stopped native input; the post-return composition produced the second candidate through the same input context.
- **The scaling finding, which is the point of this run:** SDL3's X11 backend reports the platform's content scale but does not scale the window's pixels by it, and it hands the XIM server the text-input rectangle **unscaled** (`SDL_x11keyboard.c:815-816`). So on X11 the application's logical caret area, the X root pixels and the device pixels are one space at ANY reported display scale, and the candidate window followed the anchor with zero offset at 1.25×. A non-1× display scale is therefore NOT by itself evidence of a scaled candidate anchor, and a controller that multiplied its probe band by the display scale would have probed the wrong place.
- CJK stays the caller's mechanism and nothing was bundled: the pinned face shaped **2 of 13** glyphs as notdef and the run reported that rather than calling it text. The BYTES are proved; the PICTURE of those two characters is not.
- Unresolved: this is one fractional scale on X11 with no mid-run transition. SDL3's X11 path has no true HiDPI window scaling to exercise, so a *transition* (1×→1.25× observed by a running client) remains established only by the W07 niri run, and no non-1× Wayland or other-target candidate anchor is claimed here.
- Ordinary W18-backed editing, multiline/read-only policy and native IME acceptance are established on this private Linux X11 fixture. The Neovim RPC/grid consumer remains part of the separate embedded-editor integration; no adapter or remote-grid acceptance is claimed by these ordinary-field runs.

**Approved scope reconciliation (2026-10-03):** the user selected **Keep editor
work separate**. Neovim committed-text queueing, the host preedit overlay and the
RPC/grid clipboard consumer remain requirements of the separate embedded-editor
plan. They are not W12/W18 parity acceptance. No editor implementation is claimed.

All three W12 checkboxes are complete. The W18 clipboard backs ordinary fields
through one App-owned manager. Unavailable, empty and error outcomes stay distinct.
Consumers select their multiline and read-only policies before endpoint registration.
The protocol regressions, shaped-field consumer and private X11 runs above verify these paths.

All five ordinary-field acceptance clauses are observed on the private X11/IBus
fixture. Selected multibyte paste, preedit replacement/commit/cancel, focus loss,
wrapped/scrolled candidate placement and input without `nvim` passed.
These runs do not establish CJK font coverage or another target's native input.

Count reconciliation, so a reader does not read two numbers as a contradiction: the
**53/53** total above belongs to the serial run taken before the editable-field
ownership cutover, and the **52/52** figure recorded under W25 belongs to the
`api-w12` gate after that cutover. Both runs stand as recorded; the later count is
the current one.




### W13 — Public paint and canvas

**Coverage:** R01–R04. **Depends on:** W08.

**Files:** create `src/v7/{paint,path}.zig`; modify `style.zig`, `drawcmd.zig`, `drawctx.zig`, `src/v7_render/{root,renderer,render_9slice}.zig` and the affected shader/material definitions; migrate demo-only paint emission.

**Produces:** frame-owned paint list, path builder/canvas, authored/scene color types, backgrounds/effects and affine render transforms.

- [x] Support path moves/lines/quadratics/cubics/arcs/close, fill rules, strokes and dashes, with explicit tessellation/error/capacity behavior. Custom prepaint supplies final bounds to the canvas; no retained raw command-buffer handle.
- [x] Add two-stop gradient angle/positions, palette/theme values, pattern fills, independent corner radii, border styles, shadow arrays with color/offset/blur/spread/inset and primitive opacity. Remove accepted-but-ignored style values during cutover.
- [x] Apply render transforms and clips in a documented order. Preserve paint/layer order, rectangular clipping, Oklab conversion and noapi translation. Replace assertion-only rich-paint/material exhaustion with typed failure or implemented growth/eviction policy.

**Acceptance:** paths, asymmetric corners, dashed borders, inset/outset shadows, pattern/gradient direction and opacity produce the intended offscreen pixels; transform does not silently alter layout/hit boxes; old/current paint data remain valid; capacity exhaustion is observable and does not corrupt later frames.

**Gate:** `zig build test -Dtest-filter=api-w13`; real noapi offscreen image comparisons plus visible paint specimen. Pixel checks use fixed backend/fonts and tolerances at antialiased boundaries, not source-text assertions.

**Verified W13 (2026-09-29):**

- `zig build test -Dtest-filter=api-w13` passed 22/22, exit 0: path curves, arcs and close under affine with bounded window geometry, evenodd differing from nonzero on nested outlines, dash phase across corners with explicit tessellation capacity errors, canvas bounds taken from prepaint, gradient direction with independent radii and border sides, inset and outset shadows with separate geometry and primitive opacity, pattern fills with separately converted colors, and scene lowering that exhausts materials yet still lets a later complete scene render.
- `zig build fixture` passed 5,524 and `zig build layout-check` matched all 581 golden rows, covering the geometry changes; the full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Not run: the Gate's real noapi offscreen image comparison and visible paint specimen. These tests lower paint to scene records on the CPU and compare no pixels.

**Renderer root re-export repair (2026-10-01):**

- The gap was found by making the public renderer consumer NAME the type it already received. `examples/consumers/renderer/main.zig` declares `const lowered: render.Lowered = try render.lowerPaint(...)` instead of letting the result stay anonymous, so a consumer that wants the return type in its own signature now meets a compile error rather than a silent gap. Red: that exact line failed with `root has no member Lowered`, and no other failure preceded it.
- Green is one line of source, `pub const Lowered = facade.Lowered` in [`src/v7_render/root.zig`](../../../src/v7_render/root.zig) immediately after `MaterialRange`; `LSP references` on `Lowered` reported the two pre-existing references and no third declaration. Nothing about the lowering itself changed: `lowerPaint` still allocates nothing and still writes into the caller's own scratch.
- The consumer then ran: `env -u DISPLAY -u WAYLAND_DISPLAY taskset -c 3,4 zig build run -j1 --summary all` in `examples/consumers/renderer` exited 0 with 6/6 build steps and printed `renderer: OK rects=3 materials=2`. Its pre-existing colour, border, material-slot and Oklab assertions passed unchanged, so the re-export did not perturb the lowering. The run is CPU-only: no SDL, no display, no Vulkan loader and no GPU.
- The lifetime rule that makes the type safe to name is the caller's, not the library's: `Lowered.rects`, `.materials` and `.curves` are BORROWED prefixes of the scratch slices the caller passed in, so they stay valid exactly as long as that scratch is untouched, and the next `lowerPaint` call overwrites it from the first byte.
- Scope: this closes the named-return-type gap only. No W13 box, acceptance scenario or audit row is ticked by it, and the W13 image-comparison gate above is still unrun.

**Actual canvas pixel proof and consumer repair (2026-10-01):**

- The first actual GPU run reported 369 passed and 11 failed. The failures came from incorrect consumer expectations and shared path commands.
- The consumer now uses independent outlines and canonical Oklab color values. Probes follow the authored corner order and actual shadow geometry.
- Border contrast uses all three Oklab channels. The evenodd hole equals the clear, while the nonzero hole remains filled.
- An added antialiasing probe first failed because it addressed a solid disc pixel. The corrected apex probe measures 0.75 coverage, with clear immediately above.
- `direnv exec . env -u DISPLAY -u WAYLAND_DISPLAY VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation taskset -c 3,4 zig build w13-canvas-smoke -j1 --summary all` exited 0. The environment also supplied the declared validation-layer directory through `VK_LAYER_PATH`.
- Result: **386 passed, 0 failed**, 19/19 build steps. Vulkan 1.4 used the NVIDIA GeForce GTX 1660 Ti.
- The actual 640x560 framebuffer was inspected. It shows distinct fill rules, curves, gradients, opacity, transforms, shadows, patterns and asymmetric borders.
- No production renderer or shader changed. Pixel tolerances remain unchanged, and the complete run contains no VUID.
- This supersedes the earlier unrun pixel gate. Fresh integrated capacity verification remains part of the final gate.
- The mapped `--native` arm then passed **430/430** on the same GPU through public `Application`, `noapi.Surface.initSdl` and `NativeFrame`, at an exact 640x560 logical/device extent. Its second frame changed only the authored corner record; old path/dash/shadow data and white pixels survived while current red pixels and vacated clear pixels matched. The resulting GPU image was inspected.
- The first native run exposed an invalid free after its 430 checks: the consumer discarded `ArrayList` capacity and freed logical slices. `PaintCopy` now retains the lists themselves, without an added allocation/copy. The corrected run held the mapped window for 1,000 ms, exited 0, and had no VUID or allocator failure.

**Current capacity and independent paint proof (2026-10-02):**

- `direnv exec . env -u DISPLAY -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation zig build w13-canvas-smoke -j1 -- --exercise-capacity /tmp/nogui-w13-capacity-windowless-green.ppm` passed **443/443**, exit 0.
- The corresponding private-X11 `--native --exercise-capacity /tmp/nogui-w13-capacity-native-green.ppm --hold-ms 0` run passed **482/482**, exit 0. Both 640×560 GPU images were inspected on the GTX 1660 Ti.
- Each route refused the overloaded frame with `MaterialCapacity`, canceled recording without submission, and recovered on the same material-ring slot and target. The windowless arm measured 836 authored records against the 768-slot rich-material partition.
- New independent probes cover stops at 0.25/0.75, two distinct colored shadow lobes, palette/sRGB twins and a render-only translated element whose committed hit box remains at its authored position.
- The first run failed the vacated-box oracle: the strip row's unauthored fill painted the default container color. Authoring that row with `clear_fill` made the original tight oracle pass; no renderer, shader or tolerance changed.



### W14 — Assets, images, SVG and external frames

**Coverage:** R05–R08. **Depends on:** W05, W07, W13.

**Files:** create host `assets.zig`, `image.zig`, `svg.zig`, `frame_source.zig`; core value contracts and image custom element; renderer texture registry/retirement; replace demo SVG/XML and image upload routes; update dependencies in build/devenv.

**Produces:** asset key/source/loader/cache, decoded images, asynchronous image view, SVG adapter, generational textures and external-frame lifetime contract.

- [x] Implement embedded bytes, file, URI/HTTP and application loader sources. Deduplicate concurrent loads; expose pending/ready/error, removal/invalidation, custom cache policy and byte-budget eviction. Version completions so invalidated or destroyed owners cannot receive stale content.
- [x] Implement intrinsic/aspect/object-fit, grayscale, loading/error/fallback content and animated image deadlines through W05. Frames and GPU submissions pin decoded/uploaded resources; raw slot reuse cannot change a live image.
- [x] Use **librsvg/Cairo** for SVG documents, including groups, transforms, basic shapes, curves/arcs, fill/stroke and viewBox. Load bytes with `rsvg_handle_new_from_data`, render a chosen viewport with `rsvg_handle_render_document`, and handle intrinsic-size-unavailable separately. Raster cache key includes viewport/DPI/style; monochrome tint is explicit. Keep programmatic GPU paths in W13. Remove the incomplete demo parser, not merely export it.
- [x] Define an owned frame descriptor with dimensions, pixel format/planes, alpha/color metadata, release callback and presentation timestamp. Implement CPU upload first and native import only through a real noapi-supported adapter. Expose unsupported import formats; do not promise zero-copy everywhere or add a media player/decoder requirement.

**Acceptance:** duplicate requests share one load; removal during load cannot resurrect stale content; canceled/failed loads release bytes; two frames keep an evicted texture alive until retirement; object fit and animation timing work; a full SVG specimen exercises currently skipped commands/groups; external frame replacement releases the old frame only after use.

**Gate:** `zig build test -Dtest-filter=api-w14`; actual image/SVG/animated-frame host specimen and noapi offscreen output. Use local HTTP fixture bytes, not an unreliable public URL. SVG external-resource policy is bounded to explicitly supplied resources; no ambient network/file loading.

**Dependency evidence:** local librsvg headers `include/librsvg/rsvg.h:881–947,1104–1118` and `rsvg-cairo.h:160–188` confirm intrinsic-size and viewport-render APIs. No hand-written full SVG parser is planned.

**Verified W14 (2026-09-29):**

- `zig build test -Dtest-filter=api-w14` passed 48/48, exit 0: concurrent requests sharing one load, removal during a load, invalidation, local HTTP fixture bytes plus refusal without a transport, a file key that escapes its root, pinning and byte-budget LRU eviction, object fit and alignment, two frames keeping an evicted texture alive until retirement, the external frame descriptor's replacement, backpressure and stop lifetimes, the librsvg intrinsic-size and viewport path, and the BMP, QOI, PNG, JPEG and PPM decoders with their CPU upload strides.
- `zig build lint` reported 0 errors and 0 warnings across 190 files, and the full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Not run: animated-image frame deadlines through W05 have no test, so that box stays unticked. Fit, grayscale, pending/failed fallback content and texture pinning are covered; the animated deadline is not.
- The Gate's live specimen ran for real, through the new smoke binary `src/v7_demo/w14_asset_app.zig` and step `zig build w14-asset-smoke`, on the same live niri Wayland desktop recorded under W07. It opened a real 480x260 window (`video driver: wayland`), committed 4 presented frames, drove the mounted root 4 times, and closed the window to `window_count=0`. `verdict: passed=49 failed=0`, exit 0, no leaks.
- What the run observed, in the binary's own words: embedded bytes decoding to the authored 2x2 image with its color intact; a real 68630-byte file on disk through the rooted file source plus an escaping key refused as `AccessDenied`; two requests for one app key running the loader once and both reading the same bytes; a load handle reporting `pending` then `ready` with an `accepted` publication; a byte budget of 40 evicting the least recently used entry and keeping the cache inside the budget; an invalidation bumping the version and forcing a re-read that served the new body; three pushed frames all reaching an `AnimatedSequence` with a derived 120 ms wrap period, every descriptor returned to its source, `outstanding=0`, and heap slots 0/1/2 that are the bindless indices rather than the host registry's own bookkeeping; four clock readings selecting distinct frames with the period wrapping to the first; a pinned registry slot still alive three frames after retirement; and the element's own primitive through the public `PaintWriter` for a live slot, a full grayscale amount reaching the paint record, a later clock reading moving to the next frame, and a stale generation painting the pending fill.
- PIXELS, not element probes. The scene is rendered through `v7_render.Renderer` into an offscreen `rgba32_float` Oklab target, blitted to the swapchain with the Oklab-to-sRGB shader, and the target is copied back and read after the queue is idle. The readback centre pixel matched the authored color the binary itself converted from the authored sRGB: `L=0.6280 a=0.2249 b=0.1258` for frame 0 and `L=0.8664 a=-0.2339 b=0.1795` for frame 1, both within 0.02 of the authored values, with chroma 0.2578 above the 0.05 floor. A full grayscale amount on the same frame read `L=0.6280 a=0.0000 b=0.0000`: chroma below 0.01 with the Oklab lightness unchanged within 0.02, which is the Oklab-chroma-removal contract rather than a CPU byte conversion. A later clock reading read back frame 1's values, so the frame switch is visible in the pixels.
- The heap-recycle half ran too: releasing a heap slot moved its generation 1 to 2, and an element probe holding the OLD slot with the heap's current generation emitted the pending fill instead of sampling a freed descriptor.
- This run found and fixed three real production defects, all reproduced here rather than inferred. First, `AssetManager.invalidate` removed the cache entry under the POST-bump generation, which hashed a version nothing was ever stored under, so the bytes stayed resident until unrelated pressure evicted them; it now retires the version that actually loaded, hands the bytes back when nothing is pinned, and keeps them alive-but-unserved until the last `unpin` when a pin is live. The cache test now pins that byte count, and a new test pins the pinned-invalidation lifetime. Second, `FileSource.load` copied `File.Reader.interface` into a local, and that vtable recovers its parent with `@fieldParentPtr("interface", …)`, so the read dereferenced a fabricated parent and segfaulted at address 0x78 on the first real file read; the reader now stays in place. Third, the readback copy was recorded BEFORE the color-output-to-transfer barrier, so it copied the cleared attachment and every arm read `L=0.0000 a=0.0000 b=0.0000`; the barrier now precedes the copy.
- Two claims in this record are deliberately narrow. The window is one window, one driver, one machine and one compositor. And the animated deadline through W05 is still untested, so that box stays unticked; this run proves the element's frame selection and the rendered pixels, not a W05 wake schedule.

**Current native image/deadline and SVG proof (2026-10-01):**

- The expanded real local HTTP fixture fetched exactly twice, served exactly twice and satisfied its repeated request from cache. Its serving `Io.Group` is canceled and awaited before the listener retires; the borrowed transport and context are restored.
- The first native run reproduced the host overwriting a caller/image wake with an absent scalar deadline. The host now merges scalar demand transiently; its 65/65 affected regressions cover no scalar, earlier scalar, cancellation, hidden windows and failed-paint retry.
- The image consumer published the previous draw's timestamp, omitted its capture pointer, reused captured slots and stopped before the terminal wake. It now publishes the current drawn element, captures each wake independently and waits until its last request retires. Actual wakes at **61, 123 and 183 ms** each rendered the authored color, committed exactly three frames and then committed zero during the 200-ms idle watch.
- The complete mapped X11 consumer passed **102/102**, including contain/cover/fill pixels, pending/failed fallback colors, grayscale and slot-generation retirement. On 2026-10-02 the expanded 160×68 SVG passed all **11 CPU and native GPU probes**: Q/T and C/S fill/stroke, group transforms, both arc flags, local `use` and transparency. The CPU-only arm passed **43/43**. Surface retirement preceded the platform window; Session teardown followed Application task-wake unregistration.
- Current `zig build test -Dtest-filter=api-w14 -j1 --summary all` passed **80/80**, 57/57 steps. Failing-before/passing-after regressions cover mapper-refusal double-free, stable pinned addresses across rehash, pinned-key replacement, every allocation failure in `put`, LRU admission, growing/shrinking replacement and budget refusal without eviction.
- `FrameRequests` remains caller-owned per window. Publishing borrows sequence storage; owner removal must `retire` before freeing it. Publish from the current draw and clock and merge its demand into the existing host loop. Neither the source nor the host silently installs another scheduler or prunes requests.


### W15 — Scrolling, responsive queries and virtualization

**Coverage:** L05–L07, L10. **Depends on:** W05, W08, W09.

**Files:** create `src/v7/{scroll,container_query,uniform_list,list}.zig`; modify late-subroot layout/finalization, ScrollState consumers and headless queries.

**Produces:** stable scroll handle, bounded post-layout branch, uniform and variable-height list state and item scrolling.

- [x] Expose viewport/content extent, clamped offset, reveal and programmatic scrolling without giving callers pointers to a previous tree. Keep wheel/default behavior in the router.
- [x] A query's style determines its own size; late-built children cannot resize that query or its ancestors. Build/layout its subroot once per transaction and reject recursive phase cycles.
- [x] Build only visible plus overdraw uniform items. Add variable-height prefix-sum storage, stable item keys, height estimates/measurement revisions, splice/reset invalidation, top/center/bottom/nearest reveal, logical anchor and end-follow policy.

**Acceptance:** independent nested queries switch at a declared width boundary; a million-item model allocates/builds only viewport-bounded nodes; insert/remove/remeasure above the viewport preserves the anchor; scroll-to-item and end follow remain correct as estimates become measured sizes. Focused items leaving the materialized range follow an explicit focus/removal policy, not a stale index.

**Gate:** `zig build test -Dtest-filter=api-w15`; live large uniform and mixed-height lists, resize and mutate while scrolled. Record built-item count and allocation volume as a function of viewport, not a claimed FPS target.

**Verified W15 (2026-09-29):**

- `zig build test -Dtest-filter=api-w15` passed 33/33, exit 0: clamped scroll commands and reveal on both axes, stable handles that reject cross-window, retired and non-scroll targets, independent nested scrollers, queries that branch at a measured width and cannot resize themselves or an auto-sized ancestor, recursive phase entry rejected, and uniform and variable-height million-item lists with anchor, end-follow, estimate-revision and focus policy.
- `zig build fixture` passed 5,524 and `zig build layout-check` matched all 581 golden rows, covering the post-layout branch; the full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- The Gate's live half ran for real, through the new example `examples/parity/list_live.zig` and step `zig build run-parity-list-live`, which opens a real SDL3 window through `nogui_host` with `.gpu_surface = true` and drives the two lists in a mounted `App`.
- Built-item counts as a function of the viewport, from the run's own output: at 900x600 the uniform list built 35 rows and the mixed-height list 31, with 1645163 bytes in 42 allocations for the first frame; after a real resize to 640x280 while scrolled, 18 and 16 rows. The frame cost therefore tracks the viewport, not the model: the uniform list holds 200,000 records and the mixed list 20,000, and neither frame built more than 36 rows.
- Mutating while scrolled. An insertion above the viewport moved the anchor key 201 to index 201 — the key follows the record, the index shifts — and a remeasure above the viewport held that same anchor key with its screen offset at 0.0. End follow built 15 rows and put the newest index 20002 inside the built range 19989..20004, so the newest record is on screen at the end of a 20k-row model.
- Focus and lifetime. A focused row scrolled out of the built range yielded a blur and `focusedKey() == null` rather than a stale index. The tree one frame back stayed readable at 71 nodes and still answered with the geometry it committed, and the App named it as the previous tree.
- This run is a REAL WINDOW and a REAL VIEWPORT change, but it stops at the public boundary for pixels: the tree-to-scene submission stage and `nogui.GpuEndpoint` construction are still demo-owned, so this example never calls `markPresented` and the run says so in its last line. That is a named gap, not a passing result, and no claim about rendered virtualization is made from this run.
- The run also found and fixed two real defects. `host.ManagedWindow` was named in the host frame callback's own signature but was not exported from `nogui_host`, so no consumer could write that callback; it is exported now. And the list established its scrollable extent with a spacer sized BEFORE the row visit that measures rows, so the committed content was always one measurement behind the geometry state and a follow-to-end landed on an offset the scroll host clamped away; the visit now runs first and the spacer is sized from the settled extent.

### W16 — Overlays, drag-and-drop and tooltips

**Coverage:** L08, I08, I09. **Depends on:** W05, W09, W10, W13.

**Files:** create `src/v7/{overlay,drag_drop,tooltip}.zig`; modify prepaint, paint/hit ordering and native-drop translation from W18.

**Produces:** stable anchored/deferred overlay records, flip/snap/margins, clip policy, typed internal drag ownership and delayed tooltip lifetime.

- [x] Resolve anchors from current visual geometry after layout. Link paint priority and hit order; specify inherit-clip versus window-overlay escape. Modal consumers use focus scopes and restore a surviving prior focus target.
- [x] Start a drag after the configured threshold, retain its payload outside frame arenas, route enter/move/leave/can-drop/drop/cancel and release once. External paths remain external data, not trusted commands.
- [x] Implement delayed/hoverable tooltip content, owner-removal cancellation, keyboard description and suppression while the owning interaction is invalid. Reuse W05 timers, not a tooltip scheduler.

**Acceptance:** popup follows a scrolling anchor and fits viewport edges; topmost painted overlay wins input; clip escape is intentional; disappearing anchors dismiss; rejected/external/canceled drops cannot invoke success; leaving and reentering tooltip bounds respects delay and cancels obsolete timers.

**Gate:** `zig build test -Dtest-filter=api-w16`; real popup/drag/tooltip specimen, including keyboard focus return and drag cancellation outside a window.

**Verified W16 (2026-09-29):**

- `zig build test -Dtest-filter=api-w16` passed 20/20, exit 0: overlays that follow a scrolling anchor, flip and snap at viewport edges, dismiss when the anchor vanishes, honour inherit-clip versus window escape, and take overlapping input by paint order; modal focus restoring only a surviving prior target; drags that start at threshold, survive a replacement frame and release their payload exactly once on reject, cancel and stop; tooltips that reset delay on leave/reenter, follow a hoverable move and cancel when the owner is removed.
- `zig build layout-check` matched all 581 golden rows, and the full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Not run: the real popup/drag/tooltip specimen, including drag cancellation outside a window.

**Current paint/visibility proof (2026-10-01):**

- Core `api-w16` passed **26/26**. The real Vulkan `w16-paint-smoke` passed **170/170** across 11 GPU images; all images were inspected.
- Priority and equal-priority registration govern backgrounds, text, controls, custom paint and nested placement independently of builder order. Failed staging retains prior routing.
- Registered-but-unplaced content loses placement paint metadata, remains hidden from ordinary paint, total hit-testing, focus and semantics, and never receives an overlay band. Placed descendants and ordinary underlay content keep their own visibility.
- The real native menu/drag/tooltip sequence remains a separate acceptance item; this pixel proof does not close its focus-loss or platform-event requirements.

**Current native acceptance (2026-10-02, private X11):**

- The real SDL/noapi menu specimen completed all **15 interaction steps and 98 assertions**, presented **86 GPU frames**, reported zero acquire retries and exited 0. The earlier core 26/26 and offscreen 170/170 evidence remains valid; it is not substituted for this native input run.
- A real click activated the menu once. Scrolling moved its anchor and popup from y=39 to y=19. The actual delayed tooltip won overlapping input and paint while an uncovered menu band remained visible. Escape restored File focus; moving focus to the owned auxiliary window cancelled the drag without invoking success.
- Rejected, accepted and cancelled drags released each retained payload once. Leave/reentry and owner removal cancelled obsolete tooltip delivery. The placed menu item was clicked at its painted coordinates, not its original builder coordinates.
- Inspection of the closing capture exposed the old 60×18 tooltip background overflowing its full description. The specimen now fits that unchanged description in a 240×22 single-line box; the corrected closing image was inspected, and the complete 15-step run remained green.
- The auxiliary window and display connection retired once and the application exited cleanly. This closes W16's specified native specimen on Linux X11; it does not claim a Wayland, macOS or Windows native run, or external file-manager ingress under W18.


### W17 — General animation

**Coverage:** L09. **Depends on:** W05, W08.

**Files:** create `src/v7/animation.zig`; modify App frame demand, DrawCtx helpers and existing hover/press easing consumers.

**Produces:** keyed duration/easing/sequence/repeat animation, sampled values and reduced-motion policy.

- [x] Store timeline identity/start state with the stable owner; sampled values and paint remain frame-local. Define restart, interruption and owner removal.
- [x] Feed the earliest active animation deadline into W05. Completed one-shots stop waking; reduced motion chooses the documented static endpoint and schedules no decorative animation.
- [x] Reuse the timeline for current hover/press feedback while preserving its visible easing behavior, except for the deliberate click-timing cutover in W09.

**Acceptance:** controlled timestamps prove start/mid/end/easing/repeat/sequence and interruption; no completed or removed animation requests frames; two windows do not share animation state accidentally.

**Gate:** `zig build test -Dtest-filter=api-w17`; live animation completion followed by idle host, then reduced-motion mode with no decorative frame loop.

**Verified W17 (2026-09-29):**

- `zig build test -Dtest-filter=api-w17` passed 18/18, exit 0: sequence, repeat and interruption starting at the sampled value, explicit restart from the authored start, owner retirement and reorder keeping only live widget generations, two window registries refusing cross-window starts, reduced motion snapping a repeat to its final step without looping, deadlines that include a terminal frame, and hover/press easing that preserves the previous one-pole response.
- The W05 demand tests supply the other half of this contract, and the full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- The Gate's live half ran for real, through the new smoke binary `src/v7_demo/w17_anim_smoke.zig` and step `zig build w17-anim-smoke`, driving the host as an external loop and reading the value back out of the draw code rather than from the driver. Every number below is printed and then checked, and a mismatch ends the run, so none of them is a claim without a comparison.
- Phase A, reduced motion off. A two-step sequence x2 published 38 frames over a 608 ms span and the drawn value reached exactly 20.00000, the authored endpoint. After it, the host settled in 8 iterations with `published_frames=0` and `demand_active=false`: a COMPLETED one-shot requests no further frames. An interruption continued from the SAMPLED value, 0.07573, and ended at 0.00000 in 18 frames, then settled in 8 iterations with 0 published frames. A forever repeat with the gate raised in flight painted 6 live frames reaching 9.60000, then the next frame snapped to the authored endpoint 20.00000 and the host settled with 0 published frames.
- Phase B, the same forever repeat with reduced motion on. The preference read back as `reduce`; the animation painted exactly 1 frame, the endpoint, and the host settled in 64 iterations with `published_frames=0` and `demand_active=false`. That is the whole "no decorative frame loop" claim observed rather than asserted. Lowering the gate on the parked repeat resumed it: 20 frames reaching 13.60000; raising it again parked it in 1 frame, and the host settled with 0 published frames.
- Totals for the run: 92 published frames, 1472 ms of clock, `closeWindow=true`, `Application.deinit` clean and `Session.deinit` accepted.
- What this run does NOT establish: the two-window half stays with the test filter, and the recorded `video driver: <null>` is this headless configuration's honest answer rather than a claim that a real window server was driven. The frame counts are this machine's; they are recorded as counts, not as a rate.

**Stable deadlines and presented verification (2026-10-01):**

- A new regression first failed: after presenting at 0 ms, querying demand at 12 ms returned 28 instead of the owed 16. A later clock read moved the same unpresented frame forward again. Active lanes now anchor maximum inter-presentation spacing to `presented_ms`, not each query.
- The affected core filter passes **16/16**. Host deadline regressions separately pass **65/65**, covering caller/image deadlines with no scalar lane, earlier scalar work, cancellation, hidden windows and failed-paint retry. Host scheduling merges scalar demand transiently and leaves the external deadline in its own field.
- `zig build w17-anim-smoke -- --native --ppm PATH` on owned private X11 passed **92/92** independent frame pixel comparisons and presented all 92 submissions at 480x320, with zero acquire retries, rebuilds or extent mismatches. Completed, interrupted and reduced-motion phases then recorded zero idle submissions. Endpoint, Application and Session teardown succeeded. This adds native evidence; it does not replace the dated external-loop record.

### W18 — Desktop services

**Coverage:** P05–P08, P10. **Depends on:** W07, W10.

**Files:** create host `clipboard.zig`, `dialogs.zig`, `menus.zig`, `open_url.zig`, `preferences.zig` and Linux provider adapters; add only value/service contracts to core; build/devenv declarations.

**Produces:** shared clipboard, async prompts/path dialogs, URL/drop ingress, menu/action bridge, desktop preferences and resource-path utilities.

- [x] Clipboard supports text, image and typed metadata items with declared ownership; Linux primary selection is separate. W12 fields call this one implementation.
- [x] Use SDL for supported primitives and Linux portal/D-Bus providers for dialogs/open/reveal as applicable. Expose select-many, files/directories/filter modes only where implemented; cancellation is not an empty successful file list. Parent dialog lifetime follows the window handle.
- [x] Queue launch URLs until the app handler exists; implement incoming file-drop phases and explicit URL/scheme operations. Route enabled/checked/native menu and system actions through W10; no implicit in-app replacement for a requested native global menu.
- [x] Expose appearance/button layout/scrollbar/thermal/compositor observations and bundle/auxiliary executable lookup. Reduced motion may be application-configured when no backend signal exists; do not invent GPUI system-locale parity.

**Acceptance:** clipboard item lifetime survives caller return; canceled dialog leaves app state unchanged; owner closing before dialog completion is safe; menu enable/check/action updates follow focused context; launch URL delivery occurs once; unsupported preferences are optional rather than fabricated defaults.

**Gate:** `zig build test -Dtest-filter=api-w18`; Linux X11/Wayland clipboard/primary/dialog/menu/URL smoke with explicit external-action approval. Use portal cancellation and provider-unavailable scenarios as well as success.

**Verified W18 (2026-09-29):**

- `zig build test -Dtest-filter=api-w18` passed 32/32, exit 0: clipboard items and offers that own every MIME byte, absent text distinct from empty text, file-dialog cancellation distinct from an empty selection, invalid filters rejected before any native call, unapproved launches that never reach a provider, callbacks after parent close and after teardown, one-shot URL ingress, menu enablement following the focused context, and desktop preferences and auxiliary lookup under the dummy video driver.
- The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Not run: X11 and Wayland clipboard, primary selection, dialog, menu and URL smoke. No live session was used and no external action was approved, so every provider path here is an injected fake or the dummy video driver.

- The provider-unavailable half ran for real, through the new smoke binary `src/v7_demo/w18_dialog_smoke.zig` and step `zig build w18-dialog-smoke`. The file-dialog branch runs in a child process of the same binary whose environment names no session bus, so the real portal adapter refuses before it reaches the bus. The child reported `session_bus_available=false`, `video driver dummy`, `launched pending=1`, then `outcome=unsupported pending=0 rounds=2` and `verdict: an absent portal reports unsupported`, and exited 0. That is the provider-unavailable scenario the Gate asks for, exercised against the real provider rather than a fake.
- The run's own limits are stated in its output rather than glossed: `clipboard half: not run, no --authorize-clipboard-mutation was given`, and `not run: a real file chooser dialog, an external URL launch, and the Secret Service credential store; each needs an operator's approval`. Compiling and running this step mutates nothing the user owns.
- This run also found and fixed a real library defect. `readItem` passed the pointer-to-pointer SDL returned from `SDL_GetClipboardMimeTypes` straight to `SDL_free`; the wrapper exposes the result as a slice, so the allocation is the slice's HEAD, and freeing the outer pointer passed the wrong address to SDL_free. The free now casts the array itself.
- What this run does NOT add: cancellation and success through a real portal are still unobserved, because a real file chooser needs a person at the keyboard; the clipboard half is still unrun, because it overwrites a resource the user owns and the operator has not authorized it; and the menu, URL and preferences halves have no live run at all. All of those stay open below.

**Private approved W18 native evidence (2026-10-02):**

- The approved clipboard arm ran only on owned Xvfb `:4` with private HOME/XDG and no user bus. Real text, one 1×1 PNG, typed JSON metadata and whole-item restore passed; PRIMARY was exercised separately. This does not establish Wayland or macOS Find-pasteboard behavior.
- A real GTK backend and XDG portal frontend ran on a new private bus for each chooser case. After the portal reply ownership repair, `direnv exec . zig build test -Dtest-filter=api-w18 check -j1 --summary all` passed **99/99 steps and 54/54 tests**. The previously undiscovered portal tests are now included by the host root.
- Actual cancellation and exact synthetic-path selection each exited 0 in the private native controller, classified `observed`. The selected path was `/tmp/nogui-w18-w19-native-runtime/dialog-targets/w18-dialog-target.txt`; its only content was synthetic. Live GTK chooser PNGs were inspected. Cancellation used the real Cancel mnemonic; window dismissal by Escape is the backend's separate `aborted` result and was not remapped to cancellation.
- Verification command: `direnv exec . node /tmp/nogui-private-x11-run.mjs -- bun /tmp/nogui-w18-w19-native-controller.mjs run --execute w18-dialog-cancelled w18-dialog-selected --session x11 --w18-bin ~/projects/nogui/.zig-cache/o/f6d59b78db88a1a6a113074ae70a204b/w18-dialog-smoke --w19-bin ~/projects/nogui/.zig-cache/o/aa56e2f798d8900b1d58cdfede77cbed/w19-service-smoke --run-id approved20261002g --with-evidence --approve-w18-dialog 'open one real file chooser on this desktop and answer it, so a selection, a cancellation and a parent close are each observed against a live owned window'`. Both native exits and controller verdicts were 0/`observed`; owned display evidence root `/tmp/nogui-final-private-x11-koVZfw`, phase evidence `/tmp/nogui-w18-w19-native-runtime/evidence`.
- The former immediate-close harness did not prove closure while a chooser was live. Its replacement now observes the provider-owned chooser, verifies the parent PID/XID and sends a graceful WM close without stealing focus. The first successful-looking run exposed allocator leaks, so exit 0 alone was rejected.
- **2026-10-03:** the repaired consumer keeps its receiver alive through parent destruction, joins its owned worker and drains SDL completions even after `Application.step` returns false. Manager detachment clears the owner before releasing its reference. The late-callback regression failed before repair; `api-w18` then passed 55/55.
- Actual live-chooser parent closure exited 0 with verdict `observed`, no native allocator/panic faults and no surviving owned processes. Command: `direnv exec . node /tmp/nogui-private-x11-run.mjs -- bun /tmp/nogui-w18-w19-native-controller.mjs run --execute --w18-bin ~/projects/nogui/.zig-cache/o/c372e8560f68bb06c258ad7420bb1859/w18-dialog-smoke --run-id b2fa533b20cf4d9cb9ff6d7d4e7ea55a --session x11 --x-display :4 --with-evidence --approve-w18-dialog 'open one real file chooser on this desktop and answer it, so a selection, a cancellation and a parent close are each observed against a live owned window' w18-dialog-parent-closed`. Retained summary/log: `/tmp/nogui-w18-parent-close-clean-20261003.{json,log}`. Owned fixture `/tmp/nogui-final-private-x11-TalcHv` retired.
- The bounded unclosed-parent error path also retired its worker without allocator or panic faults. Its wrapper PID deliberately failed consumer identity, so the controller returned failure, not acceptance; the native consumer returned `ParentWasNotClosed` after its 2000 ms bound. Evidence `/tmp/nogui-w18-deadline-cleanup-proof-20261003.{json,log}`. This is cleanup/error proof, not another parent-close acceptance.
- External URL/scheme/open/reveal actions remain unapproved. Wayland chooser acceptance remains open. No user clipboard, desktop, keyring or AT-SPI service was touched.
- The real owned-X11 `--native-observations` arm also exited 0. SDL driver `x11` agreed with the observed compositor type; appearance, titlebar, scrollbar, thermal, VRR, scanout and unconfigured motion stayed null where the private environment had no signal. Config/data/temp folders and executable-directory base/adjacent auxiliary paths were verified against the filesystem. A nonexistent auxiliary returned null. The focused menu bridge dispatched the live model once and refused disabled/unfocused actions; native global/dock menus correctly reported unsupported on Linux, and no native menu was claimed. Buffered synthetic launch ingress delivered once after handler installation and stayed once through four more pumps; unapproved external launch returned `ActionNotApproved` without opening anything. Log `/tmp/nogui-w18-w19-native-runtime/evidence/w18-native.log`.

**Focused checks and correlated portal repair (2026-10-03):**

- The linked `api-w18` gate passed **60/60 steps and 70/70 total tests**. Before repair, a missing own-serial ShowItems/OpenURI reply reported success, a duplicate scheme registration retained two entries, re-entrant binding compaction resolved the wrong owner, and raw Linux read errors under libc became invalid buffer lengths. Their behavior regressions now pass.
- `Registry.bindCheck/inspectCheck` reads the same focused weak-owner binding as availability and dispatch; `MenuItem.explicit_checked` is only an optional static override. Disabled checked actions retain their mark, aliases follow the model, and a dead owner loses it. The chosen binding is copied before an availability callback can compact the registry. Inspecting check state runs no action handler.
- The fresh owned-X11 `w18-native` phase exited 0/`observed`: focused states were `observe=true/false`, `not_now=false/true`; another context saw neither check. A model-only change made Observe checked with **zero invocations**, then explicit dispatch incremented the live model exactly once. Linux global/dock menu capability stayed unsupported; no native desktop menu was shown. Exact result/log: `/tmp/nogui-w18-current-focused-menu-proof-20261003.{json,log}`.
- Portal `ShowItems` and `Settings.Read` correlate their own serial. Open requests correlate both the method answer and Request decision, including cancellation arriving before the answer. Local files/directories use documented `sha{sv}` members and real borrowed descriptors, not a made-up file-URI wire argument. Re-registration replaces the in-process scheme handler without another key or leaked allocation.
- The transport now decodes raw syscalls with the kernel errno convention and negotiates UNIX_FD before `BEGIN`. Seven libc-linked direct tests and an actual isolated no-activation broker passed; the real receiver resolved/read `/dev/null`, the sender retained its descriptor, and the own-serial result was 42. `/tmp/nogui-boundary-and-fd-broker-proof-20261003.json` records commands and limits.
- Against the same fresh `4443af4b8e60b106f7c0f4e6df9755ab/w18-dialog-smoke`, all three approved real chooser phases—synthetic selection, cancellation and live parent closure—exited 0/`observed`. Command: private X11 launcher plus `bun /tmp/nogui-w18-w19-native-controller.mjs run --execute --session x11 --x-display :4 --w18-bin <binary> --with-evidence --approve-w18-dialog 'open one real file chooser on this desktop and answer it, so a selection, a cancellation and a parent close are each observed against a live owned window' w18-dialog-selected w18-dialog-cancelled w18-dialog-parent-closed`. Result: `/tmp/nogui-w18-current-all-chooser-endings-20261003.json`; owned fixture `/tmp/nogui-final-private-x11-KEp0il` retired.
- The native-services controller requires Bun; a mistaken Node invocation refused with `Bun is not defined` and retired its fixture, rather than performing a service action. No external open/reveal/desktop scheme association, native file-manager drop, capture prompt or other-OS menu acceptance was authorized or inferred.
- The exit-zero fault guard now has actual negative consumer proof: a real Zig `DebugAllocator` leaked 64 bytes; a separate real Zig child panicked and its abort was masked by an owned wrapper. Each wrapper exited 0, but the controller returned **22/failed** before an `observed` verdict. Both diagnostics came from runtime failures, not canned stderr. Exact preserved results/logs: `/tmp/nogui-w18-exit-zero-real-{leak,panic}-refusal-20261003.{json,log}`. These windowless default arms started only a no-activation private bus, retired it, and performed no provider or external action. The three fresh chooser captures were also inspected.

**Checkbox reconciliation (2026-10-03):** checkboxes 2 and 3 are complete on the
Linux X11 backend, and the evidence for both is the runs above rather than a new
execution. Checkbox 2: a real GTK backend and XDG portal frontend produced three
distinct observed endings for the same binary — synthetic selection, the real
Cancel mnemonic, and a graceful WM close while the chooser was live — each with
`unsupported` and refusal paths kept separate, and parent closure after
`onWindowClosed` accepted `Session.deinit` with no allocator or panic fault.
Checkbox 3: launch URLs queue until a handler exists and deliver once, unapproved
external launch is refused before any provider, file-drop phases and explicit
scheme operations are implemented, and the menu/system-action bridge routes
enable, check and dispatch through W10 with focused-context updates and zero
invocations for a disabled row; Linux reports native global and dock menus
unsupported and no in-app menu stands in for one.

Checkbox 1 is complete on the approved Linux X11 arm. Text, image and typed
metadata items have declared ownership. PRIMARY remains separate, and W12 fields
use the shared implementation. The user kept the Neovim RPC clipboard provider
in the separate editor plan on 2026-10-03. Checkbox 4 remains complete.

Kept separate from that, because they are different kinds of limit: other-OS
clipboard backends such as a macOS Find pasteboard belong to W23's target adapters
and are not part of this checkbox's text, and the Gate's Wayland half of the Linux
X11/Wayland smoke — Wayland clipboard, chooser and dialog success, external
open/reveal and desktop scheme association — was never approved, so the
Acceptance line keeps that half open on its own terms.

**Private Wayland acceptance (2026-10-03, continuation).** The user approved a
narrow private Wayland scope on 2026-10-03: owned Xvfb/private buses/private
HOME/settings, synthetic clipboard overwrite plus whole-item and PRIMARY
restore, and a real chooser answered with a selected, a cancelled and a
parent-closed ending. All of it ran; none of it touched a normal desktop.

- **Clipboard, `observed`.** `w18-clipboard` against
  `.zig-cache/o/fe6dcb4cbeb511fdc293d4ef9c88cdbd/w18-dialog-smoke` on an owned
  private Niri/Xvfb `:4` fixture. One item carried three MIME formats: text, one
  1×1 PNG of exactly 67 bytes and one JSON metadata blob of exactly 37 bytes.
  `readItem` returned all three, and both non-text formats read back at their
  exact expected lengths. The whole item was put back. PRIMARY is a separate
  selection: `supportsPrimarySelection` read `true`, an independent
  `wl-paste --primary` reader agreed with the run, and PRIMARY was **absent
  before and absent again after**, so the restore is independent evidence rather
  than a self-confirming round trip.
- **Three chooser endings, observed separately.** A synthetic selection, a
  cancellation driven by the chooser's real **Cancel** mnemonic (Alt+C) yielding
  `outcome=cancelled`, and a live parent close. Escape is the backend's own
  `aborted` result; it is deliberately **not** remapped to cancellation. The
  driving fixture was corrected to press the real mnemonic. No production result
  enum changed.
- **One parent-close failure was a correct refusal.** The 17-35-45Z invocation
  reported `no window titled w18 dialog smoke parent appeared on the owned
  compositor within 30000 ms`, because no buffer was mapped on the SDL parent, so
  the chooser could not exist. That is a real refusal, not a pass.
- **After the noapi mapped-parent fix the parent close is observed.** The
  18:40:35Z run against `.zig-cache/o/ebef0947c7df79c5fed45ac22c7aaac4` presented a
  real 320×180 noapi parent buffer with `gpu_surface=true`, and the owned
  compositor's close action produced `native parent close observed`,
  `parent-closed rounds=125 deliveries=1`, `outcome=parent_closed` and
  `Session.deinit=<accepted>`, controller exit 0, zero survivors.
- **Final confirmation, one invocation.** Selected, Cancel and parent-close each
  returned `observed` against that same current mapped-parent executable in a
  single run: `/tmp/nogui-w18-approved-wayland-runs/2026-10-03T18-44-24Z/result.json`,
  controller exit 0, `commandMatchesRequest: true` from the `/proc` readback, and
  zero owned or unattributed survivors. Every earlier invocation retired its
  controller, compositor, window manager and Xvfb as well.
- **Not a defect.** One earlier attempt died before start with an ELF entry point
  of `0`. That is a cached ZLS/tooling placeholder artifact, not a clipboard,
  chooser or Wayland production defect. It is recorded so no later reader reads
  it as one, and because "never pick the newest cached artifact" is a live
  hazard here.
- **What this does and does not close.** It completes the newly approved
  **private Wayland** subset of the Gate's Wayland half: Wayland clipboard item
  ownership, PRIMARY, and chooser selection/cancellation/parent lifetime on a
  current executable. It does not touch external URL open/reveal, desktop scheme
  registration, native file-manager drop, the macOS Find pasteboard, or any
  other target. The Gate's Wayland wording keeps its external-action half open on
  its own terms.



### W19 — Notifications and secure credentials

**Coverage:** P11, P12. **Depends on:** W07, W18.

**Files:** host `notifications.zig`, `credentials.zig`, Linux notification/Secret Service adapters, build/devenv and platform capability reporting.

**Produces:** async notification submit/replace/dismiss/response and secure credential read/write/delete.

- [x] Implement Linux notification identity/replacement and action callback routing to live weak owners. Report provider acceptance separately from actual user display or response.
- [ ] Implement Secret Service-backed credentials, prompt/locked-store outcomes and cancellation. No plaintext fallback, secret logging, default telemetry or frame-arena copies. W23 supplies other-platform providers.
- [x] Ensure shutdown and provider disconnect complete pending calls with a typed result; native callbacks cannot resurrect a dead Session.

**Acceptance:** replacement/dismiss affects the intended notification; delayed action for a dead owner is ignored safely; synthetic secret round-trips and deletes from the selected test store; denial/lock/disconnect do not appear as a missing password or successful write.

**Gate:** `zig build test -Dtest-filter=api-w19`; explicitly approved native tests with unique synthetic names and cleanup. Never inspect or modify a user's existing credentials for verification.

**Verified W19 (2026-09-29):**

- `zig build test -Dtest-filter=api-w19` passed 29/29, exit 0: notification identity, replacement, dismissal and response routing, provider acceptance reported separately from actual display, a delayed action for a dead owner ignored, shutdown dropping late callbacks, and Secret Service outcomes for locked, denied, cancelled, disconnected and failed writes with secure zeroing, all against a D-Bus loopback mock and a synthetic secret that is written, read back and deleted.
- The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Not run: a live notification daemon and a real Secret Service. The Gate's approved native test was not performed, and no user credential store was read or written.

**Immediate host gate recheck (2026-09-30):** closed the missing test brace in
`src/v7_host/windows/notifications.zig`.
`zig build test -Dproduct=host -Daccesskit-bridge=false -Dtest-filter=api-w19 -j1 --summary failures`
exited 0 after the typed dismissal changes. This is a filtered host test result,
not a live notification or credential-provider run; native acceptance remains open.

**D-Bus and notification integration (2026-10-01):**

- `zig build test -Dproduct=host -Daccesskit-bridge=false -Dtest-filter=api-w19 -j1 --summary all` passed 25/25 steps and 65/65 tests in Debug. The same command with `-Doptimize=ReleaseFast` passed 65/65 after the full-table replacement regression was strengthened.
- Service tracking reserves capacity before asking the provider. Refused reservations make no provider call; replacing a tracked notification reuses its slot and preserves the owner's response route even when every allocation fails. `Notify` and `CloseNotification` report allocation failure and connection loss separately from I/O faults.
- Method replies are correlated by serial while intervening signals and unrelated replies remain buffered. Output growth failure releases the copied frame through its creator allocator, including the disconnected drain path. Secret Service method waits use this correlation; portal signal readers retain their raw-message contract.
- Secret-bearing wire serialization uses one exact-sized allocation, then wipes that allocation before its creator frees it. The ReleaseFast serialization regressions passed; no plaintext intermediate growth buffer is retained.
- A real private D-Bus consumer connected from an 87,362-byte environment, queried owners and completed `AddMatch` and `RequestName` without losing `NameAcquired`; caller-owned environment boundary fixtures passed 1,201 split offsets. A separate CLI used real socket peers to prove `.out_of_memory` and `.disconnected`, and proved tracking refusal before any provider call.
- No real notification daemon or credential store was used. Approval-gated native acceptance and other-OS runtime evidence remain open.

**Private approved W19 native evidence (2026-10-02):**

- Real private Dunst and a new private bus per phase: notification replacement/dismiss, dead-owner suppression and provider-transport loss each exited 0 with controller verdict `observed`. The normal phase recorded two posts, one replacement, two closures and zero tracked entries. The disconnect phase terminated only its own PID-verified private bus after the consumer armed the wait, then observed one live-owner terminal callback. Evidence root `/tmp/nogui-final-private-x11-KM37Ly`; no user notification daemon or bus was contacted.
- Real notification action activation also passed on private Dunst: the sole displayed replacement was captured and inspected, then Dunst's own `NotificationAction` command produced `id=2 origin=pump action="w19-acknowledge"` exactly once. Native exit and controller verdict were 0/`observed`; two closures, zero tracked entries and zero dropped deliveries followed. No `ActionInvoked` signal was forged. Evidence `/tmp/nogui-w18-w19-native-runtime/evidence/w19-notify-action.log`, `notification-action-live.png`; owned display root `/tmp/nogui-final-private-x11-mdHHfG`.
- The approved real private Secret Service attempt stopped on the initial namespace existence read before writing any secret. It reproduced the wrong `OpenSession` parser: the native reply signature is `vo`, with an empty-string negotiated-output variant followed by the session object path. Source and wire fixture are repaired, but their serial build and real rerun remain pending.
- The credential approval is limited to service `nogui-w19-smoke`, account `w19-smoke-approved20261002f`, and the run's private per-phase keyring. Synthetic round-trip/delete plus locked/denied/disconnected and cleanup remain open. Any unlock/security prompt requires separate interactive approval; no prompt is auto-answered.

**Controller safety preflight (2026-10-03):**

- `direnv exec . bun /tmp/nogui-w18-w19-native-controller.mjs` exited 0 with usage; it did not hang on stdio. `providers` exited 0 and resolved the declared D-Bus, Dunst, Secret Service, portal, selection and GLib client programs. `plan w18-default w18-dialog-unavailable w18-native w19-capability` printed the private-display, private-bus and no-activation plan without launching it.
- All twelve consequential W18/W19 controller phases were invoked with `run PHASE --execute` but without approval. Each exited 20 before spawning a provider or consumer. Eleven recorded refusals are in `/tmp/nogui-w18-w19-scope-refusals-20261003.json`; the separate locked-phase refusal named its required secret-store scope.
- These checks prove harmless completion and approval refusal, not credential round-trip, denial, lock or disconnect. The changed locked/denied typed reports, per-phase datastore and failure-path focus restoration still need their applicable consumer/native verification. Orca and the test AT-SPI services stayed off.
- The actual `w18-default` phase now exits 0 with verdict `observed`, no providers, `drive=null` and no surviving owned processes. The owned Xvfb/Openbox fixture `/tmp/nogui-final-private-x11-vfzdnR` also retired. Its real no-session-bus child reported `unsupported`, retired the pending dialog and exited 0; neither clipboard nor chooser arm was authorized or entered. Fresh dialog/notification/credential missing-scope and notification wrong-scope commands each exited 20 and left the completed summary unchanged. `/tmp/nogui-safe-native-proof-20261003.json` preserves the complete commands and outcomes. The controller's literal NUL separator is now written as `\0`, retaining its runtime key while making the source searchable as text.

**Bus CLI and secret-material proofs (2026-10-04):**

- The bus CLI proof went red then green on its own source fix. The first run
  failed on a second start over the same unlinked live bus socket with
  `root_already_use`; the immutable record is
  `/tmp/nogui-w19-bus-cli-proof-40a44f78ab/actual-results.json`. The only change
  was removing two unconditional socket and lock removals ahead of the
  exclusive services directory, and the rerun passed at
  `/tmp/nogui-w19-bus-cli-proof-4dd3920d01/actual-results.json`: seven
  components, five actual refusals with every name and identity preserved, a
  genuine D-Bus accessibility `RequestName` denial, no provider activation, and
  the real CLI refusals `unknown`/leading exit 23, help and default 0, teardown,
  unapproved run 20, unlock-plan 21 and preflight. No drop-runtime and no full
  `Unlock` acceptance is claimed, and the locked store is untouched by it.
- The secret-material proof passed 11 cases with three owned tools whose exits
  are known, observed mutable byte views all zero, the Unicode LF and CRLF read
  and storage tail, `EEXIST`, a real non-zero tool and an actual 8-byte
  mode-0600 VNC file. An observer bug in the byte-view check was corrected, and a
  declared tool that does not exist on this system was replaced by an actually
  resolved one rather than a stand-in.
  `/tmp/nogui-w21-secret-wipe-proof-KKWoF0/actual-results.json` holds the record.
  Nothing here claims a backend wipe, a native allocator wipe, a JS gigacage
  wipe or any global wipe, and handover to a live keyring daemon remains
  unapproved.

**Private guard proof (2026-10-04):** `/tmp/nogui-w19-private-guard-proof-ooxyRt/private-guard-results.json`
exited 0 with the source controller at `0064` unchanged. The actual guard
functions refuse Wayland, all five foreign options, and the legacy-root
equality, descent and ancestor relations, plus the runtime equality of
`/run/user/1000` and the ancestor relation of `/run/user`; no `/run` case was
observed. The clean X11 route and a fresh
independent root pass. When the fixed root is absent the freshness branch is
recorded **EXPLICITUNEXERCISED** and no root is created. The Gcr values map two
actual `Name` and `Exec` pairs onto the shipped `System` and `PrivatePrompter`
files, with both the wrapper and the executed sibling being real Nix output;
`prepared` is true and `observed` is false. Xvfb, Openbox, xinspectors and VNC are
declared and preflight-checked against `:90` by reading only, with no program
started. No viewer, prompt, `Unlock`, credential or human acknowledgement is
involved. The earlier source-proof red at
`/tmp/nogui-w19-private-guard-proof-E4VroD` was the proof's own `Name` parser
rejecting a whole line where a bare value was expected; that parser was fixed and
the controller was not touched. The whole private `Unlock` gates remain open.

**Located-PCM helper proof is red (2026-10-04).** The helper run under
`/tmp/nogui-w21-located-pcm-proof-helpers-L2RSkO` proves what it measures and
fails on the rest. It passed the private scratch and binding check, that every
faulted capture is a byte-identical copy or prefix of the approved capture
(`71322bf0…`, 4,256,050 bytes) with no synthesised sample, a complete 100 ms
positive range from byte 114660 at peak 4295 and rms 382, and measured silence
over 100 ms of real silent bytes from byte 0. It then failed seven cases, each
named: a genuine `ENOENT` and a genuine `EISDIR` were swallowed into a zeroed
answer; the 3-byte read returned `null` from `analyzeRange` and was not accepted
there, but `locatedRangeStats` turned that unknown into zeros over the whole
requested range; the 6-byte and 40,000-byte prefixes were accepted as partial
metrics; a 1,367,100-byte request capped at 1,323,000 bytes was still published
as a whole 31,000 ms range; and measured silence against an unmeasurable range is
recorded as `the_two_answers_are_identical: false` — the known silence has 1
slice against the unknown's 0, but peak, rms and `audible_ms` are zero in **both**
while the unknown still carries the requested 100 ms metadata, which is the bug:
the unknown path publishes zero-valued energy across the full requested range
rather than an identical whole record. The run then reached its 180 s TIMEOUT
inside the expensive pair search before any final JSON was written, so this is a
partial record. The PCM source change is source-only so far: it is tagged
`measured: false` with null metrics and has no passing run behind it. No full
helper proof is claimed.

**Provider byte-handover proof is red (2026-10-04).**
`/tmp/nogui-w19-provider-byte-handover-proof-LsHxkx/report.json` is a true red.
With a real `wc -c` as the recipient, `startProvider` receives all 24 of 24
synthetic own-fixture bytes, but the 25-byte allocation is **not** wiped after any
of the five cases — normal handover, missing program, `EEXIST` log refusal, kernel
spawn `EACCES`, and the exiting recipient where the pipe accepted. That last case
is explicitly **not** an exercised `EPIPE`: the pipe accepted, so no write failure
is claimed for it. Both owned children were really reaped and the providers ended
at 0; no bus, keyring, `Unlock`, prompt, UI or credential was touched. The run
needed one proof-only getter taking `startProvider` from `0064` to `3532`, with
no behaviour change, after an earlier harness-only `yZkojW` failure where the
export was absent; the source owner `ProviderByteHandover` is now permitted to
repair the outer `finally` and drop the caller's redundant fill. No green result
exists yet.

**Provider byte-handover proof is green (2026-10-04).**
`/tmp/nogui-w19-provider-byte-handover-proof-9BtSQy/report.json` exited 0 on
source `63E8`, and the parent `node --check` on that source passes. All five
actual storage wipes pass: the normal `wc` recipient receives 24 of 24 bytes, a
real missing executable spawns no child, an `EEXIST` log refusal spawns no child,
a kernel nonexec `EACCES` spawns no child, and the actual exiting recipient
accepts the pipe. The whole observed 25-byte allocation reads zero in every case,
through the passed view's fill and the producer's pre-zeroed spare tail. Two real
children were reaped and the providers ended at 0. Case 5 is **still explicitly
unexercised** — the pipe accepted, so no `EPIPE` exception or write-failure proof
is claimed. The parent closed the password-reader/handover component todo 19 using
the prior `KKW11` read and VNC cases reused plus this new actual `startProvider`
scope; that is not whole production `Unlock`, and no prompt is claimed accepted.
The repair is deliberately boring: an inline `Uint8Array.fill(0)` in the whole
helper `finally` after the `stdin.end` drain, the unused helper removed, the
redundant caller-only success fill deleted, and the outer `passwordPayload?.fill`
kept for refusals that happen **before** handover. No secret content or hash is
serialised or logged — only an own synthetic fixture and a scalar `wc` byte count.
No user credential, UI, bus, keyring or prompt approval was used. The earlier real
red at `LsHxkx` and the harness-absent-export red at `yZkojW` are both preserved
rather than removed.

**Located-PCM helpers, second run (2026-10-04).** The next helper run passed
12 of 13. The only failure is the read-cap check, and it failed *despite* a
correct `measured: false` with null metrics, so the suspicion is a proof message
assertion rather than a product defect; the proof owner is investigating. Four
integration cases remain unexercised. This is not a finished helper proof and
nothing above is closed by it.

**Located-PCM helper scope green, integration still red (2026-10-04).** The helper
run at `/tmp/nogui-w21-located-pcm-proof-2026-10-04T19-06-19-969Z-1053874.json`
is **14/14 within its own scope only**, on source `9B7D` whose syntax check
passes: all eight fault cases, the two real positive and silence cases, and the
integrity and scope cases, including a newly requested 3-byte `RANGE_TOO_SHORT`
case. Its four integration cases are explicitly unexercised by mode.

The independent integration-only run at
`/tmp/nogui-w21-located-pcm-proof-2026-10-04T19-07-32-532Z-1053419.json` is a
**red 4 of 6**, and it is preserved as the dated artifact it is. For the exact
selected wire — request 19, transaction 7, UID 19, 98,098 PCM bytes — the unique
fragment spans 325988→424086 while the actual binding identity is 225-19 and the
spoken-true window is 118112→173730; truncating to 325,994 bytes leaves that same
window in place with spoken still true. **The cause is confirmed and it is a
HARNESS pair mix, not a production neighbour bug:** the proof paired that wire
against the FIRST UNREFUSED BINDING instead of the screen-reader-on binding it
names. Its own selected marks `0:3, 4:8, 9:14` resolve to the unique
325988→424086 fragment, while the real reader binding — screen reader on, marks
`0:6, 7:13, 14:17` — owns request 6, transaction 1, reference 55618 and the
window 118112→173730. The 325,994-byte truncation still held that entire binding
window, so its `spoken` answer was truthful **for the binding the harness
actually selected**. That record stays red 4 of 6 as dated history and is not
rewritten. **The corrected pairing has since been run and preserved:** it selects
subject request 19 / transaction 7 with **no carry among the 102 bindings**, and
it exercised 3 of 3 selected cases while leaving 17 unexercised — the mode cases
plus six downstream ones. Row eligibility for a second, distinct subject is still
pending, so the integration surface is not fully exercised and no broader green
integration claim follows. The separate repeated-fragment count and Nth-matching
text attribution remains an independent open question pending the UID clean
cutover, so the PCM component is not closed. For the record, the expensive steps are a
36 s reader fragment parse
and a 36 s baseline bind against a 1.1 s wire build: the earlier 180 s was repeat
matching, not wire-log parsing.

**Fresh private credential acceptance (2026-10-03):**

- The current `w19-service-smoke` compiled after the wire repair. The controller then ran the real GNOME Secret Service on its own PID-verified private bus and per-phase keyring: `w19-credential` exited 0 with verdict `observed`. Service `nogui-w19-smoke`, new account `w19-smoke-51e0030ce29740c1a71a86e87c24acd8`: 81 synthetic bytes written, read back, deleted and confirmed absent. No provider prompt was answered; no user store was reached.
- Evidence `/tmp/nogui-w19-roundtrip-proof-20261003.json` retains the native namespace, lifetime, provider identity and zero surviving owned processes. Xvfb/Openbox root `/tmp/nogui-final-private-x11-UNY3a1` retired.
- The separate locked fixture failed before the consumer: its `ReadAlias` decoder rejected GLib's `objectpath` annotation, then `CreateCollection` omitted its required alias argument. The daemon reported `(a{sv})` versus required `(a{sv}s)`. `/tmp/nogui-w19-locked-before-proof-20261003.json` preserves that failure. Locked, denied and disconnected acceptance stays open while the fixture signatures, decoding and session lifetime are repaired; a source-only helper is not a native pass.
- The fixture client now keeps `OpenSession`, `CreateItem` and `Session.Close` on one GDBus connection and sends an empty plain-algorithm parameter array. GLib's typed empty arrays (`@ao []`) and two-child `OpenSession` replies are decoded correctly. Actual reply samples failed before the decoder repair and passed afterward.
- The real locked fixture created and selected its own item, locked its collection and witnessed `org.freedesktop.Secret.Error.IsLocked`. Unlock returned `/org/freedesktop/secrets/prompt/u1`; the controller stopped with `unavailable` and answered no prompt. The native consumer did not run for this phase. Locked-read and item-cleanup acceptance remains blocked on a private keyring UI agent and explicit interactive prompt approval. Evidence `/tmp/nogui-w19-real-locked-prompt-proof-20261003.json`; all owned processes retired.
- `w19-credential-denied` exited 0 with verdict `observed`: the private bus refused `CreateItem` with `org.freedesktop.DBus.Error.AccessDenied`, the production consumer returned `denied`, and its following read confirmed `not_found`. Evidence `/tmp/nogui-w19-real-denied-proof-20261003.json`.
- `w19-credential-disconnected` exited 0 with verdict `observed`: a real initial read answered `not_found`, then the consumer shut down its own provider connection and its next read returned `provider_failed/disconnected`. This proves post-shutdown handling, not an unexpected daemon crash or an in-flight transport loss. Evidence `/tmp/nogui-w19-real-disconnected-proof-20261003.json`. Both denial and disconnect used new approved synthetic accounts, PID-verified private providers and buses; no owned process survived.

**Unexpected in-flight credential transport loss (2026-10-03):**

- A standalone public-host consumer used the real private GNOME Secret Service. Its initial missing-namespace read returned `not_found`; the controller then paused only its PID-verified provider and observed kernel state `T`.
- The private monitor recorded the consumer's second `SearchItems`, sender `:1.7`, serial `4`, and proved its sender PID was the consumer. No correlated reply existed before the controller terminated only its own private broker.
- The pending read completed exactly once as `provider_failed/io_error`, not `not_found`; 750 ms of settlement recorded zero late completions and `busy=false`. Worker join and provider release followed the result. Explicit local shutdown retains its separately observed `disconnected` result.
- Controller and consumer exited 0. The transcript contains only `OpenSession` and two `SearchItems` calls to Secret Service; no write, delete, Unlock or Prompt. The new store stayed empty and no owned process survived. Evidence: `/tmp/nogui-w19-inflight-loss-scanned-env-20261003/evidence/summary.json`, with retained consumer output and monitor transcript. Service `nogui-w19-inflight-loss`, account `w19-smoke-mus0imkdgm35`; no existing user credentials were addressed.

**Phase-log file-descriptor contract (2026-10-04; green, and not an `Unlock`).** The
parent ran a bounded proof that exited 0 with **14 of 14** cases. It used the same binding
as the phase controller, with `CommandUnlockRun B1EA` and proof `23D4`, and recorded
exactly 8 writes totalling 400,352 bytes across 400,342 characters, with a maximum of
400,011 characters in one write. A kernel `rename` published a 2-line, 42-byte record while
a 49-byte decoy file stayed unchanged. The refusal set stayed typed and distinct — `EEXIST`,
symlink, directory, non-follow and `EBADF` — the descriptor closed exactly once, and no file
descriptor leaked. All 13 created paths were contained in the owned root, both runtime roots
were unchanged, and providers, children, bus, prompts and keyrings were all **0**.
**What this is not:** no fresh `Unlock` was performed, no prompt was answered, and full
locked-store acceptance stays blocked on fresh consent. The two earlier reds are preserved
rather than rewritten — the older run held 11 of 14 because of an offset defect, and the
13-of-14 proof had a containment off-by-root defect that this run corrects, with no false
fake-root side effects on either. The run's scratch tree was removed after the fact, so no
durable evidence path is cited for it.



### W20 — Screen capture

**Coverage:** P13. **Depends on:** W07, W14.

**Files:** host `capture.zig`, Linux portal/PipeWire and applicable X11 adapter, W14 frame source integration, build/devenv.

**Produces:** capability/source metadata, native selection/permission session, start/frame/stop and teardown.

- [ ] Model selecting, denied/canceled, streaming, stopped and provider-failed states. Wayland portal source choice is OS-owned; do not pretend the app can enumerate arbitrary capturable windows there.
- [ ] Deliver retained frames through R08's descriptor; negotiate supported formats and color metadata. Reuse W05 completion/wake and noapi upload/import, not a second renderer or raw Vulkan import.
- [ ] Stop on owner/provider loss and release every retained frame; backpressure may replace stale video frames under an explicit policy but cannot leak buffers.

**Acceptance:** approved capture shows the selected surface, cancel returns no stream, stop prevents further delivery, format change is handled, closing the owner releases portal/PipeWire/native resources.

**Gate:** `zig build test -Dtest-filter=api-w20`; interactive portal permission approval and live preview on Wayland, applicable X11 path separately. Headless provider state tests do not prove capture works.

**Verified W20 (2026-09-29):**

- `zig build test -Dtest-filter=api-w20` passed 39/39, exit 0: canceled, refused and failed selection each reported distinctly, no stream without a provider or a live owner, a second selection refused while one is in flight, format change raising the epoch, backpressure keeping the newest frame, owner death and stop releasing every retained frame exactly once, and a negotiated format pod that refuses planar input instead of describing it wrongly.
- The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Not run: the interactive portal permission prompt, which needs explicit operator approval, and any live preview on Wayland or the applicable X11 path. A missing PipeWire reads as a disconnected provider in these tests, which is not evidence that capture works.

**Current runner integration (2026-10-02):**

- `zig build test -Dtest-filter=api-w20 -j1 --summary all` passed 81/81 across 57/57 steps. **Coverage correction (2026-10-03):** this selected provider/contract tests but excluded the eleven runner regressions then named `w20-capture-smoke`. The runner's continuously available-frame deadline, paused/resumed and terminal precedence, mapped-byte bounds and held-provider lifetime were therefore not proved by that filtered run. Its after-stop `total_pushed` probe was a structural zero, not evidence of provider-thread retirement.
- Actual `w20-capture-smoke` default and `--help` runs exit 0 without selecting or streaming. `--source-window --cursor embedded --budget-ms 1000` refuses with `NativeOptionWithoutAuthorization`; `--authorize-native-capture --source-window --budget-ms 1000` refuses with `NativeArmNeedsCursorPolicy`. Both refusals occur before any provider call.
- No portal prompt was approved, no surface was captured and no live preview was observed. The interactive acceptance above remains open; the authorization flag is not permission to accept a chooser on the user's behalf.

**ScreenCast wire and ownership repair (2026-10-03):**

- `direnv exec . env -u DISPLAY -u WAYLAND_DISPLAY zig build test -Daccesskit-bridge=false -Dtest-filter=api-w20 -j1 --summary failures` exited 0. Owned socket peers decode the actual CreateSession/SelectSources/Start/OpenPipeWireRemote requests, including separate token buffers, boolean `multiple`, cursor bits 1/2/4, `persist_mode`, the restore token and normalized sender paths.
- Five new socket cases first failed on the malformed Start dictionary. The corrected request signatures and variant alignment now reach canceled/refused responses and both streams, including optional metadata. Stream IDs survive reply-frame release; size is `(ii)` in compositor units.
- The descriptor consumer proves reply-serial correlation and handle-index selection through real SCM_RIGHTS and tagged pipe reads. Pipe writer error state proves that foreign and unselected readers are closed, without assuming descriptor numbers cannot be reused.
- Pure-parser regressions reproduced nine leaked allocations and a stale ID after an empty repeated value. Transactional string replacement now passes both clearing/replacement cases and `checkAllAllocationFailures`. A valid unknown dictionary result previously hid the following session result; dict-entry alignment and traversal now pass that regression.
- The inert application-ID override was removed from Request, the Linux Provider, smoke CLI and private fixture. Portal identity comes from the bus sender. The private fixture's proposal now states the corrected wire mapping separately from future backend observations.
- The actual current `w20-capture-smoke` build and default run exited 0 after caller migration. It resolved PipeWire only and reported capabilities, with no provider call, portal request, chooser or frame.
- No real provider, chooser or PipeWire stream was activated by these checks. Interactive permission, live preview, owner-loss capture and applicable X11 acceptance remain open.

**Runner acceptance repair (2026-10-03):**

- The source-class regression failed against the old runner: a window frame answered a monitor-only request with `observed`. The repaired runner returns `mismatch`; known-empty metadata refuses, mixed requests permit a reported subset and unknown metadata remains explicitly `<unproved>`.
- `direnv exec . env -u DISPLAY -u WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS=disabled: AT_SPI_BUS_ADDRESS=disabled: NO_AT_BRIDGE=1 GTK_A11Y=none zig build w22-popup-smoke w20-capture-smoke test -Daccesskit-bridge=false -Dtest-filter=api-w20 -j1 --summary all` passed 66/66 steps and 106/106 tests. Thirteen runner regressions now match the filter. The actual W20 default resolved PipeWire only and made no provider call, chooser or frame.
- The structural-zero post-stop counter probe and its unreachable held-queue verdict were removed. Outstanding borrowed frames and teardown errors remain checked; no stopped-session counter is presented as proof that a real provider thread retired.
- The private fixture now resolves the consumer's PipeWire library from the declared tool's own verified ELF/SONAME output and pauses scene animation for a static chooser witness. Live filtered-child loading, the static capture pair, permission, preview and real provider retirement still require execution and interactive approval.

**Runtime library resolution (2026-10-03):**

- The private capture fixture's `--check-runtime-library` arm exited 0, and
  `node --check` on that arm passed. It spawned nothing: no Xvfb, openbox, niri,
  pipewire, xdg-desktop-portal, backend or chooser, no ScreenCast request, no source
  selected, no restore token, and no permission requested or granted.
- It resolved the consumer's single runtime library the way the real run does, from
  the store output of a declared provider rather than from the operator's
  `LD_LIBRARY_PATH`, which it printed for context but ignored for resolution, inheritance and merging.
  The path it accepted is
  `/nix/store/h06qaqbc0llyr2vpqrj9ia2dpwgw120m-pipewire-1.6.8/lib/libpipewire-0.3.so.0`,
  whose real file is `libpipewire-0.3.so.0.1608.0`: 1,126,128 bytes, SHA-256
  `12131ad16fac5d978266c15243b3a307e70e915af404074fb156447fa1c80430`, 64-bit
  little-endian `ET_DYN`, ELF `SONAME libpipewire-0.3.so.0` matching the name the
  consumer opens with `std.DynLib.open`, `DT_NEEDED libc.so.6`, and a glibc
  `DT_RUNPATH`. Evidence: `artifact://13362`.
- **14 of 16** declared providers resolved. The two that did not are
  `chooser` (`slurp`, two installed programs) and `portal-front-end`
  (`xdg-desktop-portal`, two installed outputs), because both have two installed
  matches and the fixture refuses to guess between them; they are named with
  `--chooser-bin` and `--portal-bin`. That is a conservative selection step in the
  fixture, not missing information and not a reason to involve the operator. This
  arm gates only on `stream-transport` and `stream-transport-client`, both resolved.
- The continuation selected explicit installed paths:
  `--chooser-bin /nix/store/1gd4qqpf8m82lnv1n2d271n2p4k511zk-slurp-1.5.0/bin/slurp`
  and
  `--portal-bin /nix/store/xlg7qizklrgjyxnc3aiw0bhzmn6p6gg9-xdg-desktop-portal-1.22.1/libexec/xdg-desktop-portal`.
  `direnv exec . node /tmp/nogui-w20-private-capture-fixture.mjs --check-runtime-library`
  with those two flags exited 0 and resolved **16 of 16** providers. Evidence:
  `artifact://13517`. Provider-path selection is complete; no provider, chooser,
  capture request or permission was activated, and actual child library loading
  remains unproved.
- This is **not** chooser evidence and **not** capture evidence. The real run still
  needs `--execute`, the byte-exact approval and a person in front of the chooser,
  and the real static chooser witness, native permission, live preview and owner-loss
  capture stay open exactly as recorded above.

**Provider-free fixture fault modes and the approved first capture (2026-10-03, continuation).**

- The private capture fixture's own failure handling was driven with **no**
  provider, chooser, portal request, source selection or frame involved. Each
  mode was red on the earlier fixture hash `d12f98f470b7` and green on
  `4efd8bd8f5e5`:

  | Fault mode | State | Evidence |
  | --- | --- | --- |
  | bounded consumer retire | `GREEN`, exit 0 | `/tmp/nogui-w20-fault-green-20261003/consumer-retire-report.json` |
  | exited-leader group descendant | `OK`, exit 0 | `/tmp/nogui-w20-fault-green-20261003/group-descendant-report.json` |
  | foreign-birth unknown group | `REFUSED`, exit 0 | `/tmp/nogui-w20-fault-green-unknown-v2-20261003/unknown-group-report.json` |
  | no-approval consumer | `GREEN`, exit 0 | `/tmp/nogui-w20-fault-green-approval-v3-20261003/consumer-retire-report.json` |

  `REFUSED` is the correct green answer for the foreign-birth mode, not a
  failure. After the owned pid, pgid, session and start time were swapped with a
  stranger, the guard recorded that group `1513546` was not this run's to signal,
  signalled nothing, and the stranger's own group settled with
  `zero_surviving_members`. The prior red states were `RED` and
  `FIXTURE_LEFT_TERM_IGNORING_DESCENDANT`.
- The later-than-15 s timing fault is separate and also green:
  `/tmp/nogui-w20-approval-wait-proof-1791051478197/result.json` records a timing
  protocol arriving at 17.5 s with `childAliveUntilAnswer: true` and no premature
  retirement, an attributed-but-unanswered overlay expiring on its own bound
  while the child stayed alive, and a refusal that ended waiting without
  granting approval. The same file states `nativeProvidersStarted: false`,
  `captureOccurred: false` and `realApprovalEstablished: false`.
- These are **harness** faults. They prove the fixture refuses to signal a
  process it does not own and does not hang past its bounds. They are not
  capture, not permission, and not a substitute for the acceptance below.
- **Approved on 2026-10-03; the single approved capture has since run.** The user
  approved exactly one first capture: an owned private Niri/Xvfb `:6` session
  with one monitor and one stream, 30 frames, a 15 000 ms post-approval budget,
  one PPM, and a source a **person** selects manually. No automated chooser
  answer and no second capture are approved. The owned local private `:6` viewer
  window with clipboard sharing disabled was **preparation** for that single
  capture, not new capture authorization.
  *(As of the end of 2026-10-03 this had not started. It is superseded below: the
  approval was spent on 2026-10-04 and the run ended in denial, not in a
  stream.)*
- All three W20 checkboxes remain unticked. Native setup starts the private
  Niri, PipeWire and portal providers. The first actual `CreateSession` and
  `SelectSources` have now gone out on the real portal, as recorded below, so
  "no ScreenCast request has started" is no longer true; no validated stream,
  no preview and no captured frame has been observed. Unlock, external
  open/reveal/scheme/drop and every other OS or SDK remain blocked.
- **First setup, 2026-10-04:** Xvfb `:6` proved cookie client exit 0 versus
  cookieless client exit 1. Niri exited 101 because the filtered compositor
  environment could not load `libXcursor.so.1`. No viewer, chooser, portal
  request or PipeWire stream started. All seven recorded owners retired and
  were re-observed absent, but the Node wrapper timed out after 600 seconds.
  `/tmp/nogui-w20-private-capture-WetkjW/fixture.json` preserves the refusal.
  This setup establishes no capture credit.
- Current provider-free checks resolve all six required compositor SONAMEs from the declared runtime list.
  A real SONAME-scan refusal changed from an owned FD leak to complete descriptor release.
  The real-child lifecycle smoke drains naturally at Node `beforeExit`, without a forced success exit.
  All 19 safety cases held across 20 fresh module instances, with all instances retired.
  The final audit found no live owners, zombies or unobservable processes.
  Evidence: `/tmp/nogui-w20-runtime-lifecycle-fd-green-20261004/result.json` and
  `/tmp/nogui-w20-viewer-current22-20261004/result.json`.
  These provider-free checks do not establish viewer or capture acceptance.
- **Native setup repair, 2026-10-04:** the actual backend crashed on a null DRM
  device. The declared provider patch now reaches readiness with the private
  Niri compositor and keeps its shared-memory path available. The frontend
  acquired its private bus name.
  `weston-color` required unavailable `wp_color_manager_v1`. The declared
  `weston-image` client now paints an owned static image. Its private compositor
  screenshot was inspected, and two still witnesses matched.
  `/tmp/nogui-w20-private-capture-lUUPJb/fixture.json` records complete retirement
  of all 19 fixture-owned process groups. The parent viewer authenticated but
  lacked a verified compositor window witness, then exited 0 after retirement.
  No viewer acknowledgement, ScreenCast request, chooser, stream or captured
  frame occurred.
  *(Superseded 2026-10-04: this attempt started no capture at all. The run below
  issued a real portal request and a real, verified viewer handshake.)*

**First actual capture request (2026-10-04).** Evidence:
`/tmp/nogui-w20-private-capture-1RLlCp/fixture.json`. This run spent the single
approved capture. It reached the real portal and still produced no stream.

- `CreateSession` and `SelectSources` really went out, for the first time in
  this project's history, with `types=1`, `multiple=false`, `cursor_mode=2` and
  `persist_mode=0`. The backend advertised exactly `AvailableSourceTypes=1` and
  `AvailableCursorModes=3`, so the requested cursor mode was one it offers.
  `capabilities()` on the same run reported `available=true`,
  `platform=wayland`, `backend=portal_pipewire`, `multiple_streams=true`,
  `requires_user_approval=true`.
- The private viewer half is proved, not assumed. Viewer pid `3764550` with
  start ticks `30773721` was matched on the private X server: niri reported
  window `295` with relay pid `4315`, which is the XWayland satellite rather
  than the viewer, and `xprop` on XID `0x1400005` returned that exact viewer pid
  with its caption and class. The private server was pid `3762235` with start
  ticks `30771058`. The secure acknowledgement was exactly 108 bytes, mode
  `0600`, uid `1000`, `nlink` 1, carrying this run's own nonce and the same
  server identity. Private `HOME` and every `XDG_*` pointed inside the private
  root; the viewer ran with `-AcceptClipboard=0 -SendClipboard=0
  -SendPrimary=0 -SetPrimary=0` against a server started `-nosel -noprimary
  -nosetprimary -noclipboard -nosetclipboard`, so no selection crosses in either
  direction; `-FullScreen=0` and `-RemoteResize=0` were both in force. The real
  private pixels were read and saved, and the still-witness pair taken after
  the resize cycle matched.
- The chooser witness expired, and the first reason was this project's own
  parser. The chooser really ran: a `slurp` process spawned by the portal
  backend produced a 198-line `WAYLAND_DEBUG` trace of which 119 are protocol
  lines, but the parser's prefix did not accept libwayland-client's
  `[hh:mm:ss.uuuuuu] {Default Queue} -> iface#id.method(...)` form, so nothing
  was extracted and the 240 000 ms attribution bound expired with
  `found=false`. The prefix is now optional-aware; replaying that same captured
  trace through the corrected parser yields shell 5, layer-shell 10, surface 3,
  output 9, xdg-output 11, the winit surface, the selection and configure/ack
  201 in protocol order, with the raw lines retained. That is a replay of a
  real trace and not a new live witness: the corrected parser has not run
  against a fresh chooser, so the chooser clause stays unproved.
- The consumer's own result is a refusal.
  `evidence/w20-capture-smoke.log` reads
  `begin: state=denied failure=rejected returned=CaptureDenied chooser=279771 ms`,
  `stop: state=denied outstanding=0 after 18 ms` and
  `verdict: the capture half did not observe a validated stream; exit=3`. No
  stream was validated and **no production PPM was written**. The fixture wrapper
  itself exited 22 after 345.68 s.
- Retirement is real but the run is not clean as a whole. All 23 owned process
  groups were observed empty, with zero owned survivors, zero unresolved
  ownership, zero observation failures, zero unsettled reap and zero still-open
  pipes. **The six `invalid_pidfd_reply` refusals are now classified in source
  rather than unexplained, and the classification is not a live witness.** The
  reported cause is ordering: the old caller allowed 2000 ms and then sent its own
  `SIGTERM` before the helper's own 5000 ms budget, and the history record agrees —
  all six helper stdouts were empty and carried `SIGTERM`. The collector now
  declares a 20 s startup contract of 5 + 2. No fresh capture produced that
  explanation, and the earlier component proofs do not explain it either. The run
  is source-repaired and classified, still not live-witnessed, so it is not called
  clean as a whole.
- The private bus denied all five accessibility names, so this run was
  capture-only and could not have produced a11y evidence either.
- No second capture is approved. A further attempt needs renewed point-of-risk
  approval at the time it is made; the single approval is spent.

**Retirement component renewal (2026-10-04; no new capture).** Real owned-child
proofs now cover the revised pidfd helper and fixture collector. Missing birth
and wrong birth leave the live target unchanged; exact-owner TERM produces
signal exit `-15`. A blocked stdout makes the helper exit 3 after 2.12 s with
64,013 bytes already delivered, and the fixture classifies that as incomplete
report delivery, not malformed JSON or proof that no signal occurred. A real
5-second work interruption produces 456 identity refusals, one interrupted
UNKNOWN row and 443 never-attempted rows. The lists remain distinct.
Actual Node 24 pipe tests also cover a 31-byte collector cap with 622 overflow
bytes and a 4 MiB input refusal whose real stdin and child errors both carry
`EPIPE`; the intact helper refusal still proves that the child ran.
Evidence is under `/tmp/nogui-w20-real-pidfd-proof-xi_a1j5b`,
`/tmp/nogui-w20-real-work-bound-proof-g_se1cis` and
`/tmp/nogui-w20-real-node-proof-gSvCXu`. These checks started no capture provider
and requested no permission. They do not replace a fresh live fixture witness.
The six original failed replies are now explained in source, as recorded above,
and **not** by these component proofs.

**Post-run final retirement outcome, and the owned-kernel closure that proves it
(2026-10-04; no capture).** The old retirement code produced a verdict carrying no
exit status while the consumer's own log recorded exit 3, so that run had no final
result at all; the source now records the exit status instead of discarding it. Both
follow-on units — a named export of that same code and a driver taking an actual
owned child pidfd through the fixture helper — are **done**. The parent then ran the
owned-kernel closure: **exit 0 in 17.76 s**, durable JSON at
`/tmp/nogui-w20-owned-kernel-closure-EhJ1NX/owned-kernel-closure.json` under a mode-700
root. The Node check used the actual fixture and the new proof reports **782** passing.
The helper it drove is the exact declared `/tmp/nogui-w20-pidfd-signal.py`, SHA-256
`b272a192813d7a41dac7a0226796d17ed89108615a6aa0cefce384455503480f`, 28,071 bytes, on
an explicit Python 3.14.7 pin.

The three cases are all real and none is a capture:

- **A** pinned an actual owned member syscall to its start ticks and sent it `TERM`,
  answering `reply_kind=pidfd_helper_complete`.
- **B** got an actual gone-and-reaped kernel refusal and confirmed the genuine helper
  answer was not lost.
- **C** took an actual `TERM`-ignoring owned child through the wait boundary, `TERM`, the
  grace period and `KILL`, reaped it on a real FD, and refreshed the consumer's retirement
  from teardown so `retired-by-this-run` updated. Its **exit 22 is preserved** together
  with the earlier boundary facts, and C is a standalone process, so **no capture consumer
  and no genuine `Deny` claim comes from it**.

No bus, display, Wayland, runtime or audio environment was involved; `capture_request`,
`consumed` and `renewed` were all false; and the older retained proof roots were read only,
never rerun. This is corrected **collector and root-owned-child behaviour, not native
proof**, and no fresh chooser capture happened. The seven original W20 full-fixture
acceptance items stay blocked, and the six historical reply failures remain known in source
and classification but **not** live-observed on a fresh private fixture.

**Round-trip and scene-control reading corrected (2026-10-04).** The round trip was
already exercised in its first order by the old run itself — `after_attempts`
05:59:51.114 and the resumed 05:59:54.478 — and the `NULL`-returned control refused
correctly; nothing about it waits on the corrected parser. The two scene-control
images are byte-identical **1280×800** PPMs of 3,072,016 bytes whose shared SHA-256
begins `df4d7d4a`; 3,072,016 is the byte count, not the image size, and the earlier
reading of it as 3072×2016 was wrong. So scene control is proved. The chooser-specific
values are all `null` because the parser was the old one, not because the control
failed. Full native acceptance stays pending, and no new parser test task is created
by this correction.

**Chooser-witness parser repaired and read back against the recorded trace (2026-10-05).**
libwayland-client on this stack prints `[hh:mm:ss.uuuuuu] {Queue} -> iface#id.method(...)`,
so the parser strips the queue label and the request arrow before it matches. Run back
over the trace that run recorded, it now reads 119 protocol lines and the ordered
quartet on the chooser's own surface: `zwlr_layer_shell_v1#5.get_layer_surface(new id
zwlr_layer_surface_v1#10, wl_surface#3, wl_output#9, 3, "selection")` at line 129,
`wl_surface#3.commit()` at 134, `zwlr_layer_surface_v1#10.configure(201, 1280, 800)` at
156 and `zwlr_layer_surface_v1#10.ack_configure(201)` at 157. The namespace it reads,
`selection`, is the one the compositor's own live layer list in that run already carried
for output `winit`, so the live-layer gate is reachable again instead of empty. Nothing
was relaxed to get there: a configure that precedes its layer surface, a commit on
another `wl_surface`, a log with no protocol line at all and the whole-frame pixel
difference are each still refused, and `parseWaylandDebug` is now exported so a proof
reads this parser rather than a copy of it. The record also names the file the trace
came from — it never did, and a witness whose parser cannot be pointed at its input is
not re-checkable.

**Stable scene control renewed after the acknowledgement (2026-10-05).** The control the
chooser's pixels are read against is now taken again on the far side of the viewer
acknowledgement, with the two captures of each attempt a measured 200 ms apart instead of
back to back, retried inside a fixed 12-attempt bound, every attempt recorded. The first
still pair stays in the record under `still_before_viewer_handshake`, because it is the
evidence that the scene was still before a person connected, and it is no longer filed
under the key a reader would take for the baseline. **Unresolved:** in that recorded run
the capture taken with the chooser up is not a bounded chooser-shaped difference — the
control against a capture made while the chooser was on screen differs over 50,019 of
1,024,000 pixels with a bounding box spanning the whole 1280×800 output, which
`covers_the_whole_output` refuses by design. A chooser whose selection surface covers its
output may therefore never satisfy the rendered-witness gate, and that gate was left
strict rather than relaxed to fit one run.


### W21 — Semantics and native accessibility

**Coverage:** A01, A02. **Depends on:** W07, W09, W11, W12, W16.

**Files:** create core `semantics.zig`, host `accessibility.zig`, `src/v7_host/accesskit_bridge/{Cargo.toml,src/lib.rs}` and a narrow owned C header; modify built-in/custom semantics, headless JSON, focus/actions and build/devenv.

**Produces:** committed typed semantic snapshot and a real OS accessibility adapter, not only JSON metadata.

- [x] Add stable roles/names/descriptions/shortcuts/state/value/range/relations, active-descendant relationships, hidden/disabled policy, focus and synthetic children. Include slider ranges and text selection/geometry. Do not use translated names/message keys as IDs.
- [x] Publish semantics only with the successful frame and convert visual logical bounds at the native edge. Native actions resolve stable live owners and use the same activation/edit/focus path as ordinary input. Expose adapter activation and the accessibility bell through explicit native capabilities. Offscreen virtual items expose the documented list/selection relationship without materializing a million widgets.
- [x] Use a small **owned Rust static-library C-ABI bridge** to AccessKit: pinned baseline `accesskit 0.25.0`, `accesskit_unix 0.23.0` with `accesskit_atspi_common 0.20.0`, `accesskit_macos 0.27.0`, `accesskit_windows 0.35.0`; platform ports use the corresponding adapters. Define borrowed input and owned callback payloads, panic containment and main-thread marshaling. No Rust objects leak across the ABI. Optional host dependency, absent from core-only builds.

**Acceptance:** a real screen reader announces button/checkbox/radio/slider/progress/input names and state; native activate/set-value/focus/selection edits the same model once; reordering does not recreate unrelated semantic nodes; hidden/removed nodes stop receiving actions; failed frame does not publish half a tree.

**Gate:** `zig build test -Dtest-filter=api-w21`; actual Linux AT-SPI inspection plus Orca keyboard/action smoke, including text composition, modal focus and list updates. Later W23 gates use the target-native accessibility client. **The Gate's wording does not widen the composition criterion.** Whole/empty/restore `EditableText.SetTextContents` is proved natively, and that is whole-value proof only. What remains owed is the audit's stricter clause: **positioned native `EditableText` composition through the published semantic model**, which neither whole-value writes nor an SDL-side IME run closes. The wire facts are now derived from the pinned source: `org.a11y.atspi.EditableText` has six members — `SetTextContents`, `InsertText`, `CopyText`, `CutText`, `DeleteText` and `PasteText` — so the previously recorded `insertTextAtPosition` and `deleteTextBySelection` exist nowhere and that enumeration is withdrawn; only `SetTextContents` is wired and the other five answer `org.freedesktop.DBus.Error.NotSupported`. `InsertText.position` is a character offset while `InsertText.length` is a byte upper bound on the inserted text, and no member carries a spec-mandated caret result. **No public criterion is downgraded by any of that.** Closing the clause needs the source work first and a fresh W21 native approval after it, not documentation alone.

**Where that clause now stands.** The interactive, role and settings halves of this package are
proved on a full real native stack: `screen_reader_attached`, `published_roles`, the radio group
relation and its check marks, the progress value equal to the model value, native actions
reaching the model, a whole-value multilingual write through the real interface, every keyboard
path, both settings landing, the terminal owned and registered, and the operator's own
accessibility setting untouched — plus **9 spoken utterances with real audio**, 50 native
utterances all lineage-owned, and the wire paired 35/35. What stays **unclaimed** is progress
announced with real audio, progress name through navigation, reader navigation leaving the
application untouched, and six-role audio at 4/6. **The positioned-composition clause above is
untouched by any of that** and remains owed with its own prerequisite.

**Dependency evidence:** GPUI `window/a11y.rs:1–97` documents the AccessKit tree/action bridge; its workspace `Cargo.toml:511–514` pins its own baseline, `accesskit 0.24.0` and `accesskit_unix 0.21.0`, plus macOS 0.26.0 and Windows 0.33.1. Those are GPUI's pins and not this package's: the bridge above runs `accesskit 0.25.0`, `accesskit_unix 0.23.0`, `accesskit_macos 0.27.0` and `accesskit_windows 0.35.0`, and the checked-in `src/v7_host/accesskit_bridge/Cargo.lock` resolves exactly those plus `accesskit_atspi_common 0.20.0`. This plan defines our C ABI; it does not assume AccessKit already exposes that ABI.

**Verified core transaction repair (2026-10-03):**

- `App.semantic_publication` now stages the candidate semantic tree before old-frame retirement and commits it with the App tree, generation and reconciled focus. `FrameOutput.semantic_snapshot` exposes the committed borrow. Candidate keyed-owner lookup is available inside annotation; a failed annotation leaves both published outputs intact.
- The actual standalone public Session/App/Publisher consumer exited 0 across generations 1–3: first-frame annotation, failed-frame retention, recovery with stable identity and focus fallback. Evidence: `/tmp/nogui-semantic-transaction-proof-20261003.json`.
- AT-SPI, Windows and mobile callers consume the App-committed snapshot instead of staging after frame publication. Publisher teardown clears the App borrow before freeing its slots. Hidden-action and stale-pending-stage failures were reproduced and repaired; inert `popup_for` and duplicate `set_size` relations were removed.
- This proof contacted no accessibility provider. Orca and the test AT-SPI setup stay off; screen-reader, composition and other-SDK runtime acceptance remain open.
- The migrated smoke initially read the previous tree and failed three first-frame visible-list checks. Candidate-tree lookup and current-field shaping repaired that consumer: the headless arm passed all 27 checks. The owned-X11 `--native --hold-ms 1500 --ppm /tmp/nogui-semantic-native-final-OGx50Z/frame.ppm` run committed/presented five frames, generations 1–5, at 520×640 with zero measured caret delta and matching five-row publication/paint. The converted PNG was inspected. Adapter state stayed inactive and screen-reader state false; this is native-frame proof, not renewed AT-SPI or speech acceptance.

**Verified core progress and radio repair (2026-10-03):**

- The public App/Publisher regressions failed first: keyed progress returned `UnstableSemanticNode`, and selected radio reported `not_toggleable`.
- `DrawCtx.progress` now uses the existing optional-key binder. Built-in radios publish `checked` from the same selection that supplies `selected`.
- The core `api-w21` filter passed **41/41 tests**, **13/13 build steps**, exit 0.
- A separate public core consumer passed **4/4 build steps** across generations 1–3. Progress changed 60→85 and fraction 0.5→0.75 without changing identity after a Unicode caption change. Its default node remained read-only with no set-value or focus action. Ordinary radio activation changed 1→2, and explicit deselection published both unchecked.
- Evidence: `/tmp/nogui-progress-radio-proof-20261003.json`. No native adapter or screen reader ran. Native progress announcements and radio state readback remain unproved.
- The user renewed isolated W21 AT-SPI/Orca, private W18 Wayland checks and the first manual-chooser W20 capture. Source/runtime prerequisites must clear before those runs. Normal desktop services, Unlock prompts, external desktop actions and further capture requests remain outside this approval.
- **Status of that renewal, restated precisely (2026-10-03 continuation).** Of
  the three renewed scopes, only the private W18 Wayland scope ran; it is
  recorded under W18 above. The isolated Orca/AT-SPI run and the first
  manual-chooser capture **have not started**. Real private launcher, registry
  daemon and speech-dapter attempts were made and all retired with zero
  survivors; none of them was Orca, and none produced speech. No test AT-SPI
  service is running now and no normal desktop accessibility setting was
  changed.
  *(Superseded 2026-10-04 for both halves: the isolated Orca/AT-SPI scope ran,
  produced real reader submissions and real audio through an owned clock-paced
  capture, and retired with zero survivors — without six-role acceptance. The
  single approved first W20 manual-chooser capture has also since run, issued a
  real `CreateSession`/`SelectSources`, and ended `CaptureDenied` with no
  validated stream. See "Private native W21 renewal and current state
  (2026-10-04)" and the W20 "First actual capture request" entry above.)*
- **Three current W21 results are not native speech evidence.** The headless W21
  smoke passes 32/32, the core `api-w21` filter passes 41/41 across 13/13 build
  steps, and the separate three-generation public App/Publisher consumer passes
  with progress 60→85, fraction 0.5→0.75, stable identity across a Unicode
  caption change, and correct radio selection and deselection
  (`/tmp/nogui-progress-radio-proof-20261003.json`). None of the three activated
  a native adapter, reached the accessibility bus or produced sound. They are
  core and source evidence only.
  *(Renewed 2026-10-04: the alias regression first made the headless arm 36/37 RED; after the explicit callback cutover it passed 37/37. The linked core passed 90/90. These are core/model results, not native speech acceptance.)*
- **The public host read-back is documented because that consumer uses it.**
  `accessibility.Adapter.lastNumericValue(id)` is the numeric channel and returns
  an optional `f64`: `null` for an absent node and `null` for a present node with
  no numeric value, while a numeric **zero stays present** as `0.0`.
  `Adapter.lastValue` is the TEXT channel only and never carries a numeric
  range. Reading either one back out of the adapter's own buffers is the near
  side of the bridge: it states what AccessKit received, never what a platform
  announced and never what was spoken.


**Verified W21 (2026-09-29):**

- `zig build test -Dtest-filter=api-w21` passed 36/36, exit 0: a committed semantic snapshot with roles, state, slider ranges and text selection geometry; a virtualized list publishing one node for a million rows; native activation and set-value editing the bound model exactly once; stale, hidden and removed nodes refusing actions; a failed stage publishing nothing; and logical bounds converted to physical pixels at the native edge of a fake platform adapter.
- The AccessKit C-ABI bridge builds and links through `-Daccesskit-bridge` (default true), and a host without it reports unavailable rather than fake support. The full suite passes 1413/1413 across 34/34 steps with 0 leaks both with the bridge linked and with `-Daccesskit-bridge=false`.
- The AT-SPI bus is usable, and it was used. Live niri Wayland session with `DISPLAY=:0` (XWayland only), a D-Bus session bus, and a real AT-SPI registry reachable at `unix:path=/run/user/1000/at-spi/bus_0`. `at-spi2-registryd` is not on `PATH`, but the packaged binary exists and one was already running; `orca` is installed. `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache` was required, as under W07.
- One prerequisite decides whether the adapter exists at all, and it is worth recording: `accesskit_unix` 0.21 gates its entire AT-SPI backend on `org.a11y.Status.ScreenReaderEnabled`. With that property `b false` the adapter stays inactive forever and never appears on the bus. It was set to `b true` for the run, which is the same property a real screen reader sets, and reset to `b false` afterwards. It is `b false` now, the state it was found in.
- Native session, through the new smoke binary `src/v7_demo/w21_atspi_smoke.zig` and step `zig build w21-atspi-smoke`, on the same live niri Wayland desktop recorded under W07, added because the filter half above exercises only a fake platform adapter. It published one real Wayland toplevel at 520x640 through the real accessibility adapter.
- The tree read back from the real registry before any interaction: application `w21-atspi-smoke` containing frame `W21 AT-SPI Smoke` with states ENABLED, FOCUSED, SENSITIVE, SHOWING, VISIBLE, and 8 children — button `W21 Activate` with actions=click; check box `W21 Checkbox` with actions=click; slider `W21 Slider` with actions=click and value 25 of 0-100; entry `W21 Text Field` with states EDITABLE, ENABLED, SENSITIVE, SHOWING, VISIBLE; list `W21 List` with actions=click; button `W21 List Add`; button `W21 List Remove`; button `W21 Modal Open`. All 8 carried ENABLED, SENSITIVE, SHOWING, VISIBLE.
- Five real AT-SPI interface round-trips. Each was seen on the a11y bus itself, with `busctl --address=... monitor` printing `org.a11y.atspi.Action DoAction, INT32 0, method_return True`, and each was then proven by the application's own model counters rather than by the adapter's own report: `DoAction` on `W21 Activate` gave applied=1 and model button_hits=1; `DoAction` on `W21 Checkbox` gave checked=true; `Value.SetCurrentValue(75)` on the slider moved it from 25 to 75 with number_writes=1; `DoAction` on `W21 List Add` grew the rows from 3 to 4; `DoAction` on `W21 Modal Open` set modal_open=true.
- Re-reading the tree after those calls showed the check box carrying CHECKED and a new node, dialog `W21 Modal Confirm`, with FOCUSED moved off the frame onto the dialog subtree, so modal focus is observed at the AT-SPI level. The process exited 0, the leak check passed, no process was left behind, and the property was reset.
- This run found two production defects, both fixed. First, `Adapter.init` built the adapter on the stack and returned it by value while the bridge kept that raw pointer, so the pointer referenced a returned frame and the first real AT-SPI action segfaulted at address 0x68 through `futexWaitUncancelable <- enqueueRequest` in [accessibility.zig](../../../src/v7_host/accessibility.zig). No unit test could see it, because no test receives a request from a real screen reader; `init` is now self-initializing. Second, the bridge's `Drop` did not stop AccessKit's event-loop thread, so a late callback could dereference a destroyed adapter; with a screen reader registered the Zig suite aborted after all assertions had passed, with `signal ABRT` and a frame in the same file. The bridge now closes a gate that every host callback takes before the box dies, and the suite passes 1426/1426 with the screen reader registered.
- Those two suite counts are not the same observation: 1426/1426 is the Zig suite with a screen reader registered on the live bus, and the 1413/1413 in the earlier bullet is the filter-only condition. This plan does not attribute the difference between them.
- Boxes: all three stay unticked, because each is broader than what the run covered. The first box's covered part is roles, names, states, the slider range, actions, stable live owners reaching the model once, and the focus move into a dialog; its uncovered part is descriptions, shortcuts, active-descendant relationships, text selection/geometry and the hidden/disabled policy at the native edge. The second box's covered part is native activation, set-value and modal focus resolving the same live model; its uncovered part is the accessibility-bell capability, the native conversion of visual logical bounds, and the list/selection relationship through the List interface. The third box's covered part is a real bridge that linked, registered on a real registry and survived real calls; its uncovered part is panic containment, main-thread marshaling and the no-Rust-objects-leak claim.
- Not run, and still not observed: Orca keyboard activation, and Orca speech announcements for any of the four roles. Orca starts and stays alive, but it never registers on the a11y bus, never sets `ScreenReaderEnabled`, never starts speech-dispatcher and never appears in the bus listing, and a grep of the Orca 50.2 python package finds no code that sets the property. Independently, a native Wayland client cannot receive synthetic key events at all, because `wl_keyboard` is compositor-mediated, so no screen reader can inject Enter or Space into a Wayland toplevel. The AT-SPI Action interface, which is what Orca's own activate command calls, was driven instead and did reach the model; that is a substitute for the action path, not for Orca speech.
- Text composition through EditableText and list row selection through the List interface were also not driven. The host's pygobject `Atspi` bindings return `None` from `get_text_iface()` and expose no object paths, so no edit was ever issued against `W21 Text Field` and no selection call was ever issued against `W21 List`.
- The modal `STATE` flag is mapped by the adapter, but `semantics.Draft` has no `modal` field and no widget kind produces one, so no application can set it today. The dialog is published by role and the focus move into it, which is what was observed; the modal state flag itself was never set or read.

**Headless ASCII caption ownership repair (2026-10-01):**

- The defect was reproduced before it was fixed, through the public API rather than a source reading. A public consumer mounting a real `App` drew two buttons, one with a `visual_label` and one with an explicitly empty one, and the resulting map printed the visible caption TWICE. Red: the consumer failed with `UnexpectedMapCaption` at index 8 on the character `V`, i.e. the second copy of the first glyph of `VIEWONLY`.
- The cause was ownership, not glyph selection. `DrawCtx.button` emits a visible caption as a generated label child, and `renderAscii` ALSO drew the parent's own `widget.buttonVisualLabel`, so one caption had two painters. [`src/v7/headless.zig`](../../../src/v7/headless.zig) now skips the parent's own `drawText` when the button has children, which leaves the generated label as the single owner, painted at the child's own laid-out rect. The childless fallback is retained, so a button with no generated child still paints `widget.buttonVisualLabel` at its own rect and an empty `visual_label` still draws nothing.
- Registered regression: `renderAscii: a button caption paints once, never its semantic name` in [`src/v7/headless.zig`](../../../src/v7/headless.zig) builds a real `Session` and `App`, mounts a root and commits a frame with JSON, then asserts that the map's entire alphabetic glyph sequence is the visible override exactly once and that both semantic names are still in that frame's JSON. It asserts the SEQUENCE, not coordinates: a second copy of the caption, a leaked semantic name and a caption that stopped painting all change that sequence, while none of them depends on where the map puts a glyph. The final gate, run after that test's last pruning, is `env -u DISPLAY -u WAYLAND_DISPLAY taskset -c 3,4 zig build test -Dproduct=core -Dtest-filter=renderAscii -j1 --summary all`: exit 0, 15/15 steps, 9/9 tests, 8 named plus one anonymous. No production change followed the public consumer run below, so that map is still the proof the fix works.
- The same public consumer was then run for real: `env -u DISPLAY -u WAYLAND_DISPLAY taskset -c 3,4 zig build run -j1 --summary all` exited 0 with 4/4 steps and printed `OK visible=VIEWONLY hidden=empty semantic_json=preserved`. The inspected map carried ONE centered `VIEWONLY` line at the generated label and an all-`#` box with no glyphs for the suppressed button.
- What the contract is, and what it is not: a button's visible caption is drawn once, by the generated label child when the control has one and by `widget.buttonVisualLabel` at the button's own rect when it does not, while the semantic name stays machine-readable in JSON. The map's cell columns, glyph spacing and parent/child order are an artifact of text rasterization at 2px per cell and are NOT part of the API. That is why the regression asserts the glyph SEQUENCE rather than any drawn offset, and why the guide states the child's own layout position instead of a quoted float order.
- Scope and non-claims: this is a HEADLESS CPU result. It is not a rendered window, not a GPU or noapi result, and not assistive-technology evidence, so no W21 box is closed and the Orca and `EditableText` gaps recorded above stand unchanged. The accessibility bell named in that box is no longer missing: it is implemented as a window call and has its own native run recorded next. This ASCII repair says nothing about it either way.

**Native window bell and window teardown evidence (2026-10-01):**

- The bell is a WINDOW call, not a tree call, and [`src/v7_host/system_bell.zig`](../../../src/v7_host/system_bell.zig) is the code that answers it. `accessibility.Adapter.bindSystemBell`, `unbindSystemBell`, `bell` and `systemBellAvailable` reach it through the `Application` that owns the window, and `Capability.bell` is that window's runtime measurement rather than a fact about the AccessKit bridge. The backends are each platform's own: X11 borrows SDL's Xlib display, takes the XCB connection inside it and sends the core `Bell` request at percent 0, which rings without changing the volume the user selected; Wayland binds an advertised `xdg_system_bell_v1` on a **private event queue** so discovery never enters the queue SDL pumps; macOS is `NSBeep` and Windows is `MessageBeep(MB_OK)`. A provider owns only what it allocated, and the SDL window, the Xlib display, the XCB connection, the `wl_display` and the `wl_surface` stay borrowed.
- The binding contract, as these runs used it: a bind succeeds on a platform with no bell at all, because it is a lifetime statement and rings nothing; a second bind on the same adapter is `BellAlreadyBound` and a window another observer owns is `BellObserverBound`, so a refusal never displaces the observer already in place; `unbindSystemBell` is `!void`, belongs to the thread that made the binding, and on `error.WrongThread` leaves the WHOLE binding in place rather than half-clearing it; and `bell()` answers `rung`, `unsupported`, `provider_failed`, `window_closed` or `wrong_thread` instead of claiming a sound.
- The native run found a startup defect first, and the repair is part of the evidence. `runNative`'s `errdefer` ran BEFORE `Application` initialization succeeded, so an invalid SDL driver left `Application.deinit` reading uninitialized slots and the process died with `ABRT` and a general-protection fault instead of reporting the failure. The `errdefer` now sits after the successful init. The same scenario rerun is a clean `error.SdlInitFailed`, exit 1, `session_deinit=ok`, and no `ABRT`.
- X11, on a **private** Xvfb at `DISPLAY=:1` with Openbox and a new private D-Bus with no service directories, using the executable compiled by that same run: `--native --bell --hold-ms 1000 --ppm /tmp/nogui-w21-bell-x11.ppm`, exit 0, Vulkan 1.4 on the NVIDIA GeForce GTX 1660 Ti. The bell reported `available=true` and `request=rung` **while the adapter `State` was `inactive` and `screen_reader` was `false`**, which is the reason availability is measured from the window: the bridge state and the platform bell are separate facts. The PPM that came back was the real 520x640 frame with 262600 inked pixels, a field box of 19520 and a selected-row box of 10472, and the converted PNG showed the button, the check box, the slider, the `Grüße✓` caption and the selected virtual row together with the list and modal controls. The counters were `frames=1 presented=1 retries=0 rects=54 published_generation=1`; the close reported `released=true window_count=0`, retirement `surface_before_window=1 frames_at_retire=1 target=520x640`, the final bell `window_closed`, and `session_deinit` accepted.
- Wayland, on an **owned nested** niri 26.04 / Wayland 1 session with its own runtime directory, the same cached executable and `--native --bell --hold-ms 1000 --ppm /tmp/nogui-w21-bell-wayland.ppm`: exit 0, the same counters, the same real pixels and the same teardown order, and the actual PNG was inspected. That session's global enumeration contained **no `xdg_system_bell_v1`**, so the run answered `available=false request=unsupported`. That is a real negative capability read off that compositor; it is **not** proof that the Wayland bell path works. `org.a11y.Bus` is absent in that session and SDL reports unsupported operations, and the run reports both rather than suppressing them; no native AT-SPI or speech result is claimed from that session.
- A compositor-initiated close was driven for real as well, which is a window fact rather than a bell one. The owning Niri IPC `close-window --id 4` was issued on the owned socket while the run held a 600000 ms window, the process took the mid-hold retirement branch and exited 0. Pixels were correctly unavailable at that point, because the surface holding the last presented frame had already been released, and the run said so instead of reading a freed target: `frames=1 presented=1 host_running=false`, the close platform `closed` during the hold, `surface_before_window=1 target=520x640`, the bell `window_closed`, and `session_deinit` accepted. `NativeFrame` keeps its documented order — the release snapshots the stats and the target, then the teardown runs App-detach, NativeFrame, Surface and Gpu **before** SDL destroys anything — and the normal path reads those pixels out of that target first.
- What these runs are not: nobody heard the X11 bell, because `rung` is what the platform accepted rather than an audible result. No `NSBeep` or `MessageBeep` has run on its own OS here, and no compositor on this host advertises `xdg_system_bell_v1`, so there is no positive Wayland bell proof. Orca stays off, and the `EditableText` and `List` gaps recorded above are untouched by any of this. The six host window-bell regressions have now passed inside `zig build test -Dproduct=host -Daccesskit-bridge=false -Dtest-filter=api-w21 -j1 --summary all`: 25/25 steps and 67/67 tests, including 32 host tests. This unlinked gate is not a native SDK activation result.
- Validation exposed two GPU defects during a real mid-hold close: five shader-in-use destruction errors and an indirect-command-read destination-stage error. `NativeFrame.deinit` now drains submitted work before destroying shaders or descriptors, with a failed drain fatal; the noapi Vulkan backend adds `draw_indirect_bit` for `draw_arguments` hazards. The rebuilt private Niri scene, with `VK_LAYER_KHRONOS_validation` enabled, presented one frame and was closed by the owned compositor before its 600000 ms hold expired. It exited 0 with `surface_before_window=1`, `host_running=false` and accepted Session teardown; the complete run log contained no VUID or validation error. This proof used only noapi GPU calls and the owned window.

**Race-free reactivation, native Text and virtual-list selection (2026-10-01):**

- A real SDK activation previously panicked because the initial update lacked its tree declaration. Checking the host flag before conversion left a race.
- The owned C ABI now supplies the complete current snapshot synchronously inside the SDK update factory. That factory holds the SDK state lock.
- The host reserves every node, relation, character table, hash entry and send slot before the call. The supplier allocates nothing and calls no native API.
- Rust copies the borrowed records into owned SDK values before returning. The factory retains no host pointer and does not reuse a cached tree.
- The deterministic late-activation regression rejected an isolated old conversion boundary with a missing-tree failure. The current bridge passed **19/19** Rust tests.
- A new changed-branch regression exposed inverted ancestor propagation. Red omitted the changed node's container. Green publishes its ancestors without resending an unchanged sibling.
- `src/v7_host/root.zig` now imports the adapter test root explicitly. A narrow filter previously ran anonymous tests without reaching that regression.
- `zig build test -Dproduct=host -Daccesskit-bridge=false -Dtest-filter=api-w21 -j1 --summary all` passed **69/69**, with 25/25 steps.
- The rebuilt default linked consumer passed **27/27**. Its unchanged nodes remain absent from deltas, rather than forcing identity assertions onto empty updates.
- The actual native client then found a separate selection defect. Unselected rows omitted the SDK's `selected=false` property, so `Selection.SelectChild` returned false.
- The bridge now separates selection capability from its current value. Click-selectable virtual rows publish both true and false states. Non-selectable rows omit that property.
- The selection regression failed with `None` instead of `Some(false)` before the repair. Native selection then reached the model exactly once.
- Final native command: `w21-atspi-smoke --native --no-synthetic --hold-ms 90000`, with a private Xvfb at `DISPLAY=:1`, Openbox, private session/accessibility buses and a real registry.
- An external client made the D-Bus calls. Result: **67 passed, 0 failed, 0 not established**, exit 0.
- `Text.SetSelection(0,1,3)` read back `(1,3)` on the seven-character, eleven-byte `Grüße ✓` value. The caret moved to character 3.
- Character index 8 was refused without a model action, although it lies within the UTF-8 byte length. `SetCaretOffset(2)` then produced the collapsed selection.
- `Selection.SelectChild(0)` selected logical row **39998**, named `W21 row 39999`. The model reported `row_picks=1`, and native selection read back that same object.
- The list served five rows from **250000** logical rows. A past-last-child request changed neither the model nor the selected object.
- Four private deactivate/reactivate rounds each preserved all 15 object IDs and names. Every child's native `Parent` matched the walked hierarchy.
- No cycle repeated a model action. The run retired four GPU frames with `surface_before_window=1`, accepted Session shutdown, and contained no VUID or panic.
- The external client also needed correct two-scalar selection decoding and tuple-valued `Parent` decoding. It now waits for the requested row, not the old valid selection.
- Scope: the pinned SDK serves `Text` but no `EditableText`. Composition remains open. Orca stayed off, and no user accessibility setting changed.
  *(Superseded 2026-10-04: the pins moved, and the pinned Unix provider does expose `SetTextContents`. See the current entry below.)*
- No macOS, Windows, mobile, positive Wayland-bell, speech or screen-reader keyboard acceptance follows from these Linux results.


- No box in this package is closed.

**Checkbox reconciliation (2026-10-03):** checkboxes 1, 2 and 3 are complete at the
source level and are ticked above. Each clause is answered by a retained run, not
by a compile: checkbox 1 by the typed snapshot with roles, state, ranges, relations
and one node for a million rows plus the 250000-row virtual list; checkbox 2 by the
staged-then-committed publication whose failed frame publishes nothing, the native
edge conversion, actions resolving the same live model exactly once, the bell as a
window capability measured from a bound window, and the list/selection
relationship through a real SDK selection; checkbox 3 by the owned Rust C-ABI
bridge, its 19/19 Rust regressions and the unlinked-host refusal.

That supersedes the two dated statements above that predated those repairs — the
2026-09-29 "Boxes: all three stay unticked" note and the 2026-10-01 "No box in
this package is closed." Both are left in place as the record of what those runs
had actually covered; neither describes the current source state.

The Acceptance/Gate line is not weakened by the ticks, and **2026-10-04**: the
reason this clause used to be written is gone. It said the pinned SDK serves `Text`
but no `EditableText`. The pins are now `accesskit 0.25.0`, `accesskit_unix 0.23.0`
and `accesskit_atspi_common 0.20.0`, and the pinned Unix provider **does** expose
`SetTextContents`. *(The 2026-10-04 native renewal then made all three
whole/empty/restore writes through
`org.a11y.atspi.EditableText.SetTextContents`; see the current-state section
below. That part of this sentence is no longer open, and other composition
methods may still refuse.)* Against this package's own Acceptance text, what
remains unobserved is: Orca speech announcements with real audio for any of the
six roles. Native keyboard activation and whole-value `SetTextContents` writes
have since been observed. Reordering, hidden and removed nodes, and failed-frame
publication each have their own retained run, and the selection relationship is
proved natively:
`Selection.SelectChild(0)` selected logical row 39998, the model reported
`row_picks=1`, and the native selection read back that
same object from the list's five served rows over 250000 logical rows, in the 67/67
run above.

Two items in the dated record above are now obsolete rather than open, and this
note does not carry them forward. The 2026-09-29 entry said the modal `STATE` flag
could not be set because `semantics.Draft` had no `modal` field; the field exists
now (`states.modal`, set only through `Draft.modal`), `accessibility.zig` maps it to
the bridge's `1 << 8`, and the W21 smoke both authors and reads it. That entry also
said no selection call was ever issued against the list; the run above did exactly
that. A positive `xdg_system_bell_v1` ring is a runtime **supported limit**, not an
Acceptance clause: no compositor on this host advertises that global, and the
recorded `available=false request=unsupported` is the honest reading of it. macOS,
Windows and mobile accessibility targets remain unbuilt and unrun. Every dated run
above did keep Orca and the test AT-SPI setup off; the 2026-10-04 private renewal is
the one that ran a real Orca, on an owned private session, and it retired
completely.

**Private native W21 renewal and current state (2026-10-04):**

**Reader-origin, UID and profiler proofs (2026-10-04; superseded for speech by the run below).**
The genuine stock-SSIP UID component is **green and narrow**: exit 0 in 19.03 s, report
`/tmp/nogui-w21-native-uid-wt3c2jw9/report.json` — 87,144 bytes, SHA-256 `21e950ed…`, mode 0600,
link count 1, own mode-0700 root — with zero failures, two owned children reaped and no
in-session process left. It read a real SPEAK **UID 1** and the inner `send_command` **UID 2**,
with the stock code unchanged, one connection epoch, and the outer CHAR answering `None`, while
**every row is `ORPHAN`**. That component alone is not a speech proof, and it is superseded for
speech by the real-stack run recorded below; it is kept here as history and is not credited with
the speech that came later.

The earlier attempts stay historical reds and are not rewritten. The passive
genuine-components proof, `/tmp/nogui-w21-reader-origin-component-proof.py`, exited 1: its
c1 and c2 passivity cases passed, but all four harness children were ended with `SIGTERM`
rather than reaped naturally, and c3 profile precedence, c4 thread behaviour and the footer
remained unproven. The genuine-UID smoke, `/tmp/nogui-w21-native-uid-smoke.py` under root
`/tmp/nogui-w21-native-uid-rwohalnm`, exited 1 with readiness unproven — 40 seconds of log
showing only the starting state — so the client UID and the module identity are both unknown
and it is **not** a UID extraction proof. A later run's sole failure was a malformed
two-field readiness `CLIENT_NAME`, since repaired to the stock three-field form. No new
native approval was spent by any of them, and no UID-attributed speech is credited.

The profiler aggregate is red and **no profiler pass is claimed**: one proof failed six
aggregate clauses because CPython 3.14 installs monitoring tool 2 for `cProfile` — 24,607
events — so `sys.getprofile` reads `None`, which the old source helper's hook-only guard
misses; two corrective units are active. That proof's other results stand: all four children
exited naturally 0 and all 11 native thread-identity birth checks passed, with no UI, daemon
or native UID anywhere in it.

The kernel-side located-PCM integration run over the legacy consumer exercised **10 of 10**
cases with 0 failures and 17 unexercised in 564.45 s, integration-only. Result
`/tmp/nogui-w21-located-pcm-proof-2026-10-04T21-25-54-565Z-1451831.json`, journal
`/tmp/nogui-w21-located-pcm-proof-journal-aUZ0gJ/cases.jsonl`. AFTER-unlink, AFTER-directory and
a third AFTER-truncate all passed with `unknown`, `spoken=false` and null across all ten
metrics, and the first eligible legacy row 6/1 read its real before flags, reference 55618B,
13 chunks and the unique `[118112,173730]` window over a 4,256,050-byte whole. **The
historical 19/7 subject is still absent and was not retargeted**, and the 11 helper cases are
excluded because the mode is integration-only, so this is **not** a full 27-pass. UID
provenance remains LEGACY_ORDINAL and unsafe: the native causal UID is unknown and the old root
is not credited. The measured cost was a 301,024 ms `bound_subject_forward_pass` against
32,780 ms baseline bind, 30,981 ms AFTER-unlink, 43,138 ms AFTER-directory and 64,307 ms
AFTER-truncate, which leaves the 64 KB pipe hypothesis **unproven**; the bounded-IO item is
closed, and no approved evidence changed, no process was started and no fresh approval was
involved.



**Current results (2026-10-04/05; consolidated).**

**A full real native stack now produces genuine speech.** Three real-stack runs are on record,
all on a real Xvfb `:90`, a real session bus, real dconf with `screen_reader_enabled` read back
true, the real AT-SPI bus and registryd with `ScreenReaderEnabled=true`, a real speech-dispatcher
with the espeak-ng module and module observer all owned and pinned, real Orca 50.2 attached and
alive, a real focused window, a real XTEST keyboard, a real AT-SPI client, and a real PCM monitor
capture on the LIBAO NULL no-hardware backend. `bg355` and `bg357` exited 1 with no synthesis,
the second after the owner-gate repair below. `bg367` ran after that repair **and** the
reader-hook restructure and is the one that speaks: **0 tracebacks, a 372-row reader trace,
`spoken_utterances=9`, `synthesized=true`**, the evidence gate `ok`, and PCM genuinely read and
clock-paced. Attribution in that run: **50 native utterances, every one lineage `owned`, on the
real reader thread**; **35 carrying message ids**; **37 distinct `frag_seq`, each with its own
ACSS**; **100 `reader_text` rows beside 100 `ssip_argument` rows**; **waveform identity proved
for 9** by exact-once PCM location, with **41 unproved and explicitly not credited**; wire paired
**35/35, zero unpaired, zero disagreements**.

**PASS:** `screen_reader_attached`; `published_roles`; the radio group relation and its check
marks; the progress value equal to the model value; native actions reaching the model; a
whole-value multilingual write through the real interface; every keyboard path; both settings
landing; the terminal owned and registered; and the operator's own accessibility setting
untouched.

**FAIL, recorded as unclaimed rather than pending:** progress announced with real audio; progress
name through navigation; reader navigation leaving the application untouched, with **0 chords
delivered** in that run; and six roles spoken with real audio at **4/6**, the button role
mismatched and progress unannounced.

**Reader attached and roles published is not reader announced.** That distinction is the
load-bearing one here. The nine utterances are observed with real audio and are claimed;
everything beyond them is not — not the 41 unproved waveforms, not progress, not the two missing
roles.

**Native full acceptance stays 18/22 and is not granted.** The four remaining native items —
progress name/state binding and progress identity credit — plus two reader dispatch/retirement
branches, five provenance partials needing native faults or a fragment extension, and five
Windows/macOS menu items needing a non-Linux runtime, are **blocked with named prerequisites**.
They are not pending and not reachable.

**Two real product defects were found by these runs and fixed, each with before/after proof.**

1. `correlateSpeech()` read its evidence-owner gate from the 4th positional argument while the
   finalised owner list was passed *inside* the reader-identity object in the 3rd, so the gate
   always received `null`, saw all three required owners missing, and refused to read any PCM or
   credit any utterance **even though finalisation had succeeded**. Fixed by passing the finalised
   list positionally; the re-run flips `evidence_owners.ok` from `false` to `true` with all three
   owners recorded `established=true missing=[]` and 6,646,888 bytes read at `clock_paced=true`.
   The closure-order proof had already shown that gate refusing correctly, so the repair fixes
   the real run's inability to ever *use* it.
2. The reader dispatch hook **crashed on a `None` target**: its guard was gated on `_pending`,
   letting unbound frames dispatch `None` once binding had completed, and the error path itself
   dereferenced `None`, killing Orca 50.2 at startup before any presentation. Restructured so a
   still-`None` target always returns, verified by zero tracebacks, the 372-row trace and 9
   spoken utterances.

Both reader proofs stayed green through every hook revision. They are green against the current
helper: compatibility **111/111**, verdict `proven`, 0 failures; failure proof **226/226**,
verdict `proven`, 0 failures. The helper is `nogui_reader_origin.py`, **SHA-256**
`4ecc9fcf5dfa704c97cfb758b7dad16a8ac0dcf36118f7aa48491bb0953ea271`, measured by the parent with
`sha256sum /tmp/nogui-w21-reader-origin/nogui_reader_origin.py` and reproducible with that exact
command. Two earlier digests are prior states only: `b8d38931…` from the cleanup round and
`1d0605a4…` from before it. Two limits on the failure proof stand: the source `MAX` bounds remain
**unexercised**, with the real `RLIMIT` 32768 exercising only the common failure path, and the
induced `direct_hook` bind `BaseException` is labelled not a natural nested monitor. Five bad
witnesses were fixed in the harness and **not** by weakening helper behaviour.

**Gates.** The full Python `unittest` suite passes **175 tests** with Ruff clean. Zig lint reports
**0 errors and 0 warnings across 258 files**; Debug check is **89/89**; ReleaseSafe check is green
in 133 s with **1959/1959** tests passed. The ReleaseSafe leg became green after a concrete fix
rather than a lucky rerun: `w23_windows_smoke.zig` shadowed its top-level `refusal()` function
with a local `refusal` bool, and renaming that local to `duplicate_refused` removed the only
compile failure. Formatting is clean after touching one file. The fixture gate passes **5,524**
with 0 failed and 0 unsupported, the layout golden matches **581 rows**, the build passes **25 of
25** steps, and the vendored noapi tests pass **3/3** steps with **66/66** tests. All six external
dependency consumers pass — `core`, `text`, `renderer`, `host`, `test_support` and `offscreen`,
the last with its CPU arm at 32 checks — which is consumer and packaging evidence, not native OS
evidence.

**Portable scopes unchanged.** The current W21 headless source passes **42/42** — typed positioned
composition, live sequential selection, an 8192-byte storage refusal, ring whole-value 4096×2 plus
overflow and the exact published state — core and headless evidence with no native adapter, bus
or reader involved. The device-free private W19 kernel proof passes **28 of 28** with 0 skips,
descriptors balanced at 16 → 16 and every private owned child gone, and it **earns no native
credit**; `NOGUI_W19_CONTROLLER_MAIN=1` refuses with exit 2 before any import. The cached-GI
off-bus check proved **6 of 8** claim slots and stops there, overall `not_established`: real
`Object.app` assignments raise `RuntimeError`, no populated app chain exists, and nothing
corroborates an identity or memory offset. The AT-SPI type-library version reads as **2.0**
through the library's own `get_version`, with no ctypes bypass. The stock SSIP UID component on its
own stays a narrower record than speech — a genuine run with real SPEAK UID 1 and inner
`send_command` UID 2, one connection epoch, the outer CHAR answering `None`, and **every row
`ORPHAN`** — superseded for speech by `bg367` and not credited with it.

**W19 unknowns.** The canonical controller source is unchanged at `A71E` with every item already
fixed in source, but the **native 11 fields and 2 kernel branches remain unknown** — source-fixed
is not observed — and no UI approval was used. **GCR 3 preparation is done and is preparation
only:** the inert unlock-plan run is source-ready against real providers, the gcr3 41.2 prompter
wrapper and two `Exec` service cross-checks, on a private `:90` X11 display with a fresh root, but
**no child service, GUI, keyring or prompt was started, nothing was observed, and no native
approval was used**. `Unlock` itself stays blocked on fresh consent.

**The lifecycle closure proof is green:** exit 0, no missing claims, `unexpected_programs` empty,
no re-signal, zero live owned groups and every owned pid gone. Earlier failed lifecycle and
observer attempts are prior states, not results.

**Metadata C is green:** 9 cases, **115 PASS / 0 FAILED / 1 UNEXERCISED**, the single
unexercised case being the named mid-call symlink swap needing an in-window adversary. Both
independent birth references agree exactly and exactly one field is plausible; the `EMFILE` is
real and kernel-level. The metadata fragment is 7,246 bytes. Root
`/tmp/nogui-native-metadata-kernel-final-failed-92c0d0c5-1d4c-4f1e-9b6a-63e3f4d3e0ba` — *the
directory name predates the repair round; the run it holds is the green one.*

**Peer-credential mechanism.** A `SO_PEERCRED` socketpair reports PID 2469773, UID 1000 and
GID 100, each matching that process's own `getpid`, `getuid` and `getgid`; the socket is
unconnected and closed with no peer, and descriptors are balanced at 8 → 8. A mechanism result,
not a presentation or audio result.

**First-phase native steps still blocked.** The native `Action` describe and `TextSelection` steps
remain source-complete and native-unexercised: the retained real act answered everything and
recorded no query refusal. Both stay **blocked** on a fresh approved private AT-SPI fault
provider or query refusal — not on a refused mock echo, not on a source assertion, and not on
rerunning the unchanged boundary proof.

**Cocoa and Windows are source-typed, with no native claim.** Six real `C struct`
`@property(copy)` errors were reproduced against the real `nogui_macos.h` and corrected at source,
and the portable GNUstep ARC syntax passes. **Full AppKit SDK, the shim and native Cocoa remain
unexercised.** Windows source is type-checked, cross-compilation reached link and the native
ReleaseSafe gate is green; an actual Windows or Cocoa menu run still needs that runtime.

**The tracker is closed:** 838 items, 751 done and 87 explicitly blocked with a named
prerequisite, zero open.

- Dated evidence for the block below:
  `/tmp/nogui-w21-approved-2026-10-04T04-54-32-795Z/evidence/result.json`. It
  superseded the earlier present-tense no-client, no-whole-write and no-keyboard
  claims in the records above it, and it is itself superseded by the
  2026-10-04T14-09-07-151Z run recorded further below. Every bullet in this
  block describes that 04:54 run and is not the current state.
- The real private AT-SPI `EditableText.SetTextContents` route held complete
  Unicode, empty and restore writes. The application published
  `W21 Ω αβγ 日本語 ✓ Grüße` at 35 host **bytes**, then empty at 0 bytes, then
  its own first reading `Grüße ✓` at 11 host bytes; the platform served the same
  whole values back as 21, 0 and 7 **characters** with the caret collapsed at
  21, 0 and 7 and `getNSelections` 0 each time. Each write moved the model
  exactly once (`text_writes` 1→2→3→4) and moved only `caret`, `text` and
  `text_writes`.
- The earlier native run at
  `/tmp/nogui-w21-approved-2026-10-04T03-32-22-518Z` reached the field but
  panicked in the SDK consumer after Unicode and clear. Staging now owns the
  complete text value and three tables for one committed frame. The C ABI
  preserves present-empty text separately from absent text, and a collapsed
  empty caret addresses zero. The renewed native smoke exited 0 without that
  failure. Its actual final framebuffer was inspected.
- Native keyboard Space/Return activation, slider movement, radio selection,
  printable text and caret movement held, each against a real published model
  counter: `button_hits` +1 for Space and +1 for Return, `level` delta 5 for the
  slider keys, radio choice 1→2 with focus following the selected option and
  Left moving it back exactly, one printable character taking `text_writes` 4→5
  and caret 11→12, and one caret key moving caret 12→11 with the text and the
  write count unchanged. The count/index enumeration and sparse reporter
  corrections are now exercised on the real provider.
- The stock reader's own object navigator is the one route that reaches the
  read-only indicator. The indicator is published `read_only=true`,
  `focusable=false`, `actions=0x0`, so neither the FOCUS route nor the keyboard
  can reach it. From `W21 Slider` at sibling 7 under `[<window>]`, one
  `Orca+Control+Left` "previous sibling" command reaches `W21 Progress` at
  sibling 6; the reader's own log then runs `_generate_progress_bar` with
  `formatType: unfocused` and produces `_generate_accessible_name: [W21
  Progress]`, `_generate_progress_bar_value: [30 percent.]` and
  `Results: [W21 Progress, 30 percent.]`. No model key moved across that chord,
  so the reader's extra modifier never reached the application as a mutation.
  That is an observation, not closure: the required item still demands real
  owned audio for that control.
- Full acceptance was false for that run, and exactly eight non-text client steps
  failed, each with a named cause rather than one category label:
  `slider:set-value`, whose own `Value` setter call never reached the model;
  `progress:is-read-only-and-cannot-be-driven`, which is a **bogus gate**
  because the indicator really is read-only and non-focusable and the run never
  attempted a mutation at all; `list:the-selection-interface-reads-back-what-was-asked`,
  which compared a `selected_count` of 1 and an `index` of 2 as though they were
  two child counts; `list-add:custom-action`, because the `Add` named action
  was absent from the tree; `modal:disabled-control` and
  `modal:hidden-left-the-tree-and-disabled-stayed-in-it`, which exposed a **real
  SDK bug** — a disabled node still published `Enabled`/`Sensitive`, which also
  made the `Disabled` clause impossible to satisfy from the platform side; and
  `list-add:works-again-after-the-dialog-closed` plus
  `list-add:republished-and-drivable`, the absent reactivation named action.
  The clock-paced capture credited that run 0/6 names with states: adjacent
  submissions receive zero-width attribution windows. No role or condition is
  dropped.
- Real synthesis and clock pacing are themselves proved, independently of the
  credit question: `parec` recorded 8,079,086 bytes over 183,199 ms of
  `s16le 22050 Hz mono` from the private null sink's monitor, 1,741 observed
  intervals of which 1,740 grew, median 44,039 bytes/s against a declared
  44,100. The daemon logged one "server audio is not supported" error and it is
  attributable to **no** module, because all three located module logs are empty
  and both the configured and the refused binary carry the identical string.
- All 32 owned pids were re-observed gone after teardown, with no own survivor.
  The normal accessibility setting was `false` before and after. The native
  smoke exited 0; the client and complete fixture exited 1.
- Focused checks before the named-action cutover were unlinked `api-w21`
  93/93, locked bridge-only Rust 22/22 and linked CLI 38/38. Current focused
  changed-union results are recorded below. Neither set is a renewed full
  project gate or native acceptance. Earlier mobile 4/4 and Windows 7/7
  checks remain model evidence, not target runtimes.
- `accesskit 0.25.0`, Unix 0.23.0/common 0.20.0, macOS 0.27.0 and Windows
  0.35.0 remain the coherent pins. Unsupported partial text methods were named
  and never called. Whole-value proof does not establish native IME composition.
  A01 and A02 remain open.

**Named-action and disabled-state cutover (2026-10-04; since exercised natively).** The
bridge C ABI now carries
`nogui_accesskit_custom_action { int32_t id; const char* name; size_t name_len; }`
on every node alongside `custom_actions_len`, and the action request returns
that exact signed `int32_t`. The host's tree buffer reserves every descriptor
slice before it hands out a single pointer, so a growth during node append
cannot move a buffer a descriptor already points into, and the SDK owns its own
copy of every name. The locally pinned **same-version** `accesskit_atspi_common`
0.20.0 patch is what makes those records reach a reader: upstream 0.20.0
published a single `click` action and sent `Action::Click` for index 0 whether
or not the node was clickable, while the patch publishes `click` at index 0
**only** for a genuinely clickable node — so a custom-only action list
legitimately starts at index 0 — publishes every `Node::custom_actions` entry
with its own exact signed id, and stops reporting `Enabled | Sensitive` for a
disabled node. A custom-only action index of 0 is therefore valid, and index 0
means `click` only when the node really is clickable.

The parent reproduced the former named-list-owner branch failure
(`expected 1, found 0`), restored the correction and passed Core `api-w21`
**95/95**. The locked offline Rust `--workspace --all-features` command passed
**22 SDK + 22 bridge tests**, including `simplified`; the rebuilt linked CLI
passed **38/38**. These focused checks cover the source cutover, not renewed
native acceptance or the final full project gate. No existing client step name
or JSON envelope changed. The pinned `Value` setter still acknowledges
asynchronously, and `UnknownObject` is not evidence of a read-only node.
Named actions and exact model deltas are not to be replaced by click fallbacks
or by an "expected limitation". A fresh full-union run and a renewed native
acceptance run over the changed tree are the outstanding proof.

**Genuine wire component renewal (2026-10-04; native reader audio still open).**
The declared `sd_espeak-ng` and module observer passed five real cases: normal
speech, STOP, repeated identical text, SIGKILL and post-fork pidfd refusal.
The input/output traces equal the actual forwarded bytes. Independent decoding
through the current native controller agrees with every raw/index span,
request owner and transaction bracket in all five cases. Normal speech yields
33 chunks / 214,588 PCM bytes, including 13 chunks with odd escape counts.
STOP retains its original request 4 / transaction 1, with ten genuine audio
chunks after STOP and a real module `703 STOP` closure; daemon `703 CANCELED`
remains a separate UID-bearing message. Repeated text owns distinct requests
4 and 5 and transactions 1 and 2, with 214,588 and 214,994 PCM bytes respectively.
SIGKILL is a true `-9` wrapper exit, not normal exit 137. A child-only kernel
filter allows the observer's self-pin but refuses its forked child's pin:
the gated child exits 126 and is reaped, the observer exits 2, no module executes
and no bytes are forwarded. No synthetic module or fabricated reply is used.
The real replay first caught a consumer defect: INIT/QUIT were mislabeled as
no-reply commands and block spans omitted the verb line. It also caught a false
requirement for a transaction bracket in traces containing no transaction.
Those causes are corrected; per-transaction bracket coverage remains required.
Evidence: `/tmp/nogui-w21-real-module-proof-wwbav570/actual-results.json` and
`current-consumer-replay.json`. This standalone proof has no daemon UID ledger,
reader presentation or clock-paced monitor, so it grants no native waveform
credit and closes no six-role name-plus-state acceptance.

**Error-path frame flush under a real size limit (2026-10-04).**
`/tmp/nogui-w21-real-module-proof-kz4dv4d2/actual-results.json` closes the
error-framer flush item and nothing else. A launcher built with
`cc -Wall -Wextra -Werror -O2` ran the genuine `sd_espeak-ng` under its own
`RLIMIT_FSIZE` of 131072 with `SIGXFSZ` ignored, and `fsize-refused` passed. The
actual `truncated_event_count` is 1 and that event's owner, request and
transaction are all `null` with `has_audio=false`; one unclosed transaction
close carries the same own transaction 1, request 4 and a null `closed_by`;
17 chunks decoded into 109844 PCM bytes. `stdout.bin` is exactly 131072 bytes
while indexed, forwarded and driver-received counts are 120970, so
`stream_check.agrees` is **false** and is recorded as false: a partial write
crossing the limit put 10102 extra bytes on disk before `EFBIG`. No exact full
raw accounting is claimed from that record. The observer was killed with a
genuine `SIGKILL` of -9, the footer reports `module_reaped true` with signal 9
through pidfd only, and cleanup completed. No Orca, display, bus, keyring, audio
sink or native UI is involved. This is a component error-path result; it is not
W21 acceptance and closes no required item.

**Latest owned native run (2026-10-04T14-09-07-151Z; four acceptance criteria
still unmet).** Exit 1, `full_acceptance: false`, **18/22** required items
established. The main native client reports no failures and the named-policy
client passes **23/23**: both signed named list actions publish under their own
names with index 0 a named action and not a click, the source records **two
named-list activations and zero clicks**, and each blocked node offers no
`Action` at all, established by enumerating that node's own interfaces rather
than by catching an exception. The typed consumer is retired before the reader
starts, every owner retires after it, and the operator accessibility setting
reads `false` before and after. Stock Orca 50.2 handled `Insert+ctrl+Left` as
`Left` (113) after 102 ms and presented `[progress bar: 'W21 Progress']`; the
application model moved nothing, the keyboard stayed on `W21 Slider`, and the
indicator stayed `focusable=false` and was never focused. Unestablished:
progress value with real audio, progress name through stock object navigation,
reader object navigation leaving the application untouched, and six-role audio
at 0/6. The reader's own log is 14,563 CRLF lines carrying 102 `SPEECH OUTPUT`
lines with 0 proved fragments; the monitor is a real 4,140,114-byte
clock-paced capture and real synthesis is proved separately; raw and index
agree and 42 of 51 wire submissions joined, the 9 refusals being the daemon's
own `__spd_0` index mark on a payload that did not carry it. The reader's grab
agreement could not be read out of its own CRLF log, which is why the
untouched-navigation criterion stays open although no model key moved. The CRLF
ingress fix is source-only and its causal fixes and replay are in progress, so
no regenerated 18/22 result and no new native full pass are claimed. Evidence:
`/tmp/nogui-w21-approved-2026-10-04T14-09-07-151Z/evidence/result.json`.

**Earlier owned native run (2026-10-04T11:16; dated and superseded).** The main
native client reported no failures and **17/21** required criteria held,
including eleven published named nodes, radio relations, exact keyboard/model
deltas, Value and whole-value EditableText writes. The separate named-policy
consumer recorded two exact named-list activations with zero click
fallthrough, and its client had five failures: four unreadable `queryAction`
answers and a two-click expectation that contradicts the named-action-only
model contract. The genuine native module trace exposed 183 raw/index
disagreements because the consumer absorbs the closing `700 INDEX MARK` line
into the mark name, and the live wait did not observe the buffered completion
marker. Original failed evidence:
`/tmp/nogui-w21-approved-2026-10-04T11-16-02-453Z/evidence/result.json`.
Neither native audio nor named-policy acceptance is closed by either run.

**Bus-free boundary proof, root isolation, viewer transport and causal status
(2026-10-04).** `/tmp/nogui-w21-native-boundary-resumed-EN3QjV` is green and narrow: the actual
callback exception report, its retention, a later callback and
the `KeyboardInterrupt` escape. The retained `boundaries.json` proves only the later gate
continuation and `KeyboardInterrupt` propagation, and is **explicitly not native `Text` or
`Selection`**. It is not a native RPC refusal and grants no
acceptance credit.

**First-phase native `Action` describe and `TextSelection`: source-complete, native-unexercised
(2026-10-04).** In `/tmp/nogui-w21-approved-client.py`, `read_actions`, `describe`,
`read_platform_text`, `read_platform_selection` and `Steps.run` are complete for both steps.
The **native unknown and refusal branches have never run**: the retained real act
`/tmp/nogui-w21-approved-2026-10-04T14-09-07-151Z/evidence/client-act.json` answered everything
and recorded no query refusal. Both are **blocked** on a fresh approved private AT-SPI fault
provider or query refusal — not on a refused mock echo, not on a source assertion, and not on
rerunning the unchanged boundary proof. Native full acceptance stays **18/22**.

Root isolation went red then green. The preserved RED held 7 of 14 and failed 7
at `/tmp/nogui-w21-root-isolation-pP0ivE/results.json`, with a stale `RootA`
model and stale speech counters visible in an empty `RootB`. After minimal state
resets, `/tmp/nogui-w21-root-isolation-Ez2wDA/results.json` holds **14/14** in
one process and one actual import: real `RootA` with 16 model keys and actual
speech counts, then a new empty `RootB` with no old keys, level `null` rather
than `0`, and every counter at 0.

The viewer transport proof is green:
`/tmp/nogui-w19-viewer-transport-proof-E2vRoL/actual-results.json` exited 0 with
`passed: true` in 12.77 s, with all ten actual component cases in scope
REACHED — its own Xvfb with binary Xauthority, the actual 8-byte mode-0600 VNC
password, its own 127.0.0.1 LISTEN inode with a wrong live PID refused, a real
RFB handshake accepting 12 bytes, where the fault relay deliberately forwarded
only the upstream's first 11 actual bytes and closed — the upstream did send the
full 12-byte `RFB 003.008\n`, and production `rfbGreeting` at 6699–6723 already
accumulates TCP chunks to 12, so the source is valid and carries no split-TCP
defect. That negative case is a deliberate prefix truncation, not an upstream
short-greeting failure. The declared VNC viewer route is a separate manifest API
and carries no parent viewer acceptance. The rest of that scope is an exclusive
manifest collision with inode and bytes preserved, and an
absent prompter whose start spawned nothing and left no new children and no
Gcr. Only the proof's retirement order was corrected: a handle is retained and
its known exit taken before any bare PID probe, so an already-exited VNC
password process was known to be gone and was never probed or signalled. Its
three owned children all report known exits — Xvfb 0, VNC 0 and x11vnc 1, the
non-zero preserved — relay connections closed, cleanup completed, and the root
descriptor was retained and then closed. Two earlier reds are preserved rather
than rewritten: `aAHBq2`, the original API-shape failure, and `SeyT6a`, the
real ten-case cleanup misclassification. No parent viewer window, no pixels, no
user acknowledgement, no `Unlock` and no prompt is involved, and there is no
IPv6 proof.

The reader chord parser's own cases pass on actual unchanged copies:
`/tmp/nogui-w21-dconf-chord-proof-2026-10-04T18-25-58-128Z-963057.json` records
13/13 exercised cases passed on the first of two runs.
marker at mark byte 1311021 for the key the reader reported — `Left`, hw 113,
matched line `^^^^^ HANDLE ATSPI_KEY_PRESSED_EVENT: 'Left' (113) ^^^^^` among
five close markers in the copy, one marker for that key, `keyval_agrees: true`
in 8 ms. The negative case asks for `KP_Divide` / `Orca+KP_Divide` /
`routePointerToItemHandler` at mark byte 1467210, where the proof's own scan of
that window finds only `KP_Add`; nothing is credited, with 0 markers for that key
and `keyval_agrees: false` after 2069 ms. The missing-log case answers a real
`ENOENT` as `orcaLogSince ok: false` with `keyval: null` and `keyval_agrees:
null` in 2 ms — an unknown, not silence. The copy is byte-for-byte the
1,477,471-byte real log at `257e35e6…` with 0 markers written by this proof,
restored byte for byte; the approved log is untouched, the operator's dconf user
database is byte-identical before and after, and no child process outlives the
proof. No keypress was sent and no reader was launched: this is a retained real
parser proof, not native command delivery.

**That first run left 10 `BOOL` cases unexercised, not passed.** The harness
pointed `dconf compile`'s OUTPUT at a path that was already a directory, so every
compile failed with `g_rename() failed: Is a directory`. That fixture bug was in
the harness, not the parser, and it is kept here as the dated record of that run.

**The rerun is 22/22 exercised with one corrupt-database branch unexercised**
(`/tmp/nogui-w21-dconf-chord-proof-2026-10-04T18-37-15-156Z-988754.json`, with
the decoded corrupt case in `artifact://16827`). A real compile of DBFILEs
succeeds; `true`, `false` and unset are typed known answers; two equal booleans
and two equal unset reads agree; recompiling `true` to `false` and a boolean to
unset are refused; and real `ENOENT`, non-zero and non-boolean queries are
unknown and never agree with anything. The corrupt own database is **not** a
pass: its actual native CLI answers status 0 with empty stdout and stderr, so the
helper reports a known unset and DB integrity stays **UNESTABLISHED** — there is
no failed-query signal, and no warning or refusal is invented for it. The
operator's dconf database is byte-identical before and after each proof. The
parent closed todo 24, *"Require two successful exact native dconf reads"*, as a
component gate only, and todo 25, the exact keyval `HANDLE` gate, was closed by
the previous run. No native keypress, reader, UI or accessibility change is
involved.

Reader log IO is green at 10/10
(`/tmp/nogui-w21-reader-log-io-proof-2026-10-04T16-23-43-912Z-564174.json`):
`ENOENT`, `EISDIR` and `EACCES` each answer a typed unknown rather than a
readable empty result, a failed log explicitly cannot be used to claim a
`HANDLE` marker, the whole actual 1,477,471-byte Orca log reads with its SHA-256
unchanged, and no kernel child was left behind.

The causal replay is closed again at 16/16
(`/tmp/nogui-w21-causality-regression-e9bzdo/result.json`) with the raw and root
index original unchanged. That is the invariant replay, not full causal
acceptance: three native fixes and the causal-ownership design are still
underway, and a fresh private native run needs renewed approval. The four
unestablished criteria above therefore stay unestablished, the 18/22 result
stands immutable, and no regenerated result and no native full pass are claimed.

The observer's own journal IO is green at **14/14 with no unexercised case**
(`/tmp/nogui-w21-observer-io-proof-2026-10-04T17-41-14-151Z-835680.json`): a
readable empty journal reads as zero records and reports `idle: true`; a missing
journal is a typed `ENOENT` failure with `idle: false` and the reason retained;
a directory in its place is a typed `EISDIR` read refusal; and a mode-000 journal
owned by this uid 1000 actually triggers `EACCES` rather than a simulated one,
with the permission restore clearing the old error and counting the record the
refusal had left unread. Counters over the real closed 687,886-byte journal
match an independent measurement — 1,411 records, 52 submissions, 51 begun, 52
ended, 0 open — that approved journal is byte-identical before and after, scratch
permissions were restored, and the proof started no process. The IO item is now
actually closed.

Root isolation is green again in its own right at 14/14
(`/tmp/nogui-w21-root-isolation-9s1P9g/results.json`: one fresh process, one
import, control established), and a second causal replay is closed at 16/16 with
the evidence unchanged (`/tmp/nogui-w21-causality-regression-ZpystS/result.json`),
including `crlf_reader_log_preserves_the_stock_navigator_grab`,
`the_preserved_reader_log_reaches_the_production_fragment_binder` and
`the_preserved_evidence_is_byte_identical_after_the_driver_read_it`. That is the
invariant set and nothing more: the native 22 required criteria are unchanged and
no fresh UI approval was spent, so the four criteria above stay unestablished.

**Component TODO closed on the wire only (2026-10-04).** A read-only review
matched the exact controller SHA `cca92cce…` against the `ZpystS` replay, and the
TODO *"Make the speech-module trace causal before forwarding and bind actual
protocol transactions without borrowing the next reply"* closes on wire evidence
alone: the actual bytes under the size limit were 120970 with traced, forwarded
and driver-received counts in agreement, while 131072 bytes reached the disk, and
the truncation left no next reply to borrow — the unclosed transaction is `true`
with `closed_by` `null` and the truncated event's owner, request and transaction
all `null`. `ZpystS` itself reports 52 submissions, 52 transactions and 52
joined, no request-sequence collisions and 0 raw-subsequence violations, with
the one missing-UID transaction at offset 6013 refused rather than borrowed.

What that does not establish: the whole reader and presentation origin remains
**unestablished**, and the 13 unique plus 13 repeat pair is not credited as UID
proof, because source retries falsify that bijection. The private-guard preflight
is recorded under W19 below; it is a guard and preflight result, not a native or
Gcr acceptance result.

### W22 — Linux native popup and layer-shell extensions

**Coverage:** P14. **Depends on:** W07, W16.

**Files:** host `linux/{popup,layer_shell,decorations}.zig`, native window extension contract, SDL/native-surface adapter, build/devenv protocol dependencies.

**Produces:** real popup role/positioner/grab, native decoration/move/resize/system-menu integration and layer-shell role/options.

- [x] Extend the host/noapi surface attachment seam for native windows when SDL's ordinary window role is insufficient. Obtain native display/window handles only through supported SDL/platform integration; never extract raw Vulkan handles.
- [x] Implement popup anchor rectangle, offset/flip/slide/resize constraints, grab and dismissal. Keep in-app overlay semantics distinct from an OS popup surface.
- [x] Implement layer/anchors/margins/exclusive zone/keyboard interactivity/input region and protocol configure/ack/close lifecycle. Capabilities depend on compositor globals; do not label an ordinary toplevel as layer-shell when the protocol is absent.

**Acceptance:** compositor places/grabs/dismisses the popup correctly; layer surface reserves the intended region and updates on output changes; closing parent/output/protocol failure releases resources without double surface teardown.

**Gate:** `zig build test -Dtest-filter=api-w22`; real X11 popup behavior and Wayland popup/layer-shell behavior on a compositor advertising the protocol, plus explicit unavailable behavior on one that does not.

**Verified W22 (2026-09-29):**

- `zig build test -Dtest-filter=api-w22` passed 39/39, exit 0: popup defaulting plus flip, slide and resize against a work area, a grab that requires an approved seat serial, dismissal and double-teardown safety, explicit `LayerShellUnsupported` when the capability is missing, the configure/ack/commit lifecycle with unacknowledged and repeated-ack errors, exclusive zone and input region, compositor close and output disconnect, decoration hit classification, and the Wayland interface opcode order and loader lifetime.
- The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Native session, through the new smoke binary `src/v7_demo/w22_layer_shell_smoke.zig` and step `zig build w22-layer-shell-smoke`, on the same live niri Wayland desktop recorded under W07. niri does advertise the protocol: a registry round trip reported `globals=48`, `zwlr_layer_shell_v1_name=6`, `zwlr_layer_shell_v1_version=5`, `wl_output_count=1` and `wl_compositor_version=6`, and the adapter's own probe returned `capability=supported`.
- A real surface was created and driven end to end. The request was layer `top`, anchor `top_dock` (bits 13 = top|left|right), margins t12 r24 b0 l24, exclusive zone 64 and keyboard interactivity `none`. The compositor delivered `configure serial=3133760 size=1872x64`; 1872 is the compositor's own anchored width, 1920 minus the two 24 margins, because the requested width was 0. The ack serial matched, the state reached `mapped`, a buffer was committed at 1872x64, and `niri msg --json layers` confirmed `{"namespace":"w22-layer-smoke","output":"eDP-1","layer":"Top","keyboard_interactivity":"None"}`.
- The explicit unavailable path was also run for real, on the X11 driver: `capability=unavailable`, `LayerShellUnsupported`, and an ordinary toplevel that still opened, mapped and closed. A layer role does not exist on that driver at all, so the refusal is an exercised code path rather than an inferred one; it is not the same as a Wayland compositor that advertises neither the global nor the protocol.
- This run found two protocol defects, both fixed. First, `LayerSurface.deinit` marshalled `wl_compositor.release` (opcode 2) under a `>= 4` guard while the protocol requires version 7, and the local descriptor declared `release` since 4; niri answered `error 1: invalid version for wl_compositor#57.release (4, need at least 7)` and then `Wayland display connection closed by server (fatal)`, so any real teardown killed the display connection. `since_version.wl_compositor_release` is now 7 and the run reports zero protocol errors. Second, four interface descriptors in `src/v7_host/linux/wayland.zig` held requests at the wrong opcode because a request had been dropped: `xdg_positioner` (`destroy` at index 6 instead of 0), `wl_seat` (`release` at index 0 instead of 3), `wl_surface` (`set_input_region` at 4 instead of 5, with `set_opaque_region` missing) and `xdg_surface` (`ack_configure` at 3 instead of 4). All 14 descriptors in that file were audited against the protocol XML. The opcode-order test had been pinning the wrong `xdg_positioner` order and was corrected to the protocol order and extended to name every indexed entry, because an assertion covering only the first and last request cannot see a shift in the middle of a table.
- The popup half ran too, through the new smoke binary `src/v7_demo/w22_popup_smoke.zig` and step `zig build w22-popup-smoke`, on the same live session but forced onto the X11 driver with `SDL_VIDEODRIVER=x11`. The app reported `video driver: x11`. That is XWayland's X server reached through `DISPLAY=:0`, not a standalone Xorg session.
- A real X11 popup role was created and then confirmed independently of the adapter's own verdict, by reading the window's SDL properties back: `x11_display_pointer=.{ .value = anyopaque@216e6270 } x11_window_number=10485777 x11_screen=0`. The path is `NativePopup.create` to `parent.createPopup` to `SDL_CreatePopupWindow` with `SDL_WINDOW_POPUP_MENU`, which SDL's X11 backend maps to an override-redirect transient window. The readback and the exit status are what the run observed; the override-redirect mapping is SDL's own behaviour for that flag and is not something this smoke can see.
- The full lifecycle ran and the process exited 0: `activate` moved the popup to `active`, `dismiss` was accepted and the adapter released the SDL window, a second popup created after the parent close reported `AlreadyClosed` when dismissed, the parent close left `window_count=0`, and `Session.deinit` was accepted instead of returning a live-app or live-model error.
- Refusals are explicit and each is asserted by name against its exact outcome string, so a wrong outcome is a hard error and not a printed observation: `InAppOverlayHasNoNativeSurface` for `create(.in_app_overlay)`, `InvalidSize` for a zero-size create, `RiskConfirmationRequired` for an unapproved grab at create time and again on the live popup, `PopupGrabUnsupported` for an approved grab, and `AlreadyClosed` for dismissal after parent close.
- The Wayland half of the same binary is the interesting result, and it is the reverse of the usual expectation. On the same niri compositor `create(.os_surface)` is accepted, but `show` fails with `NativeRoleUnavailable`, the SDL window is released, the run reports that in words and returns `error.PopupRoleNotObtainable` with exit 1. On this stack X11 is the driver that yields a working native popup role and Wayland is not.
- The placement solver diverges by driver, because the two drivers report different work areas. X11 reported `work_area=0,0 3840x1080` and resolved `rect=144,276 180x120` with `flipped_x` true; Wayland reported `work_area=1920,0 1920x1080` and resolved `rect=1920,276 180x120` with `slid_x` true. Same request and same solver, two different strategies chosen, so a placement recorded on one driver is not evidence of placement on the other.
- Not run: a compositor-delivered `zwlr_layer_surface_v1.closed` event, since niri sends none for a healthy surface and the close exercised here was client-side only; the exclusive zone's reserved extent, which niri's IPC does not report; and the layer-shell refusal path against a real Wayland compositor that omits the global, because no such compositor exists on this host. The popup run above adds a real role, a real driver-reported work area and an accepted client-initiated dismissal; it does not add a compositor-placed or compositor-grabbed popup, because the grab is still refused.
- Boxes: all three stay unticked, and each for a named reason rather than for want of a run. The first box's covered part is that native display and window handles came from supported SDL integration and were read back as SDL properties, with no raw Vulkan handle involved; its uncovered part is the host/noapi surface attachment seam itself, which this run did not exercise. The second box's covered part is the anchor rectangle, the offset, the flip and slide decision resolved against a real driver-reported work area, the accepted dismissal, and the in-app overlay kept distinct from an OS popup surface by a refusal; its uncovered part is the grab, refused on this stack rather than obtained, and the resize constraint, which no observation in either run reports. The third box's covered part is the configure/ack/map/commit lifecycle recorded above; its uncovered part is the compositor-delivered close, the exclusive zone's reserved extent, and a refusal on a compositor that omits the global. No box in this package is closed.

- The run was repeated after this round's protocol-table corrections, and the two smokes were rebuilt and rerun on the same session. Layer shell, Wayland: `registry round trip: globals=49 zwlr_layer_shell_v1_name=6 zwlr_layer_shell_v1_version=5 wl_output_count=2 wl_compositor_version=6`, `capability=supported`, `attach: layer=top anchor_bits=13 exclusive_zone=64 margins=t12,r24,b0,l24`, `configure delivered: serial=2035852 size=1872x64`, `ack delivered: acked_serial=2035852 state=mapped`, `buffer committed: output_size=1872x64`, `toplevel opened: ... usable_as_layer=false`, `probe on a live xdg_toplevel surface: capability=unavailable`, `client close: state=destroyed repeat_teardown=DoubleTeardown`, `Session.deinit=<accepted>`. The X11/XWayland toplevel closed with `getWindow=StaleWindow window_count=0`.
- Popup, X11 via `SDL_VIDEODRIVER=x11`, exit 0 with no leak: a real role was created and confirmed from the window's OWN SDL properties (`x11_display_pointer=.{ .value = anyopaque@2d1a5280 } x11_window_number=20971537 x11_screen=0`), each refusal was asserted by name (`InAppOverlayHasNoNativeSurface`, `InvalidSize` for a zero size, `PositionerIncomplete` for a zero anchor rect — a distinct refusal from a zero size, not the same error reused, `RiskConfirmationRequired` for an unapproved grab, `PopupGrabUnsupported` for an approved one, `AlreadyClosed` for a dismissal after a parent close), the parent close left `window_count=0`, and the work area differed by driver again: X11 `work_area=0,0 3840x1080` resolving `rect=144,276` with `flipped_x`, Wayland `work_area=1920,0 1920x1080` resolving `rect=1920,276` with `slid_x`.
- The Wayland half of the popup binary is unchanged in outcome and now leaks nothing: `create(.os_surface): <accepted> driver=wayland`, then `show: NotApplicableOnThisDriver`, then exit 1 with `PopupRoleNotObtainable`. The leak was real: `show` refused the xdg-shell path WITHOUT releasing the role it had already allocated, so the run aborted inside SDL with a garbage Vulkan surface. Three defects came out of these reruns, all fixed. `NativePopup.create` assigned only `gpa` and `machine` on a `gpa.create(Role)` allocation, leaving `vulkan`, `scan` and `wl` as whatever the allocator returned; `deinit` then read that garbage as a Vulkan surface and crashed inside `SDL_Vulkan_DestroySurface`. The role is now value-initialized. Second, `show` refused a driver that cannot take the role without releasing the role, so the Wayland run leaked it. Third, the smoke kept its own second popup alive-flagged across a parent close that dismisses but does not free, leaking the role.
- What these reruns do NOT add: the grab is still refused on this stack, so no compositor-grabbed popup is observed; the xdg-shell role is still not obtainable through SDL on niri, so the Wayland popup half remains an exercised refusal rather than a working role; and the layer surface's reserved extent is still not reported by niri's IPC. All three stay open in the boxes below.

**Current W22 integration (2026-10-02, owned nested Niri):**

- The layer and ordinary toplevel now present through one shared noapi GPU and two `Surface.initSdl` surfaces. The real program exits 0 with role, GPU surface, SDL window, Application and Session retirement; the prior null-call crash in SDL's hidden Vulkan framebuffer is no longer present.
- The final clears are linearized at compile time for the actual `.b8g8r8a8_srgb` attachment. The compositor screenshot was inspected; sampled pixels exactly match the authored blue `(30,64,216)`, gold `(255,208,32)`, black, green `(14,122,60)` and pink `(255,45,85)`.
- An owned outer X11 window resize drives the nested output from `1280x800@60.000` to `1024x768@60.000`. A real output event and ordinary client resize `616x603 → 488x571` were observed. The controller restores the exact outer position `(160,607)`, size `1280x800`, mode, scale and transform. An `Applied` custom-mode reply alone did not change this backend.
- The client still proves zone `64 → 128` reduces the ordinary client height by exactly 64, and bounded input plus the `none → on-demand → none` keyboard sequence remain observed. The new output-change run exposes three still-failing checks: reservation and compositor geometry witnesses mix phases, and the layer's post-mode configure/ack/buffer witness is absent. Compositor-delivered `closed` and output removal remain unproved. No W22 completion is claimed.

**Real W22 terminal proof (2026-10-02, owned Sway):**

- `direnv exec . node /tmp/nogui-w22-terminal-fixture.mjs --layer-program ~/projects/nogui/.zig-cache/o/7c05185a0b471fcfbb922aceeb504799/w22-layer-shell-smoke --terminal-arm-ms 20000 --render-node /dev/dri/by-path/pci-0000:01:00.0-render --strict --json` exited 0. Both scenarios ran and every required claim passed. Evidence: `/tmp/nogui-w22-terminal-VUGEaW/logs/evidence.json`.
- Sway 1.12 / wlroots 0.20 used an owned headless GLES2 output at measured **1024×768**. A real `wlr-virtual-pointer-unstable-v1` device supplied pointer capability before SDL opened; it sent no motion, button, axis or frame events and requested no keyboard.
- Disable delivered the layer's own compositor `closed` before its client destructor. Unplug delivered `wl_registry.global_remove` for the output bound by that layer's own registry. Both programs exited 0; client, pointer helper and compositor retired in reverse order. Disable also removed an output global on this compositor; that observation is not a guarantee that the two endings are mutually exclusive.
- The run reproduced and repaired two defects: the reservation consumer committed a pending configure without acknowledging it, and output removal after `closed` left `output_attached=true`. The latter regression failed before repair and passed afterward; the machine remains destroyed and rejects double teardown.
- This closes the two terminal-event gaps. Nested-Niri phase-bounded geometry/configure/ack/buffer witnesses, popup role/grab acceptance and the GPU-capable missing-global scenario remain separate.

**Current W22 contract integration (2026-10-03, no live display):**

- The mandatory `wayland.Api.display_dispatch_queue_pending` addition exposed an unmigrated layer-shell wire fixture at compilation. Its explicit empty-private-queue callback now satisfies the same table as production; the loader has no optional or fake-success default.
- `direnv exec . env -u DISPLAY -u WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS=disabled: AT_SPI_BUS_ADDRESS=disabled: NO_AT_BRIDGE=1 GTK_A11Y=none zig build test -Daccesskit-bridge=false -Dtest-filter=api-w22 -j1 --summary all` exited 0: **60/60 steps, 61/61 total tests**.
- The actual `w22-layer-shell-smoke` default exited 0, **12/12 steps**. SDL `dummy` produced explicit `NotWayland`/`LayerShellUnsupported`, refused to relabel its ordinary toplevel, retired the window with a stale-handle check, and accepted Application/Session teardown. This is refusal and caller-integration proof, not a Wayland presentation or input grab.
- The source now separates mapped X11 server-status grabs from pre-commit Wayland grabs using owned-parent press provenance. Native grab/dismissal, transformed private-Niri input/resize and GPU-capable missing-global acceptance remain queued; no synthetic serial or authorization flag substitutes for operator approval.

**Native X11 server-input acceptance (2026-10-03):**

- The popup grab now owns a separate XCB connection opened on SDL's actual X display. Borrowing SDL's connection allowed SDL's own focus processing to ungrab the pointer; SDL also did not preserve the grabbed popup's XID for an outside press. `takeX11Press` reads the server's button event, filters its target XID and rejects protocol errors.
- `direnv exec . zig build w22-popup-smoke test -Dtest-filter=api-w22 -j1 --summary all` exited 0: **64/64 steps, 62/62 tests**; the default consumer refused `HeadlessDisplayServer` and shut down cleanly. `zig fmt --check` passed for the changed W18/W22 Zig files.
- The strict private `popup-x11` scenario exited 0 using `~/projects/nogui/.zig-cache/o/6ca2f103d468fabe95e716928bf98a47/w22-popup-smoke`, scope `isolated popup tests`, and a 6000 ms grab arm. The X server delivered button 1 at timestamp 192907226 to popup XID 6291508, with outside coordinates `(568,-1579)`. The popup presented a real 180×120 noapi buffer; its retained screenshot was inspected.
- Parent-close release failed before repair: the model was dismissed but `x11_grab_held=true`. After `onParentClose` was changed to ungrab first, a second real press reached the parent while the fresh popup window was still alive and `x11_grab_held=false`. Later window/role retirement, `AlreadyClosed` refusal and Application/Session shutdown all passed. Managed-parent proof now checks the exact native process's XID, not an unrelated nested compositor's client count.
- Evidence: `/tmp/nogui-w22-final-grab-20261003/scenario-popup-x11.txt` and `niri/runtime/w22-popup-x11-popup-hold.png`. This is X11 acceptance, not acceptance of the whole fixture: its subsequent `popup-wayland` scenario timed out after 90000 ms at real-parent-input readiness. The detached native child escaped controller teardown and required verified private-process SIGKILL. Wayland input progress and supervisor descendant retirement remain open.

**Wayland popup and layer acceptance repair (2026-10-03):**

- The serial `w22-popup-smoke w22-layer-shell-smoke test -Daccesskit-bridge=false -Dtest-filter=api-w22 -j1 --summary all` build passed **66/66 steps and 63/63 total tests**. A new repeated-acknowledgement regression failed before repair. Each delivered configure resets its acknowledgement generation; the same serial may legitimately be delivered again after wrap, but one delivered configure cannot be acknowledged twice. `waitForConfigure` now waits for an unacknowledged configure, not the retained answer to the preceding request.
- Real parent input exposed malformed hand-written pointer metadata: enter/leave argument order, button unsigned fields, nullable cursor syntax and version inheritance. The private pointer constructor now inherits a seat binding capped to the pointer interface's version. An unmapped outer Niri window also produced a false readiness witness; the fixture now maps only its kernel/PID-verified output window and checks `IsViewable` before launching a consumer. The consumer commits pending synchronized libdecor subsurface state so the parent main surface, not its shadow, receives the opening press.
- `/tmp/nogui-w22-background-dismissal-20261003/evidence.json` records a strict `popup-wayland` exit 0. Actual `wl_pointer.button` serial **11** on the owned parent's main surface was carried by `xdg_popup.grab`. The compositor configured **180×120**, accepted acknowledgement **12**, answered reposition with configure **14**, and accepted that acknowledgement once. A real private-output background press elicited exactly one compositor `popup_done`; popup, xdg surface and shell destructors followed it. The controller parses the wire's actual positional serial and does not credit an application-generated dismissal line. Application/Session shutdown passed; four owned process groups, one native child and every pointer button retired. The current `popup-x11` consumer also passed again in `/tmp/nogui-w22-next-configure-fixed-20261003/scenario-popup-x11.txt`.
- Deadline cleanup is independently established by the failed duplicate-ack run, `/tmp/nogui-w22-parent-state-committed-20261003/evidence.json`: the detached native child was retired before the compositor, TERM followed by bounded KILL when required. All owned groups and the native child were gone; no unproven survivor was killed. This supersedes the unresolved descendant cleanup recorded above, not the historical failure.
- `/tmp/nogui-w22-layer-output-complete-20261003/scenario-layer.txt` establishes transformed `Flipped180` input without changing the fixture's transform: empty region delivered zero; bounded region delivered **2 inside / 0 outside**; restored default delivered **1 / 1**. The inspected screenshot places the bar and its markers upright. Keyboard readback follows `none → on-demand → none`, with no key or exclusive capture. Reservation **64 → 128** reduces the ordinary client by exactly **64 logical pixels**. Output **1280×800 → 1024×768** produced a new **976×128** layer configure, acknowledgement and actual noapi buffer; exact output and outer-window geometry were restored.
- The same fixture's owned Weston GPU probe exited 0 with `zwlr_layer_shell_v1_name=0`, `LayerShellUnsupported`, an ordinary xdg toplevel still mapped, **seven real 420×260 frames** on the GTX 1660 Ti, and accepted GPU/Application/Session retirement. This is the missing-global Wayland path, not the dummy or X11 refusal.
- The healthy layer controller's first verdict was FAIL solely because it incorrectly owned two unrequested terminal observations. The corrected strict combined `layer,popup-x11,popup-wayland` fixture exited 0: **all three scenarios PASS**, terminal observations still explicitly unproved in the healthy run, and no unowned observed claim. Evidence: `/tmp/nogui-w22-scoped-native-acceptance-20261003/evidence.json`. Six owned process groups and three native children retired; zero survivors or unattributed children. This credits the healthy resize/input/lifetime and native popup scopes, not terminal events; real Sway terminal evidence remains separate.
- Fresh terminal verification used the current `w22-layer-shell-smoke` binary: `direnv exec . node /tmp/nogui-w22-terminal-fixture.mjs --layer-program ~/projects/nogui/.zig-cache/o/844ade3313815d17164bee06b2dfa5e6/w22-layer-shell-smoke --terminal-arm-ms 20000 --render-node /dev/dri/by-path/pci-0000:01:00.0-render --strict --json` exited 0. Both actual Sway terminal scenarios ran, every claim passed and clients/helpers/compositors retired; `/tmp/nogui-w22-terminal-VGqLoj/logs/evidence.json`. Disable and unplug endings are not asserted mutually exclusive.

**Stale-seat refusal on the production grab path (2026-10-03):**

- `/tmp/nogui-w22-stale-seat-final-20261003/scenario-popup-wayland.txt` records a
  strict `popup-wayland` scenario exit 0 on an owned nested Niri with a private
  runtime directory and PID-verified compositor. Command:
  `node /tmp/nogui-w22-stale-seat-controller.mjs --scenario popup-wayland --runtime-dir … --socket … --wayland-display wayland-1 --x11-display :4 --layer-program ~/projects/nogui/.zig-cache/o/aedf3cd144bf525ec7b171e9b4ec2df3/w22-layer-shell-smoke --popup-program /tmp/nogui-w22-stale-seat-consumer/zig-out/bin/w22-stale-seat-consumer --niri niri --output winit --hold-ms 8000 --output-watch-ms 20000 --json --approve-private-native-grab 'isolated popup tests' --private-grab-arm-ms 6000`.
- The press is real. A private `wl_pointer` button landed on the owned parent's
  own main surface at the point the compositor itself reported
  (`window 2 … at 400,202 480x397`, `is_focused=true`), and the run recorded
  `parent press: serial=11 provenance=wl_pointer.button on this parent's
  wl_surface`. That serial is the same **11** the successful grab carried in the
  background-dismissal run above, so the two agree on the value rather than on a
  fixture constant.
- With that serial withdrawn, the production path refused with
  `grab(real press, approved): MissingSeatSerial`, and the summary is
  `stale-seat: real_serial=11 simulated_withdrawal=true refusal=MissingSeatSerial
  shared_display_error=0 pending=false`. The shared SDL display reported no
  protocol error, the grab was never left pending, and the parent close then
  released the role: `state=dismissed dismiss_reason=parent_closed has_grab=false
  x11_grab_held=false`, `dismiss after parent close: AlreadyClosed`,
  `window_count=0`. Teardown was orderly and accepted: `Application.deinit ok,
  Session.deinit=<accepted>`, native exit code 0 with no signal.
- **What is injected and what is not:** the seat metadata was withdrawn
  **simulated**, by the fixture. No compositor `wl_registry.global_remove` for the
  seat was observed, and none is claimed; the run reports
  `compositor_global_withdrawal_observed=false`. The real half is the press, its
  serial, the refusal, the clean display and the teardown. That is exactly what this
  package asks for here — the missing-serial refusal plus the production native
  guard consumer on a real connection — so the simulated withdrawal is the scope of
  the check and not a shortfall in it.
- Retired: xvfb, openbox, niri, the scenario supervisor and the one native child
  all exited 0, the child was gone before it was retired, and
  `unattributedNativeChildren` is empty. Orca and the test AT-SPI setup were off.
- The scoped negative proof is `/tmp/nogui-w22-no-press-final-20261003/evidence.json`:
  the same fixture with no press injected returned `NoRealParentPress` after
  announcing readiness, with a healthy compositor query, no signal, no allocator
  fault and zero owned or unattributed survivors.
- All three W22 checkboxes stay ticked, and this run changes nothing about that.
  Measured against this package's exact Acceptance text, every clause has retained
  evidence: the compositor placed the popup (configured 180×120, acknowledgement
  12, reposition configure 14 acknowledged once), grabbed it with the real serial
  11, and dismissed it (one compositor `popup_done` from a real background press,
  plus parent-close release); the layer surface reserved its intended region
  (reservation `64 → 128` changed the ordinary client by exactly 64 logical pixels)
  and updated on output change (1280×800 → 1024×768 produced a new 976×128
  configure, its acknowledgement and a real noapi buffer, with exact geometry
  restored); and closing by parent, by compositor-delivered `closed` and by output
  removal released resources with the machine destroyed and double teardown refused.
  Nothing here requires the compositor to withdraw the seat global in production,
  and no new oracle is introduced.





### W23 — Conditional platform extensions and adapters

**Coverage:** P15 and target-specific portions of P01–P13/A02/R08. **Depends on:** W12, W14, W18, W19, W20, W21.

**Files:** new host `macos/`, `windows/`, `mobile/` adapters and target-gated build/devenv/package declarations; shared extension/capability values; corresponding native accessibility bridge targets. These directories are planned implementation locations, not existing backends.

Do not make Linux emulate inapplicable platform concepts. Conversely, returning Unsupported on every OS is not completion. Separate portable API completion, Linux implementation completion and each additional target's completion in release notes.

| Adapter slice | Required work | Native acceptance |
| --- | --- | --- |
| E01 macOS windows/application | Native tabs and tab navigation/merge/move policy, titlebar controls, document edited/path metadata, activation/hide/reopen and Services integration. | Two document windows tab/detach, metadata and Services action reach the correct live model. |
| E02 macOS text/services/media | Find pasteboard, character palette, native menus/dock/recent documents, Keychain/notifications/dialogs and CVPixelBuffer frame adapter. | Focused input receives palette/Find actions; approved synthetic service operations and frame release work. |
| E03 Windows host/services | App identity, jump list/recent documents, supported native window interop, native menus/dialogs/clipboard/credential/notification/capture adapters. | Identity groups the right app; jump-list action reaches the right window; approved service lifecycle and capture succeed. |
| E04 mobile window/input lifecycle | Safe-area insets, back request, soft-keyboard show/hide/geometry, text-state changes, background/resume, memory-pressure and supported raw touch/native gestures. | Actual device/simulator rotate/keyboard/back/background cycle preserves text/focus and releases resources on teardown. Do not advertise absent recognizers. |
| E05 accessibility targets | AccessKit macOS/Windows adapters and a real native semantic adapter for any mobile target advertised as supported. | VoiceOver/Narrator or the target screen reader reads state and performs focus/edit/activate actions. |
| E06 diagnostics/capabilities | GPU device/driver/software-emulation metadata via noapi, subpixel-order capability, native display/keyboard/appearance/power signals where available. | Real device values match backend observations; unknown subpixel/display metadata stays unknown. |

- [ ] Implement each applicable slice against the fixed shared contracts, including its failure/cancel/shutdown paths. Avoid conditional branches in core layout/input for native policy.
- [ ] Compile core/text/render/host consumers for each advertised target. noapi surface support and target SDK/toolchain access are hard prerequisites: extend noapi where necessary, never bypass it with raw graphics handles.
- [ ] Run each native acceptance on the corresponding OS/device. Record unverified/unimplemented targets explicitly; do not count a cross-compile or Linux Unsupported result as runtime parity.

**Gate:** target-native `zig build test -Dtest-filter=api-w23` plus the table scenarios. The current Linux workstation cannot supply macOS/Windows/mobile runtime proof; that is an execution prerequisite, not permission to omit these API families from the plan.

**Verified W23 (2026-09-29):**

- `zig build test -Dtest-filter=api-w23` exits 0 and reports 7 tests, but no test in the repository carries an `api-w23` name. Those 7 are the artifacts' unnamed `test {}` blocks, so the run is not W23 evidence.
- `zig build check` compiles every product for this Linux target and the full suite passes 1413/1413 across 34/34 steps with 0 leaks. No `macos/`, `windows/` or `mobile/` adapter directory exists.
- Not runnable on this host: macOS, Windows and mobile. No slice of E01–E06 is implemented, and no advertised target has runtime evidence.

**Notification ownership repairs (2026-10-01, Linux host):**

- One notification id now produces one terminal response. `NotificationsService.handleResponse` untracks a `.closed` response before the owner's handler runs, so a handler that shuts the service down from its own close callback has nothing left to complete. Red: `zig test src/v7_host/notifications.zig --test-filter 'keeps one terminal response'` failed with `expected 1, found 2` for the handler's shutdown count. Green: the same file passes 5/5, exit 0.
- A late toast activation no longer buffers into a provider that `disconnect` retired. The retirement latch is taken under the ring's lock, the activation callback refuses it before touching the ring, and the payload watermark waits for deliveries still on the stack rather than for an empty ring alone, so a handler that pumps again cannot have the key it is reading overwritten. Red: the queue length was 1 where 0 is required, and a reentrant drain changed a live borrowed key from `outer-key` to `third-key`. Green: the Windows provider suite passes 17/17, exit 0, including `a toast activation after shutdown reaches nothing` and `a nested toast drain keeps the key an outer handler still holds`.
- A drained D-Bus frame is released when the output list cannot grow. `Connection.drainAvailable` frees the copy it just made when the append fails, and the post-disconnect re-drain frees the copy it cannot store. Red: an isolated failing-allocator harness retained 144 bytes, exactly the frame length, and the debug allocator reported the leak at `dbus.zig:691`. Green: the same harness reports `retained_bytes=0`.
- macOS: every native notification callback, including the two the framework answers on a private queue, is marshalled onto the main queue before it reads the callback table, and the free is itself a main-thread operation, so the table can no longer be read while it is retired. The staged tests that released the service from inside a response handler were removed: no shared contract grants a destructive callback teardown, and the sibling AccessKit bridge states the same prohibition. This is a source-level argument only; the Objective-C shim is not compiled or linked on this host, so no macOS runtime proof exists yet.
- The Windows native source now counts callbacks before releasing its registration lock, clears the callback/context together on unregister, revokes COM with no lock held, and waits for in-flight activations before returning. A retiring registration also refuses a competing registration. This removes the source-level unguarded callback-copy window; the SDK shim remains uncompiled and unrun on Windows, so native barrier acceptance stays open.

**Settled portable consumer integration (2026-10-02):**

- The `api-w23` portable gate passed **149/149**. Linux compiled and ran `w23-windows-smoke`, `w23-macos-smoke` and `w23-mobile-smoke`.
- The Windows consumer's notification mode, moved model initialization, partial-frame JSON ownership, typed diagnostic formatting and menu routing now compile.
- The macOS consumer's approval storage, pixel-buffer holder and partial window/registry teardown now compile.
- The mobile consumer uses the existing host pump and an owned iOS text control. No arbitrary native control-address option remains.
- The mobile probe reports whether this build includes the platform half. It does not claim a device exists.
- The settled Linux gate passed **106/106 steps and 1,858/1,858 tests**, whole-tree formatting, both linters and **126 Python tests**.
- These portable results do not compile or execute the target-native Objective-C/JNI/Win32 SDK shims. Native E01–E05 and screen-reader acceptance remain open.

**Current E06 Linux runtime proof:**

- The freshly compiled `w23-diagnostics-smoke` exited 0 with DISPLAY/Wayland/session-bus/AT-SPI access disabled. One real noapi device created a 4×4 texture, submitted a command buffer and reached queue idle; surface count remained zero.
- Its GTX 1660 Ti vendor/device `0x10de/0x2191` agrees with kernel PCI files for `0000:01:00.0`. Driver `595.104.02` agrees with both `/proc/driver/nvidia/version` and `/sys/module/nvidia/version`; software emulation is false and unsourced subpixel order stays `unknown`. The prior private W18 observation arm supplies the separate native display/preference absence proof.
- The selected GPU name now uses noapi's existing bounded property-string slice, not the entire padded Vulkan array. Raw diagnostic stdout/stderr contain **zero NUL bytes**, against 230 in the preserved failing W22 transcripts. The vendored patch hash, file inventory and content digest were updated without changing upstream provenance. `/tmp/nogui-safe-native-proof-20261003.json` preserves the actual output and byte counts. This is Linux runtime evidence, not macOS/Windows/mobile SDK acceptance.

**Windows field consumer repairs (2026-10-03, portable CPU proof):**

- The real pinned-font regressions reproduced a UTF-16 selection start of 2 instead of 1, an empty-value range panic and a Shift-Left selection start of 4 instead of 3. Whole-value assignment now preserves reversed Unicode endpoints; empty and full-capacity hit-tests use valid bounds. Movement uses `TextLayout.previousGrapheme/nextGrapheme`, not the removed partial Unicode scanner. Combining marks, emoji ZWJ sequences and word deletion pass.
- The production caption began at x=367.89844 while the native caret began at x=22. The consumer now authors the same 15-unit font, left inset, single-line paragraph and clipping policy for painting and native measurement. Start/end caret geometry agrees with the actual generated caption's layout.
- A commit queried before repaint left native caret x=82.203125 instead of the new painted x=97.34375. Native geometry queries now refresh from the current scoped model value. An empty field has a positive-height caret; a caret beyond the clipped carrier is unavailable rather than placed outside it.
- Pointer activation previously focused the widget but dropped committed text. Pointer and native focus now bind one weak-owned endpoint. The real `App` regression accepts “é”, ignores input after window blur, then accepts “😀” after pointer refocus.
- `direnv exec . env -u DISPLAY -u WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS=disabled: AT_SPI_BUS_ADDRESS=disabled: NO_AT_BRIDGE=1 GTK_A11Y=none zig build w23-windows-field-test -Daccesskit-bridge=false -Dtest-filter='api-w23 Windows field' -j1 --summary all` exited 0: **20/20 steps, 5/5 tests**. These tests force the production helpers, text endpoint and caption paths on Linux. They do not compile or execute the Win32/WinRT SDK shims, menus, shell launch or Narrator; target-native E03/E05 acceptance remains open.



### W24 — Inspector and diagnostics

**Coverage:** D03, D04. **Depends on:** W06, W08, W10, W13.

**Files:** new `src/v7/inspection.zig` and `src/v7_host/inspector.zig`; existing `src/v7/perf_counters.zig`, `src/v7_demo/perf.zig`, W05 task and W10 action timing hooks, and build options.

**Produces:** read-only frame snapshot/provider, pick mode, opt-in source metadata, bounded frame/task/action collectors and reusable benchmark context.

- [x] Expose stable IDs, layout/visual bounds, resolved styles, clipping, focus/capture and semantic relationships. Inspector selection resolves the current generation; never expose arbitrary component memory or retain a frame pointer indefinitely.
- [x] Reuse existing perf JSONL/counters/Tracy and optional GPU timestamps. Add bounded cursor-based timing collection and task/action attribution only at the corresponding real service boundaries; keep disabled instrumentation zero-cost.
- [x] Benchmark with production scheduling and real elapsed time; deterministic tests keep virtual time. Preserve current performance scene flags and schemas unless a documented versioned change is required.

**Acceptance:** picking an overlay selects the same target as input, stale inspection handles fail, measured task/frame records have coherent ordering and bounded retention, disabled instrumentation does not allocate per frame.

**Gate:** `zig build test -Dtest-filter=api-w24`; actual inspector interaction and current performance recorder smoke. No speedup claim without paired measurements; API parity is not a 120-FPS promise.

**Verified W24 (2026-09-29):**

- `zig build test -Dtest-filter=api-w24` passed 35/35, exit 0: overlay picking that matches input order, stale handles for destroyed, recycled and removed widgets, frame snapshots carrying bounds, clipping, focus, capture and semantics, bounded chronological collection, source metadata, zero allocation when disabled, task and action timing including nested depth, and the host inspector lifecycle and action-registry records.
- `python3 -m unittest discover -s tools -p 'test_*.py'` passed 125 tests, and the full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Native session, through the new smoke binary `src/v7_demo/w24_inspector_smoke.zig` and step `zig build w24-inspector-smoke`, on the same live niri Wayland desktop recorded under W07. A real window opened with `video driver: wayland` and an observed 520x420.
- A live pick at a computed point inside the control resolved to `owner=0x1/slot=0/gen=1`, role `button`, label `Inspect Target A`, visual bounds `x=20 y=56 w=360 h=72`, with a child label node. The pick agreed with input hit testing on both the frame node id and the stable widget id, and a real pointer sequence through `App.handle` at the same coordinates focused the control and ran its `onClick` exactly once. After `Session.update` the label read `Inspect Target B` with identity preserved and bounds unchanged.
- Stale-handle rejection was exercised for real in both forms: a node removed gives `StaleHandle`, and a node replaced into the same slot with a bumped generation also gives `StaleHandle`. The bounded collectors retained 16 records at saturation, 8 frames, 4 tasks and 4 actions.
- Limits this run reported about itself: the window paints a clear colour with no renderer mounted, so the screenshot cannot show the inspected controls and all the evidence above is API-observed; no overlay was present, so the overlay form of "picking an overlay selects the same target as input" was exercised only in its normal-tree form; the pointer events were synthetic values passed to `App.handle` on a real, mapped, focused window; and only one window, layout, machine and display server were covered.
- The recorder half ran too, through the new benchmark binary `src/v7_demo/w24_perf_pair_bench.zig` and step `zig build w24-perf-pair-bench`, on the same live session. It reuses the existing `perf.zig` Recorder through `window.zig`; no second recorder was built, and the existing perf JSONL and counters are unchanged.
- The two arms are two configurations of this one tree, not two binaries. Arm A is offscreen with the todo scene, arm B is offscreen with the spotify scene, and the only difference is the mounted root; `bench.json` records that difference in `differs_only_in` and names each arm's artifacts after its own configuration, so a file is never filed under a label that contradicts what it recorded. Twenty interleaved pairs were kept per arm after discarding three leading pairs, and the discard was passed on the command line rather than chosen after the data was in. The clock is `Io.Clock.awake`, `CLOCK_MONOTONIC`, sampled around whole runs; no injected clock and no simulated time.
- Wall milliseconds, n 20 per arm: arm A min 1824.8, median 2135.2, mean 2144.5, max 2818.4, stddev 255.2; arm B min 4594.4, median 5141.1, mean 5280.6, max 6619.1, stddev 504.5. The recorder's own `cpu_compute` sample-phase median, read back out of that run's JSONL rather than timed separately: arm A median 12.861 ms, mean 13.112, stddev 1.564; arm B median 46.883 ms, mean 47.494, stddev 4.344.
- Paired comparison over the 20 kept pairs: median difference +3018.7 ms, mean difference +3136.1, standard deviation of the differences 453.4, Cohen's `d_z` 6.92, exact two-sided sign test p 2e-6, 0 of 20 pairs with arm B faster, and non-overlapping bootstrap 95% intervals, arm A [1882.6, 2259.3] against arm B [4901.6, 5646.4]. The recorder artifacts are in `zig-out/w24-perf-pair/` and were accepted by `tools/run_v7_perf.py`'s own header and per-sample validators.
- This is a smoke, and not a speed claim. Load average ran 8 to 14 on 12 CPUs for the whole measurement, with a 650% CPU compile, the 1426-test gate and sibling workers contending, and this box cannot be shown idle. The separation is large and consistent, but the absolute milliseconds are contaminated by load this run cannot remove, so nothing here states how much of the difference would remain on an idle machine.
- It is not a frames-per-second result either. `run_v7_perf.py`'s own `within_120_fps_budget` check passed in 0 of the 20 kept runs in either arm, and the sample-phase p99 ranged 14.2 to 27.1 ms for todo and 48.5 to 154.1 ms for spotify against the 8.33 ms budget, which is what that gate's own wording predicts: API parity is not a 120-FPS promise. Neither arm met the budget, so the pair cannot be read as one arm meeting it and the other missing it.
- The offscreen-against-presented comparison could not run at all. A presented run is aborted by the demo's own `rejectPerfEvents` guard on any pointer or key event, so on a shared display it only survives at short configurations, and both arms are therefore offscreen. That guard is working as designed and was not weakened to make the benchmark pass.
- The run also found a real limitation in the existing tooling. `tools/run_v7_perf.py`'s `pair` subcommand requires two binaries with different sha256 in the same profile, so a pair is two source revisions and cannot express two configurations of one tree, and the `matrix` subcommand has no A/B arm axis at all. That is the precise gap this binary fills: two arms, one tree, one difference.
- Boxes: all three stay unticked, and the recorder run is why the third one is still not a claim. The first box's covered part is the generation-resolved pick, the bounds snapshot and stale-handle failure recorded above; its uncovered part is resolved styles, clipping, focus/capture and semantic relationships through a full inspection round trip. The second box's covered part is that the existing perf JSONL and counters were reused with no second recorder and no schema change, and that `run_v7_perf.py` accepted the artifacts; its uncovered part is optional GPU timestamps and task/action attribution at the real service boundaries, which this run did not measure. The third box's covered part is a benchmark on production scheduling timed with real `CLOCK_MONOTONIC` elapsed time across whole runs, driven through the existing perf configuration and its existing scene flags; its uncovered part is the presented path, which the `rejectPerfEvents` guard blocked, so no run in this pair presented a frame. No box in this package is closed.

- The smoke was rebuilt and rerun on the same session after this round's inspection changes, and the pixels are now REAL rather than API-observed. A real window opened with `video driver: wayland`, `observed=520x420 pixels=520x420`, and the run painted 7 rects through the public `v7_render.Renderer` into an offscreen Oklab target, blitted to the swapchain, and read the target back: `paint readback (Oklab): probe_ok=true background_ok=true probe=[0.7346 0.0800 0.1471 1.0000] background=[0.1940 0.0001 -0.0160 1.0000] expected_probe=[0.7346 0.0800 0.1471 1.0000]`. The probe pixel equals the authored value the binary computed, to the last printed digit, and the background differs from it, so the readback is reading the rendered scene and not a constant.
- The pick half reran and still agrees with the engine: `pick-1 agreement: pick_node==input_hitTest=true pick_id==input_hitStable=true`, and the new routed line reports all three policies on the same point: `policy=input node=4 input_node=4 visual_node=4 matches_input=true`.
- The rest of the run reported the same bounded behaviour: `collectors action: capacity=4 reserved=4 requested=6 recorded=6 retained=4 overruns=2 bounded=true`, a 1343-byte snapshot JSON whose head carries the frame, node, role, bounds, visibility, enabledness and focus scope, a 16-line performance JSONL, `close: released=true window_count=0 ... snapshots_after_close=<cleared>`, and `session_deinit=ok view_draws=22 frames_presented=22`.
- Two defects came out of this rerun and both were in the SMOKE, not the library. Its readback recorded a `copyFromTexture` and then read the host-visible buffer in the SAME frame, before that copy was submitted, so every channel read 0; the copy is now recorded in the frame that produced it and the bytes are read after `waitIdle`. And both the probe and the background read the same buffer, so a second read in the same frame overwrote the first; they are now both taken from the one submitted copy. Neither defect touched the inspection API, and the `api-w24` filter was green before and after these fixes.
- What this run does NOT add: still no overlay is present, so "picking an overlay selects the same target as input" is exercised only in its normal-tree form; the pointer events are still synthetic values passed to `App.handle` on a real mapped window, which the run's own output states; and optional GPU timestamps were not exercised by this run, so `gpu_execute_ns` stays unobserved here.

**Checklist reconciliation (2026-10-01):** the third checkbox is established by
the recorded real-clock, production-scheduling paired benchmark. Its failed
120-FPS budget and contaminated absolute timings remain facts, not reasons to
retract that narrower clock/scheduling result. The first two boxes are now
established by the rendered inspector and timestamp runs below.

**Rendered inspector, timing and teardown acceptance (2026-10-01):**

- `direnv exec . env DISPLAY=:4 SDL_VIDEODRIVER=x11 WAYLAND_DISPLAY= DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/nogui-w07-native-runtime-7IEVSwpX/bus taskset -c 3,4 zig build w24-inspector-smoke -j1 --summary all -- --native --gpu-timing --hold-ms 0` exited 0, 28/28 build steps. The private X11 window committed and presented 33 frames on Vulkan 1.4 / GTX 1660 Ti, with 11 overlay resolutions.
- The overlay's rendered Oklab and final-sRGB pixels matched its authored fill. Inspector picking, overlay hit testing and routed input selected the same overlay action; removing the overlay cleared its pixels and made its handles stale. Removed and recycled ordinary handles also returned `StaleHandle`.
- The round trip inspected resolved fill/radii/opacity/layer/shadow/overflow and semantic name/parent/child relationships, then changed the label and fill while preserving identity. A clipped child accepted the inside probe and rejected the outside probe. Press/hold/release snapshots tracked focus, capture and pointer count; the styled handler and clipped-child handler each ran once.
- GPU query results were read after submission and attached by frame ID: 31 written, 31 read, 31 attached, zero refused or unattached. The device reported a 1 ns period and 64 valid timestamp bits; the span ring retained 16 and the frame/task/action rings retained 8/4/4. Four real task completions and six real action dispatches reached their bounded collectors.
- `direnv exec . env -u DISPLAY -u WAYLAND_DISPLAY taskset -c 3,4 zig build w24-inspector-smoke -j1 --summary all -- --gpu-timing --ppm /tmp/nogui-w24-timing-green.ppm` also exited 0, 28/28 steps: 35 committed frames, no presentation, 32/32 GPU results attached, and the 520×520 saved sRGB image was inspected. The current full suite passed 1828/1828 tests across 57/57 steps.
- Native surfaces are released from `on_before_close`, before the SDL window/connection. Partial initialization publishes an owner only after initialization succeeds. The native run ended with zero windows, cleared snapshots, `model_release=ok` and `session_deinit=ok`; the current headless executable's `/proc/nogui-w24-denied.ppm` write failed with `FileNotFound`, exit 1, without the former native teardown abort.
- Pointer values in this scenario are explicitly synthetic `App.handle` input, not compositor-delivered input. The native run proves actual presentation, not external-pointer ingress. No speedup or FPS claim follows from these timestamps.

### W25 — Real-text headless/offscreen consumers and examples

**Coverage:** D02, integration evidence for the rich UI packages. **Depends on:** W06, W11, W12, W14, W15, W16, W17, W21, W24.

**Files:** `src/v7_test/` optional text/render adapters, extracted `src/v7_text/`, `src/v7_render/`, new `examples/parity/` consumers, demo `main.zig` modes, `build.zig`.

**Produces:** real-font headless context, no-window offscreen context, public-API-only examples and replayable scenarios.

- [x] Add optional CPU text and offscreen noapi adapters without forcing GPU initialization in layout-only tests. Share font resolution/layout with the graphical host, not a separate byte-count test implementation.
- [x] Build examples for an application-owned editable field, two windows sharing a model, a virtualized mixed-height feed, a custom canvas/image/SVG view, and a menu/tooltip/drag interaction. These exercise public modules, not private demo imports.
- [x] Run the same state scenario headlessly and through the host, compare meaningful model/focus/selection/semantic results, then inspect actual pixels/native behavior separately.

**Acceptance:** downstream code can implement these consumers without modifying `WidgetKind` or importing demo internals; headless and graphical text geometry agree for pinned fonts; offscreen rendering does not create a native window; all example-owned tasks/models/resources shut down cleanly.

**Gate:** `zig build test -Dtest-filter=api-w25`, existing headless replay/layout commands and real example runs. Add explicit build steps for examples and document their exact commands in the same package; do not publish non-runnable pseudo-examples.

**Verified W25 (2026-09-29):**

- `zig build test -Dtest-filter=api-w25` exits 0 and reports 7 tests, but no test carries an `api-w25` name. Those 7 are the artifacts' unnamed `test {}` blocks, so the run is not W25 evidence.
- The only public-API consumer in the tree, `examples/parity/text_field.zig`, builds under `zig build check` and its two tests are counted in the `api-w12` filter, not this one. The full suite passes 1413/1413 across 34/34 steps with 0 leaks.
- Not run: the example scenarios this package names do not exist. There is no two-window shared-model example, virtualized mixed-height feed, custom canvas/image/SVG view, or menu/tooltip/drag example, and no headless/host comparison was made.

**Checklist reconciliation (2026-10-01):** the dated 2026-09-29 absence is
superseded by the current optional `v7_frame` products and public consumers
listed under audit D02. The external paragraph specimen ran both windowless
and presented arms with 1,016/1,023 checks and inspected pixels. The first two
checkboxes are complete. The separate native menu/tooltip/drag interaction gate remains W16.

**Current paired state proof (2026-10-02):** both `run-parity-state-pair` routes exited **0**, comparing **64 fields** and **12 character-geometry elements** with no mismatch. The parent inspected both **320×220** GPU images. The scenario inserts `seedé`, checks the agreement control and compares focus, selection, semantic values and geometry; input is explicitly synthetic even in the presented route. Mutating one pen, advance or value rectangle made the controller exit **1** with the exact differing field. Native GPU/surface retirement precedes host close/task-wake unregister; shape leases and both readable App trees retire before their model/text owners. Missing required shaders, a missing native blit shader and an unavailable native video backend each returned the original error without a reported partial-owner leak. This closes the paired comparison, not W12's real IME or W16's full interaction acceptance.

**Reviewed consumer integration (2026-10-03):**

- The focused `api-w25` command with `-Daccesskit-bridge=false -j1 --summary failures` exited 0. The editable-field regression first failed with semantic anchor 0 instead of 6. Publication now converts the directional anchor and cursor from UTF-16 to UTF-8 instead of sorting away their direction.
- The actual windowless field emits strict JSON and preserves anchor/focus `6/0`, a visible caret, a 34.2031-unit shaped line and different pinned-font advances `7.8594/8.5781`. `/tmp/nogui-w25-field-windowless-20261003` records the command and complete JSON. It presented zero native frames.
- `direnv exec . node /tmp/nogui-private-x11-run.mjs -- zig build run-parity-shared-model-native -Daccesskit-bridge=false -j1 --summary failures -- --ppm /tmp/nogui-w25-shared-native-left-20261003.ppm --ppm-right /tmp/nogui-w25-shared-native-right-20261003.ppm` exited 0 on owned Xvfb/Openbox and GTX 1660 Ti.
- Two real 360×220 windows presented five/six frames with zero retries. The left header alone acquired focus and one click. Both mounted views kept the shared model after caller tickets were released; revision 3 reached both images. Closing the left window left the right window alive and presenting. The inspected PNGs show `left r3` with its focus outline and `right r3` without one. Input remains explicitly synthetic.
- The private wrapper now passes its own display, HOME and disabled session-bus environment to the controller. Its prior child-environment leak was reproduced before that change. The fresh run used `/tmp/nogui-final-private-x11-XLuQuK` and retired its X11 fixture. Orca and test AT-SPI remained off.
- The actual native field first aborted at the shape-cache pin assertion during teardown. It now releases its layout leases before `NativeFrame.deinit`, retires the surface in the host's pre-close hook and owns partial construction without competing errdefers. The current run `/tmp/nogui-w25-field-native-20261003c` exited 0 and compared its four presented frames' record against the verified windowless baseline: value, directional selection, endpoint/focus/semantic state and real-font geometry agree. The inspected 320×200 image contains the model text and focused endpoint. The pinned Latin font renders the Japanese sample with its missing-glyph box; this is no native IME or CJK coverage claim.
- `SDL_VIDEODRIVER=dummy` rejected that native field's Vulkan window with `SdlError` and exit 1, without the previous teardown assertion, double free or reported allocator leak.
- `run-parity-canvas-view-native` exited 0 on owned Xvfb/Openbox and GTX 1660 Ti: 36 Oklab pixel probes across three presented frames, decoded raster/SVG assets, a changed task-delivered polyline, and stale/unbound retirement to zero image commands. The first run exposed retry count 2863311530 from defaults never applied to undefined storage. Whole-struct initialization fixed it; the fresh run reports zero retries/resizes/rebuilds/extent mismatches without changing pixel acceptance. `/tmp/nogui-w25-canvas-native-20261003b.ppm` holds the last frame with both assets bound.
- A private Xvfb readiness run also exposed server resets between short-lived probe clients and Openbox startup. The wrapper now starts its owned Xvfb with `-noreset`; both subsequent presented consumers completed and retired their private fixtures.
- The corrected word-selection scenario now starts from `seed äö`, selects the final word and produces `seed é`; the separator survives. The freshly built state-pair executable ran both routes through the parent controller with exit 0, comparing all 64 named fields and 12 character-geometry elements. `/tmp/nogui-w25-state-pair-owned-BwJKvo` contains both complete logs. Both inspected 320×220 images agree.
- Mutating one pen position, character advance or value-rectangle origin in the fresh native record made the controller exit 1 at the exact differing field. `/tmp/nogui-w25-state-mutations-20261003/result.json` records all three refusals. No measured geometry was re-pinned to a constant.
- `direnv exec . env -u DISPLAY -u WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS=disabled: AT_SPI_BUS_ADDRESS=disabled: NO_AT_BRIDGE=1 GTK_A11Y=none zig build run-parity-test-context -Daccesskit-bridge=false -j1 --summary all` passed 20/20 steps. The public CPU/windowless GPU contexts measured matching widths `10.172/42.078`, checked Oklab L `0.35 → 0.55`, retained the device after a caller-owned model refused teardown, rejected further rendering with `ContextClosed`, and released the model before retrying teardown. No SDL window, surface or swapchain was created. Read-only lifetime review found no material defect; fresh packaged core-only dependency proof remains in W26.

**Editable-field service ownership repair (2026-10-03):**

- `Consumer` now borrows the actual App text-input manager instead of owning an unused second manager. Endpoint registration, copy/cut/paste and native candidate publication share that route. An existing W18 clipboard service is preserved.
- The routed multibyte regression failed before repair because cut reached an unbound App manager. The final `api-w12` gate passes 52/52 tests. Its scenario cuts and restores an astral grapheme, selects both UTF-16 units, then pastes one three-byte character over that range exactly once; the model becomes `aあb` with a collapsed caret at UTF-16 offset 2.
- The actual windowless controller run `/tmp/nogui-field-app-manager-windowless-20261003` exits 0. The private-X11 run `/tmp/nogui-field-app-manager-presented-20261003` exits 0 against that baseline and presents four frames. Value `abdい`, reversed semantic anchor/focus `6/0` and pinned-font geometry agree. The 320×200 native image was inspected.
- The native frame path explicitly publishes candidate geometry after its own commit/render; the host's absent `on_frame` hook is not credited with this work. SDL's stored area/cursor must match that shaped caret before the record is accepted. Regressions reject shifted area, shifted cursor and an absent measured caret. Input remains scripted; the separate W12 real clipboard/IME controllers target `w12-ime-smoke`, not this example.



### W26 — Distribution and full acceptance

**Coverage:** D05 and closure of the complete audit. **Depends on:** W19, W20, W22, W23, W25.

**Files:** `build.zig`, `build.zig.zon`, README, API guides under `docs/`, example consumers and the audit status table. Include README and all required resources in package paths. Include licenses only with established provenance; do not invent permission for vendored code.

- [x] Package and run clean external consumers for core-only, text-only, renderer, host and test support. No consumer may depend on repository-relative demo files or undeclared developer tools. Document allocator/borrow/thread/coordinate/error rules at the public entry points.
- [x] Recheck every audit row against its implementation and acceptance result. Mark platform rows by actual backend coverage, and list explicit supported limits. Remove dead aliases, old demo implementations and superseded documentation after cutover.
- [ ] Run the full integrated gate once after the final integrated changes, plus native scenarios on every advertised target. Record exact commands, environment, outputs and any remaining failures; do not relabel a failed scenario as optional parity.

**Integrated commands on Linux:**

```sh
zig build test
zig build fixture
zig build layout-check
zig build lint
zig fmt --check src build.zig build.zig.zon
python3 -m unittest discover -s tools -p 'test_*.py'
zig build v7
```

`gate` is the house aggregate where the configured environment provides it. Run either the aggregate plus uncovered scenarios or the individual checks; do not repeat identical checks just to inflate evidence. Graphical/native example runs remain mandatory and are not replaced by the command block.

**Release permission (2026-10-02):** Janis Gertulla explicitly authorized MIT licensing for the original nogui and noapi code. `LICENSE` and `vendor/noapi/LICENSE` record the grants, and both source manifests include them. The pinned upstream inventory remains unchanged; the current inventory records the added grant. Third-party licenses and notices are not relicensed. This resolves the owner-permission prerequisite, not the remaining package and native acceptance.

**Bundled-font notice byte proof (2026-10-03):** each of the four notice files was
compared against its upstream source with no normalization — the reader's envelope
and trim were not treated as upstream bytes — and all four matched exactly:

| Local file | Upstream | Bytes | SHA-256 (local = upstream) |
| --- | --- | ---: | --- |
| `src/Inter-LICENSE.txt` | `rsms/inter` @ `9221beed3` `LICENSE.txt` | 4,380 | `262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a` |
| `src/DejaVu-LICENSE.txt` | `dejavu-fonts` `version_2_37` `LICENSE` | 8,816 | `7a083b136e64d064794c3419751e5c7dd10d2f64c108fe5ba161eae5e5958a93` |
| `src/FiraCode-LICENSE.txt` | `ryanoasis/nerd-fonts` `patched-fonts/FiraCode/LICENSE` | 4,389 | `1d41e10031ab125302780a05ec4c91d218e47db0c7e37cf315cce5e608cdc25c` |
| `src/NerdFonts-LICENSE.txt` | `ryanoasis/nerd-fonts` `LICENSE` | 6,200 | `1f6ad4edae6479aaace3112ede5279a23284ae54b2a34db66357aef5f64df160` |

Evidence: `/tmp/nogui-font-notice-byte-proof-20261003.json`, checked
2026-10-03T05:36:28Z. This closes the notice-provenance question behind the owner
MIT grants recorded above, separately from them: the third-party font terms are
reproduced verbatim and none is relicensed.

**Final Linux integration proof (2026-10-03):**

- `direnv exec . env -u DISPLAY -u WAYLAND_DISPLAY -u AT_SPI_BUS_ADDRESS DBUS_SESSION_BUS_ADDRESS=disabled: NO_AT_BRIDGE=1 GTK_A11Y=none zig build test check lint -j1 --summary all` passed **109/109 steps and 1,912/1,912 tests**. The existing full fixture run passed **5,524/5,524** and the layout check matched all **581** golden rows; no intervening layout change invalidated them. Python tooling passed **126/126**.
- After the final W21 consumer-only repair, the actual headless/native runs above passed; `zig build check lint -j1 --summary all` passed **88/88 steps**, with zero errors/warnings across 258 files. `zig fmt --check src build.zig build.zig.zon examples` exited 0. No unaffected suite was repeated for evidence inflation.
- Through `/tmp/nogui-private-x11-run.mjs`, actual `zig build v7 -j1 --summary all -- --gpu-remount-smoke` passed **34/34 steps**, reused Mandelbrot slot 2 after one hidden frame and retired its owned fixture. Current W18 `--native-observations` passed **13/13 steps**: focused menu/system enable/check/dispatch, single queued synthetic launch, explicit unapproved-launch refusal and absent-portal outcome. Linux native global menus remain unsupported; none was displayed.
- The approved W22 no-press private-niri scenario returned `NoRealParentPress` after readiness, with no signal, allocator fault or surviving child and a healthy compositor query. Supervisor exit 0; zero owned or unattributed survivors. Evidence: `/tmp/nogui-w22-no-press-final-20261003/niri/runtime/w22-no-press-result.json`; retained real-press proof is `/tmp/nogui-w22-scoped-native-acceptance-20261003/evidence.json`.
- These runs keep Orca and the test AT-SPI setup off. Other SDK/device acceptance, interactive capture/Unlock permission and unapproved external desktop actions remain open. The canonical six-consumer fresh-cache package run is the remaining distribution check, not replaced by these checkout-local passes.

**Canonical packaged distribution run (2026-10-03):**

- `zig fetch --global-cache-dir …/fetch-cache ~/projects/nogui` resolved
  the canonical package name **`nogui-0.0.0-CnwuaG3HQAKb0ToiHHC8yGLT3hYbbFZ2TdJxNqSYVCbV`**
  and produced a 6,761,650-byte archive. It was extracted with
  `tar -xzf … --strip-components=1` into a private root.
- The archive is complete against its manifest: 92 declared paths, 1,948 extracted
  entries, 1,874 files, 37,799,789 bytes, `undeclared_files: 0`,
  `missing_declared: 0`, and 39 required paths checked including README, `LICENSE`,
  `vendor/noapi/LICENSE` and all four bundled-font notices — `src/Inter-LICENSE.txt`,
  `src/DejaVu-LICENSE.txt`, `src/FiraCode-LICENSE.txt` and
  `src/NerdFonts-LICENSE.txt`. The generated `src/v7_host/accesskit_bridge/target`
  tree exists in the repository and is deliberately absent from the package. The one
  empty declared path is `src/proto`, which has no source files.
- **The `repo_untouched: true` record is narrowed to what it measured.** It
  established two absences, not a statement about the checkout: the generated
  `src/v7_host/accesskit_bridge/target` tree did not ship in the package, and the
  one exact checkout path `zig-pkg/nogui-0.0.0-CnwuaG3HQAKb0ToiHHC8yGLT3hYbbFZ2TdJxNqSYVCbV`
  was absent. A read-only re-derivation on 2026-10-04
  (`/tmp/nogui-w26-provenance-proof.json`; node v24.20.0, no consumer, no build,
  no fetch, no write into the run root) confirmed that generated bridge target is
  present in the checkout and absent from the package, and found the checkout
  also carries `.tmp-6d5594940322ddbf`. That the fetch left nothing else in the
  checkout changed is therefore not established, and is not claimed.
- All six consumers built and ran **cold** from the extracted package, each with its
  own empty `--cache-dir` and `--global-cache-dir` verified empty before its first
  command, and with `DISPLAY`, `WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS` and
  `ZIG_GLOBAL_CACHE_DIR` cleared:

  | Consumer | Command | Exit | Observed |
  | --- | --- | ---: | --- |
  | `core_only` | `zig build run` | 0 | `core_only: OK` |
  | `text_only` | `zig build run` | 0 | `text_only: OK width=136.09`, with `FontUnavailable` and `UnknownFont` kept distinct |
  | `renderer` | `zig build run` | 0 | `renderer: OK rects=3 materials=2` |
  | `test_support` | `zig build run`, `zig build test` | 0, 0 | `test_support: OK checked=true generation=2` |
  | `host` | `zig build run` (`SDL_VIDEODRIVER=dummy`) | 0 | `host: OK session_window=1 idle_frames=1 worker_frames=2 wakes=1` |
  | `offscreen` | `--empty-font-registry`, then `-- /tmp/…/offscreen.ppm` | 0, 0 | 32 CPU checks with `refused=FontUnavailable`; then 1,016 windowless GPU checks on the GTX 1660 Ti |

  6/6 consumers passed, 0 failed, 11 commands run. The offscreen windowless arm
  wrote a real 640×640 PPM of 1,228,815 bytes.
- **The original controller did not complete in one invocation, and the record says
  so.** It failed with `marker_missing`: the harness required the literal
  `refused=error.FontUnavailable`, while the consumer correctly printed
  `refused=FontUnavailable`. The consumer's own exit was 0 and its 32 CPU checks
  all passed; the failure was in the controller's incidental error-format wording,
  not in the product. The incidental wording gate was removed, and a continuation
  (`/tmp/nogui-w26-finish-offscreen.mjs`) retained every successful cold-cache
  command and ran **only** the remaining windowless GPU arm. `repeated_consumers` is
  empty, so no consumer was re-run to manufacture a clean-looking result, and the
  offscreen cold-cache guard passed before the original controller's CPU command.
  This checkbox asks that the consumers be packaged and run clean, which the six
  cold-source results above establish; it does not ask for one uninterrupted
  controller invocation, so this run needs no repetition and none is pending.
- This supersedes the sentence above that named the six-consumer package run as the
  remaining distribution check, and the dated 2026-09-29 note that no comparable
  clean external consumer existed for text-only, renderer, host or test support.
  Both are left in place as the record of what was true then.

**Cold-package continuation (2026-10-04; read-only, no consumer re-run):**

- The 2026-10-03 counts stay as recorded: 1,948 extracted entries, 1,874 files
  and 37,799,789 bytes were measured immediately after extraction and before any
  consumer built. The same filtered fetch package measures 1,874 files and
  37,799,789 bytes now, so the file count and byte total agree. The extraction
  directory holds 24,561 entries, 22,819 files and 887,439,707 bytes today
  because all six consumers built in it; that is post-build output and not what
  the archive extracted. The original entry count also included symlinks, which
  the current measurement does not.
- The retained frame is not blank. `offscreen.ppm` is 640×640 and 1,228,815
  bytes, and 281,031 of its 409,600 pixels differ from the `33,36,41`
  background. The same proof's flat-frame self-check shows `parsePpmFrame`
  refusing a flat `33,44,55` probe and accepting a marked one, so the check that
  would reject a blank frame is exercised and its refusal is real.
- The historical compiler binding is not recoverable. All 11 commands are
  recorded, 10 of 10 compiler commands name the bare `zig` and 0 record an
  absolute `argv0`, so only the `0.16.0` version log binds that run. The
  toolchain on this host today is
  `/nix/store/fvlqxywq2p7h2147m0wdp8g0m38zdprp-zig-0.16.0/bin/zig`, which reports
  version 0.16.0, and that is not read back into the 2026-10-03 run.
- Current marker and refusal behaviour was proved against the retained logs
  without re-running a consumer: five marker groups re-read 1,016 GPU and 32 CPU
  checks and refuse a missing marker, an unparsable count and the retained
  original `marker_missing` refusal; four refusal groups (preexisting root,
  unsafe root, symlinked parent, version gate) each refuse and leave the checkout
  listing unchanged. `report.json`, `completed-report.json` and the PPM are
  unchanged. Evidence:
  `/tmp/nogui-w26-offscreen-marker-resumed-20261004.json`,
  `/tmp/nogui-w26-refusal-resumed-20261004.json` and
  `/tmp/nogui-w26-provenance-resumed-20261004.json`.

**Canonical gate on the landed docs and frozen source (2026-10-04):**

- The first attempt failed and is kept as dated evidence: 111 of 113 steps and
  1,932 of 1,933 tests, the only failure the `w23_mobile_smoke`
  `PublishedRunIsNotOwned` frame-lifetime test, with the ReleaseSafe, noapi,
  Python and fixture legs never reached. Formatting was fixed, both linters were
  zero across 258 files and the layout matched 581 rows in that failed run too.
- The repair was behaviour-only and source-consumer scoped: an obsolete allocator
  provenance assertion and a dead `LiveLedger` were removed, with no production
  behaviour changed. The real `w23-mobile-field-test` target then passed 21/21
  steps and 4/4 tests in 5.84 s, and a real mount of `Field`/`Session`/`App`/
  `annotate` leaves the complete initial text, caret and generation 1 after a
  failed publication and grows to generation 2 on retry. No mobile device is
  involved and no mobile runtime acceptance is claimed.
- The rerun exited 0 in 986.08 s and reached every leg: Debug `test check
  layout-check lint`, ReleaseSafe `test check`, the vendored noapi suite with
  Tracy off, 126 Python tests in 31.670 s, and the standalone fixture command at
  5,524 passed, 0 failed, 0 unsupported across 5/5 steps. Both linters reported
  zero errors and zero warnings across 258 files, formatting was checked across
  the tree after a narrow pass corrected two files, and the layout golden
  matched all 581 rows. The default mobile probe reported its platform
  unavailable with no device. The linked W21 headless consumer exited 0 with 38
  passed and 0 failed, including `publish.an_abandoned_stage_changes_nothing` and
  the borrowed-text cancel whole-value case, with the native adapter inactive
  and the screen reader false.
- **That run printed no aggregate Zig test count**, so none is restated here and
  none is carried over from the failed attempt. This gate is source and tooling
  evidence on the landed documentation and frozen source. It is not native
  acceptance, not a full project-union pass, and it closes no W20, W21 or W26
  criterion. Root isolation and the viewer transport settled green afterwards, on
  the bounded terms recorded in W21 above, which still closes no native criterion.

**Remaining W26 work, named rather than narrowed (2026-10-03):**

- Checkbox 2 is complete: the source-backed matrix contains all 66 original IDs
  exactly once across all 26 packages, with baseline provenance preserved.
  Review findings in README evidence and package-controller wording are corrected;
  supported limits and unmet native acceptance remain explicit, not counted complete.
- Checkbox 3 stays unticked. The final serial Linux build passed 113/113 steps,
  1,912/1,912 tests, 5,524 fixtures and 581 golden rows. First-party formatting
  and all 126 Python tests passed, but "native scenarios on every
  advertised target" is not satisfied: macOS, Windows and mobile are unbuilt and
  unrun, and on Linux the interactive portal capture permission, the Secret Service
  locked-store read, Orca speech and `EditableText` composition, and external
  open/reveal/scheme association remain unapproved or unobserved. Those are this
  box's own targets; no scenario outside them is treated as missing here.
  *(Superseded 2026-10-04 for its W21 part: the isolated Orca/AT-SPI scope ran and retired completely, so it is no longer an approved-but-unstarted scope. Orca speech is now observed as reader submissions with a clock-paced capture, but no role is established with real audio, so this box's own Orca-speech target remains unmet; the `EditableText` composition target was partly met — all three whole/empty/restore `SetTextContents` writes held natively, while composition through the unimplemented partial methods is still unproved. The W20 capture half is also no longer an approved-but-unstarted scope: the single approved capture ran on 2026-10-04, issued a real `CreateSession`/`SelectSources` and ended `CaptureDenied` with no validated stream and no production PPM. Every non-Linux target is unchanged and still unbuilt.)*
- The approval and SDK prerequisites that no tool can satisfy here stand as they
  are, with each scope named rather than flattened into one blanket refusal.
  **Executed and retired, without full acceptance:** the isolated W21 Orca/AT-SPI
  run on owned private buses/private HOME/private settings, with real speech and
  complete teardown and zero survivors, but no role credited with real audio;
  and the single approved W20 manual-chooser capture, bounded to an owned private
  Niri/Xvfb `:6` session with one monitor and one stream, 30 frames, a
  15 000 ms post-approval budget, one PPM and a source a person selects. That
  capture really started the portal provider, the front end, PipeWire and the
  consumer's `CreateSession`/`SelectSources`, and still ended in denial.
  *(This supersedes the 2026-10-03 statement that neither had started and that
  no portal provider, chooser or PipeWire stream had run.)* **Still unapproved
  and blocked:** any second capture or any automated chooser answer, a keyring
  UNLOCK prompt (no private keyring UI agent exists), external
  open/reveal/registration/drop, and every non-Linux target, which is an SDK and
  OS prerequisite rather than a permission one. A further capture attempt needs
  renewed point-of-risk approval at the time it is made. Credential work stays
  inside the private synthetic namespace and store only, with no existing user
  credential read, written or deleted and no prompt auto-answered. The W22 popup
  scope stays `isolated popup tests`.

**Final serial Linux closeout (2026-10-03):**

```sh
direnv exec . env -u DISPLAY -u WAYLAND_DISPLAY -u AT_SPI_BUS_ADDRESS DBUS_SESSION_BUS_ADDRESS=disabled: NO_AT_BRIDGE=1 GTK_A11Y=none zig build test check fixture layout-check lint -j1 --summary all
direnv exec . zig fmt --check src build.zig build.zig.zon
direnv exec . env -u DISPLAY -u WAYLAND_DISPLAY -u AT_SPI_BUS_ADDRESS DBUS_SESSION_BUS_ADDRESS=disabled: NO_AT_BRIDGE=1 GTK_A11Y=none python3 -m unittest discover -s tools -p 'test_*.py'
```

The formatter also checked all 22 first-party example Zig files and six consumer
manifests by explicit path. An initial broad examples check reached ignored
`zig-pkg` dependency copies; five reported project files were formatted, leaving
those copies unchanged. A later manifest glob supplied an invalid README child
path; explicit paths corrected that command. The settled build result above was
retained, then formatting and Python completed with exit 0; this is not claimed
as one uninterrupted shell invocation. Both linters reported zero errors and
warnings across 258 files. Orca and the test AT-SPI setup stayed off.

**Documentation reconciliation (2026-10-03, continuation).** This entry is
docs-only and changes no source, test, step or runtime configuration.

- The two files this package owns for distribution — `README.md` and
  `docs/API.md` — were reconciled against the renewed narrow approvals, and
  `docs/superpowers/plans/2026-09-26-gpui-api-audit.md` was reconciled with them.
  Three present-tense claims were stale and were corrected rather than deleted:
  the W18/W20 "capture or clipboard unapproved" framing, the blanket "Orca stays
  off / no test AT-SPI services started" framing, and the closeout sentence that
  said the approved runs "still await verified private fixtures" after the
  private Wayland subset had already executed.
- What was corrected is the **present tense only**. Every dated historical
  outcome above stays as written, including the 2026-10-03 W18 X11 chooser
  endings, the 2026-10-02 W07/W16/W25 records and the 2026-09-29 W21 note that
  all three boxes stayed unticked. Where a dated sentence and the current state
  differ, the current state is stated in a new dated entry instead of by editing
  the old one.
- The dated gate counts in the section above — 113/113 steps, 1,912/1,912 tests,
  5,524 fixtures, 581 golden rows, 258 lint files, 126 Python tests — remain the
  recorded observations of that run. No build, test, lint or formatter was re-run
  for this documentation change, and none is restated here as renewed.
- The package hash `nogui-0.0.0-CnwuaG3HQAKb0ToiHHC8yGLT3hYbbFZ2TdJxNqSYVCbV`
  and the 6,761,650-byte archive identify **that** clean-cache proof. They are
  historical evidence of the archive as extracted then; they are not a digest of
  the current tree, and the docs-only edits above do not change them.
- No acceptance criterion is closed by this entry. W20's three boxes, W21's
  Orca/speech/`EditableText` clause, W18's external-action half, W19's locked
  store and every non-Linux target remain exactly as open as the sections above
  record them.


**Verified W26 (2026-09-29):**

- `zig build test -Dtest-filter=api-w26` exits 0 and reports 7 tests, but no test in the repository carries an `api-w26` name. Those 7 are the build artifacts' unnamed `test {}` blocks, which a name filter cannot exclude, so the run is not W26 evidence.
- The integrated block ran once: `zig build test -j6 --test-timeout 15m` passed 34/34 steps and 1413/1413 tests with 0 leaks; `zig build check` exited 0; `zig build fixture` passed 5,524; `zig build layout-check` matched all 581 golden rows; `zig build lint` reported 0 errors and 0 warnings across 190 files; `zig fmt --check src build.zig build.zig.zon` was clean; `python3 -m unittest discover -s tools -p 'test_*.py'` passed 125 tests.
- Not run: clean external consumers for the text-only, renderer, host and test-support products, and the native scenarios on every advertised target. W01 recorded a clean external core-only consumer on 2026-09-26; nothing comparable exists for the other four products. The noapi licensing provenance prerequisite above is still open.

- The integrated block was run again after this round's integration work, and every step is green on this tree. `zig build test` exits 0 with 0 test failures and 0 leaks across the whole suite; `zig build check` exits 0; `zig build fixture` reports `{"passed":5524,"failed":0,"unsupported":0}`; `zig build layout-check` prints `layout matches golden` over 581 rows; `zig build lint` reports **0 errors and 0 warnings across 199 files**; `zig fmt --check src build.zig build.zig.zon` exits 0; `python3 -m unittest discover -s tools -p 'test_*.py'` passed 125 tests.
- Every public example and every native smoke was then RUN, not compiled: `run-parity-text-field`, `run-parity-shared-model`, `run-parity-virtual-feed`, `run-parity-uniform-feed`, `run-parity-query-consumer`, `run-parity-canvas-view`, `run-parity-menu-overlay` and `run-parity-list-live` all exit 0; `w07-host-smoke`, `w22-layer-shell-smoke`, `w17-anim-smoke`, `w14-asset-smoke` (49/49), `w18-dialog-smoke` and `w24-inspector-smoke` all exit 0 with no leak. `w22-popup-smoke` exits 0 on the X11 driver and exits 1 on Wayland, which is this stack's documented refusal rather than a pass: the run reports `show: NotApplicableOnThisDriver` in words before returning, and it no longer leaks the role on the way out.
- The lint count moved from 46 findings across 15 files to 0. The findings were real style and safety issues in the code this round touched: long lines, snake_case function names in a smoke, `catch {}` blocks that swallowed platform and provider failures, `deinit`s that did not poison their value, an anonymous-struct literal used as a `for` source, and `undefined` defaults without a safety comment. Two of the `catch {}` replacements changed BEHAVIOUR for the better and were verified by their own smokes: a display-snapshot `put` that could not record a display now warns instead of discarding, and a popup teardown plan that could not be recorded now warns.
- This round also fixed a batch of real defects found by running the code rather than reading it, all recorded in the packages above: the D-Bus array writer counted its alignment padding inside the array's byte length, so every reader over-read; `AssetManager.invalidate` removed the cache entry under the post-bump generation and leaked the bytes; `AssetManager.load` could start a second load for a request that arrived after the first one's cache probe; the virtual list established its scrollable extent before the row visit that measures rows, so the committed content was always one measurement behind; `FileSource.load` copied a `@fieldParentPtr`-based reader interface and segfaulted on the first real file read; the W14 readback recorded its copy before the barrier that makes the color output visible to a transfer; the W24 smoke had the same readback defect plus two reads of one buffer; the popup role was left uninitialized except for two fields, and `deinit` then read garbage as a Vulkan surface; `show` refused a driver without releasing the role; the clipboard freed a pointer-to-pointer SDL had not allocated; the W07 smoke's window tracker never dropped a closed window, so its last-window-close path was unreachable; the smoke binaries used the pre-cutover popup, inspector and window-slot APIs; and `ImageSequence`/`AnimatedSequence` lifetime rules were violated by a consumer holding a borrowed timeline across `deinit`.
- What is still open after this gate, stated plainly because the gate does not close it: the noapi licensing provenance prerequisite is unresolved and no distributable release is claimed; macOS, Windows and mobile remain unbuilt and unrun, so W23's E01–E05 have no runtime evidence on any other target; Orca speech and text composition through EditableText are still unobserved; the interactive portal file chooser, the Secret Service store, screen capture permission and the clipboard mutation all still need explicit operator approval and have not been run; and the W25 examples stop at the public boundary for PIXELS because the tree-to-scene submission stage and `GpuEndpoint` construction are still demo-owned, which is a named gap in the library rather than in the examples.

- The stale `slangc` comment in [`build.zig`](../../../build.zig) is corrected rather than left to mislead the next reader. It had claimed that the check step does not need `slangc`, which is false: `w13-canvas-smoke`, `w17-anim-smoke` and `w24-inspector-smoke` each depend on the shader update step through their own executable step, and `check` depends on all three. Line 714 now reads that test and lint do not require `slangc` while `check` includes the shader-backed smoke builds, which is what the dependency graph already did. The README's matching open finding is removed with it.
- That is a comment repair against the graph that was already there: no build step, dependency or artifact changed, and no W26 box or acceptance scenario is closed by it.

## Existing-plan reconciliation

These rules supersede conflicting infrastructure instructions in the two older plans, not their product goals. Their implementations are **not added** to GPUI parity: GPUI does not supply a built-in code editor or catalog localization system.

### Embedded Neovim plan

| Older instruction | Unified replacement |
| --- | --- |
| Add `.code_editor` to every closed `WidgetKind` switch | Implement `DrawCtx.codeEditor` as a wrapper over W08's custom element descriptor; keep explicit cell-grid measurement, post-layout resize, clipping and semantic role. Do not add another layout/paint dispatch family. |
| `FocusTarget { control: Id, editor: ComponentId }` | One stable W02/W09 widget/focus identity for all controls and editor leaves. Editor session identity is separate from view identity. |
| Editor-specific modifiers, composition offsets and direct SDL routing | Reuse W09 events and W12 text protocol. Preedit selection is UTF-8 bytes relative to preedit. Ordinary fields and Neovim are distinct focused consumers. |
| Direct `font_id:u8`, private demo grid paint | Validated W11 font request/metrics and W13 paint records; grid cells may still use fixed advances and editor-owned highlight data. |
| Editor-owned clipboard implementation and independent worker delivery | W18 system service plus bounded editor RPC adapter on W05 scheduling/completion. Preserve the existing RPC backpressure, child isolation, recovery and save requirements. |
| Surface-pixel mouse conversion before editor coordinates | W02/W07 logical visual-content coordinates, then cell conversion. Device conversion is only at the rendering/native boundary. |
| Root explicitly owns session and immutable grid snapshots | Retain that ownership through a persistent model/host resource. Never put RPC buffers/grid in frame state. GPU and two-frame pins govern snapshot retirement. |

Tasks for private RPC protocol/isolation/recovery can be implemented independently, but the public leaf/input/paint integration consumes W02, W03, W05, W08, W09, W11–W13 and W18. Do not implement both old and new focus/text runtimes temporarily as the shipped interface.

### Localization plan

- Keep immutable catalogs, typed arguments, explicit locale selection, fixed two-slab frame budget and zero-copy adoption into all seven text-bearing widgets.
- A catalog may be shared by Session owners, but each App retains its own two text slabs and locale selection. Setters invalidate the affected window through W04/W05 and preserve current catalog/text lifetime guarantees.
- `message_key` remains content metadata, not `WidgetId`, accessibility identity or list identity. Stable widget keys replace demo label-text searches.
- Raw and localized content enter W11's same text/run/style/layout path. Compute run ranges against the resolved current-locale bytes, not against a previous translation.
- Keep the formatter's declared locale/number/plural limits; improved font/bidi capability does not silently expand catalog-language support. No second shape cache or accessibility tree.

## Completion criteria and risks

**API parity completion requires:** every gap row linked to an implemented package, all acceptance scenarios exercised, public consumers using the API without private demo imports, no silent no-op fields, correct two-frame/GPU lifetime, and native coverage labeled by tested backend. This plan's completion is only the design/audit deliverable, not that implementation milestone.

| Risk | Required control |
| --- | --- |
| Identity and ownership cutover breaks existing immediate callers | W02/W03 atomic caller migration and old/current-frame tests before higher-level features. |
| New phases violate postorder or introduce cyclic layout | W08 bounded late-subroot finalization; W15 query children cannot size their query parent. |
| Async jobs, native callbacks or GPU uploads outlive frame/model owners | Weak generational handles, owned payloads, cancel acknowledgement and separate GPU retirement pins. |
| Accepted API values have no visible implementation | Every text/paint/service field has a consumer-level scenario; no value-only parity claims. |
| Unicode units and DPI spaces become mixed | Typed/named boundary conversions shared by text, pointer, IME and accessibility. |
| Optional host dependencies leak into core package | External core-only and text-only consumers at W01 and W26. |
| Native portability is overstated | Per-target capability matrix, actual OS runs, unsupported distinct from denial/cancel/failure. |
| Feature scope drifts into a full editor/widget suite or GPUI clone | Preserve explicit audit scope and existing separate feature plans. |

## Planning-session verification

Executed against the current implementation, not the proposed API:

- `zig build v7` completed successfully and ran the existing **six-frame headless Todo demo** with CPU font measurement.
- Parsed the emitted frame records: counter changed `0 → 1` at frame 3; `buy milk` changed `false → true` at frame 4; todo count changed `2 → 3` at frame 5 and retained `1 of 3 done` in frame 6.
- This smoke establishes that the current headless consumer and three injected interactions run. It does **not** prove the proposed APIs, native services, focus-reorder risk, GPU output or GPUI backend behavior.
- Structural checks passed: all **66** audit rows map to one primary package among **26** packages; package and dependency tables agree; the graph is acyclic. All **55** local document/source links checked across the new documents and their added integration links resolve, as do **60** cited GPUI Rust source paths. Markdown table column counts are consistent.
- Source code, tests and runtime configuration were not changed by this planning task. The full implementation gate above has not been run for this docs-only change.
