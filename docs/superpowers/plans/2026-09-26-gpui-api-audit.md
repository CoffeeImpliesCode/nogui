# GPUI API capability audit

**Date:** 2026-09-26. **Status (2026-09-29 gate run):** W01–W03 verified; every W04–W26 per-package test filter is green and the full suite passes 1,413/1,413. Native runs on the live session on the same date added evidence for W07, W22 and W24, through the native Wayland driver in almost every case and through XWayland's X server for the W22 popup, but every W04–W26 gate still has an unrun or blocked half — the W07 X11 half was attempted and is blocked by a host graphics-stack fault outside this repository — so 60 of the 66 gap rows remain unverified. Gap descriptions below preserve the audit baseline, not the current implementation.

**Current status (2026-10-03 integration):** read
[Current implementation and acceptance matrix](#current-implementation-and-acceptance-matrix-2026-10-01)
below before any dated section above it. That matrix reconciles all 66 gap rows against the
source that exists now. The C/L/I/T/R/P/A/D tables at the end remain the 2026-09-26 source
baseline. The settled `test check lint` gate passed **109/109 steps and 1,912/1,912 tests**,
including the repaired Windows consumer; both linters report zero errors and zero warnings
across **258 files**. The **126 Python tests**, **5,524/5,524 layout fixtures** and **581-row
golden** passed, and `zig fmt --check src build.zig build.zig.zon examples` exited 0.
The clean-cache package gate now runs: canonical archive
`nogui-0.0.0-CnwuaG3HQAKb0ToiHHC8yGLT3hYbbFZ2TdJxNqSYVCbV` was extracted with empty build
caches and **all six external consumers passed 6/6**.
Actual earlier menu-overlay and private X11/IBus evidence remains valid:
**35 accepted items, zero refusals and both candidate-window observations**.

**House gate renewal (2026-10-04):** `direnv exec . gate` exited 0 after three lint corrections.
It completed Debug and ReleaseSafe checks, noapi tests, formatting, lint and Python tooling.
Both linters reported zero errors and warnings across 258 files.
The layout comparison matched all 581 rows. All 126 Python tests passed.
The separately renewed fixture command passed all 5,524 cases, with zero failures or unsupported cases.
Current controller helpers passed 82 exercised cases, 24 navigator cases and three real kernel `environ` ENOENT rounds.
One historical log trap remained explicitly unexercised. These helpers started no native provider.
Cold-package renewal and W20/W21 native acceptance remain separate.

**Continuation status (2026-10-03, documentation reconciliation).** A later
renewal of narrow approvals produced new real runs and also produced stale
**present-tense** claims in `README.md`, `docs/API.md` and this document. Those
claims have been corrected; dated historical outcomes have not been rewritten.
What changed:

- **Observed:** the private **Wayland** half of W18. On an owned private
  Niri/Xvfb `:4` fixture with private buses and private HOME, a whole clipboard
  item carrying text, a 1×1 PNG (67 B) and a JSON metadata blob (37 B) was
  offered, read back at exact lengths and fully restored; PRIMARY reported
  supported and was read back through an independent `wl-paste --primary` reader
  that found nothing copied both before and after. All three real GTK chooser
  endings — synthetic selection, the real Cancel mnemonic (Alt+C), and a live
  parent close — were observed against the current mapped-parent executable
  `ebef0947c7df79c5fed45ac22c7aaac4` in one exit-0 invocation with zero survivors.
- **Observed, provider-free:** the W20 capture fixture's own fault modes —
  bounded consumer retire, exited-leader group descendant, no-approval consumer,
  foreign-birth unknown group (correctly `REFUSED`) and a later-than-15 s timing
  fault. No provider, chooser, portal request or frame was involved.
- **Ran and retired (2026-10-04):** the isolated W21 Orca/AT-SPI run. See the
  dated continuation below.
- **Approved once; that single approved capture has now run (2026-10-04):**
  exactly one first W20 manual-chooser capture, bounded to an owned private
  Niri/Xvfb `:6` session with one monitor and one stream, 30 frames, a
  15 000 ms post-approval budget, one PPM and a manually chosen source. The
  approved `:6` viewer window with clipboard sharing disabled was preparation
  for that one capture, not new capture authorization.
  The 2026-10-04 setup proved private X cookie client exit 0/cookieless exit 1;
  Niri then exited 101 on missing `libXcursor.so.1`, before viewer or capture.
  All seven recorded owners retired and were re-observed absent. The Node
  wrapper timed out after 600 seconds despite complete retirement. Evidence:
  `/tmp/nogui-w20-private-capture-WetkjW/fixture.json`. No capture credit follows.
  Current provider-free checks resolve all six required compositor SONAMEs.
  A real SONAME-scan refusal now releases all owned directory descriptors.
  The real-child lifecycle smoke drains naturally at Node `beforeExit`, without a forced success exit.
  All 19 safety cases held across 20 fresh module instances, with all instances retired.
  The final audit found no live owners, zombies or unobservable processes.
  Evidence: `/tmp/nogui-w20-runtime-lifecycle-fd-green-20261004/result.json` and
  `/tmp/nogui-w20-viewer-current22-20261004/result.json`.
  Native setup then reached real Niri and portal readiness after the declared
  provider patch fixed a null-DRM-device crash. The incompatible `weston-color`
  client required `wp_color_manager_v1`. The declared `weston-image` client now
  paints an owned static image. Its private compositor screenshot was inspected,
  and two still witnesses matched.
  `/tmp/nogui-w20-private-capture-lUUPJb/fixture.json` records complete retirement
  of all 19 fixture-owned process groups. The parent viewer authenticated but
  lacked a verified compositor window witness, then exited 0 after retirement.
  No viewer acknowledgement, ScreenCast request, chooser, stream or captured
  frame occurred. *(Both dated attempts above started no capture; they are
  retained history and are not evidence for or against the run below.)*
- **First actual capture request (2026-10-04):** evidence
  `/tmp/nogui-w20-private-capture-1RLlCp/fixture.json`. The single approval was
  spent here, and the run reached the real portal without producing a stream.
  `CreateSession` and `SelectSources` really went out for the first time, with
  `types=1`, `multiple=false`, `cursor_mode=2` and `persist_mode=0`, against a
  backend advertising `AvailableSourceTypes=1` and `AvailableCursorModes=3`. The
  private viewer half is proved rather than assumed: viewer pid `3764550` (start
  ticks `30773721`) was matched on the private X server, where niri reported
  window `295` through relay pid `4315` — the XWayland satellite, not the
  viewer — and `xprop` on XID `0x1400005` returned that exact viewer pid with
  its caption and class. The private server was pid `3762235` (start ticks
  `30771058`), and the secure acknowledgement was exactly 108 bytes, mode
  `0600`, uid `1000`, `nlink` 1, carrying this run's own nonce and that same
  server identity. Private `HOME`/`XDG_*`, clipboard off in both directions,
  `-FullScreen=0` and `-RemoteResize=0` were all proved, the real private pixels
  were read and saved, and the post-resize still-witness pair matched.
  The chooser witness expired at its 240 000 ms bound: the chooser really ran and
  its `slurp` process produced a 198-line `WAYLAND_DEBUG` trace with 119 protocol
  lines, but this repository's parser rejected libwayland-client's
  `{Default Queue} ->` prefix and extracted nothing. That parser prefix is now
  corrected; replaying the same captured trace yields shell 5, layer-shell 10,
  surface 3, output 9, xdg-output 11, the winit surface, the selection and
  configure/ack 201 in protocol order with the raw lines retained — a replay of a
  real trace, **not** a new live witness, and the corrected parser has not yet
  run against a fresh chooser. The consumer's own verdict is a refusal:
  `begin: state=denied failure=rejected returned=CaptureDenied chooser=279771 ms`
  and `verdict: the capture half did not observe a validated stream; exit=3`, so
  there is **no validated stream and no production PPM**; the fixture wrapper
  itself exited 22 after 345.68 s. All 23 owned process groups were observed gone
  with no survivors, no unresolved ownership, no observation failures, no
  unsettled reap and no open pipes. **The six `invalid_pidfd_reply` refusals are now
  classified in source rather than unexplained**, and the classification is not a
  live witness: the old caller allowed 2000 ms and sent its own `SIGTERM` before
  the helper's own 5000 ms budget, all six helper stdouts were empty and carried
  `SIGTERM`, and the collector now declares a 20 s startup contract of 5 + 2. No
  fresh capture produced that explanation and no earlier component proof explains
  it. Source-repaired and still not live-witnessed, so this run is not called clean.
  No second capture is approved; a further attempt needs renewed point-of-risk
  approval at the time it is made.
- **Retirement component renewal (2026-10-04; no new capture):** real owned-child
  pidfd tests pass for missing/wrong birth refusal, exact TERM (`-15`), bounded
  blocked-stdout exit 3 with a partially delivered 64,013-byte report, and a
  genuine work interruption partitioned into 456 refusals, one UNKNOWN and
  443 never-attempted rows. Actual Node 24 pipe tests cover collector overflow
  and stdin/child `EPIPE` without falsely calling the helper unstarted.
  Evidence: `/tmp/nogui-w20-real-pidfd-proof-xi_a1j5b`,
  `/tmp/nogui-w20-real-work-bound-proof-g_se1cis` and
  `/tmp/nogui-w20-real-node-proof-gSvCXu`. No capture provider or permission
  request ran. The six original replies' causes are now classified in source as
  recorded above, not by these component proofs; renewed live retirement remains
  unproved.
- **Still open:** live capture, the validated stream and preview, chooser
  acceptance, name-plus-state audio for six roles, the remaining native
  action/state failures, native IME composition, the W19 locked-store Unlock,
  external open/reveal/scheme/drop and every non-Linux target. Whole-value
  editing and native keyboard movement have held in the W21 renewal below.
- **Not renewed by this entry:** the gate counts, the fixture and golden totals,
  the lint file count and the Python totals are the recorded observations of the
  2026-10-03 settled run. This reconciliation changed documentation only and
  re-ran no build, test, lint or formatter. The 113/113-step settled gate
  supersedes the 109/109 figure written above. The canonical package name and
  archive size identify **that** clean-cache proof; they are historical evidence
  of the archive as extracted then, not a digest of the current tree.

The corrected claims are the ones that said capture was unapproved, that no test
AT-SPI service could be started, and that the approved runs "still await
verified private fixtures". The 66 original IDs, the 26 work packages, the dated
baseline tables and the separate Neovim editor scope are unchanged.

**Continuation (2026-10-04, W21 native renewal and pin move).** The latest
evidence is `/tmp/nogui-w21-approved-2026-10-04T14-09-07-151Z/evidence/result.json`.
It supersedes present-tense claims that the approved private run had not started,
that the SDK exposed no `EditableText`, or that whole-value writes and keyboard
movement remained unobserved. The earlier failed runs below, including the
`04-54-32-795Z` and `11-16-02-453Z` runs, are historical records, not current
acceptance.

- **The approved isolated Orca/AT-SPI scope ran and retired completely.** Owned
  private fixture rooted at `/tmp/nogui-w21-approved-2026-10-03T23-55-00-659Z`,
  complete record in `evidence/result.json`. A private session bus and a private
  accessibility bus served by a real `at-spi2-registryd`; `org.a11y.Status`
  answered `IsEnabled=true` and `ScreenReaderEnabled=true`, both written into and
  read back from that run's own private dconf database. The configured
  `espeak-ng` module logged `Initialized successfully.`; Orca 50.2 stayed alive
  past its startup grace period. Exit 1, `full_acceptance: false`, 11 of 20
  required items unmet.
- **Real audio was captured, clock-paced, not read from a log line.** `parec`
  recorded the private null sink's `w21-audio.monitor` into
  `evidence/speech-pcm.raw`: 8,440,180 bytes over 191 387 ms of `s16le 22050 Hz
  mono`, 1,527 observed intervals of which 1,526 grew, median 44,039 bytes/s
  against the declared 44,100, `clock_paced: true`.
- **Real window pixels exist.** The smoke exited 0 with
  `frames=220 presented=220`, adapter `state=active` and `screen_reader=true`, 19
  published nodes, the 520×760 window on the `x11` driver, `inked=297960`
  pixels, and the frame written to `evidence/w21-last-frame.ppm`. The shader
  working-directory defect that had stopped this arm from presenting is fixed.
- **What it did not establish, and is therefore not credited with:** the AT-SPI
  client enumerated nothing — `evidence/w21-client.log` reports the window never
  appeared on the bus and `saw: []`, `client-act.json` does not exist, and
  that run's `children()` converted enumeration exceptions into an empty list, so
  that absence is a refusal to enumerate, not a measurement; **no `EditableText`
  write** — the run records that the client wrote no `EditableText` report, so no
  whole-value edit was attempted, and the smoke's own closing line reads
  `text_writes=0`, `button_hits=0`, `row_picks=0`; **0/6 roles spoken with real
  audio**, with 34 spoken and 344 speech submissions, 101 naming a control, and
  every attributed utterance's own capture window never advancing, so no line
  owns audio — all six are still named with the cause "the AT-SPI client never
  reached this control on the real bus"; the progress value clause is 0/1 and its
  NAME route was not attempted; and **no keyboard activation** — 16 and 24 tab
  walks, no `button_hits` or `level` movement, focus never reaching `W21 Text
  Field`, and zero navigator grabs reported by the reader itself.
- **The reporter's own output is a separate defect.** The first publication
  carried all 19 nodes; the next carried 2 with `full=false` and emitted the
  focused object's ID `11046169448000896806` as `role=unknown name=""`, and later
  partial publications emitted more empty records, so the controller's
  focus-name resolver resolved an empty name.
- **Retirement is real.** All 32 owned PIDs were re-observed after teardown and
  none survived, the survivor observation passed with no failures, every group
  member was retired through a pinned `pidfd_open`/`pidfd_send_signal` handle,
  and the operator's own accessibility setting read `false` before and after.
- **The pin move retires two prerequisites.** The bridge now runs
  `accesskit 0.25.0`, `accesskit_unix 0.23.0`, `accesskit_atspi_common 0.20.0`,
  `accesskit_macos 0.27.0` and `accesskit_windows 0.35.0` coherently across
  source and the locked `Cargo.lock`. The recorded `accesskit_unix 0.21`
  prerequisite is gone, and so is the standing reason the `EditableText` clause
  was called unobservable: the pinned Unix provider **does** expose
  `SetTextContents`. The latest native renewal held all three whole/empty/restore
  writes, read back through platform `Text`. Unsupported partial methods were
  named and never called; native IME composition remains unproved.
- **There is no current full-union result.** `Dispatcher.set_text` now takes
  `?[]const u8` with a non-null selection, so a non-null value is the entire new
  contents and a null value is selection-only. The current locked Rust bridge
  suite passed **22/22**, unlinked `api-w21` passed **93/93**, and linked CLI
  smoke passed **38/38**. Earlier mobile **4/4** and Windows **7/7** counts remain
  model evidence; both portable targets compiled, not ran on their native OS.
  The mobile proof covers ordinary empty clear, character-table edits, refused-
  frame borrow retention and a non-prefix whole-value alias that previously
  crashed in memcpy. Windows' non-prefix whole alias also changed from a real
  memcpy abort to exact `😀Ωtail`, six characters and UTF-16 caret 7 with one
  edit and no staging. Count/index enumeration and sparse W21 reporting are now
  exercised natively. Complete six-role speech acceptance remains pending.
  The active-preedit alias regression changed from corruption to exact 18-byte,
  eight-character `漢字üße ✓€` preservation through the whole write and a later
  composition/cancel, with end caret 18 and no stale restore. Only a marked
  overlapping payload receives the bounded 96-byte stack copy.
  A01 and A02 stay open. The W19 locked-store `Unlock`, external
  open/reveal/scheme/drop and non-Linux target prerequisites are unchanged.
  *(Superseded 2026-10-04 on one point: the first W20 capture is no longer an
  untouched prerequisite. The single approved capture ran, issued a real
  `CreateSession`/`SelectSources` and ended `CaptureDenied` with no validated
  stream and no production PPM; see the W20 entry above.)*
- **Latest native text proof and remaining failures:** frame-owned text and
  character tables removed the native SDK corruption; present-empty C ABI
  values and a collapsed caret at zero preserved empty runs. The application
  published `W21 Ω αβγ 日本語 ✓ Grüße` at 35 host **bytes**, then empty at 0
  bytes, then its own first reading `Grüße ✓` at 11 host bytes; the platform
  served the same whole values back as 21, 0 and 7 **characters** with the caret
  collapsed at 21, 0 and 7 and `getNSelections` 0 each time, moving the model
  exactly once per write (`text_writes` 1→2→3→4) and moving only `caret`, `text`
  and `text_writes`. Native keyboard activation held for both Space and Return,
  slider keys, radio movement, printable text and caret movement each moved a
  real published model counter. The actual final framebuffer was inspected.
  Exactly eight non-text client steps failed, each with a named cause rather than
  one category: `slider:set-value`, whose own `Value` setter call never reached
  the model; `progress:is-read-only-and-cannot-be-driven`, a **bogus gate**
  because the indicator really is read-only and non-focusable and no mutation
  was attempted; `list:the-selection-interface-reads-back-what-was-asked`, which
  compared a `selected_count` of 1 and an `index` of 2 as two child counts;
  `list-add:custom-action`, the absent `Add` named action;
  `modal:disabled-control` and
  `modal:hidden-left-the-tree-and-disabled-stayed-in-it`, which exposed a **real
  SDK bug** where a disabled node still published `Enabled`/`Sensitive` and so
  made the `Disabled` clause impossible to satisfy; and
  `list-add:works-again-after-the-dialog-closed` plus
  `list-add:republished-and-drivable`, the absent reactivation named action.
  The stock reader's own object navigator is the one route that reaches the
  read-only indicator: from `W21 Slider` at sibling 7, one
  `Orca+Control+Left` reaches `W21 Progress` at sibling 6 and the reader's own
  log produces `_generate_accessible_name: [W21 Progress]`,
  `_generate_progress_bar_value: [30 percent.]` and
  `Results: [W21 Progress, 30 percent.]` with no model key moving across it.
  That is recorded as an observation, not as closure. Name-plus-state audio
  remains **0/6** because each attributed utterance's own capture window never
  advances. Real synthesis and clock pacing are themselves proved separately:
  8,079,086 bytes over 183,199 ms, 1,741 observed intervals of which 1,740 grew,
  median 44,039 bytes/s against a declared 44,100, and the daemon's one "server
  audio is not supported" error is attributable to no module. The smoke exited
  0, but the client and complete fixture exited 1. All **32 owned pids** were
  re-observed gone, with no own survivor; the normal accessibility setting
  stayed `false`. A01 and A02 remain open.
- **Named-action and disabled-state cutover (2026-10-04; since exercised natively).** The
  bridge C ABI now carries
  `nogui_accesskit_custom_action { int32_t id; const char* name; size_t name_len; }`
  on every node plus `custom_actions_len`, and the action request returns that
  exact signed `int32_t`, so a platform round trip is answered by the id rather
  than by a re-derived index. The host's tree buffer reserves every descriptor
  slice before handing out a single pointer, so growth during node append cannot
  move a buffer a descriptor already points into, and the SDK owns its own copy
  of every name. The locally pinned **same-version** `accesskit_atspi_common`
  0.20.0 patch publishes `click` at index 0 **only** for a genuinely clickable
  node — a custom-only action list legitimately starts at index 0 — publishes
  every `Node::custom_actions` entry with its own exact signed id, and stops
  reporting `Enabled | Sensitive` for a disabled node. No client step name and
  no JSON envelope changed. The parent reproduced the former named-list-owner
  failure (`expected 1, found 0`), then passed the corrected Core `api-w21`
  **95/95**, the locked offline all-features Rust workspace
  **22 SDK + 22 bridge tests**, and the rebuilt linked CLI **38/38**. These are
  focused changed-source checks, not a final full project gate. Native acceptance
  since ran and is recorded above; it is not closed. Earlier 93/93, bridge-only 22/22 and CLI 38/38
  counts predate this cutover. The pinned `Value` setter still acknowledges asynchronously,
  and `UnknownObject` is not
  treated as evidence of a read-only node. Named actions and exact model deltas
  are not to be replaced by click fallbacks or an "expected limitation".
- **Genuine wire component renewal (2026-10-04; not native reader acceptance):**
  five actual `sd_espeak-ng`/observer cases pass: speech, STOP, repeated text,
  SIGKILL and kernel-denied post-fork pidfd acquisition. The current controller
  independently re-frames every trace with zero raw/index disagreements,
  owner violations or ownerless replies. It decodes real odd-escape frames and
  retains separate request/transaction IDs for repeated text. The real STOP
  closes on module `703 STOP`, not a daemon UID event; ten audio chunks after
  STOP stay with that owner. SIGKILL is a real `-9` wrapper exit. Kernel refusal
  reaps the gated child as exit 126, records that no module executed and forwards
  zero bytes. The replay exposed and corrected INIT/QUIT no-reply
  misclassification, omitted verb spans and the false demand for a bracket when
  no transaction exists. Evidence:
  `/tmp/nogui-w21-real-module-proof-wwbav570/actual-results.json` and
  `current-consumer-replay.json`. There is no standalone daemon UID ledger,
  reader presentation or paced monitor, so this grants **no six-role waveform
  credit**. Full native and project-union acceptance remain open.
- **Latest owned native run (2026-10-04T14-09-07-151Z; acceptance still fails):**
  exit 1, `full_acceptance: false`, **18/22** required items established. The
  main native client has no failures and the named-policy client passes **23/23**:
  both signed named list actions publish under their own names, index 0 is a named
  action and not a click, the source records **two named-list activations and zero
  clicks**, and each blocked node offers no `Action`, established by enumerating
  that node's own interfaces rather than by catching an exception. Keyboard,
  Value, EditableText, model deltas and private accessibility settings hold; the
  typed consumer is retired before the reader starts and every owner after it,
  with the operator setting `false` before and after. Stock Orca 50.2 handled
  `Insert+ctrl+Left` as `Left` (113) after 102 ms and presented
  `[progress bar: 'W21 Progress']`; the model moved nothing, the keyboard stayed on
  `W21 Slider`, and the indicator stayed `focusable=false` and was never focused.
  Four criteria are unestablished: progress value with real audio, progress name
  through stock object navigation, reader object navigation leaving the
  application untouched, and six-role audio at 0/6. The reader's own log is 14,563
  CRLF lines with 102 `SPEECH OUTPUT` lines and 0 proved fragments; the 4,140,114-
  byte monitor is real and clock-paced and real synthesis is proved separately;
  raw and index agree and 42 of 51 wire submissions joined, the 9 refusals being
  the daemon's own `__spd_0` mark on a payload without it. The reader's grab
  agreement could not be read out of its CRLF log, which is why the untouched
  criterion stays open although no model key moved. The CRLF ingress fix is
  source-only and its causal fixes and replay are in progress, so no regenerated
  18/22 result and no new native full pass are claimed. Evidence:
  `/tmp/nogui-w21-approved-2026-10-04T14-09-07-151Z/evidence/result.json`.
- **Reader-origin, UID and profiler proofs (2026-10-04; superseded for speech by the run below).**
  The genuine stock-SSIP UID component is **green and narrow**: exit 0 in 19.03 s, report
  `/tmp/nogui-w21-native-uid-wt3c2jw9/report.json` — 87,144 bytes, SHA-256 `21e950ed…`, mode 0600,
  link count 1, own mode-0700 root — with zero failures, two owned children reaped and no
  in-session process left. It read a real SPEAK **UID 1** and the inner `send_command` **UID 2**,
  with the stock code unchanged, one connection epoch and the outer CHAR answering `None`, while
  **every row is `ORPHAN`**. That component alone is not a speech proof, and it is superseded for
  speech by the real-stack run below; it is kept as history and is not credited with the speech
  that came later.
  The earlier attempts stay historical reds and are not rewritten: the passive
  genuine-components proof `/tmp/nogui-w21-reader-origin-component-proof.py` exited 1 with
  c1 and c2 passivity passing but all four harness children ended by `SIGTERM` rather than
  natural reap, and c3 profile precedence, c4 thread behaviour and the footer unproven; the
  genuine-UID smoke `/tmp/nogui-w21-native-uid-smoke.py` under root
  `/tmp/nogui-w21-native-uid-rwohalnm` exited 1 with readiness unproven — 40 seconds of log
  showing only the starting state — so the client UID and module identity are unknown and it
  is **not** a UID extraction proof. A later run's sole failure was a malformed two-field
  readiness `CLIENT_NAME`, since repaired to the stock three-field form. No new native
  approval was spent and no UID-attributed speech is credited. The profiler aggregate is red
  and **no profiler pass is claimed**: one proof failed six aggregate clauses because
  CPython 3.14 installs monitoring tool 2 for `cProfile` — 24,607 events — so
  `sys.getprofile` reads `None`, which the old source helper's hook-only guard misses, with
  two corrective units active; that proof's other results stand, all four children exiting
  naturally 0 and all 11 native thread-identity birth checks passing, with no UI, daemon or
  native UID in it. The legacy consumer's kernel-side located-PCM integration run then
  exercised **10 of 10** cases with 0 failures and 17 unexercised in 564.45 s, integration-only
  (`/tmp/nogui-w21-located-pcm-proof-2026-10-04T21-25-54-565Z-1451831.json`, journal
  `/tmp/nogui-w21-located-pcm-proof-journal-aUZ0gJ/cases.jsonl`): AFTER-unlink, AFTER-directory
  and a third AFTER-truncate all passed with `unknown`, `spoken=false` and null across all ten
  metrics, and the first eligible legacy row 6/1 read its real before flags, reference 55618B,
  13 chunks and the unique `[118112,173730]` window over a 4,256,050-byte whole. **The
  historical 19/7 subject is still absent and was not retargeted**, and the 11 helper cases are
  excluded because the mode is integration-only, so this is **not** a full 27-pass. UID
  provenance remains LEGACY_ORDINAL and unsafe, so the native causal UID is unknown and the old
  root is not credited. The 64 KB pipe hypothesis is left **unproven** by the measured 301,024
  ms `bound_subject_forward_pass` against 32,780 / 30,981 / 43,138 / 64,307 ms for the later
  steps; the bounded-IO item is closed and no approved evidence changed.
-
- **First-phase native `Action` describe and `TextSelection`: source-complete, native-unexercised
  (2026-10-04).** In `/tmp/nogui-w21-approved-client.py`, `read_actions`, `describe`,
  `read_platform_text`, `read_platform_selection` and `Steps.run` are complete for both steps.
  The **native unknown and refusal branches have never run**: the retained real act
  `/tmp/nogui-w21-approved-2026-10-04T14-09-07-151Z/evidence/client-act.json` answered everything
  and recorded no query refusal. Both are **blocked** on a fresh approved private AT-SPI fault
  provider or query refusal — not on a refused mock echo, not on a source assertion, and not on
  rerunning the unchanged boundary proof, whose retained
  `/tmp/nogui-w21-native-boundary-resumed-EN3QjV/boundaries.json` proves only the later gate
  continuation and `KeyboardInterrupt` propagation and is **explicitly not native `Text` or
  `Selection`**. Native full acceptance stays
  **18/22**.

- **A full real native stack now produces genuine speech.** Three real-stack runs are on record,
  all on a real Xvfb `:90`, a real session bus, real dconf with `screen_reader_enabled` read back
  true, the real AT-SPI bus and registryd with `ScreenReaderEnabled=true`, a real
  speech-dispatcher with the espeak-ng module and module observer all owned and pinned, real
  Orca 50.2 attached and alive, a real focused window, a real XTEST keyboard, a real AT-SPI
  client, and a real PCM monitor capture on the LIBAO NULL no-hardware backend. `bg355` and
  `bg357` exited 1 with no synthesis, the second after the owner-gate repair below; `bg367` ran
  after that repair **and** the reader-hook restructure and is the one that speaks — **0
  tracebacks, a 372-row reader trace, `spoken_utterances=9`, `synthesized=true`**, the evidence
  gate `ok`, PCM genuinely read and clock-paced. Attribution: **50 native utterances, every one
  lineage `owned`, on the real reader thread**; **35 carrying message ids**; **37 distinct
  `frag_seq`, each with its own ACSS**; **100 `reader_text` rows beside 100 `ssip_argument`
  rows**; **waveform identity proved for 9** by exact-once PCM location with **41 unproved and
  explicitly not credited**; wire paired **35/35, zero unpaired, zero disagreements**.
  **PASS:** `screen_reader_attached`; `published_roles`; the radio group relation and its check
  marks; the progress value equal to the model value; native actions reaching the model; a
  whole-value multilingual write through the real interface; every keyboard path; both settings
  landing; the terminal owned and registered; and the operator's own accessibility setting
  untouched. **FAIL, recorded as unclaimed rather than pending:** progress announced with real
  audio; progress name through navigation; reader navigation leaving the application untouched,
  with **0 chords delivered** in that run; and six roles spoken with real audio at **4/6**, the
  button role mismatched and progress unannounced.
- **Reader attached and roles published is not reader announced.** That distinction is the
  load-bearing one here. The nine utterances are observed with real audio and are claimed;
  everything beyond them is not — not the 41 unproved waveforms, not progress, not the two missing
  roles.
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
  `None` target** — its guard was gated on `_pending`, letting unbound frames dispatch `None`
  once binding had completed, and the error path itself dereferenced `None`, killing Orca 50.2 at
  startup before any presentation. Restructured so a still-`None` target always returns, verified
  by zero tracebacks, the 372-row trace and 9 spoken utterances. Both reader proofs stayed green
  through every hook revision.
- **Reader proofs green against the current helper:** compatibility **111/111**, verdict `proven`,
  0 failures; failure proof **226/226**, verdict `proven`, 0 failures. The helper is
  `nogui_reader_origin.py`, **SHA-256**
  `4ecc9fcf5dfa704c97cfb758b7dad16a8ac0dcf36118f7aa48491bb0953ea271`, measured by the parent with
  `sha256sum /tmp/nogui-w21-reader-origin/nogui_reader_origin.py` and reproducible with that exact
  command. Two earlier digests are prior states only: `b8d38931…` and `1d0605a4…`. Two limits
  stand on the failure proof: the source `MAX` bounds remain **unexercised**, with the real
  `RLIMIT` 32768 exercising only the common failure path, and the induced `direct_hook` bind
  `BaseException` is labelled not a natural nested monitor.
- **Gates.** The full Python `unittest` suite passes **175 tests** with Ruff clean. Zig lint reports
  **0 errors and 0 warnings across 258 files**; Debug check **89/89**; ReleaseSafe check green in
  133 s with **1959/1959** tests passed. The ReleaseSafe leg became green after a concrete fix
  rather than a lucky rerun: `w23_windows_smoke.zig` shadowed its top-level `refusal()` function
  with a local `refusal` bool, and renaming that local to `duplicate_refused` removed the only
  compile failure. Formatting clean after touching one file. Fixture **5,524** passed, 0 failed,
  0 unsupported; layout golden **581 rows**; build **25/25** steps; vendored noapi **3/3** steps
  with **66/66** tests. All six external dependency consumers pass, the last with its CPU arm at
  32 checks — consumer and packaging evidence, not native OS evidence.
- **Portable scopes unchanged.** W21 headless **42/42** — typed positioned composition, live
  sequential selection, an 8192-byte storage refusal, ring whole-value 4096×2 plus overflow, the
  exact published state — core and headless evidence. The device-free private W19 kernel proof
  **28 of 28**, 0 skips, descriptors 16 → 16, every private owned child gone, **no native
  credit**; `NOGUI_W19_CONTROLLER_MAIN=1` refuses with exit 2 before any import. Cached-GI
  off-bus proved **6 of 8** claim slots and stops there, overall `not_established`; the AT-SPI
  type-library version reads as **2.0** through the library's own `get_version`, no ctypes bypass.
- **W19 unknowns.** Controller source unchanged at `A71E`, every item fixed in source, but the
  **native 11 fields and 2 kernel branches remain unknown** — source-fixed is not observed — and
  no UI approval was used. **GCR 3 preparation is done and is preparation only:** source-ready
  against real providers on a private `:90` X11 display with a fresh root, but **no child
  service, GUI, keyring or prompt was started, nothing was observed, and no native approval was
  used**. `Unlock` stays blocked on fresh consent.
- **Lifecycle closure proof green:** exit 0, no missing claims, `unexpected_programs` empty, no
  re-signal, zero live owned groups, every owned pid gone. Earlier failed lifecycle and observer
  attempts are prior states, not results.
- **Metadata C green:** 9 cases, **115 PASS / 0 FAILED / 1 UNEXERCISED**, the single unexercised
  case being the named mid-call symlink swap needing an in-window adversary; both independent birth
  references agree exactly and exactly one field is plausible; the `EMFILE` is real and
  kernel-level. Metadata fragment **7,246 bytes**. Root
  `/tmp/nogui-native-metadata-kernel-final-failed-92c0d0c5-1d4c-4f1e-9b6a-63e3f4d3e0ba` — *the
  directory name predates the repair round; the run it holds is the green one.*
- **Peer-credential mechanism:** a `SO_PEERCRED` socketpair reports PID 2469773, UID 1000, GID
  100, each matching that process's own `getpid`/`getuid`/`getgid`; the socket is unconnected and
  closed with no peer; descriptors balanced at 8 → 8. A mechanism result, not presentation or
  audio.
- **Cocoa and Windows source-typed, no native claim.** Six real `C struct` `@property(copy)`
  errors reproduced against the real `nogui_macos.h` and corrected at source; portable GNUstep
  ARC syntax passes. **Full AppKit SDK, the shim and native Cocoa remain unexercised.** Windows
  source type-checked, cross-compilation reached link, native ReleaseSafe green; an actual
  Windows or Cocoa menu run still needs that runtime.
- **The tracker is closed:** 838 items, 751 done and 87 explicitly blocked with a named
  prerequisite, zero open.
- **Repository-wide gate re-verification (2026-10-05):** every house gate leg was re-run on
  the landed tree and recorded, not restated. `zig fmt --check src build.zig build.zig.zon`
  exits 0, as does the same check over the 22 first-party example sources and over
  `src/v7_host/credentials.zig`; a bare `examples/` walk additionally lists 11 files, all
  generated `zig-pkg` dependency copies the gate does not cover. `zig build test` exits 0 at
  `63/63 steps succeeded; 1966/1966 tests passed`, `zig build check` exits 0, `zig build
  layout-check` exits 0 matching all 581 golden rows, and `zig build test check
  -Doptimize=ReleaseSafe` exits 0 at `106/106 steps succeeded; 1966/1966 tests passed`. `zig
  build fixture` exits 0 with `{"passed":5524,"failed":0,"unsupported":0}` over 5/5 steps,
  the vendored noapi leg exits 0 at 3/3 steps and 66/66 tests, and `python3 -m unittest
  discover -s tools -p 'test_*.py'` exits 0 with 175 tests OK — 116 in `test_run_v7_perf.py`,
  10 in `test_import_taffy_v013_fixtures.py` and 49 in `test_speech_module_observer.py`.
  `zig build lint` was the single red leg on the first pass: `zlint -S --deny-warnings`
  reported one `unsafe-undefined` warning at `src/v7_demo/w23_windows_smoke.zig:4580`, where
  `var second: windows.Menus.Subclass = undefined;` carried no `SAFETY:` line. The parent
  added that comment and the step now exits 0 at 0 errors and 0 warnings across 258 files,
  with `ziglint` 0/0 throughout; the repair is a comment and changes no behaviour, so the
  `0 errors and 0 warnings across 258 files` bullet above stands again and its dated
  1959/1959 figure remains that run's own. One artifact is recorded rather than hidden:
  five `failed command: .../test --listen=-` lines appear on stderr in each `zig build test`
  invocation, five in Debug and five in ReleaseSafe, each preceded by a `+- run test w` tree
  and carrying no test count. Both builds exit 0 and report every step and test as passed,
  and one such binary run outside the build system without `--listen=-` printed `All 1118
  tests passed` and exited 0, so those lines are a runner reporting artifact rather than a
  failing suite. **No native or approval-gated scope was touched here and no native
  approval is inferred.** The W20 slice's 25 of 25 provider-free checks were not re-run,
  and the full `fixture --execute` flow stays approval-gated.

- **Earlier owned native run (2026-10-04T11:16; dated and superseded):** the main
  native client had no failures and **17/21** required criteria held, and the
  named-policy consumer's client still failed four Action-absence checks on
  unreadable `queryAction` exceptions while wrongly expecting two clicks. The
  audio proof then refused credit because 183 raw/index fields disagreed: the
  consumer read the closing `700 INDEX MARK` line as part of a mark name. The
  stock reader's log contained the genuine Left-key completion marker and one
  `W21 Progress` presentation, but the live wait never observed that marker.
  Original failed evidence is preserved at
  `/tmp/nogui-w21-approved-2026-10-04T11-16-02-453Z/evidence/result.json`.
  This run closes neither native audio nor named-policy acceptance, and neither
  does the later one.

Companion: [dependency-ordered implementation plan](2026-09-26-gpui-api-parity.md).

## Scope and provenance

- **N:** `~/projects/nogui`, canonical `src/v7/`, renderer `src/v7_render/`, and supporting `src/v7_demo/`. Working-copy commit at audit start: `55841746fd103d62265c8db2475a8f7387e76294`. Existing working changes were included in the reading, not discarded.
- **G:** `~/projects/github-zed-industries-zed/crates/gpui`, package version **0.2.2**, checkout HEAD `ac44e9f5df57a9e1a9d6deacddead974edabc8e7`. This identifies the checkout; it does not assert a clean working tree.
- Compare GPUI **capabilities**, not Rust spelling, every overload, Zed's `ui` crate, or Zed's editor. GPUI combines immediate rendering with retained application state. A literal retained-widget rewrite is not the target.
- Public coverage starts at [G `gpui.rs`](../../../../github-zed-industries-zed/crates/gpui/src/gpui.rs), lines 10–160 and 164–346, and [N `root.zig`](../../../src/v7/root.zig). Feature-gated, platform-specific, and example-only APIs are distinguished below.
- **Missing:** no corresponding reusable contract found. **Partial:** a narrower contract exists. **Demo-only:** implementation exists outside the reusable library. **Conditional:** capability depends on a native platform or is incomplete upstream. These labels describe current source, not an executed defect.
- Negative searches covered canonical exports and the plausible implementation paths listed for each family. Demo services were checked separately. A missing export alone was not taken as proof of a missing implementation.
- Source ranges are navigation evidence from this snapshot, not immutable line identifiers. `N` and `G` prefixes in tables use the roots above. Each gap has one primary work package; dependencies and cross-cutting work are in the plan.

W01 extracted reusable CPU text and SDL host modules. Its core-only external consumer, selected-product builds, tests, layout checks, pixel comparisons, and native-window smoke passed. The companion plan records the evidence. No capability gap is closed until its owning package passes acceptance.

### Verified implementation evidence — W02 (2026-09-27)

| Gap | Current W02 result | Source and exercised evidence |
| --- | --- | --- |
| C08 | Frame tree, input, state, scroll limits, keyed mounts, and JSON publish only after the build succeeds. A failed GPU frame cancels its noapi recording before staged resource cleanup; submitted work is waited on before unmount. Persistent models and tasks do not exist yet and retain their W03/W05 ownership gates. | [App transaction](../../../src/v7/app.zig), [mount staging](../../../src/v7/drawctx.zig), [GPU frame contract](../../../src/v7/runtime.zig), [noapi surface abort](../../../vendor/noapi/noapi/Surface.zig). `api-w02` tests cover caught/propagated GPU init failure, layout/JSON rollback, external scroll rollback, old snapshots, and remount. Native `--gpu-remount-smoke` completed. |
| I05 | Interactive controls have exact parent-component-scoped keys and generational `WidgetId`; `FrameNodeId` remains dense. Insertion, reorder, removal, remount, duplicate keys, and stale clicks cannot silently retarget focus or capture. Future overlays/semantics/animations must consume the same handles in their own packages. | [Identity registry](../../../src/v7/identity.zig), [tree lookup](../../../src/v7/widget.zig), [App event routing](../../../src/v7/app.zig), [Todo keys](../../../src/v7_demo/ui.zig), [Spotify keys](../../../src/v7_demo/spotify_content.zig). The baseline same-kind insertion focus transfer was reproduced by a failing test before the fix; `zig build v7 -- --keyed-reorder-smoke` now prints `keyed-reorder-smoke: OK`. |
| L04 | Stored border boxes and 16-byte clips remain unchanged while layout/input use logical window units and renderer/host convert device pixels at their boundary. Text, SVG quads, strokes, and rounded-rect AA use the per-axis device footprint. | [Coordinate values](../../../src/v7/geometry.zig), [host translation](../../../src/v7_host/window.zig), [renderer](../../../src/v7_render/render_9slice.zig), [shader](../../../shaders/quad_frag.slang). `api-w02` exercises nested border/padding/scroll at 1×, 1.25×, 2×; the 1× 581-row layout golden is unchanged. Native Todo/Spotify/tiger/strokes 1× shots were inspected; non-1× GPU pixels were not captured. |

W02 gate: `zig build test -Dtest-filter=api-w02` passed 36/36 tests; the full test suite passed 1,143/1,143, all 5,524 layout fixtures passed, and `layout-check` matched 581 rows. `zig build lint` passed with zero warnings. Standalone noapi tests passed 61/61. The original gap rows below remain source-backed baseline observations; this dated section records only verified W02 changes.

### Verified implementation evidence — W03 (2026-09-27)

| Gap | Current W03 result | Source and exercised evidence |
| --- | --- | --- |
| C01 | Session owns typed values with strong, weak, erased and reservation handles. Store/type/generation/ticket checks, scoped read/update, borrow conflicts and last-owner destruction are exercised. Release observation remains W04. | [Session store](../../../src/v7/session.zig), [handle types](../../../src/v7/model.zig), [ownership regressions](../../../src/v7/w03_contract_test.zig). Tests cover wrong store/type, stale and duplicate owners, uninitialized reservations, weak upgrade after release, reservation-source aliasing, and destructor reentry. |
| C02 | An App binds its root once, supports explicit replacement, and dispatches host event/frame/precision hooks against the current root. A model-backed root borrows its model during typed view draw; two Apps can render one model with separate views and GPU mounts. Typed event subscriptions remain W04. | [App root swaps and host hooks](../../../src/v7/app.zig), [component adapter](../../../src/v7/component.zig), [scoped draw context](../../../src/v7/context.zig), [host migration](../../../src/v7_demo/window.zig). Tests cover two-view updates, callback-triggered replacement, missing-root errors, mounted-child GPU alias rejection, and old/candidate borrow conflicts. |
| C03 | Arena state remains shallow-copy transient state; persistent resources belong in Session or an explicit caller-owned view. A component absent from a committed frame resets its local state on remount. | [transient state contract](../../../src/v7/state.zig), [public lifetime guide](../../../README.md), [state and unmount tests](../../../src/v7/root.zig). Session shutdown rejects live Apps or owners. |

W03 gate: filtered `api-w03`, full Zig tests, 5,524 normalized fixtures, 581-row layout golden, format and both linters passed. Native three-frame Spotify, Todo keyed-reorder and Todo GPU-remount scenarios passed. The original rows below remain snapshot evidence; W04 still owns release listeners, typed subscriptions, globals and deferred notifications.

### Verified implementation evidence — W04 (2026-09-29; source recheck 2026-09-30)

| Gap | Current result | Source and exercised evidence |
| --- | --- | --- |
| C04 | `Session.observe`, `observeRelease`, and `subscribe` bind weak owners and return Session-local cancellation tokens. Owned event payloads queue FIFO; self-unsubscribe, owner release, and registration during delivery cannot retarget the active event. | [subscriptions](../../../src/v7/subscription.zig), [owned FIFO effects](../../../src/v7/effects.zig), [Session delivery](../../../src/v7/session.zig), [two-App observer scenario](../../../src/v7/app.zig). The recorded `api-w04` gate passed 22/22 on 2026-09-29; the two-App scenario rejects a frame started inside an observer, then delivers a deferred second update after unsubscribe. |
| C05 | Typed globals live in the Session, with scoped reads/updates and committed window-read dependencies. Model/global changes coalesce redraw demand per dependent window, not distinct events; failed frames keep the prior dependency set. | [global store](../../../src/v7/globals.zig), [frame dependency publication](../../../src/v7/session.zig), [public contract](../../../README.md). The same recorded `api-w04` gate covers rejected borrows, global updates and failed-frame dependency rollback. |

The source recheck does not claim a fresh filtered run. The 2026-09-29 full
suite and W04 gate are recorded in the plan; later renderer/host changes need
the final integration gate. Baseline rows below remain the original findings.

### Verified implementation evidence — W05 (2026-09-30)

| Gap | Current result | Source and exercised evidence |
| --- | --- | --- |
| C06 | The Session task service owns worker scheduling, weak-owner completion, per-window delivery and wake registration. A completion racing a wait cannot be lost; cancellation and bounded shutdown keep stale owners from receiving updates. | [task service](../../../src/v7/task.zig), [Session task bridge](../../../src/v7/session.zig), [external worker/idle/close consumer](../../../examples/consumers/host/main.zig). The recorded `api-w05` gate passed 27/27; on 2026-09-30 the live dummy host exited 0 with `idle_frames=1 worker_frames=2 wakes=1` after a worker changed the model. The host unregisters its wake callback before Session task shutdown. |
| C07 | Frame demand tracks invalidation and deadlines; idle windows do not render, while explicit continuous work can advance. | [frame demand](../../../src/v7/frame_demand.zig), [host stepping](../../../src/v7_host/application.zig). The same live host ran twenty 5 ms idle steps before the worker and ten after it with no extra frame or deadline. The recorded `api-w05` cases cover injected deadlines, hidden windows, retry, and continuous mode. |

The live worker/idle/shutdown scenario fills the half of the W05 gate marked
unrun in the 2026-09-29 plan entry. Other packages' gates remain separate.

### Verified implementation evidence — W06 (2026-09-30)

| Gap | Current result | Source and exercised evidence |
| --- | --- | --- |
| D01 | The test context runs production Session/App dispatch with a virtual clock, bounded idle flush, stable-key queries and stale-frame refusal. Direct `Event` and JSON dispatch share the parser contract. | [test context](../../../src/v7_test/context.zig), [dispatcher](../../../src/v7_test/dispatcher.zig), [parity/selection test](../../../src/v7_test/w06_contract_test.zig), [Todo JSON-lines script](../../../testdata/sim/todo-increment.jsonl). The recorded `api-w06` gate passed 11/11; `zig build v7 -- --sim testdata/sim/todo-increment.jsonl` exited 0 on 2026-09-30. Parsed frames 1/2/3 had focus 0/46/46 and counter 0/0/1, with the two todos unchanged. |

### Source and native gate recheck — W07 (2026-09-30; acceptance open)

| Gap | Current result | Evidence and remaining boundary |
| --- | --- | --- |
| P01 | Reusable owned and externally driven host lifecycle, launch/reopen/quit hooks and distinct last-window policy exist. | [Application](../../../src/v7_host/application.zig), [W07 contracts](../../../src/v7_host/w07_contract_test.zig), [external-loop smoke](../../../src/v7_demo/w07_host_smoke.zig). Current `api-w07` passed 44/44. Owned X11 and Wayland two-window runs exited 0; the current X11 run drove nine external-loop steps, never called `Application.run`, and released Session/GPU after all windows. |
| P02 | Generational multiwindow handles, separate App views/GPU mounts, transactional open, close veto and slot reuse are implemented. | The X11 NVIDIA/lavapipe dual runs each showed revision 2 in both views and refused a completion aimed at a retired window while the peer received one. A current NVIDIA X11 dual run reopened host slot 0 at generation 2 and rejected generation 1. |
| P03 | Display snapshots/IDs, work/full bounds, scale events and logical/device transforms are public; unavailable Wayland global position remains conditional. | The current private Niri run drove real output scale 1→1.25: logical 900×620 held, pixels became 1125×775, actual pointer motion hit the committed probe on both sides, candidate/App generation matched and presentation had zero extent mismatches. Candidate-area publication is not a visible IME-window claim. |
| P04 | Requested and observed window states, move/resize/focus/minimize/maximize/decorations and capability reporting are public. | Current owned Openbox/X11 observed minimize=true/visible=false, then restore=false/visible=true within deadline. Left-only 900×620 resize held the peer at 520×380. Wayland minimize remains explicitly unobservable rather than fabricated. |

The earlier 2026-09-29 diagnosis called both X11 Vulkan faults external-only
and said this smoke had no one-window flag. Both assertions are superseded:
`--windows 1` was already supported, and the smoke had an in-repo teardown
ordering violation (swapchain/`VkSurfaceKHR` released after SDL window) fixed
through `on_before_close`. After that fix, both NVIDIA and lavapipe X11
single/dual runs exited 0 with `released_before_window=slots`. A lavapipe
X11 dual `--present-frames 1` probe committed an extra frame without present
(`committed=2 presented=1 without_present=1`) and exited 0. These results
do not prove what caused the older faults. The W07 package and all four gap
rows remain gated on the live display/DPI and minimize criteria in the plan.

### Verified implementation evidence — W08 (2026-09-30)

| Gap | Current result | Source and exercised evidence |
| --- | --- | --- |
| L01 | Custom leaves and bounded late subroots share the normal layout/prepaint/paint/semantic transaction. | [element contract](../../../src/v7/element.zig), [ruler consumer](../../../src/v7_demo/ui.zig). Twenty named W08 cases passed in the current filter. The windowless noapi ruler shot exited 0 and its line/ticks were inspected. No GPU handle enters the core descriptor. |
| L02 | Intrinsic measurement accepts known dimensions and available-space modes; revision changes invalidate cached measurement. | [layout context](../../../src/v7/layout/context.zig), [custom element tests](../../../src/v7/w08_contract_test.zig). The ruler supplies intrinsic 240×18 without text measurement; parent stretch determines its final width. Min/max/definite and revision behavior are exercised by the W08 cases. |
| L03 | Hidden subtrees keep layout but suppress paint, hit, focus and semantics; display-none removes layout contribution. | W08 hidden/display-none cases passed; 5,524 fixtures and the unchanged 581-row golden passed. |

Command: `env -u DISPLAY -u WAYLAND_DISPLAY ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test fixture layout-check -Dtest-filter=api-w08 -j4 --summary all`: 56/56 steps, 27/27 tests including seven anonymous module tests. Ruler command: `env -u DISPLAY -u WAYLAND_DISPLAY zig build v7 -- --ruler-smoke --shot /tmp/nogui-w08-ruler.ppm`, exit 0, 954×1044 inspected pixels. The older audit-wide tables below retain their dated baseline; this section supersedes their W08 open status.

### Integration close-up — W11 (2026-09-30; acceptance open)

The core now registers the component tests and resolves `default_text` through
root and nested draw scopes. Five failing-before/passing-after regressions cover
the two scope cases and three fieldwise font-default cases. The focused core
commands passed 4/4 and 10/10 including module tests; the external core consumer
exited 0 with `core_only: OK`. See the [W11 plan evidence](2026-09-26-gpui-api-parity.md#w11--shared-typography-and-shaped-text-layout).

The full current core gate failed: 1,066/1,071 tests passed, with five failures
in two W21 visible-row bounds cases, flex and grid baseline alignment, and
the pinned fixture corpus. Their causes were not investigated or classified
as pre-existing before the halt. Formatting passed for the five immediate
core/host files. The filtered host W19 command also exited 0 with the
AccessKit bridge disabled; no live notification or credential provider ran.

The ordinary mixed-script caption in the external offscreen consumer still
fails with `InvalidWrapWidth` after NVIDIA GPU initialization. Its rendered
specimen gate remains open. The temporary diagnostic was removed. Both
read-only integration reviewers stopped; their source risks are deferred,
not verified fixes. The user requested a temporary halt; no further work is
authorized until a direct resume instruction. Historical gate counts below
remain dated evidence, not a current full-parity result.

### Verified implementation evidence — audit-wide gate run (2026-09-29)

One full gate pass on the Linux host at `~/projects/nogui`, with `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache`, after the four defect fixes recorded at the end of this section.

| Gate | Command | Result |
| --- | --- | --- |
| Full Zig suite | `zig build test -j6 --test-timeout 15m` | 34/34 steps, 1,413/1,413 tests, 0 leaks. |
| Full Zig suite, host bridge unlinked | `zig build test` with `-Daccesskit-bridge=false` | 1,413/1,413 tests. |
| Static check | `zig build check` | exit 0. |
| Layout fixtures | `zig build fixture` | 5,524 passed, 0 failed, 0 unsupported. |
| Layout golden | `zig build layout-check` | OK, 581 rows match golden. |
| Lint | `zig build lint` | 0 errors, 0 warnings across 190 files. |
| Format | `zig fmt --check src build.zig build.zig.zon` | clean. |
| Tool tests | `python3 -m unittest discover -s tools -p 'test_*.py'` | 125 tests, OK. |

Per-package gate, `zig build test -Dtest-filter=api-wNN`. Every filter exited 0 with zero failures; 603 tests in total.

| Package | Tests | Package | Tests | Package | Tests |
| --- | ---: | --- | ---: | --- | ---: |
| W04 | 22 | W12 | 32 | W20 | 39 |
| W05 | 27 | W13 | 22 | W21 | 36 |
| W06 | 11 | W14 | 48 | W22 | 39 |
| W07 | 18 | W15 | 33 | W23 | 7 |
| W08 | 26 | W16 | 20 | W24 | 35 |
| W09 | 30 | W17 | 18 | W25 | 7 |
| W10 | 40 | W18 | 32 | W26 | 7 |
| W11 | 25 | W19 | 29 | **Total** | **603** |

#### Gap-row status after this run

W01 owns no gap row. The other 25 packages own 66 rows, and this run moves none of them past the state the plan gate requires.

| Family | Rows | Verified | Open | Owning-package filters now green |
| --- | ---: | ---: | ---: | --- |
| C | 8 | 4 (C01, C02, C03, C08) | 4 | W04 22, W05 27 |
| L | 10 | 1 (L04) | 9 | W08 26, W15 33, W16 20, W17 18 |
| I | 10 | 1 (I05) | 9 | W09 30, W10 40, W16 20 |
| T | 8 | 0 | 8 | W11 25, W12 32 |
| R | 8 | 0 | 8 | W13 22, W14 48 |
| P | 15 | 0 | 15 | W07 18, W10 40, W18 32, W19 29, W20 39, W22 39, W23 7 |
| A | 2 | 0 | 2 | W21 36 |
| D | 5 | 0 | 5 | W06 11, W24 35, W25 7, W26 7 |
| **Total** | **66** | **6** | **60** | 603 |

The six verified rows are the ones carried by the dated W02 and W03 sections above. Every W04–W26 row gained a green automated filter and nothing else: a passing filter proves the owning package's automated suite is green, not that the capability the row asks for exists and behaves correctly on a real display, under a real input stack, or on a second operating system.

#### What these passing filters do not prove

Each companion-plan gate has two halves, a `zig build test -Dtest-filter=api-wNN` half and a run-against-a-real-stack half. For W04–W26 the filter run delivered the first half for all 23 packages and the second half for none. The later native session runs delivered part of the second half for W07, W21, W22 and W24 and closed no row. The 60 open rows break down as follows.

| Package | Open rows | Evidence the gate still requires |
| --- | --- | --- |
| W04 | C04, C05 | A two-view counter run: an observer that removes itself during delivery, plus a deferred model update, with no callback seeing a partially built frame. |
| W05 | C06, C07 | A live worker-loaded view, frame counts across a measured idle interval and after one completion, a completion racing sleep waking the host, and shutdown. Hidden windows must be shown not to spin. |
| W06 | D01 | An actual JSON replay through `zig build v7 -- --sim <script>`, compared on parsed state rather than on harness mocks. |
| W07 | P01, P02, P03, P04 | The Wayland half ran: two real windows on one `Session` model, a compositor screenshot, an honoured resize, a close veto and a clean `Session.deinit()`, and it now also completes under the Mesa lavapipe ICD as well as the default NVIDIA ICD. The X11 half was attempted and is blocked on this host, not missing: `zig build w07-host-smoke` under `SDL_VIDEODRIVER=x11` aborts on the default NVIDIA ICD after an `NVRM: Xid ... 31` fault, and under lavapipe it writes a tiled clear past the end of the shared-memory window image inside Mesa. Each of the host's two available Vulkan paths fails for a diagnosed reason that sits outside this repository, so no X11 two-window run of this gate is possible on this machine. Still missing regardless: minimize, DPI and display change, and external-loop embedding. |
| W08 | L01, L02, L03 | A live custom ruler/canvas consumer with non-text intrinsic dimensions. The corpus and golden passed; the live consumer did not run. |
| W09 | I01, I02, I06, I07, I10 | The actual Todo controls under press, move, release and cancel; key-up reaching the consumer; a slider dragged out and back. |
| W10 | I03, I04, P09 | A live alternate keyboard-layout and cursor run, plus a configurable Todo shortcut replay. |
| W11 | T01, T02, T03, T04, T06 | Pinned-font real-font measurement and an offscreen or live text specimen, including RTL mixed text and combining/ZWJ boundary mapping. |
| W12 | T05, T07, T08 | Actual Linux IME composition, preedit commit and cancel, candidate-window placement over a wrapped and scrolled caret, clipboard, and focus switching. |
| W13 | R01, R02, R03, R04 | Real noapi offscreen pixel comparisons at fixed backend, fonts and antialiasing tolerance, plus a visible paint specimen. |
| W14 | R05, R06, R07, R08 | An actual image, SVG and animated-frame host specimen served from local fixture bytes. |
| W15 | L05, L06, L07, L10 | Live large uniform and mixed-height lists, resized and mutated while scrolled, with built-item count and allocation volume recorded as a function of viewport. |
| W16 | L08, I08, I09 | A real popup, drag and tooltip specimen, including keyboard focus return and drag cancellation outside the window. |
| W17 | L09 | A live animation run followed by an idle host, then reduced-motion mode with no decorative frame loop. |
| W18 | P05, P06, P07, P08, P10 | X11 and Wayland clipboard, primary selection, dialog, menu and URL smoke, including portal cancellation and provider-unavailable outcomes rather than only success. |
| W19 | P11, P12 | Approved native notification and secret-store runs using unique synthetic names, including denial, locked-store and disconnect paths. A user's existing credentials are never inspected. |
| W20 | P13 | An interactive portal permission approval and a live Wayland preview, with the applicable X11 path exercised separately. **2026-10-04:** the single approved capture ran. `CreateSession` and `SelectSources` really went out with `types=1`, `multiple=false`, `cursor_mode=2`, `persist_mode=0`; the private viewer handshake was verified by pid, XID and a 108-byte mode-0600 uid-1000 `nlink`-1 acknowledgement carrying the run's own nonce; and the consumer ended `begin: state=denied failure=rejected returned=CaptureDenied` with exit 3, so **no validated stream and no production PPM**. All 23 owned groups retired with zero survivors; the six `invalid_pidfd_reply` refusals are now **classified in source rather than unexplained** — the old caller allowed 2000 ms and sent its own `SIGTERM` before the helper's own 5000 ms budget, all six helper stdouts were empty and carried `SIGTERM`, and the collector now declares a 20 s startup contract of 5 + 2 — so they are source-repaired and classified but still not live-witnessed. Still open: the chooser witness (the harness parser rejected the real `{Default Queue} ->` trace form, the fix is a replayed trace only and no fresh live witness has run), the live preview, stop/owner-loss and native resource retirement. |
| W21 | A01, A02 | The AT-SPI half ran: a real registry, a real bridge, a real tree read before any interaction and five real interface round-trips that reached the model. The window bell and the window teardown ran as well, natively, from the window each run actually opened: X11 `available=true request=rung` with the adapter `inactive` and `screen_reader=false`, an owned nested compositor advertising no `xdg_system_bell_v1` answering `available=false request=unsupported`, the real 520x640 frame read back and inspected on both, and a compositor-initiated close taking the mid-hold retirement branch. The 2026-10-04 private renewals really ran the reader on an owned private bus and retired with zero survivors, most recently `/tmp/nogui-w21-approved-2026-10-04T14-09-07-151Z`, whose dated predecessor is the 04-54 run. The latest one moved further than the earlier attempt: all three whole/empty/restore `SetTextContents` writes held with the platform reading each whole value back at 21/0/7 characters, `getNSelections` 0 and exactly one model write each; Space and Return activation, slider keys, radio movement, printable text and caret movement each moved a real published counter; the reader's own stock object navigator reached the read-only indicator and presented `[progress bar: 'W21 Progress']`; and real synthesis with a clock-paced capture is independently proved. Still missing: an Orca announcement credited with real audio for any of the six roles, still 0/6 because no fragment of the reader's own output was proved in the capture; the progress value and the progress name through stock object navigation, which the reader's own CRLF log cannot settle because its grab agreement does not parse out of it; text composition through the unimplemented partial `EditableText` methods; list row selection through the List interface; any positive Wayland bell proof; and any macOS or Windows bell runtime. That renewal also retires the recorded `accesskit_unix 0.21` prerequisite and the recorded reason the SDK had no `EditableText`: the pins are now `accesskit 0.25.0`, `accesskit_unix 0.23.0` and `accesskit_atspi_common 0.20.0`, and the pinned Unix provider does expose `SetTextContents`. See the 2026-10-04 continuation above: the custom-action ABI and the provider patch are no longer untested, because that run's named-policy client passes 23/23 with two signed named-list activations and zero clicks. |
| W22 | P14 | A real layer surface on niri now configures, acks, maps and commits, and the explicit unavailable path ran on X11. The X11 popup ran as well, on XWayland: a real popup role created through `SDL_CreatePopupWindow` with `SDL_WINDOW_POPUP_MENU`, read back from the window's own SDL properties as `x11_window_number=10485777`, the full lifecycle ending with `window_count=0` and an accepted `Session.deinit`, exit 0, while the same binary on the Wayland driver accepted `create(.os_surface)` and then failed `show` with `NativeRoleUnavailable` and `error.PopupRoleNotObtainable`, exit 1. Still missing: a compositor-delivered `closed` event, the exclusive zone's reserved extent, an obtained grab rather than a `PopupGrabUnsupported` refusal, and the layer-shell refusal path on a real Wayland compositor that omits the global. |
| W23 | P15 | macOS, Windows and mobile adapters. Not runnable on this host at all; see below. |
| W24 | D03, D04 | Live inspector interaction ran on a real window: pick, agreement with hit testing, one activation, identity across a model update, both stale-handle forms and saturated bounded collectors. The recorder half also ran, as a paired A/B over 20 kept pairs, and it is a smoke rather than a speed claim: 20 interleaved pairs per arm, 3 leading pairs discarded at pair level, `CLOCK_MONOTONIC` wall time, arm A (offscreen, todo) median 2135.2 ms against arm B (offscreen, spotify) median 5141.1 ms, median difference +3018.7 ms, Cohen's `d_z` 6.92, two-sided sign test p 2e-6, 0 of 20 pairs with B faster, non-overlapping bootstrap 95% intervals. Load average ran 8 to 14 on 12 CPUs, `within_120_fps_budget` passed in 0 of 20 kept runs in either arm, and the presented arm could not run at all, so no speed claim is supportable and D04 stays open. |
| W25 | D02 | Real example runs and the documented headless replay and layout commands end to end. |
| W26 | D05 | Clean-cache distribution acceptance and a build of the external core-only consumer against the public API. |

Three of the 23 filters, `api-w23`, `api-w25` and `api-w26`, match no named test in
the tree. The numbers they report are anonymous `test {}` blocks. W23 has no
adapter source at all, W25 has one of its five named example scenarios, and W26
has no external consumer package. Treat those three packages as unimplemented
rather than verified.

> **Superseded 2026-10-01, kept as history.** This was true on 2026-09-29 and is no longer
> true of the tree. `src/v7_host/macos/`, `src/v7_host/windows/` and `src/v7_host/mobile/`
> now exist and are reached from `src/v7_host/root.zig`, which also pulls their test files
> into the host test artifact; `api-w23` now names 129 test blocks, `api-w25` names 8 and
> `api-w26` names 1. Adapter source existing is not adapter acceptance — see P15.

Named categories that remain uncovered, stated plainly:

- **X11 multi-window** — P01, P02, P03, P04 (W07), and the Linux halves of the W18 desktop services. The Wayland half of W07 is covered by live two-window runs on niri, under the default NVIDIA ICD and again under Mesa lavapipe, each exit 0. The X11 half was attempted and is blocked rather than unmeasured: on `DISPLAY=:0` the same binary aborts under the default NVIDIA ICD with `NVRM: Xid (PCI:0000:01:00): 31, ENGINE GRAPHICS GPC2 GPCCLIENT_PROP_0, FAULT_PRIV_VIOLATION ACCESS_TYPE_VIRT_WRITE @ 0x1_22184000`, the identical address in six runs, while the Wayland W07 run passed under the same GPU load and both `w24-inspector-smoke` and `w22-popup-smoke` passed on that same X11 stack; and under the only non-NVIDIA ICD installed, Mesa lavapipe, the process dies inside `libvulkan_lvp.so` writing a 64x64 clear at x = 576 or 704, y = 320 past the end of a 480x360 shared-memory window image. Both are faults in the host's graphics stack, not in this repository, and this machine has no non-NVIDIA ICD paired with a Mesa newer than 26.2.3, which is what a working X11 combination would need here. The W22 popup's single real X11 window therefore remains one capability on a Wayland-hosted X server, not a two-window run, not a display or DPI change, and not a clipboard. P01–P04 stay open as a blocked gate, and no nogui defect is claimed from either fault.
- **IME** — T05 and T07 (W12) plus the composition path of T08. A replay of synthesized events cannot prove candidate-window placement or native IME behavior.
- **Portal permission** — P13 (W20). Headless provider-state tests do not prove that capture works, and neither does a portal request alone. **2026-10-04:** the single approved capture really did issue `CreateSession` and `SelectSources` against the private portal and really did verify its private viewer handshake, then ended `CaptureDenied` with exit 3, no validated stream and no production PPM. So the request path is now exercised for real and the stream path is not.
- **AT-SPI and Orca** — A01 and A02 (W21). The OS-bridge half is now real, not JSON. The adapter appeared on the real AT-SPI registry at `unix:path=/run/user/1000/at-spi/bus_0`, the tree was read back from that registry before any interaction, and five real `org.a11y.atspi` interface calls — `Action.DoAction` four times and `Value.SetCurrentValue` once — reached the model, each confirmed by the model's own counters rather than by the adapter's own report. **2026-10-04:** the reader half is no longer hypothetical. Orca 50.2 ran for real on an owned private accessibility bus with `ScreenReaderEnabled=true`, submitted real speech, and the owned clock-paced capture proves `clock_paced: true`, so "Orca never speaks" is retired as a claim. The `2026-10-04T14-09-07-151Z` run moved further again: all three whole/empty/restore `EditableText.SetTextContents` writes held with the platform reading each whole value back at 21/0/7 characters, `getNSelections` 0 and exactly one model write each; Space and Return activation, slider keys, radio movement, printable text and caret movement each moved a real published counter; and the reader's own stock object navigator reached the read-only indicator from `W21 Slider` at sibling 7 and presented `[progress bar: 'W21 Progress']` while the model stayed unmoved. What still keeps this bullet open is specific: **0/6 roles credited with real audio**, because none of the reader's own output fragments was proved in the capture, and four required items are unestablished — the progress value with real audio, the progress name through stock object navigation, reader object navigation leaving the application untouched, and six-role audio. The navigation item fails on the reader's own CRLF log, whose grab agreement does not parse; the CRLF ingress fix is source-only and its replay has not run. Still unproven: text composition through the partial `EditableText` methods this provider does not implement; list row selection through the List interface; and the modal state flag. The custom-action ABI and the disabled-state provider patch are no longer untested: that run's named-policy client passes 23/23 with two signed named-list activations and zero clicks, and each blocked node's missing `Action` interface is established by enumerating that node's own interfaces. A real bridge, a real OS interface and a real screen reader are demonstrated; a screen reader *credited* with a correct announcement is not.
- **Layer-shell and popup** — P14 (W22). A real `zwlr_layer_shell_v1` surface now configures, acks, maps and commits on niri, and niri's own IPC confirms the layer, output, namespace and keyboard interactivity. A real X11 popup role now also exists, on XWayland, and the same smoke binary shows the Wayland driver refusing to show one at all, with `NativeRoleUnavailable` and exit 1. Still uncovered: a compositor-delivered `closed` event, the exclusive zone's reserved extent, and the layer-shell refusal path on a real Wayland compositor that omits the global, which no compositor on this host provides. An ordinary SDL window is still not a layer-shell surface, and the accepted dismissal in the X11 run was client-initiated rather than compositor-delivered.
- **Native notifications and credentials** — P11 and P12 (W19). The adapters now have unit coverage, but neither has been driven against a real notification daemon or secret store.
- **macOS, Windows and mobile adapters** — P15 (W23) in full, plus the target-specific portions of P01–P13, A02 and R08. These cannot run on this Linux host at all, and the `api-w23`, `api-w25` and `api-w26` filters match **zero named tests**: the counts those three filters report are anonymous `test {}` blocks that a name filter cannot exclude. No `macos/`, `windows/` or `mobile/` adapter directory exists, so there is nothing target-specific to exercise and no slice of E01–E06 has been started.

> **Superseded 2026-10-01, kept as history.** The zero-named-test and "no adapter directory
> exists" claims are 2026-09-29 facts about a tree that has since gained
> `macos/`, `windows/` and `mobile/` adapters under `src/v7_host/`, plus target shims wired
> in `build.zig`. What remains exactly as true as it was: no slice of E01–E06 has runtime
> evidence on any other operating system, and a `LinuxUnsupported` refusal is not target
> acceptance.
- **External consumer packaging** — D05 (W26), together with the D02 (W25) offscreen and example runs. A green suite inside this repository is not a consumer build from a clean cache.

The remaining gates are not capability claims, and this section does not make any: 5,524 fixtures and the 581-row golden cover the layout corpus at 1×, not shaped text at other scale factors, and `zig build lint`, the format check and the 125 Python tool tests are style and tooling gates, not GUI evidence.

#### Defects found and fixed while making the suite green

Each of these is a real finding about an audited surface, not a test-harness detail.

1. **`Application.deinit` unconditionally called `sdl3.quit`.** SDL video, events and the clipboard are process-global, so releasing the first host destroyed the second host's window and event state. Fixed by [sdl_session.zig](../../../src/v7_host/sdl_session.zig), a reference-counted session that every `Application` and every SDL-using test acquires and that quits only on the last release. This is a live finding about P01 and P02.
2. **The W21 AccessKit bridge existed as source but no build step referenced it.** Its adapter could not compile and [w21_accessibility_test.zig](../../../src/v7_host/w21_accessibility_test.zig) never ran, so A01 and A02 had no executable evidence at all. [build.zig](../../../build.zig) now builds and links the bridge under `-Daccesskit-bridge` (default true), and the suite passes 1,413/1,413 both linked and unlinked.
3. **Seven test files were unreachable from their test roots, leaving 35 tests dead.** A walk from the seven test roots now reaches every Zig file under `src/`. Any test count gathered before this fix was an undercount of what the repository already exercised.
4. **[vendor/noapi-provenance.json](../../../vendor/noapi-provenance.json) recorded 4 patches while 12 vendored files were locally modified.** The record now holds 10 entries. It is closer to an inventory but still not a complete one: five modified example files have no entry, and three recorded entries already match HEAD.

The gap tables below are unchanged. They remain the 2026-09-26 source baseline; this section records 2026-09-29 gate state and does not restate or supersede any row.

### Verified implementation evidence — live native session run (2026-09-29)

One native pass on the workstation's real graphical session, after the filter run above:
`XDG_SESSION_TYPE=wayland`, `WAYLAND_DISPLAY=wayland-1`, `XDG_CURRENT_DESKTOP=niri`,
`DBUS_SESSION_BUS_ADDRESS` set, `grim` available, `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache` required.
`DISPLAY=:0` is XWayland, not a standalone X server. SDL selected the native Wayland driver by
default, so the runs below are Wayland evidence unless a row says otherwise. The W22 popup run forced
`SDL_VIDEODRIVER=x11` and is XWayland X11 evidence, and it covers one popup role only.

| Package | Command | Observed on the live session |
| --- | --- | --- |
| W07 | `zig build w07-host-smoke` | `video driver: wayland`, `global position capability: false`. Two real windows on one `Session` model, three committed frames each, revision 2 seen by both windows, a `grim` capture at `/tmp/w07_wayland_final_both.png` showing left sRGB (89,179,225) over 486932 counted pixels and right sRGB (231,160,97) over 973042 in `b8g8r8a8_srgb`, a later explicit resize honoured exactly, a close veto holding the window and its release retiring the session window, `Session.deinit()` succeeding instead of returning `LiveApps` or `LiveModels`, exit 0. Repeated under the Mesa lavapipe ICD with identical observable values, exit 0 again. |
| W07 | `zig build w07-host-smoke` with `SDL_VIDEODRIVER=x11` | Attempted, and it does not complete, for a different diagnosed reason on each of this host's two Vulkan paths. Under the default NVIDIA ICD six runs aborted with `signal ABRT` and the kernel journal shows the same fault each time: `NVRM: Xid (PCI:0000:01:00): 31, ENGINE GRAPHICS GPC2 GPCCLIENT_PROP_0, FAULT_PRIV_VIOLATION ACCESS_TYPE_VIRT_WRITE @ 0x1_22184000`. Under the Mesa lavapipe ICD, the only non-NVIDIA driver installed, gdb 17.2 on the already-built binary puts every frame inside `/nix/store/...mesa-26.2.0/lib/libvulkan_lvp.so` on a rasterizer worker thread, faulting on a `rep stos` in `u_surface.c:146` via `u_memset.h:35` from `lp_rast.c:171`, with destination stride 1920 and layer stride 691200 against a 64x64 fill at x = 576 or 704, y = 320, about 46 KB past the end of the shared-memory image. Both are host defects; the Wayland path is unaffected. |
| W22 | `zig build w22-layer-shell-smoke` | niri does advertise the global: `globals=48`, `zwlr_layer_shell_v1_name=6`, `zwlr_layer_shell_v1_version=5`, `wl_output_count=1`, `wl_compositor_version=6`, adapter probe `capability=supported`. A real surface requested layer `top`, anchor `top_dock`, margins t12 r24 b0 l24, exclusive zone 64, keyboard interactivity `none`; the compositor delivered `configure serial=3133760 size=1872x64`, the ack serial matched, the state reached `mapped`, a buffer committed at 1872x64, and `niri msg --json layers` confirmed `{"namespace":"w22-layer-smoke","output":"eDP-1","layer":"Top","keyboard_interactivity":"None"}`. The explicit unavailable path ran for real on the X11 driver. |
| W22 | `zig build w22-popup-smoke` with `SDL_VIDEODRIVER=x11` | `video driver: x11`, so this is XWayland's X server reached through `DISPLAY=:0`, not a standalone Xorg session. `NativePopup.create` to `parent.createPopup` to `SDL_CreatePopupWindow` with `SDL_WINDOW_POPUP_MENU` produced a real role, confirmed by reading the window's SDL properties back rather than by the adapter's own verdict: `x11_display_pointer=.{ .value = anyopaque@216e6270 } x11_window_number=10485777 x11_screen=0`. The lifecycle ran to exit 0: `activate` reached `active`, `dismiss` was accepted and the SDL window released, a second popup created after parent close reported `AlreadyClosed`, the parent close left `window_count=0`, and `Session.deinit` was accepted. Refusals are asserted by name, so a wrong outcome is a hard error rather than a printed observation: `InAppOverlayHasNoNativeSurface`, `InvalidSize`, `RiskConfirmationRequired`, `PopupGrabUnsupported`, `AlreadyClosed`. Placement: work area `0,0 3840x1080` gave `rect=144,276 180x120` with `flipped_x` true. |
| W22 | `zig build w22-popup-smoke`, native Wayland driver, same compositor | The comparison that inverts the usual expectation. `create(.os_surface)` was accepted, `show` failed with `NativeRoleUnavailable`, the SDL window was released, the run reported that in words and returned `error.PopupRoleNotObtainable`, exit 1. Placement: work area `1920,0 1920x1080` gave `rect=1920,276 180x120` with `slid_x` true. On this stack X11 yields a working native popup role and Wayland does not, and the same solver resolves a different strategy per driver. |
| W24 | `zig build w24-inspector-smoke` | A real window at an observed 520x420. A live pick resolved to `owner=0x1/slot=0/gen=1`, role `button`, label `Inspect Target A`, visual bounds `x=20 y=56 w=360 h=72`, with a child label node, agreeing with input hit testing on both the frame node id and the stable widget id. A pointer sequence through `App.handle` at the same coordinates focused the control and ran `onClick` exactly once; after `Session.update` the label read `Inspect Target B` with identity and bounds preserved. Both stale forms returned `StaleHandle`, and the bounded collectors saturated at 16 records: 8 frames, 4 tasks, 4 actions. |
| W24 | `zig build w24-perf-pair-bench` | Two arms of one tree, not two binaries: A is offscreen with the todo scene, B is offscreen with the spotify scene, and `bench.json` records the mounted root as the only difference. 20 interleaved pairs kept per arm, 3 leading pairs discarded at pair level with that cut passed on the command line rather than chosen after the data was in, and the clock is `CLOCK_MONOTONIC` sampled around whole runs. Wall ms A: min 1824.8, median 2135.2, mean 2144.5, max 2818.4, stddev 255.2, n 20; B: min 4594.4, median 5141.1, mean 5280.6, max 6619.1, stddev 504.5, n 20. Recorder `cpu_compute` sample-phase median ms: A 12.861 median, 13.112 mean, 1.564 stddev; B 46.883, 47.494, 4.344. Paired: median difference +3018.7 ms, mean +3136.1, standard deviation of the differences 453.4, Cohen's `d_z` 6.92, two-sided sign test p 2e-6, 0 of 20 pairs with B faster, and non-overlapping bootstrap 95% intervals A [1882.6, 2259.3] and B [4901.6, 5646.4]. Artifacts in `zig-out/w24-perf-pair/` were accepted by `tools/run_v7_perf.py`'s own header and per-sample validators. It is a smoke: load average 8 to 14 on 12 CPUs, `within_120_fps_budget` passed in 0 of 20 kept runs in either arm, and the presented arm could not run. |
| W21 | `zig build w21-atspi-smoke` | A real AT-SPI registry at `unix:path=/run/user/1000/at-spi/bus_0` and the real AccessKit bridge, publishing one 520x640 Wayland toplevel. The tree read back before any interaction: application `w21-atspi-smoke` containing frame `W21 AT-SPI Smoke` with states ENABLED, FOCUSED, SENSITIVE, SHOWING, VISIBLE, and 8 children all carrying ENABLED, SENSITIVE, SHOWING, VISIBLE, among them `W21 Slider` with value 25 of 0-100 and `W21 Text Field` with EDITABLE. Five real interface round-trips, each seen as `org.a11y.atspi.Action DoAction, INT32 0, method_return True` by `busctl --address=... monitor` on the a11y bus and each then confirmed by the model's own counters rather than by the adapter's own report: `DoAction` on the button gave applied=1 and button_hits=1, `DoAction` on the check box gave checked=true, `Value.SetCurrentValue(75)` moved the slider from 25 to 75 with number_writes=1, `DoAction` on `W21 List Add` grew the rows from 3 to 4, `DoAction` on `W21 Modal Open` set modal_open=true. The re-read showed CHECKED on the check box and a new node, dialog `W21 Modal Confirm`, holding FOCUSED. Exit 0, leak check passed, no process left behind, `org.a11y.Status.ScreenReaderEnabled` reset to `b false`. |

What this run did not establish, reported by the runs themselves:

- **W07.** The real X11 half was attempted and could not be completed, on either Vulkan path this host
  offers. That is a blocked gate, not a missing measurement, and neither failure is a defect in this
  repository. Under the default NVIDIA ICD six runs of `zig build w07-host-smoke` with
  `SDL_VIDEODRIVER=x11` aborted with `signal ABRT` and the journal shows the same fault every time,
  `NVRM: Xid (PCI:0000:01:00): 31, ENGINE GRAPHICS GPC2 GPCCLIENT_PROP_0, FAULT_PRIV_VIOLATION
  ACCESS_TYPE_VIRT_WRITE @ 0x1_22184000`, while the Wayland W07 run passed under the same GPU load and
  `w24-inspector-smoke` and `w22-popup-smoke` both passed on that same X11 stack. Under the Mesa lavapipe
  ICD, the only non-NVIDIA driver installed, gdb 17.2 on the already-built binary put every frame inside
  `/nix/store/...mesa-26.2.0/lib/libvulkan_lvp.so` on a rasterizer worker thread, faulting on a `rep
  stos` in `u_surface.c:146` via `u_memset.h:35` from `lp_rast.c:171`, with destination stride 1920 and
  layer stride 691200 against a 64x64 fill at x = 576 or 704, y = 320, about 46 KB past the end of the
  480x360 shared-memory window image. Both are host graphics-stack defects worth reporting upstream, the
  Wayland path is unaffected, and this machine has no non-NVIDIA ICD paired with a Mesa newer than
  26.2.3, which is what a working X11 combination would need here. Neither did minimize: `requestMinimize` set
  `requested.minimized = true`, and after a 3000 ms pump the window was still visible, unchanged in size,
  and still painted in a `grim` capture taken while the request was outstanding. SDL3's Wayland backend
  never sets `SDL_WINDOW_MINIMIZED` for `xdg_toplevel.set_minimized` because niri does not advertise the
  xdg-shell MINIMIZE capability, so this is an unobservable request on this stack, not a working minimize
  path. The run changed the contract rather than the outcome: `ObservedState.minimized` is now `?bool`,
  with a matching `Application.Capabilities.minimized` derived from `display.hasWindowMinimized()`, so a
  platform that cannot observe minimization reports `null` instead of a false reading.
  [w07_contract_test.zig](../../../src/v7_host/w07_contract_test.zig) pins that honest contract. The
  compositor also ignored the requested initial size, granting 954x1044 to both windows instead of 480x360
  and 520x380; requested and observed size are demonstrably different values on this backend.
- **W21.** Orca never entered any of it. No keyboard activation and no speech announcement for any of
  the four roles, because Orca starts and stays alive but never registers on the a11y bus, never sets
  `ScreenReaderEnabled`, never starts speech-dispatcher and never appears in the bus listing, and a
  grep of the Orca 50.2 python package finds no code that sets the property. Independently of that,
  a native Wayland client cannot receive synthetic key events at all, because `wl_keyboard` is
  compositor-mediated, so no screen reader can inject Enter or Space into a Wayland toplevel. The
  AT-SPI Action interface, which is what Orca's own activate command calls, was driven instead and did
  reach the model, but that substitutes for the action path, not for Orca. Text composition through
  EditableText and list row selection through the List interface were never driven either: the host's
  pygobject `Atspi` bindings return `None` from `get_text_iface()` and expose no object paths, so no
  edit and no selection call was ever issued. The modal `STATE` flag is mapped by the adapter but no
  application can set it, because `semantics.Draft` has no `modal` field and no widget kind produces
  one; the dialog was published by role and by the focus move instead. One prerequisite is not
  self-service and is worth recording: `accesskit_unix` 0.21 gates its whole AT-SPI backend on
  `org.a11y.Status.ScreenReaderEnabled`, so that property was set to `b true` for the run and reset to
  `b false` afterwards, which is the value it holds now.
  *(Superseded 2026-10-04: that was what this 2026-09-29 pass observed. The isolated
  W21 AT-SPI/Orca scope then ran for real on an owned private bus with
  `ScreenReaderEnabled=true`, and Orca did register and did submit speech. The run
  still established no announcement with real audio for any role, no
  `EditableText` write and no keyboard activation. See the continuation near the
  top of this document.)*
- **W22.** The X11 popup ran, and it is still XWayland's X server rather than a standalone Xorg session, so it is one X11 capability rather than X11 evidence in general. Its dismissal was client-initiated, not compositor-delivered, and its grab was refused with `PopupGrabUnsupported` rather than obtained. No compositor-delivered `zwlr_layer_surface_v1.closed`, because niri sends none for a healthy surface and the close exercised here was client-side only. No observation of the exclusive zone's reserved extent, which niri's IPC does not report. And no layer-shell refusal run against a real Wayland compositor that omits the global, because no such compositor exists on this host; the unavailable path was exercised on the X11 driver instead, and the popup refusal was exercised against real niri, which is a different capability from the layer-shell global.
- **W24.** The paired recorder measurement exists, and it is still not a speed claim. Load average ran 8 to 14 on 12 CPUs for the whole measurement, with a 650% CPU compile, the 1426-test gate and sibling workers contending, and this box cannot be shown idle, so the absolute milliseconds are contaminated in a way the run cannot correct. `run_v7_perf.py`'s own `within_120_fps_budget` check passed in 0 of the 20 kept runs in either arm, and the sample-phase p99 ranged 14.2 to 27.1 ms for todo and 48.5 to 154.1 ms for spotify against the 8.33 ms budget, which is what that gate's own wording predicts: API parity is not a 120-FPS promise. The presented arm never ran, because a presented run is aborted by the demo's own `rejectPerfEvents` guard on any pointer or key event and so survives only at short configurations on a shared display; that guard is working as designed and was not weakened to make the benchmark pass. D04 stays open.
- **W24 tooling.** `tools/run_v7_perf.py`'s `pair` subcommand requires two binaries with different sha256 in the same profile, so a pair is two source revisions and cannot express two configurations of one tree, and its `matrix` subcommand has no A/B arm axis. That gap is what the new paired binary fills, and it is a limitation of the existing tooling that no command in the tree could show.

The limits the W24 run placed on its own evidence: the window paints a clear colour with no renderer
mounted, so a screenshot cannot show the inspected controls and all of the above is API-observed; no
overlay was present, so only the normal-tree form of "picking selects the same target as input" was
exercised; the pointer events were synthetic values passed to `App.handle` on a real, mapped, focused
window; and one window, layout, machine and display server were covered.

The limits the recorder pair placed on its own evidence: both arms were offscreen, so no run in the
pair presented a frame; the two arms differ by mounted root, so the comparison is scene against
scene and not the isolated cost of one widget; the box was under load for the whole measurement, so
what the numbers say about this machine under this load is all they say; and one machine, one
compositor and one session were covered. The direction of the difference is well separated and the
intervals do not overlap, so the ordering of the two scenes is not in doubt, but the run supports no
statement about how much of it would remain on an idle machine and none about frames per second.

The limits the W21 run placed on its own evidence: the five calls came from an AT-SPI client over the
real bus, not from Orca, so this is a real OS bridge and a real interface but not a real screen reader;
the tree was read by inspection rather than captured from a running listener; the painted window is
not part of any of it, since the evidence is the tree and the model counters; and one registry, one
compositor and one machine were covered.

No P or D row reaches the acceptance its package demands, so the gap tables below and the six-of-66
verified count above are unchanged. This section records that a live session exists and what it showed,
not that any row closed.

#### Defects found and fixed during this native run

The first two were found only by talking to a real compositor, the last two only by a real AT-SPI
registry delivering a real request into the bridge. No test filter could see any of them.

5. **`LayerSurface.deinit` killed the display connection on every teardown.** It marshalled
   `wl_compositor.release` (opcode 2) under a `>= 4` guard while the protocol requires version 7, and the
   local descriptor declared `release` since 4. niri answered
   `error 1: invalid version for wl_compositor#57.release (4, need at least 7)` and then
   `Wayland display connection closed by server (fatal)`. The since-version is now 7 and the run reports
   zero protocol errors.
6. **Four Wayland interface descriptors held requests at the wrong opcode.** A dropped request shifted
   everything after it in [wayland.zig](../../../src/v7_host/linux/wayland.zig): `xdg_positioner` had
   `destroy` at index 6 instead of 0, `wl_seat` had `release` at index 0 instead of 3, `wl_surface` had
   `set_input_region` at 4 instead of 5 with `set_opaque_region` missing, and `xdg_surface` had
   `ack_configure` at 3 instead of 4. All 14 descriptors in that file were audited against the protocol
   XML. The opcode-order test had been pinning the wrong `xdg_positioner` order and therefore agreed with
   the defect; it now names the protocol order and every indexed entry, because an assertion covering only
   the first and last request cannot see a shift in the middle of a table.
7. **`Adapter.init` handed the bridge a pointer to a returned stack frame.** The adapter was built on
   the stack and returned by value while the bridge kept that raw pointer, so the pointer referenced a
   frame that had already been returned, and the first real AT-SPI action segfaulted at address `0x68`
   through `futexWaitUncancelable <- enqueueRequest` in
   [accessibility.zig](../../../src/v7_host/accessibility.zig). `init` is now self-initializing.
   A finding about A02, and one no unit test could have caught, because no test ever receives a request
   from a real screen reader.
8. **The bridge teardown did not stop AccessKit's event loop, so a late callback could reach a dead
   adapter.** `Drop for Adapter` in `accesskit_unix` 0.21 only enqueues `RemoveAdapter` on a channel a
   detached thread drains whenever it gets to it. With a screen reader registered on the bus the Zig
   suite aborted after every assertion had passed, with `signal ABRT` and a frame in
   [accessibility.zig](../../../src/v7_host/accessibility.zig). The bridge now closes a gate that
   every host callback takes before the box dies
   ([teardown.rs](../../../src/v7_host/accesskit_bridge/src/teardown.rs)), and the suite passes
   1426/1426 with the screen reader registered. Also a finding about A02, and the reason defect 7 hid
   it: the W21 unit tests never receive a request from a real screen reader, so they never drove the
   bridge's callback path and never exercised its teardown against a live AccessKit loop. Only a real
   registry could reach either one.

#### Host-side defects found during this native run, not fixed here

The two below are real findings about the audited host surface, but neither lives in this repository, so
neither is fixed here. Both blocked the X11 half of the W07 gate, both are reportable upstream with this
evidence, and neither is a nogui defect.

9. **The NVIDIA driver faults in XWayland presentation.** Six runs of `zig build w07-host-smoke` with
   `SDL_VIDEODRIVER=x11` aborted with `signal ABRT`, and the kernel journal shows the same fault each
   time: `NVRM: Xid (PCI:0000:01:00): 31, ENGINE GRAPHICS GPC2 GPCCLIENT_PROP_0,
   FAULT_PRIV_VIOLATION ACCESS_TYPE_VIRT_WRITE @ 0x1_22184000`, the identical address in all six runs.
   Three controls locate it in the X11 presentation path rather than in the audited code: the Wayland
   W07 run passed under the same GPU load, `w24-inspector-smoke` on X11 passed, and `w22-popup-smoke` on
   X11 passed. The Wayland path is unaffected.
10. **Mesa's llvmpipe tiled clear writes outside the surface.** Under the only non-NVIDIA Vulkan ICD
   present, Mesa lavapipe, a gdb 17.2 batch backtrace on the already-built binary puts every frame
   inside `/nix/store/...mesa-26.2.0/lib/libvulkan_lvp.so`, on a rasterizer worker thread and not the
   main thread: `util_fill_rect`, `util_fill_box`, `lp_rast_clear_color`, `rasterize_scene`,
   `thread_function`, `impl_thrd_routine`. The faulting instruction is a `rep stos` in the 32-bit
   row-fill fast path, `src/gallium/auxiliary/util/u_surface.c:146` calling the inlined
   `util_memset32` at `src/util/u_memset.h:35`, reached from `lp_rast.c:171`. Live values at the
   fault: destination stride 1920 for a 480-wide surface, layer stride 691200 for a 360-high one, and a
   64x64 fill rect at x = 576 in one run and 704 in another with y = 320, so the store runs about 46 KB
   past the end of the single X11 shared-memory window image into an unmapped gap. The origin differs
   between runs, and the render area this repository passes is (0,0,480,360), which is in range and bins
   to tile (0,0), so it cannot be a value supplied here; no swapchain blit is issued at all. Mesa
   26.1.6, 26.2.0, 26.2.2 and 26.2.3 reproduce it identically, each reporting `GPU: llvmpipe (LLVM
   21.1.8, 256 bits)`. The Wayland path is unaffected. The contrast that isolates it: the one-window
   `w24-inspector-smoke` on X11 with lavapipe completes, and the two-window `w07-host-smoke` on Wayland
   with lavapipe completes, so X11 and the two-window path are both required. The two were not fully
   separated, because w07 exposes no single-window flag and `w22-popup-smoke` is not a usable control:
   on X11 with lavapipe it exits 0 while printing a null video driver, meaning it never opened a Vulkan
   window.

## Current implementation and acceptance matrix (2026-10-01)

This section reconciles **all 66 gap rows** against the source that exists in this tree now
and against the proof actually on record. It is the current reading of the tracker. Every
section above it is dated history and is left unchanged, including the 2026-09-29 audit-wide
gate tables and the two supersede notes attached to claims that source has since overtaken;
the C/L/I/T/R/P/A/D tables at the end of this document remain the **2026-09-26 source
baseline** and their deficiency text is not restated or softened here.

Three words are used with fixed meanings and are never merged:

- **Source** — the named file and symbol exist today. It is not a claim that the code has
  been exercised, and it is not a claim that it is correct.
- **Proof** — a dated run recorded in the [companion plan](2026-09-26-gpui-api-parity.md) or
  in this document. A filtered unit suite, an injected driver or mock, a headless or
  synthetic replay, a `LinuxUnsupported` refusal and a real OS runtime are five different
  kinds of evidence and each is labelled as the one it is.
- **Unfulfilled** — the specific acceptance item still open **within that row's own
  package**. Where a package's acceptance scenario was completed and accepted at its date,
  that is stated and the cell names what remains, if anything, inside that package. An
  unrelated red product elsewhere in the repository does not reopen already accepted
  evidence.

### Gate state at this reconciliation

- **2026-10-03 settled source, the current gate:** `zig fmt --check src build.zig
  build.zig.zon examples` exited 0. `zig build test check lint` passed **109/109 steps and
  1,912/1,912 tests**, with `check lint` contributing 88 steps and both linters reporting
  zero errors and zero warnings across **258 files**. Python tooling passed **126/126**.
  The 2026-10-02 totals of 106/106 steps and 1,858/1,858 tests are superseded by this run
  and survive only as dated history.
- The unchanged layout corpus passed **5,524/5,524**, with zero unsupported cases.
  The layout golden passed **581 rows**.
- **2026-10-04 canonical gate on the landed docs and frozen source:** the first
  attempt failed at 111 of 113 steps and 1,932 of 1,933 tests, the only failure
  the `w23_mobile_smoke` `PublishedRunIsNotOwned` frame-lifetime test, with the
  ReleaseSafe, noapi, Python and fixture legs never reached. The repair was
  behaviour-only and source-consumer scoped — an obsolete allocator provenance
  assertion and a dead `LiveLedger` removed, no production behaviour changed — and
  the real `w23-mobile-field-test` target then passed 21/21 steps and 4/4 tests in
  5.84 s. The rerun exited 0 in 986.08 s and reached every leg: Debug `test
  check layout-check lint`, ReleaseSafe `test check`, vendored noapi with Tracy
  off, 126 Python tests, and standalone fixture 5,524 passed / 0 failed / 0
  unsupported over 5/5 steps, with zero lint findings across 258 files,
  tree-wide formatting after a narrow pass corrected two files, and 581 matching
  golden rows. The default mobile probe reported its platform unavailable with no
  device, and the linked W21 headless consumer exited 0 with 38 passed and 0
  failed, with the adapter inactive and the screen reader false. **That run
  printed no aggregate Zig test count**, so none is stated here and none is
  inferred from the failed attempt. No mobile device and no native acceptance is
  claimed by either attempt.
- **Three resumed proofs, each bounded to what it actually exercised.** The bus
  CLI proof went red on a second start over an unlinked live bus socket
  (`root_already_use`, `/tmp/nogui-w19-bus-cli-proof-40a44f78ab`) and green after
  removing only two unconditional socket and lock removals ahead of the exclusive
  services directory (`-4dd3920d01`): seven components, five refusals with names
  and identities preserved, a genuine D-Bus `RequestName` denial, no provider
  activation, and the CLI refusals `unknown`/leading 23, help and default 0,
  teardown, unapproved 20, unlock-plan 21 and preflight — no drop-runtime and no
  full `Unlock` claim. The secret-material proof passed 11 cases with three owned
  tools of known exit, observed mutable byte views all zero, the Unicode LF and
  CRLF read and storage tail, `EEXIST`, a real non-zero tool and an actual
  8-byte mode-0600 VNC file, claiming nothing about a backend wipe, a native
  allocator wipe, a JS gigacage wipe or a global wipe, with live keyring daemon
  handover still unapproved. The bus-free W21 boundary proof covers only the
  callback exception report, its retention, a later callback and the
  `KeyboardInterrupt` escape, and is not a native RPC refusal.
- **The wire component's error-path frame flush is green and narrow.**
  `/tmp/nogui-w21-real-module-proof-kz4dv4d2/actual-results.json` ran the genuine
  `sd_espeak-ng` under a launcher built with `cc -Wall -Wextra -Werror -O2` and
  its own `RLIMIT_FSIZE` of 131072 with `SIGXFSZ` ignored; `fsize-refused`
  passed. `truncated_event_count` is 1 with that event's owner, request and
  transaction all `null` and `has_audio=false`; the one unclosed transaction
  close carries the same own transaction 1, request 4 and a null `closed_by`; and
  17 chunks decoded to 109844 PCM bytes. `stdout.bin` is exactly 131072 bytes
  against indexed/forwarded/driver-received counts of 120970, so
  `stream_check.agrees` is **false** and stays recorded as false — a partial
  write crossing the limit put 10102 extra bytes on disk before `EFBIG`, and no
  exact full raw accounting is claimed. The observer took a genuine `SIGKILL`
  of -9 with `module_reaped true` and signal 9 through pidfd only, and cleanup
  completed. No Orca, display, bus, keyring, audio sink or native UI is involved.
  This closes the error-framer flush item and no W21 required item.
- **Root isolation, the viewer transport, reader log IO and the causal replay.**
  Root isolation is green at 14/14 after minimal state resets
  (`/tmp/nogui-w21-root-isolation-Ez2wDA/results.json`, one process, one actual
  import, real `RootA` with 16 model keys and actual speech counts, then a new
  empty `RootB` with no old keys, level `null` rather than `0` and every counter
  at 0), with the earlier 7/14 red preserved at
  `/tmp/nogui-w21-root-isolation-pP0ivE/results.json`. The viewer transport proof
  is green at `/tmp/nogui-w19-viewer-transport-proof-E2vRoL/actual-results.json`:
  exit 0, `passed: true`, 12.77 s, ten actual component cases in scope REACHED —
  own Xvfb with binary Xauthority, actual 8-byte mode-0600 VNC password, own
  127.0.0.1 LISTEN inode with a wrong live PID refused, RFB accepting 12 bytes
  where the fault relay deliberately forwarded only the upstream's first 11
  actual bytes and closed — the upstream did send the full 12-byte `RFB 003.008\n`
  and production `rfbGreeting` at 6699–6723 already accumulates TCP chunks to 12,
  so the source is valid and that negative case is a deliberate prefix
  truncation, not an upstream short-greeting failure; the declared viewer route is
  a separate manifest API with no parent viewer acceptance. The rest of that
  scope is an exclusive manifest collision
  with inode and bytes preserved, and an absent prompter spawning nothing with
  no new children and no Gcr — corrected only in retirement order, a retained
  handle whose known exit is taken before any bare PID probe, with three owned
  children reporting known exits Xvfb 0, VNC 0 and x11vnc 1, all relay
  connections closed, cleanup complete and the root descriptor retained then
  closed; the `aAHBq2` API-shape red and the `SeyT6a` cleanup-misclassification
  red are both preserved. No parent viewer window, pixels, user acknowledgement,
  `Unlock` or prompt is involved and there is no IPv6 proof. Reader log IO is
  green at 10/10
  (`/tmp/nogui-w21-reader-log-io-proof-2026-10-04T16-23-43-912Z-564174.json`):
  `ENOENT`, `EISDIR` and `EACCES` each answer a typed unknown, a failed log
  cannot claim a `HANDLE` marker, the whole 1,477,471-byte Orca log reads with
  unchanged SHA-256 and no kernel child remains. The causal replay is closed at
  16/16 (`/tmp/nogui-w21-causality-regression-e9bzdo/result.json`) with the raw
  and root index original unchanged — invariants, not full native acceptance:
  three native fixes and the causal-ownership design are still underway, so the
  four unestablished W21 criteria stay unestablished and no regenerated 18/22
  result and no native full pass are claimed.
- **The reader chord parser passes; the `BOOL` fixture bug belongs to its first run.**
  `/tmp/nogui-w21-dconf-chord-proof-2026-10-04T18-25-58-128Z-963057.json` records
  13/13 exercised cases passed on the first of two runs: the positive case credits the reader's own close
  marker at byte 1311021 for `Left`/hw 113 in 8 ms with `keyval_agrees: true`;
  the negative case asks for `KP_Divide` / `Orca+KP_Divide` /
  `routePointerToItemHandler` at byte 1467210 where the window holds only
  `KP_Add`, credits nothing, and reports `keyval_agrees: false` after 2069 ms;
  and a real `ENOENT` log answers `orcaLogSince ok: false` with `keyval: null`
  and `keyval_agrees: null` in 2 ms, an unknown rather than silence. The copy is
  byte-for-byte the 1,477,471-byte real log at `257e35e6…` with 0 markers
  written by the proof, the approved log is untouched, the operator's dconf user
  database is byte-identical before and after, and no child process outlives it.
  No keypress was sent and no reader was launched, so this is a retained parser
  proof and not native command delivery. **That first run left 10 `BOOL` cases
  unexercised, not passed**, because the harness pointed `dconf compile`'s OUTPUT
  at an existing directory and every compile failed with `g_rename() failed: Is a
  directory`; it is kept as the dated record of that run.
- **The rerun is 22/22 exercised with one corrupt-database branch unexercised**
  (`/tmp/nogui-w21-dconf-chord-proof-2026-10-04T18-37-15-156Z-988754.json`,
  decoded corrupt case in `artifact://16827`). A real compile of DBFILEs succeeds,
  `true`/`false`/unset are typed known answers, two equal booleans and two equal
  unset reads agree, recompiling `true` to `false` and boolean to unset are
  refused, and real `ENOENT`, non-zero and non-boolean queries are unknown and
  never agree. The corrupt own database is **not** a pass: its actual native CLI
  answers status 0 with empty stdout and stderr, so the helper reports a known
  unset and DB integrity stays **UNESTABLISHED** with no failed-query signal and
  no invented warning or refusal. The operator's dconf database is byte-identical
  before and after each proof. The parent closed todo 24, *"Require two successful
  exact native dconf reads"*, as a component gate only, and todo 25, the exact
  keyval `HANDLE` gate, was closed by the previous run. No native keypress,
  reader, UI or accessibility change is involved.
- **The IO item is now actually closed.** The observer's own journal IO is green
  at 14/14 with no unexercised case
  (`/tmp/nogui-w21-observer-io-proof-2026-10-04T17-41-14-151Z-835680.json`): a
  readable empty journal reads as zero records with `idle: true`, a missing one is
  a typed `ENOENT` with `idle: false` and the reason retained, a directory is a
  typed `EISDIR` refusal, and a mode-000 journal owned by uid 1000 actually
  triggers `EACCES`, with the permission restore clearing the old error and
  counting the record the refusal left unread. Counters over the real closed
  687,886-byte journal match an independent measurement — 1,411 records, 52
  submissions, 51 begun, 52 ended, 0 open — that journal is byte-identical
  before and after, and no process was started. Root isolation is green again at
  14/14 (`/tmp/nogui-w21-root-isolation-9s1P9g/results.json`) and a second causal
  replay is closed at 16/16 with the evidence unchanged
  (`/tmp/nogui-w21-causality-regression-ZpystS/result.json`), including
  `crlf_reader_log_preserves_the_stock_navigator_grab`. The native 22 required
  criteria are unchanged and no fresh UI approval was spent.
- **The speech-module trace TODO closes on the wire only.** A read-only review
  matched the exact controller SHA `cca92cce…` against the `ZpystS` replay. The
  actual bytes under the size limit were 120970 with traced, forwarded and
  driver-received counts in agreement while 131072 bytes reached the disk, and
  the truncation left no next reply to borrow: unclosed `true`, `closed_by`
  `null`, and the truncated event's owner, request and transaction all `null`.
  `ZpystS` reports 52 submissions, 52 transactions and 52 joined, no
  request-sequence collisions and 0 raw-subsequence violations, with the one
  missing-UID transaction at offset 6013 refused rather than borrowed. The whole
  reader and presentation origin is still **unestablished**, the 13 unique plus
  13 repeat pair is not credited as UID proof because source retries falsify that
  bijection, and the private-guard preflight is recorded separately below; no
  native or Gcr acceptance result is claimed by either.
- **The private guard is green on its own terms.**
  `/tmp/nogui-w19-private-guard-proof-ooxyRt/private-guard-results.json` exited 0
  with the source controller at `0064` unchanged. The actual guard functions
  refuse Wayland, all five foreign options, the legacy-root equality, descent and
  ancestor relations, and the runtime equality of `/run/user/1000` with the
  ancestor relation of `/run/user`; no `/run` case was observed. The clean X11
  route and a fresh independent root pass.
  With the fixed root absent the freshness branch is recorded **EXPLICITUNEXERCISED**
  and no root is created. The Gcr values map two actual `Name` and `Exec` pairs
  onto the shipped `System` and `PrivatePrompter` files with both the wrapper and
  the executed sibling being real Nix output, `prepared` true and `observed`
  false; Xvfb, Openbox, xinspectors and VNC are preflight-checked against `:90` by
  reading only, with no program started. No viewer, prompt, `Unlock`, credential
  or human acknowledgement is involved. The earlier red at
  `/tmp/nogui-w19-private-guard-proof-E4VroD` was the proof's own `Name` parser
  rejecting a whole line where a bare value was expected, fixed in the proof and
  not in the controller. The whole private `Unlock` gates remain open.
- **The located-PCM helper proof is red, and stays red.** Under
  `/tmp/nogui-w21-located-pcm-proof-helpers-L2RSkO` it passed the private scratch
  and binding check, that every faulted capture is a byte-identical copy or prefix
  of the approved capture (`71322bf0…`, 4,256,050 bytes) with no synthesised
  sample, a complete 100 ms positive range from byte 114660 at peak 4295 and rms
  382, and measured silence over 100 ms of real silent bytes from byte 0. It then
  failed seven cases, each named: a genuine `ENOENT` and a genuine `EISDIR`
  swallowed into a zeroed answer; the 3-byte read returned `null` from
  `analyzeRange` and was not accepted there, but `locatedRangeStats` turned that
  unknown into zeros over the whole requested range; the 6-byte and 40,000-byte
  prefixes were accepted as partial metrics; a 1,367,100-byte request capped at
  1,323,000 bytes was published as a whole 31,000 ms range; and measured silence
  against an unmeasurable range is recorded as `the_two_answers_are_identical:
  false` — known silence has 1 slice against the unknown's 0, while peak, rms and
  `audible_ms` are zero in **both** and the unknown still carries the requested
  100 ms metadata, which is the defect. The run reached its 180 s TIMEOUT inside
  the expensive pair search before any final JSON, and the PCM source change is
  source-only so far — tagged `measured: false` with null metrics and no passing
  run — so no full helper proof is claimed.
- **The provider byte-handover proof is a true red.**
  `/tmp/nogui-w19-provider-byte-handover-proof-LsHxkx/report.json` shows
  `startProvider` receiving all 24 of 24 synthetic own-fixture bytes to a real
  `wc -c`, while the 25-byte allocation is **not** wiped after any of the five
  cases — normal handover, missing program, `EEXIST` log refusal, kernel spawn
  `EACCES`, and the exiting recipient where the pipe accepted. That last case is
  explicitly not an exercised `EPIPE`, so no write failure is claimed for it. Both
  owned children were really reaped and the providers ended at 0, and no bus,
  keyring, `Unlock`, prompt, UI or credential was touched. One proof-only getter
  took `startProvider` from `0064` to `3532` with no behaviour change after the
  harness-only `yZkojW` failure, and the source owner `ProviderByteHandover` is
  permitted to repair the outer `finally` and remove the caller's redundant fill.
  No green result existed at that point.
- **The provider byte-handover proof is green.**
  `/tmp/nogui-w19-provider-byte-handover-proof-9BtSQy/report.json` exited 0 on
  source `63E8`, with the parent `node --check` passing. All five actual storage
  wipes pass: the normal `wc` recipient receives 24 of 24 bytes, and a real
  missing executable, an `EEXIST` log refusal and a kernel nonexec `EACCES` each
  spawn no child, while the actual exiting recipient accepts the pipe. The whole
  observed 25-byte allocation reads zero in every case, through the passed view's
  fill and the producer's pre-zeroed spare tail; two real children were reaped and
  providers ended at 0. Case 5 is **still explicitly unexercised** because the
  pipe accepted, so no `EPIPE` exception or write-failure proof is claimed. The
  parent closed the password-reader/handover component todo 19 from the prior
  `KKW11` read and VNC cases reused plus this new actual `startProvider` scope;
  that is not whole production `Unlock` and no prompt is claimed accepted. The
  repair is an inline `Uint8Array.fill(0)` in the whole helper `finally` after the
  `stdin.end` drain, with the unused helper removed, the redundant caller-only
  success fill deleted, and the outer `passwordPayload?.fill` kept for refusals
  before handover. No secret content or hash is serialised or logged, only an own
  synthetic fixture and a scalar `wc` byte count, and no user credential, UI,
  bus, keyring or prompt approval was used. The earlier `LsHxkx` real red and the
  `yZkojW` harness-absent-export red are both preserved.
- **The located-PCM helpers, second run, passed 12 of 13.** The only failure is
  the read-cap check, and it failed despite a correct `measured: false` with null
  metrics, so it is suspected to be a proof message assertion rather than a
  product defect; the proof owner is investigating. Four integration cases remain
  unexercised, so this is not a finished helper proof.
- **The located-PCM helper scope is green; the integration run is still red.** The
  helper run at
  `/tmp/nogui-w21-located-pcm-proof-2026-10-04T19-06-19-969Z-1053874.json` is
  **14/14 inside its own scope only**, on source `9B7D` with a passing syntax
  check: all eight fault cases, the two real positive and silence cases, and the
  integrity and scope cases, including a newly requested 3-byte `RANGE_TOO_SHORT`
  case. Its four integration cases are explicitly unexercised by mode. The
  independent integration-only run at
  `/tmp/nogui-w21-located-pcm-proof-2026-10-04T19-07-32-532Z-1053419.json` is a
  **red 4 of 6**: for the exact selected wire — request 19, transaction 7, UID 19,
  98,098 PCM bytes — the unique fragment spans 325988→424086 while the actual
  binding identity is 225-19 and the spoken-true window is 118112→173730, and
  truncating to 325,994 bytes leaves that same window in place with spoken still
  true. **The cause is confirmed and it is a HARNESS pair mix, not a product
  defect:** the proof paired that wire against the FIRST UNREFUSED BINDING instead of
  the screen-reader-on binding it names. Its own selected marks `0:3, 4:8, 9:14` resolve
  to the unique 325988→424086 fragment, while the real reader binding — screen reader on,
  marks `0:6, 7:13, 14:17` — owns request 6, transaction 1, reference 55618 and the
  window 118112→173730. The 325,994-byte truncation still held that entire binding
  window, so the `spoken` answer was truthful **for the binding the harness actually
  selected**; it is not evidence of a production neighbour bug. That artifact stays red
  4 of 6 as dated history and is not rewritten. **The corrected pairing has since been
  run and preserved:** it selects subject request 19 / transaction 7 with **no carry
  among the 102 bindings**, exercising 3 of 3 selected cases and leaving 17 unexercised
  — the mode cases plus six downstream ones. Row eligibility for a second, distinct
  subject is still pending, so the integration surface is not fully exercised and no
  broader green integration claim follows. The separate repeated-fragment count
  and Nth-matching text attribution remains an independent open question pending the UID
  clean cutover. The PCM component is therefore not closed here.
  The expensive steps are a 36 s reader fragment parse and a 36 s baseline bind against
  a 1.1 s wire build —
  the earlier 180 s was repeat matching, not wire-log parsing.
- The actual `run-parity-menu-overlay` CLI passed drag refusal, cancellation, accepted
  payload release, tooltip deadlines, reentry, owner retirement and menu restoration.
  The fix cancels stale leave requests rather than changing the specimen coordinates.
- The complete private X11/IBus run accepted **35 items with zero refusals**.
  Both candidate-window observations passed. The parent inspected the final candidate
  capture and the painted scrolled field.
- Linux ran the Windows, macOS and mobile probes and the SDL-dummy W12 consumer.
  These runs prove portable compilation and explicit unavailable results, not native target acceptance.
- The prior W11 windowless **1,016-check** and mapped **1,023-check** text specimens remain valid.
  The external host consumer retains its idle/wake/retirement proof.
- **The six clean packaged consumers ran.** The controller fetched and extracted canonical
  archive `nogui-0.0.0-CnwuaG3HQAKb0ToiHHC8yGLT3hYbbFZ2TdJxNqSYVCbV` (6,761,650 bytes) into
  `/tmp/nogui-w26-clean-final-with-witness-20261003` with `DISPLAY`, `WAYLAND_DISPLAY` and
  `DBUS_SESSION_BUS_ADDRESS` cleared and a per-consumer empty local **and** global cache
  asserted before each first command. **11 commands, 6/6 consumers passed, 0 failed**:
  `core_only: OK`, `text_only: OK width=136.09`, `renderer: OK rects=3 materials=2`,
  `test_support: OK checked=true generation=2` plus its own `zig build test`,
  `host: OK session_window=1 idle_frames=1 worker_frames=2 wakes=1 target_adapter=ShimUnavailable`
  under `SDL_VIDEODRIVER=dummy`, and the offscreen consumer's CPU arm
  `checks=32 … refused=FontUnavailable` and windowless-GPU arm `checks=1016` writing a
  640×640 `offscreen.ppm`. The package witness records **92 declared paths**, 1,948 extracted
  entries / 1,874 files, 39 required paths checked, **0 undeclared files, 0 missing declared
  paths**. The generated `src/v7_host/accesskit_bridge/target`
  tree is present in the checkout and **absent from the archive**, which is the exclusion
  witness itself. One historical harness correction is on the record and does **not**
  qualify the result: the controller's empty-font-registry marker had expected
  `refused=error.FontUnavailable` while the consumer prints `refused=FontUnavailable`; the
  incidental error prefix was dropped from the expectation and only the remaining GPU arm
  needed a re-run. The CPU arm's `FontUnavailable` refusal is real consumer output, and the
  **six cold consumers stand as valid** — nothing in W26 requires one uninterrupted
  controller invocation.
- **`repo_untouched: true` is narrowed to what it measured.** That run checked two
  absences: the generated bridge target does not ship in the package, and the one
  exact checkout path `zig-pkg/nogui-0.0.0-CnwuaG3HQAKb0ToiHHC8yGLT3hYbbFZ2TdJxNqSYVCbV`
  is absent. A read-only re-derivation on 2026-10-04 confirmed the first of those
  and found the checkout also carries `.tmp-6d5594940322ddbf`, so the record does
  not establish that nothing in the checkout changed. The original
  1,948-entry / 1,874-file / 37,799,789-byte counts were measured before any
  consumer built and stand; the same filtered fetch package measures 1,874 files
  and 37,799,789 bytes now, while the extraction directory holds 24,561 entries
  and 887,439,707 bytes of post-build output. The retained frame is not blank:
  640×640, 1,228,815 bytes, 281,031 of 409,600 pixels differing from the
  `33,36,41` background, with the same parser rejecting a flat probe. The
  historical compiler binding is not recoverable: 10 of 10 compiler commands
  name the bare `zig` and 0 record an absolute `argv0`, so only the `0.16.0`
  version log binds that run; today's toolchain
  `/nix/store/fvlqxywq2p7h2147m0wdp8g0m38zdprp-zig-0.16.0/bin/zig` reports 0.16.0
  and is not read back into it. No completed consumer was re-run. Evidence:
  `/tmp/nogui-w26-provenance-proof.json`,
  `/tmp/nogui-w26-offscreen-marker-resumed-20261004.json`,
  `/tmp/nogui-w26-refusal-resumed-20261004.json` and
  `/tmp/nogui-w26-provenance-resumed-20261004.json`.
- **Four full font notices ship.** `src/Inter-LICENSE.txt`, `src/DejaVu-LICENSE.txt`,
  `src/FiraCode-LICENSE.txt` and `src/NerdFonts-LICENSE.txt` are declared in
  [build.zig.zon](../../../build.zig.zon) `.paths`, accompany the bundled
  `InterVariable.ttf`, `DejaVuSans.ttf` and `FiraCodeNerdFont-Regular.ttf`, and were counted
  by the same 0-undeclared / 0-missing witness. The authoritative upstream text for each was
  located and packaged earlier, and `README.md` cites all four sources. **2026-10-03,
  provenance verified rather than attributed:** the four files were compared against their
  cited upstreams as exact HTTP response bytes with no normalization —
  `src/Inter-LICENSE.txt` 4380, `src/DejaVu-LICENSE.txt` 8816, `src/FiraCode-LICENSE.txt`
  4389, `src/NerdFonts-LICENSE.txt` 6200 bytes, each `exactBytesEqual: true` with matching
  local and upstream SHA-256. The static reader was used first and its transport envelope was
  not mistaken for upstream bytes. Proof
  `/tmp/nogui-font-notice-byte-proof-20261003.json`, `checked_at`
  `2026-10-03T05:36:28.468Z`. This closes provenance; it is a recorded result, not a new gate.

### Module boundary as it stands

`src/v7_frame/` is a real reusable boundary, not a demo helper: `root.zig` exports
`Offscreen`/`writePpm` ([offscreen.zig](../../../src/v7_frame/offscreen.zig)),
`NativeFrame` ([native.zig](../../../src/v7_frame/native.zig)), `BindlessHeap`
([heap.zig](../../../src/v7_frame/heap.zig)), `SystemVulkanLoader`
([loader.zig](../../../src/v7_frame/loader.zig)), `TextEngine`/`srgbToOklab`
([text_gpu.zig](../../../src/v7_frame/text_gpu.zig)) and
`scene.recordFrameScene` ([scene.zig](../../../src/v7_frame/scene.zig)). It is consumed by
`src/v7_demo/window.zig`, six smoke binaries and `examples/parity/list_live.zig`, and by the
external `examples/consumers/offscreen` package. `src/v7_host/root.zig` additionally exports
`macos`, `windows` and `mobile` adapter modules alongside the Linux ones.

### Package coverage — 26 packages, 66 rows

"Named blocks" records the 2026-10-01 source inventory, not a current pass count.
The dated gate and native records above provide executed results after later changes.
No target-native result follows from the portable inventory.

| Package | Gap rows | Named blocks | Primary source today |
| --- | --- | ---: | --- |
| W01 | none (owns no row) | 0 | [src/v7/root.zig](../../../src/v7/root.zig), [build.zig](../../../build.zig), `examples/consumers/*` |
| W02 | C08, L04, I05 | 32 | [identity.zig](../../../src/v7/identity.zig), [geometry.zig](../../../src/v7/geometry.zig), [app.zig](../../../src/v7/app.zig) |
| W03 | C01, C02, C03 | 16 | [session.zig](../../../src/v7/session.zig), [model.zig](../../../src/v7/model.zig), [context.zig](../../../src/v7/context.zig) |
| W04 | C04, C05 | 15 | [subscription.zig](../../../src/v7/subscription.zig), [effects.zig](../../../src/v7/effects.zig), [globals.zig](../../../src/v7/globals.zig) |
| W05 | C06, C07 | 20 | [task.zig](../../../src/v7/task.zig), [frame_demand.zig](../../../src/v7/frame_demand.zig), [application.zig](../../../src/v7_host/application.zig) |
| W06 | D01 | 4 | [src/v7_test/context.zig](../../../src/v7_test/context.zig), [dispatcher.zig](../../../src/v7_test/dispatcher.zig) |
| W07 | P01, P02, P03, P04 | 26 | [host application.zig](../../../src/v7_host/application.zig), [host window.zig](../../../src/v7_host/window.zig), [display.zig](../../../src/v7_host/display.zig), [window_contract.zig](../../../src/v7/window_contract.zig) |
| W08 | L01, L02, L03 | 19 | [element.zig](../../../src/v7/element.zig), [layout/context.zig](../../../src/v7/layout/context.zig), [style.zig](../../../src/v7/style.zig) |
| W09 | I01, I02, I06, I07, I10 | 25 | [event.zig](../../../src/v7/event.zig), [input.zig](../../../src/v7/input.zig), [focus.zig](../../../src/v7/focus.zig), [app.zig](../../../src/v7/app.zig) |
| W10 | I03, I04, P09 | 43 | [action.zig](../../../src/v7/action.zig), [keymap.zig](../../../src/v7/keymap.zig), [key_context.zig](../../../src/v7/key_context.zig), [host keyboard.zig](../../../src/v7_host/keyboard.zig), [cursor.zig](../../../src/v7_host/cursor.zig) |
| W11 | T01, T02, T03, T04, T06 | 22 | [text.zig](../../../src/v7/text.zig), [style.zig](../../../src/v7/style.zig), [measure.zig](../../../src/v7_text/measure.zig), [shape_cache.zig](../../../src/v7_text/shape_cache.zig) |
| W12 | T05, T07, T08 | 37 | [text_input.zig](../../../src/v7/text_input.zig), [core clipboard.zig](../../../src/v7/clipboard.zig), [host window.zig](../../../src/v7_host/window.zig) |
| W13 | R01, R02, R03, R04 | 15 | [paint.zig](../../../src/v7/paint.zig), [path.zig](../../../src/v7/path.zig), [style.zig](../../../src/v7/style.zig), [drawcmd.zig](../../../src/v7/drawcmd.zig) |
| W14 | R05, R06, R07, R08 | 54 | [asset_types.zig](../../../src/v7/asset_types.zig), [image_view.zig](../../../src/v7/image_view.zig), [host assets.zig](../../../src/v7_host/assets.zig), [image.zig](../../../src/v7_host/image.zig), [svg.zig](../../../src/v7_host/svg.zig), [frame_source.zig](../../../src/v7_host/frame_source.zig) |
| W15 | L05, L06, L07, L10 | 30 | [container_query.zig](../../../src/v7/container_query.zig), [uniform_list.zig](../../../src/v7/uniform_list.zig), [list.zig](../../../src/v7/list.zig), [virtual_list.zig](../../../src/v7/virtual_list.zig), [scroll.zig](../../../src/v7/scroll.zig) |
| W16 | L08, I08, I09 | 15 | [overlay.zig](../../../src/v7/overlay.zig), [drag_drop.zig](../../../src/v7/drag_drop.zig), [tooltip.zig](../../../src/v7/tooltip.zig) |
| W17 | L09 | 13 | [animation.zig](../../../src/v7/animation.zig), [frame_demand.zig](../../../src/v7/frame_demand.zig) |
| W18 | P05, P06, P07, P08, P10 | 38 | [clipboard.zig](../../../src/v7_host/clipboard.zig), [dialogs.zig](../../../src/v7_host/dialogs.zig), [menus.zig](../../../src/v7_host/menus.zig), [open_url.zig](../../../src/v7_host/open_url.zig), [preferences.zig](../../../src/v7_host/preferences.zig), [linux/portal.zig](../../../src/v7_host/linux/portal.zig) |
| W19 | P11, P12 | 45 | [notifications.zig](../../../src/v7_host/notifications.zig), [credentials.zig](../../../src/v7_host/credentials.zig), [linux/notifications_dbus.zig](../../../src/v7_host/linux/notifications_dbus.zig), [linux/credentials_secret_service.zig](../../../src/v7_host/linux/credentials_secret_service.zig) |
| W20 | P13 | 58 | [capture.zig](../../../src/v7_host/capture.zig), [linux/capture_portal.zig](../../../src/v7_host/linux/capture_portal.zig), [linux/capture_pipewire.zig](../../../src/v7_host/linux/capture_pipewire.zig) |
| W21 | A01, A02 | 51 | [semantics.zig](../../../src/v7/semantics.zig), [host accessibility.zig](../../../src/v7_host/accessibility.zig), [accesskit_bridge](../../../src/v7_host/accesskit_bridge) |
| W22 | P14 | 47 | [linux/popup.zig](../../../src/v7_host/linux/popup.zig), [linux/popup_real.zig](../../../src/v7_host/linux/popup_real.zig), [linux/layer_shell.zig](../../../src/v7_host/linux/layer_shell.zig), [linux/layer_shell_real.zig](../../../src/v7_host/linux/layer_shell_real.zig), [linux/decorations_real.zig](../../../src/v7_host/linux/decorations_real.zig), [linux/wayland.zig](../../../src/v7_host/linux/wayland.zig) |
| W23 | P15 | 129 | [macos/root.zig](../../../src/v7_host/macos/root.zig), [windows/root.zig](../../../src/v7_host/windows/root.zig), [mobile/root.zig](../../../src/v7_host/mobile/root.zig), [diagnostics.zig](../../../src/v7_host/diagnostics.zig) |
| W24 | D03, D04 | 36 | [inspection.zig](../../../src/v7/inspection.zig), [host inspector.zig](../../../src/v7_host/inspector.zig), [perf_counters.zig](../../../src/v7/perf_counters.zig) |
| W25 | D02 | 8 | [src/v7_frame/offscreen.zig](../../../src/v7_frame/offscreen.zig), [examples/parity](../../../examples/parity), [examples/consumers/offscreen](../../../examples/consumers/offscreen) |
| W26 | D05 | 1 | [build.zig](../../../build.zig), [build.zig.zon](../../../build.zig.zon), [README.md](../../../README.md), `examples/consumers/*` |

Row count by owner: W02 3, W03 3, W04 2, W05 2, W06 1, W07 4, W08 3, W09 5, W10 3, W11 5,
W12 3, W13 4, W14 4, W15 4, W16 3, W17 1, W18 5, W19 2, W20 1, W21 2, W22 1, W23 1, W24 2,
W25 1, W26 1 — **66**, matching the 2026-09-26 baseline exactly, with W01 owning none.

### The matrix — 66 rows, each ID exactly once

#### C — Ownership, contexts, effects and scheduling

| Gap | Pkg | Current source (N) | Proof on record | Unfulfilled acceptance |
| --- | --- | --- | --- | --- |
| C01 | W03 | `session.zig`, `model.zig` (`Model`, `WeakModel`, `Reservation`, `ErasedModel`, `ErasedWeakModel`), `w03_contract_test.zig` | [W03, 2026-09-27](2026-09-26-gpui-api-parity.md#w03--session-typed-models-and-scoped-contexts): filter green, two-App/shared-model tests, native Spotify three-frame and Todo GPU-remount smokes. W03's gate was completed and accepted on that date | **None outstanding inside W03.** The package scenario is discharged. |
| C02 | W03 | `app.zig` `mountRoot`, `mountModelRoot`, `replaceRoot`, `registerTextEndpoint`; `context.zig` `FrameInfo`; `component.zig` | Same [W03](2026-09-26-gpui-api-parity.md#w03--session-typed-models-and-scoped-contexts) entry; gate completed and accepted 2026-09-27 | **None outstanding inside W03.** Typed event subscriptions belong to W04 and are recorded on C04. |
| C03 | W03 | `state.zig` transient contract; `README.md` ownership rules | Same [W03](2026-09-26-gpui-api-parity.md#w03--session-typed-models-and-scoped-contexts) entry; gate completed and accepted 2026-09-27 | **None outstanding inside W03.** The ownership rule is a documented contract by design, not an unfulfilled requirement. |
| C04 | W04 | `subscription.zig`, `effects.zig` owned FIFO, `session.zig` delivery | [W04, 2026-09-29](2026-09-26-gpui-api-parity.md#w04--notifications-subscriptions-and-globals): 22/22 recorded, including the gate's named two-view counter scenario with a self-removing observer. W04's gate was completed and accepted on that date | **None outstanding inside W04.** |
| C05 | W04 | `globals.zig`, `session.zig` window-dependency publication | Same [W04](2026-09-26-gpui-api-parity.md#w04--notifications-subscriptions-and-globals) entry; gate completed and accepted 2026-09-29 | **None outstanding inside W04.** |
| C06 | W05 | `task.zig`, `clock.zig`, `frame_demand.zig`, `host application.zig` wake unregister, `examples/consumers/host` | [W05, 2026-09-29/30](2026-09-26-gpui-api-parity.md#w05--tasks-clocks-and-frame-demand): 27/27 recorded **plus** the live host run at `idle_frames=1 worker_frames=2 wakes=1`, twenty idle steps, ten after completion, clean shutdown. W05's gate was completed and accepted on that date | **None outstanding inside W05.** This is the only row whose full gate, including its live half, was delivered. |
| C07 | W05 | `frame_demand.zig`, `host application.zig` stepping | Same [W05](2026-09-26-gpui-api-parity.md#w05--tasks-clocks-and-frame-demand) entry, including the live idle/worker/shutdown run; gate completed and accepted 2026-09-30 | **None outstanding inside W05.** The unobservable-minimization limit is a platform fact recorded under P04, not a W05 shortfall. |
| C08 | W02 | `app.zig` transaction, `drawctx.zig` mount staging, `runtime.zig` GPU frame contract, `vendor/noapi` `Surface.zig` abort | [W02, 2026-09-27](2026-09-26-gpui-api-parity.md#w02--identity-coordinate-boundaries-and-frame-publication): 36/36 recorded and `--gpu-remount-smoke` ran. W02's gate was completed and accepted on that date | **None outstanding inside W02.** |

#### L — Composition, layout, scrolling and animation

| Gap | Pkg | Current source (N) | Proof on record | Unfulfilled acceptance |
| --- | --- | --- | --- | --- |
| L01 | W08 | `element.zig` custom-leaf descriptor and bounded late subroot | [W08, 2026-09-29/30](2026-09-26-gpui-api-parity.md#w08--custom-element-phases-measurement-and-visibility): 26/26 recorded, then `--ruler-smoke --shot` exited 0 on the windowless noapi path with its pixels inspected. The plan states plainly that this closes the W08 gate | **None outstanding inside W08.** |
| L02 | W08 | `layout/context.zig` intrinsic measure, `w08_contract_test.zig` | Same [W08](2026-09-26-gpui-api-parity.md#w08--custom-element-phases-measurement-and-visibility) entry; gate closed 2026-09-30 | **None outstanding inside W08.** |
| L03 | W08 | `style.zig` `Display`, `layout/dispatch.zig` | Same [W08](2026-09-26-gpui-api-parity.md#w08--custom-element-phases-measurement-and-visibility) entry plus 5,524/5,524 fixtures and the 581-row golden; gate closed 2026-09-30 | **None outstanding inside W08.** |
| L04 | W02 | `geometry.zig` named spaces, `host window.zig` translation, `render_9slice.zig`, `quad_frag.slang` per-axis footprint | [W02, 2026-09-27](2026-09-26-gpui-api-parity.md#w02--identity-coordinate-boundaries-and-frame-publication): nested border/padding/scroll at 1×, 1.25×, 2× with the 581-row golden unchanged; gate completed and accepted | **None outstanding inside W02.** Non-1× GPU pixels are a recorded platform observation limit (see P03), not a W02 shortfall. |
| L05 | W15 | `container_query.zig`, `virtual_list.zig` | [W15, 2026-09-29](2026-09-26-gpui-api-parity.md#w15--scrolling-responsive-queries-and-virtualization): 33/33 recorded, then `examples/parity/list_live.zig` ran for real through `nogui_host` and reported built-row counts as a function of viewport | **None outstanding inside W15.** The example's own last line names its boundary at the public API for pixels; that is a scope statement inside a completed package, not an unmet W15 requirement. |
| L06 | W15 | `uniform_list.zig`, `virtual_list.zig` | Same [W15](2026-09-26-gpui-api-parity.md#w15--scrolling-responsive-queries-and-virtualization) entry; `list_live` reported 35 uniform rows of 200,000 at 900x600 and 18 after a resize to 640x280 | **None outstanding inside W15.** |
| L07 | W15 | `list.zig` sparse variable-height geometry, `virtual_list.zig` | Same [W15](2026-09-26-gpui-api-parity.md#w15--scrolling-responsive-queries-and-virtualization) entry; anchor key follow, remeasure above the viewport and end follow into a 20k model were observed live | **None outstanding inside W15.** |
| L08 | W16 | `overlay.zig` committed bands, dormant visibility and clip policy; `drawcmd.zig`, scene/text lowering and semantic/focus routing | [W16](2026-09-26-gpui-api-parity.md#w16--overlays-drag-and-drop-and-tooltips): core 26/26 and Vulkan offscreen 170/170 across 11 inspected images; **2026-10-02 private X11:** complete real native specimen, 15 steps/98 assertions, 86 GPU frames, exit 0. Scrolled anchoring, topmost paint/input, placed-item click and Escape focus return passed. | **None outstanding inside W16's specified specimen.** Native evidence is Linux X11, not every SDL backend. |
| L09 | W17 | `animation.zig`, `frame_demand.zig`, host `Application` transient deadline merge | [W17](2026-09-26-gpui-api-parity.md#w17--general-animation): the dated external-loop proof is retained. **2026-10-01:** the clock-retreat regression failed before the fix; core 16/16 and host 65/65 now pass. A mapped private-X11 run compared and presented 92/92 frames, then recorded zero idle GPU submissions and clean teardown. | **None outstanding inside W17.** The two-window contract remains unit evidence; mapped evidence is one driver/GPU at 1×. |
| L10 | W15 | `scroll.zig`, `uniform_list.zig` reveal/anchor/end-follow | Same [W15](2026-09-26-gpui-api-parity.md#w15--scrolling-responsive-queries-and-virtualization) entry; clamped scrolling, reveal and independent nested scrollers were exercised | **None outstanding inside W15.** |

#### I — Input, dispatch, focus and commands

| Gap | Pkg | Current source (N) | Proof on record | Unfulfilled acceptance |
| --- | --- | --- | --- | --- |
| I01 | W09 | `event.zig`, `input.zig`, `app.zig`; key-up routes through the keymap and widget path. The baseline ignored-key-up observation is superseded. | [W09](2026-09-26-gpui-api-parity.md#w09--unified-input-focus-and-pointer-capture): dated 30/30 replay gate, then current mapped private-X11 Todo acceptance. One held Space produced one down/up and 19 repeats without duplicate activation; two discrete presses toggled once each. Two native commits inserted exactly `"ok"`. | **None outstanding inside W09.** Native composition remains T07/W12; other-target input remains P15/W23. |
| I02 | W09 | `app.zig` capture/target/bubble, `component.zig` handler hook | Same W09 records: replay establishes phase order and independent propagation/default control; native routed root capture/bubble and actual control outcomes passed through SDL input. | **None outstanding inside W09.** |
| I03 | W10 | `action.zig` comptime descriptors and registry, `host menus.zig` bridge | [W10](2026-09-26-gpui-api-parity.md#w10--actions-bindings-and-keyboardcursor-services): dated 40/40 contracts plus current real X11 Todo registry outcomes and inspected GPU output. | **None outstanding inside W10.** Native OS menu invocation belongs to P08/W18. |
| I04 | W10 | `keymap.zig`, `key_context.zig` | Same current W10 native Todo run: real context/user/disabled precedence, 2,000 ms chord resolved once at 2,088 ms, two suffix replays each activated once, completed chord removed one row; 37 presentations, exit 0. | **None outstanding inside W10 on Linux X11.** Other-target runtime remains P15/W23. |
| I05 | W02 | `identity.zig`, `id.zig` generational `WidgetId`, `key.zig` `ComponentKey` | [W02, 2026-09-27](2026-09-26-gpui-api-parity.md#w02--identity-coordinate-boundaries-and-frame-publication): failing-before/passing-after same-kind insertion test and `--keyed-reorder-smoke: OK`; gate completed and accepted | **None outstanding inside W02.** |
| I06 | W09 | `focus.zig`, `app.zig` tab groups and removal fallback | Same W09 records: dated traversal/removal regressions and native checkbox/field clicks retaining their own stable focus, with field endpoint binding. | **None outstanding inside W09.** Orca acceptance sits under A02 and is not a W09 shortfall. |
| I07 | W09 | `app.zig` pointer capture, release-based activation | Same W09 native Todo run: release away does not activate, valid press/release activates once, slider out-and-back capture releases, and keyboard repeats do not duplicate activation. The surface retired before its owned window. | **None outstanding inside W09.** Native evidence is one X11 driver at 1×. |
| I08 | W16 | `drag_drop.zig`, `host open_url.zig` `DropPhase`/`DropPhaseTracker`, `host application.zig` `.drop_file`/`.drop_text` routing | [W16](2026-09-26-gpui-api-parity.md#w16--overlays-drag-and-drop-and-tooltips): **2026-10-02 private X11** actual rejected/accepted drags and focus-loss cancellation to an owned auxiliary window; no cancelled success, three retained payloads each released once, complete 15-step specimen exit 0. | **None outstanding inside W16.** A native file-manager drop remains P07/W18, not this internal-drag proof. |
| I09 | W16 | `tooltip.zig` with W05 timers; native `menu_overlay.zig` specimen | Same [W16](2026-09-26-gpui-api-parity.md#w16--overlays-drag-and-drop-and-tooltips) native run: real 500 ms delay, hoverable popup, overlapping paint/input winner, leave/reentry and owner-removal cancellation. The corrected 240×22 background contains the unchanged full description in the inspected closing image. | **None outstanding inside W16's specified specimen.** Observed native backend: private Linux X11. |
| I10 | W09 | `event.zig` touch ids and capture | Same [W09](2026-09-26-gpui-api-parity.md#w09--unified-input-focus-and-pointer-capture) entry; touch IDs surviving cancel without mouse duplication recorded | **None outstanding inside W09.** This row is conditional by design: no recognizer suite is advertised, and mobile raw touch lives in `src/v7_host/mobile/` and is unbuilt (P15). |

#### T — Typography, shaping, editing and IME

| Gap | Pkg | Current source (N) | Proof on record | Unfulfilled acceptance |
| --- | --- | --- | --- | --- |
| T01 | W11 | `text.zig`, `v7_text/measure.zig`, `v7_text/shape_cache.zig` font handles, requests and metrics | [W11](2026-09-26-gpui-api-parity.md#w11--shared-typography-and-shaped-text-layout): current filter 40/40, windowless 1,016 and mapped private-X11 1,023 checks with inspected pinned-font pixels; CPU-only empty registry passed 32 checks and recovered after adding the faces through the same App/service. | Native rendering established at 1× on one GPU/driver. Missing configured fonts is exercised; other-target typography is not claimed. |
| T02 | W11 | `style.zig` typed fieldwise text styles, `text.zig` runs/decorations | Same W11 runs paint the same multistyle specimen through canonical layout/scene paths in windowless and mapped modes. | Native 1× rendering established. Other-scale/target runtime evidence is not claimed. |
| T03 | W11 | `measure.zig` `TextLayout`, `LayoutRun`, `LayoutLine`, `shape_cache.zig` | Same mapped 1,023-check specimen paints mixed Hebrew, combining accents and a ZWJ cluster with explicit missing-glyph fallback. Own layout pens/quads, boundary oracles and readback ink are checked; its actual image was inspected. | Rendered specimen established; not a claim of full Unicode/font coverage. |
| T04 | W11 | `text.zig` paragraph alignment, clamp, start/middle/end truncation | Same current default/mapped runs: centered two-line clamp, height 44, all three explicit `~~` suffix positions within width 150, and original records/layout reread after a changed three-line frame. | Windowless and native 1× acceptance established. Other-target typography remains unrun. |
| T05 | W12 | `text_input.zig` model-owned endpoint/selection/geometry; `host window.zig` native adapter; App's manager; ordinary `text_field` and W12 smoke | [W12](2026-09-26-gpui-api-parity.md#w12--general-editable-text-ime-and-edit-actions): **2026-10-03** 53/53 filtered tests before the editable-field ownership cutover and 52/52 after it. Dummy 88/88 checks and the approved native clipboard/IME consumers also passed. The public field borrows the App manager and keeps an installed W18 port. Windowless/presented model, directional selection and pinned-font geometry agree. | Ordinary protocol and private-X11 committed-text/IME acceptance are established. The user kept Neovim remote-grid integration in the separate editor plan on 2026-10-03. |
| T06 | W11 | `text_input.zig` `utf8ToUtf16`, `utf16ToUtf8`, `utf16Length`, `isUtf8Boundary`; `v7_text/measure.zig` `TextLayout.byteToUtf16`/`utf16ToByte` and shaped grapheme boundaries | W11 boundary and shaped-layout proofs remain recorded. The 2026-10-02 real W12 document replaced UTF-16 marked range `11:13`, corresponding to UTF-8 bytes `11..17`, exactly once. Native caret and selection ended at `13:13`. | Native multibyte document editing is established on private X11. Combining/ZWJ and surrogate boundaries retain the W11 contract/specimen proof, not a new native editing claim. |
| T07 | W12 | `text_input.zig` marked range and geometry, SDL native adapter, committed-frame caret publication | [W12](2026-09-26-gpui-api-parity.md#w12--general-editable-text-ime-and-edit-actions): **2026-10-03** fresh `486fb11b…/w12-ime-smoke` private X11/IBus accepted 35 items, zero refusals, both attributed candidate windows. Real preedit, selected multibyte commit, wrapped/scrolling geometry, blur cancellation and composition after focus return passed. Both candidate crops and final full field were inspected; `/tmp/nogui-w12-current-real-ime-20261003/log/`. **2026-10-05, non-1×:** a freshly approved owned Xvfb at `-dpi 120` with `Xft.dpi: 120` on the owned root `RESOURCE_MANAGER` reported `display_scale=1.2500` beside `pixel_scale=1.0000x1.0000`, and the controller accepted **36 items, 0 refused, 2/2 candidate windows**; anchor `(634,868 1x28)` from window origin `(480,828)`, XIM SPOT `(634,896)`, candidate **370×69 at (634,896)** at distance `0,0`, then **336×69 at (753,952)** after the real focus round trip. Both captures inspected; `/tmp/nogui-w12-scaled-real-ime-20261005/log/`. | **None outstanding in this native X11 composition scenario.** SDL3's X11 backend reports a content scale but does **not** scale window pixels or the XIM anchor by it, so a non-1× display scale is not itself evidence of a scaled candidate anchor. A mid-run scale **transition** at non-1×, non-1× Wayland and CJK font coverage remain open and are not inferred here. Shared clipboard is established separately…
| T08 | W12 | `core clipboard.zig` (`Item`, `Offer`, `Selection`, `Capability`), `text_input.zig` `Clipboard`, `host clipboard.zig` | **2026-10-03:** current real-font W12 consumer passed thirteen native steps and five consumer checks under the exact approved private-X11 restore scope. Selected multibyte paste replaced once; a second process read exact copy/cut bytes; CLIPBOARD/PRIMARY baselines restored before and after process retirement. Eight independent newline pairs, two CRLF pairs and read-only refusal without a clipboard/writer passed a separate actual model consumer. Evidence `/tmp/nogui-w12-current-native-clipboard-20261003/` and `/tmp/nogui-boundary-and-fd-broker-proof-20261003.json`. | **Ordinary focused-consumer clipboard/policy acceptance is established on Linux X11.** No user selection was touched. Wayland and other-target clipboards are not claimed. The user kept Neovim RPC/grid integration in the separate editor plan. |

#### R — Paint, canvas, assets and surfaces

| Gap | Pkg | Current source (N) | Proof on record | Unfulfilled acceptance |
| --- | --- | --- | --- | --- |
| R01 | W13 | `paint.zig`, `path.zig` and public custom canvas; `w13_canvas_smoke.zig` | [W13](2026-09-26-gpui-api-parity.md#w13--public-paint-and-canvas): dated filters retained. Current windowless capacity arm passed 443/443; private-X11 two-frame arm passed 482/482. Both actual GPU images were inspected. | Fixed-backend path/pixel, capacity-refusal/recovery and old/current ownership acceptance met on Vulkan/GTX 1660 Ti. No cross-platform pixel identity claimed. |
| R02 | W13 | Authored sRGB versus Oklab, gradient stops, palette and pattern lowering | Same W13 runs: independent 0.25/0.75 stops, palette/sRGB twins, gradient direction, pattern phase and opacity passed original tight Oklab oracles. | Fixed-backend acceptance met. |
| R03 | W13 | Independent radii, borders and structured shadow arrays | Same W13 runs: asymmetric corners, dashed/dotted sides, inset/outset blur and two distinct warm/cool shadow lobes passed. The mapped second commit retained original path/dash/shadow data while revised pixels changed. | Fixed-backend acceptance met, including material-partition refusal without submission and same-slot recovery. |
| R04 | W13 | Render-only affine transforms, clip order and committed hit geometry | Same W13 runs: translated ink left the element's authored box while total input remained there; rotated/vacated/outside-clip probes and previous-frame ownership passed. The strip row's implicit fill was corrected without renderer or tolerance changes. | Fixed-backend pixel and hit-box acceptance met. |
| R05 | W14 | Asset loaders/keys, texture registry and cache ownership | [W14](2026-09-26-gpui-api-parity.md#w14--assets-images-svg-and-external-frames): current 80/80 filtered checks and private-X11 102/102; two real local HTTP fetches/serves, dedup, invalidation, root refusal, budgets and Oklab pixels. Mapper-refusal regression protects two-frame registry ownership and exact descriptor release. | Linux acceptance met. Recorded drivers are Wayland and X11 on one GPU. |
| R06 | W14 | `ImageView`, `ImageSequence`, caller-owned `FrameRequests`, decoders and uploader | Native 102/102: three deadline commits with authored colors, zero idle commits, explicit owner retirement, contain/cover/fill, grayscale, fallback and stale-generation refusal. Current draw/clock publication merges into the existing host deadline. | Linux acceptance met. Removal must retire a borrowed request before freeing sequence storage; neither source nor host automatically prunes it. |
| R07 | W14 | librsvg/Cairo and `SvgRasterCache`; incomplete demo parser removed | Current 160×68 specimen: 11/11 independent CPU and native GPU probes, including Q/T, C/S, arcs, group transforms, local `use` and transparency; CPU-only 43/43. Current cache regressions prove stable pins, `EntryPinned`, transactional OOM/budget refusal and growing/shrinking replacement. | Full Linux specimen/cache acceptance met. Ambient external resources remain refused. |
| R08 | W14 | Owned external-frame descriptor, CPU upload and conditional macOS adapter | Dated and current W14 proofs retain frames through GPU/registry retirement, return descriptors once and refuse stale generations; current mapper-refusal tests cover the rejected admission path. | Portable Linux descriptor/upload acceptance met. Conditional macOS native-import compilation/runtime remains under W23, unestablished on this Linux host. |

#### P — Application host, windows and native services

| Gap | Pkg | Current source (N) | Proof on record | Unfulfilled acceptance |
| --- | --- | --- | --- | --- |
| P01 | W07 | `host application.zig` lifecycle and hooks, `host sdl_session.zig`, `w07_host_smoke.zig` | [W07](2026-09-26-gpui-api-parity.md#w07--application-and-multiwindow-host): current 44/44 filter, real X11/Wayland two-window and external-loop runs, close/task/slot refusal and clean Session/GPU retirement; two-window injected construction refusal reported no leak. | Linux lifecycle acceptance established. Other-target runtime remains P15. |
| P02 | W07 | `host application.zig` generational slots, close veto, last-window policy | Same [W07](2026-09-26-gpui-api-parity.md#w07--application-and-multiwindow-host) entry: reopened slot 0 at generation 2 rejecting generation 1, veto holding the window, `ran=true delivered=0` for the closed window and `delivered=1` for the survivor | **Open inside W07:** nothing on the Linux path; this is the best-evidenced W07 row. macOS and Windows multiwindow runs remain absent under P15. |
| P03 | W07 | `host display.zig`, `window_contract.zig` `DisplayId`, `ObservedState`, `divergence` | Current [W07](2026-09-26-gpui-api-parity.md#w07--application-and-multiwindow-host): private output scale 1→1.25, pixels 900×620→1125×775, unchanged logical extent, raw/routed real pointer agreement and committed probe hits at both scales; platform-accepted candidate generation 26 matches App, zero extent mismatches. | Linux DPI/pointer/render and candidate-area alignment established; an actual IME candidate window remains W12. Unavailable global position still returns `UnsupportedGlobalPosition`. |
| P04 | W07 | `host window.zig`, `window_contract.zig` `RequestedState`, `Borders`, `Divergence` | Current [W07](2026-09-26-gpui-api-parity.md#w07--application-and-multiwindow-host): owned Openbox/X11 observed minimized=true/visible=false then restored minimized=false/visible=true within deadline; left-only resize leaves the peer unchanged. | Linux minimize/restore acceptance established on X11. Wayland reports the unsupported observation honestly; other targets remain P15. |
| P05 | W18 | `host dialogs.zig`, `host linux/portal.zig`, `w18_dialog_smoke.zig`, raw Linux D-Bus transport | [W18](2026-09-26-gpui-api-parity.md#w18--desktop-services): **2026-10-03** fresh linked gate 70/70 total tests; spec-correct serial/request correlation and early cancellation pass. The same current consumer completed all three approved real GTK endings—synthetic selection, cancellation, live parent close—0/`observed`, no native faults, all owned processes retired. `/tmp/nogui-w18-current-all-chooser-endings-20261003.json`. Existing bounded unclosed-parent cleanup proof is retained. A real private broker also relayed a borrowed descriptor after UNIX_FD negotiation. **2026-10-03 continuation, private Wayland:** the same three endings were observed again on an owned private Niri/Xvfb `:4` fixture against the current mapped-parent executable `ebef0947c7df79c5fed45ac22c7aaac4`, all three verdicts `observed` in one invocation, wrapper exit 0, `commandMatchesRequest: true` from the `/proc` argv readback, zero survivors. Escape is the backend's own `aborted` result and is not remapped to cancellation; the real Cancel mnemonic (Alt+C) produced `outcome=cancelled`, and only the driving fixture changed. One earlier parent-close attempt failed correctly because no buffer was mapped on the SDL parent. `/tmp/nogui-w18-approved-wayland-runs/2026-10-03T18-44-24Z/result.json`. | Linux X11 **and Wayland** chooser selection/cancellation/parent lifetime and real broker FD transport are observed. **Still open:** approved external opening/revealing, desktop scheme registration and real file-manager drop. Stand-in descriptor tests are not desktop launch acceptance. |
| P06 | W18 | `host clipboard.zig`, `core clipboard.zig`, shared W12 clipboard adapter | Approved private-X11 whole text/1×1 PNG/typed-metadata item and independent PRIMARY proof retained. **2026-10-03** current real-font W12 caller rerun passed all thirteen numbered steps and five consumer checks: selected multibyte replacement once, independently read exact copy/cut bytes, and complete CLIPBOARD/PRIMARY restore. `/tmp/nogui-w12-current-native-clipboard-20261003/`; actual consumer image inspected. **2026-10-03 continuation, private Wayland:** one item offered text, a 1×1 PNG of exactly 67 bytes and a JSON metadata blob of exactly 37 bytes; `readItem` returned all three and both non-text formats matched their exact expected lengths; the whole item was restored; `supportsPrimarySelection` read `true`; and the independent `wl-paste --primary` reader exited 1 with `Nothing is copied` and 0 bytes both before and after, so the restore is independent rather than self-confirming. `/tmp/nogui-w18-approved-wayland-runs/2026-10-03T17-16-05Z/result.json`. | Linux **X11 and Wayland** synthetic item/PRIMARY ownership, ordinary W12 consumption and restore are established. The conditional macOS Find pasteboard remains unobserved. No user clipboard was touched. |
| P07 | W18 | `host application.zig` SDL drop routing; `open_url.zig` launch queue, `SchemeRegistry`, `UrlDispatcher`, `LaunchHookAdapter`, `DropPhaseTracker`; portal URI/file descriptor client | **2026-10-03** 70/70 total W18 tests include missing/foreign replies, Request cancellation versus failure, actual descriptor target identity and allocator-clean repeated case-insensitive scheme registration. Current native observation arm delivered buffered synthetic ingress once through four extra pumps and refused an unapproved external launch. `/tmp/nogui-w18-current-focused-menu-proof-20261003.{json,log}`. | **Open:** actual file-manager drop, external open/reveal and desktop scheme association were not authorized. In-process registration is not OS association. Conditional macOS/Windows service paths remain unbuilt under P15. |
| P08 | W18 | `host menus.zig`, `action.zig` live weak-owner check query; `macos/menus.zig`, `windows/menus.zig` | **2026-10-03** current owned-X11 observation arm showed focused enabled/checked state, a disabled checked action, expired owner's unchecked state and a model-only check change with zero invocations. Explicit dispatch reached the live model once. The linked 70/70 gate includes alias and re-entrant binding-compaction regressions. `/tmp/nogui-w18-current-focused-menu-proof-20261003.{json,log}`. **A later same-session rerun** of `zig build w18-dialog-smoke -j1 --summary all -- --native-observations` on the private X11 fixture completed **13/13 build steps**, exit 0, and recorded focused state reads with **zero invocations**, `observe` and `system.quit` dispatching **once** each, an unrelated context reporting **unavailable**, and a disabled row with **zero invocations**; `/tmp/nogui-final-private-x11-90MA5t/result.json`. The menu and `SystemAction` entries resolve enable/check/dispatch through the **same W10 action registry** the app already uses — one registry, no parallel menu policy. | Shared focused enable/check/dispatch contract established on the same registry as ordinary actions. Linux global/dock menu support reports **unavailable** and no desktop menu was shown or claimed; this arm proves the in-process bridge, not an OS menu bar. Real other-OS native menu/dock/recent/jump-list acceptance remains under P15. |
| P09 | W10 | `host keyboard.zig`, `host linux/keyboard_layout.zig`, `host cursor.zig` | [W10 native proof, 2026-10-01](2026-09-26-gpui-api-parity.md#w10--actions-bindings-and-keyboardcursor-services): mapped private Xvfb, actual pointer enter/motion, hide/show and hide-until-move; actual US→German identity, one layout callback, generation 0→1 and scancode 28/29 labels Y/Z→Z/Y; exit 0 | **Linux X11 scenario established.** Other-target native evidence is not claimed. No user desktop setting or synthetic SDL event was used. |
| P10 | W18 | `host preferences.zig`, `macos/preferences.zig` | **2026-10-02, real owned X11:** `w18-dialog-smoke --native-observations` exited 0. SDL driver and compositor type agreed; unobserved theme/button/scrollbar/thermal/VRR/scanout/motion signals stayed null. Owned config/data/temp folders, executable-directory base path and adjacent auxiliary lookup were checked against the filesystem. | Linux observation/path contract established, including truthful optional absence and caller-owned path copies. Application motion override is not an OS signal. Conditional macOS preference/gesture SDK runtime remains under P15. |
| P11 | W19 | `host notifications.zig`, `linux/notifications_dbus.zig`, target providers | Earlier 65/65 Debug/ReleaseFast ownership/error checks retained. **2026-10-02:** approved private Dunst replacement/dismiss, dead-owner suppression and real bus-loss runs exited 0. A further real action run displayed one replaced toast, captured/inspected it and used Dunst's own action command: exactly one `origin=pump action="w19-acknowledge"`, two closures, zero tracked and dropped entries, exit 0. | Linux real identity/replacement/dismiss/action and transport-loss paths are observed. Dead-owner native proof currently covers its later daemon response; portable regressions cover stale-owner action routing. Windows COM compilation/runtime and macOS queue runtime remain target gates. |
| P12 | W19 | `host credentials.zig`, `linux/credentials_secret_service.zig`, target providers | Earlier serial-correlated waits and wiped creator-owned serialization proof retained. **2026-10-03:** the real private GNOME-keyring round-trip wrote/read/deleted 81 synthetic bytes and confirmed absence; policy denial returned `denied` followed by `not_found`; explicit provider shutdown returned `provider_failed/disconnected`, all exit 0. **Unexpected in-flight loss is now separately observed:** after an initial `not_found`, the controller confirmed the owned daemon paused in state `T`, correlated the consumer's unanswered `SearchItems` by sender `:1.7`, serial `4` and consumer PID, then killed only its private broker. The pending result was `provider_failed/io_error` exactly once, with zero late completions, `busy=false`, joined worker and released provider; controller and consumer exited 0. Only `OpenSession` and two `SearchItems` calls reached Secret Service, the new store stayed empty, and no child survived. Evidence `/tmp/nogui-w19-inflight-loss-scanned-env-20261003/evidence/summary.json` plus the retained round-trip/denial/shutdown records. The real locked fixture still stopped at an unanswered Unlock prompt. | **Open:** locked-item consumer read/cleanup, interactive prompt outcomes and other-target stores. Unexpected in-flight loss is closed by the new native proof, not by relabelling the earlier requested shutdown. The locked item remains because cleanup also needs the unapproved prompt. Approved missing-namespace reads used service `nogui-w19-inflight-loss`, new account `w19-smoke-mus0imkdgm35`, and a new private store; no existing user secrets were touched. A private keyring UI agent and interactive prompt approval remain absent. |
| P13 | W20 | `host capture.zig`, `linux/capture_portal.zig`, `linux/capture_pipewire.zig`, `w20_capture_smoke.zig`, `windows/capture.zig` | [W20](2026-09-26-gpui-api-parity.md#w20--screen-capture): earlier provider selection, epoch, backpressure and exact-once release proofs retained. **2026-10-03:** the old 81/81 filter excluded eleven runner regressions. The corrected serial build passes 106/106 tests, including thirteen runner regressions. A window stream answering a monitor-only request failed before repair and now returns `mismatch`; known-empty metadata refuses, a mixed request permits a reported subset and unknown metadata stays `<unproved>`. The structural-zero post-stop probe was removed. Actual default runs select and capture nothing. **The private-fixture runtime-library resolver is repaired and proved harmless, exit 0:** it located the library the consumer opens as `std.DynLib.open("libpipewire-0.3.so.0")` at `/nix/store/h06qaqbc0llyr2vpqrj9ia2dpwgw120m-pipewire-1.6.8/lib/libpipewire-0.3.so.0`, real file `…so.0.1608.0`, 1,126,128 bytes, SHA-256 `12131ad16fac5d978266c15243b3a307e70e915af404074fb156447fa1c80430`, ELF type 3 (ET_DYN), SONAME `libpipewire-0.3.so.0`, `DT_NEEDED libc.so.6` plus a glibc `DT_RUNPATH`; 14 of 16 declared providers resolved, with the chooser and portal front-end deliberately unresolved until an exact CLI path is named. The operator's `LD_LIBRARY_PATH` was printed for context but ignored for resolution, inheritance and merging. That arm started **no** provider, made no `ScreenCast` request, showed no chooser, captured nothing and requested or granted no permission. **2026-10-03 continuation, provider-free fixture fault modes:** bounded consumer retire is `GREEN`/exit 0, the exited-leader group-descendant mode is `OK`/exit 0, the no-approval consumer is `GREEN`/exit 0, and the foreign-birth unknown-group mode is `REFUSED`/exit 0 — the correct green answer there, because after the owned pid/pgid/session/start-time were swapped with a stranger the guard recorded that the group was not this run's to signal, signalled nothing, and the stranger's group settled with `zero_surviving_members`. A separate later-than-15 s timing fault is green: the timing protocol arrived at 17.5 s with `childAliveUntilAnswer: true` and no premature retirement, and a refusal ended waiting without granting approval. Every one of these states `nativeProvidersStarted: false`, `captureOccurred: false` and `realApprovalEstablished: false`. **2026-10-04:** the single approved capture ran. `CreateSession` and `SelectSources` really went out with `types=1`, `multiple=false`, `cursor_mode=2` and `persist_mode=0`; the private viewer handshake was verified by pid, XID and a 108-byte mode-`0600` uid-1000 `nlink`-1 acknowledgement carrying the run's own nonce; and the consumer ended `CaptureDenied` with exit 3, no validated stream and no production PPM. | **Open inside W20:** live capture is still **unobserved**, and the reason is now a run rather than a non-event. A portal request really happened and the private viewer really appeared; what did not happen is a validated stream, a preview, a captured frame or real provider retirement. The chooser witness is still missing for a harness reason — the chooser's own `slurp` trace existed but this repository's parser rejected libwayland-client's `{Default Queue} ->` prefix — and the corrected parser has only been replayed against the captured trace, not run against a fresh chooser. The chooser/front-end paths are selected. The single first capture is **spent**: no automated chooser answer and no second capture are approved, and a further attempt needs renewed point-of-risk approval at the time it is made. Six `invalid_pidfd_reply` refusals also remain in this project's own teardown path. Provider contracts, the resolver proof and the harness fault modes do not prove live capture. |
| P14 | W22 | `linux/popup_real.zig`, `native_input.zig`, `layer_shell.zig`, `layer_shell_real.zig`, `decorations_real.zig`, `wayland.zig`, noapi surface attachment | Earlier native records retained. **2026-10-03:** 63/63 total filtered tests, including failing-before repeated-ack repair. Strict owned `layer,popup-x11,popup-wayland` all PASS; `/tmp/nogui-w22-scoped-native-acceptance-20261003/evidence.json`. X11 proves actual server grab/outside press and immediate parent-close ungrab. Wayland proves parent-surface serial carried by the grab, distinct once-acknowledged configure generations, real 180×120 noapi buffer, compositor `popup_done` and subsequent role destructors. Transformed `Flipped180` input proves empty/bounded/restored delivery, with no fixture transform override; reservation changes client height by exactly 64; output resize produces a 976×128 configure/ack/buffer and exact restoration. Owned GPU Weston proves missing layer global with seven ordinary toplevel frames; `/tmp/nogui-w22-layer-output-complete-20261003/weston/wayland-no-layer.txt`. Fresh Sway closed/removal scenarios both pass; `/tmp/nogui-w22-terminal-VGqLoj/logs/evidence.json`. Detached-child timeout cleanup also retires every owned process, with zero unattributed survivors. **Two further owned-niri runs cover teardown and stale metadata.** *No-press teardown* (`/tmp/nogui-w22-no-press-final-20261003/`): an approved grab with no user-event serial refused `MissingSeatSerial` and left `has_grab=false pending_serial=null state=positioned`; the parent reached `PARENT-PRESS-READY`, then the run ended at `NoRealParentPress` with `no_input_injected=true`, `readiness_before_refusal=true`, `native_fault=false`, `child_proc_gone=true` and a healthy compositor afterwards. *Stale-metadata guard* (`/tmp/nogui-w22-stale-seat-final-20261003/evidence.json`): a **real** parent press delivered `serial=11` with provenance `wl_pointer.button` on that parent's own `wl_surface`; after the seat advertisement record was invalidated the armed grab refused `MissingSeatSerial` with `shared_display_error=0` and `pending=false`, parent close reported `dismissed` / `parent_closed` / `has_grab=false` / `x11_grab_held=false`, and native exit was 0 with orderly `Application`/`Session` teardown and the pointer released. | **Linux P14 native acceptance is met** by the retained scoped set plus the separate actual Sway terminal verification; healthy PASS is not credited with events the runs did not request, and the Sway scenarios supply those. **Evidence scope only:** the stale-metadata guard was exercised against a *simulated* withdrawal — `actual_compositor_global_withdrawal` and `compositor_global_withdrawal_observed` are both `false`, so these runs did not witness a real `wl_registry` `global_remove` for a seat. That bounds what the evidence shows and creates no new acceptance criterion; no mandatory seat-withdrawal or IPC-reservation oracle is added here. No generic system-menu or other-platform runtime parity is inferred. |
| P15 | W23 | `macos/`, `windows/`, `mobile/` target adapters and shims. Native E01–E05 consumers are `w23-macos-smoke`, `w23-windows-smoke` and `w23-mobile-smoke`. `diagnostics.queryGpu` supplies E06 metadata through noapi. | [W23](2026-09-26-gpui-api-parity.md#w23--conditional-platform-extensions-and-adapters): the prior portable `api-w23` gate passed 149/149. Current Linux E06 proof creates/submits a real 4×4 noapi texture without a surface, matches GTX 1660 Ti `0x10de/0x2191` and driver `595.104.02` to kernel observations, and records zero diagnostic NUL bytes. The Windows field's production-font/App gate passes 5/5, including directional Unicode selection, empty/full hit-testing, grapheme/word edits, pointer blur/refocus and caret agreement before repaint. The actual portable Windows CLI exits 0 and reports no target provider or window. | **Open:** native SDK compilation and E01–E05 execution on macOS, Windows and mobile, including target screen readers and approved services. Portable helpers and unavailable probes are not target acceptance. Owner-authorized nogui/noapi MIT grants are resolved. |

#### A — Accessibility

| Gap | Pkg | Current source (N) | Proof on record | Unfulfilled acceptance |
| --- | --- | --- | --- | --- |
| A01 | W21 | `App.semantic_publication`, `semantics.zig` roles, state, text geometry, `VirtualList`, relations, `active_descendant` and `modal`; `accessibility.zig` | [W21](2026-09-26-gpui-api-parity.md#w21--semantics-and-native-accessibility) retains the dated tree and role evidence. **2026-10-01:** the private client read five virtual rows from 250000 logical rows, selected an unselected row through AT-SPI, and confirmed exactly one model callback plus native read-back. Four reactivation cycles preserved all 15 IDs, names and parent relationships. **2026-10-03:** an actual public App/Publisher consumer proved first-frame annotation, failed-frame retention, stable identity on recovery and semantic focus matching Core fallback across generations 1–3; `/tmp/nogui-semantic-transaction-proof-20261003.json`, exit 0. Hidden-action and pending-stage failure regressions were reproduced and repaired. Unsupported duplicate `set_size` and inert `popup_for` fields were removed. **The same date also ran the native seam itself** on the private X11 fixture: `--native --hold-ms 1500 --ppm …/frame.ppm` committed and presented **5 frames, generations 1–5, at 520×640** through the public `App` path, with **matching five-row publication and paint**, a zero measured caret delta and a headless arm of **27/27**; the converted `frame.png` was inspected and `frame.ppm` is 520×640. | Screen-reader modality, speech and keyboard/action acceptance remain open. `modal` is expressible and reaches the bridge today (`Draft.modal` → `states.modal` → `FLAG_MODAL` → `set_modal()`), so the old "modality cannot be expressed" finding no longer applies; what remains is only that **no real screen reader has observed it**. **2026-10-04:** a real screen reader did run, on an owned private bus, and was credited with no announcement at all — 0/6 roles with real audio — so this cell is open on evidence, never on expressibility. *(The keyboard half of that older sentence is superseded: the latest run really did move model counters from physical Space/Return activation, slider keys, radio movement, printable text and caret movement. The audio credit did not move.)* The native seam run proves first-frame publication, layout and ink on a real window; it activates no adapter and no screen reader, so it is not a screen-reader observation. |
| A02 | W21 | `App.semantic_publication`, `FrameOutput.semantic_snapshot`, `host accessibility.zig`, `system_bell.zig`, `application.zig`, owned `accesskit_bridge/`, target adapters | **2026-10-01:** bridge 19/19 Rust tests, unlinked host `api-w21` 69/69, default linked consumer 27/27, and real private AT-SPI client **67 passed, 0 failed**. Native UTF-8 text selection/caret editing and virtual-row selection through `Selection.SelectChild` reached the model exactly once. Four full-tree reactivation rounds preserved the hierarchy. The complete validation-enabled run contained no VUID or panic and retired the GPU surface before its SDL window. The earlier X11 bell and negative Wayland capability evidence remains valid. **2026-10-03:** semantic staging and commit now belong to the App frame transaction; AT-SPI, Windows and mobile callers consume the committed snapshot rather than publishing post-hoc. The standalone core transaction consumer exited 0. The native first-frame seam run committed and presented **5 frames, generations 1–5, at 520×640** with matching five-row publication and paint, a zero measured caret delta and a headless arm of **27/27**; adapter state stayed `inactive` and screen-reader state `false`. **Modality is expressible in current source**, which reverses the 2026-09-29 finding: `Draft.modal: ?bool` (`semantics.zig`) writes `states.modal`, and the owned bridge maps `FLAG_MODAL` to `set_modal()`. | The user renewed isolated W21 AT-SPI/Orca authorization on 2026-10-03, and that approved run **has now run** (2026-10-04) on an owned private fixture and retired with every owned PID gone; it had not started before that date. What it still does not deliver is named: **no Orca announcement credited with real audio for any of the six roles** (`six_roles_spoken_with_real_audio` is 0/6, because each attributed utterance's own capture window never advances), and **eight failed non-text client steps** — the `Value` setter call, a bogus read-only-progress gate that attempted no mutation, a virtual-row comparison that read `selected_count` 1 and `index` 2 as two child counts, the absent `Add`/`Remove` named actions, a real SDK defect where a disabled node still published `Enabled`/`Sensitive`, and the absent reactivation named action. The recorded reason the composition interface was called unavailable is **retired twice over**: the pins are now `accesskit 0.25.0`, `accesskit_unix 0.23.0` and `accesskit_atspi_common 0.20.0` whose Unix provider **does** expose `SetTextContents`, and the latest run really issued all three whole/empty/restore writes, reading each whole value back at 21/0/7 characters with `getNSelections` 0 and exactly one model write each. Native keyboard activation, slider, radio, text and caret movement also held against real published counters, and the reader's own object navigator reached the read-only indicator and generated its name and value. Composition through the partial methods this provider does not implement is still unobserved, and those methods were named and never called. Target-native accessibility remains unproved on every non-Linux target. The negative Wayland bell result (`available=false`, `request=unsupported` on an owned compositor advertising no `xdg_system_bell_v1`) is a **truthful supported-limit report, not a failed gate**; the positive Wayland case is likewise a recorded platform limit, not an added acceptance item. |

The same-date core progress/radio repair adds no native credit. Its core filter passed 41/41 tests. The public App/Publisher consumer preserved progress identity across a Unicode caption change and published exact numeric values and fractions. Ordinary radio activation and deselection published both checked states correctly. Evidence: `/tmp/nogui-progress-radio-proof-20261003.json`. Real progress announcements and new radio state readback were owed the approved private run, which **had not started on 2026-10-03** and did run on 2026-10-04. *(Updated 2026-10-04 for the latest run: the earlier arm recorded that
`progress_name_spoken_through_stock_object_navigation` was not attempted because the
keyboard never reached `W21 Slider`. The 11:16 run did attempt it — one stock
`Orca+Control+Left` from `W21 Slider` at sibling 7 reaches `W21 Progress` at
sibling 6, and the reader's own log produces `_generate_accessible_name:
[W21 Progress]`, `_generate_progress_bar_value: [30 percent.]` and
`Results: [W21 Progress, 30 percent.]`. It is still **not established**, because
`progress_value_announced_with_real_audio` remains 0/2 and neither submission
was attributed to this application's own `level`. The spoken form is real; the
owned audio is not. The 14:09 run attempts it again and is still not
established: `Insert+ctrl+Left` is handled as `Left` after 102 ms and presents
`[progress bar: 'W21 Progress']` with the model unmoved, but its reader log is
CRLF, the grab agreement does not parse out of it, and no fragment of its own
output was proved in the capture.)*

> **Superseded by the real-stack run recorded above (2026-10-04/05).** Everything above is the
> reading before the current evidence. On a full real native stack the interactive, role and
> settings criteria are now proved, together with **9 spoken utterances carrying real audio**, 50
> native utterances all lineage-owned on the real reader thread, 37 distinct fragments each with
> its own ACSS, 100 `reader_text` rows beside 100 `ssip_argument` rows, waveform identity proved
> for 9 with 41 explicitly not credited, and the wire paired 35/35 with zero unpaired and zero
> disagreements. What stays **unclaimed** is progress announced with real audio, progress name
> through navigation, reader navigation leaving the application untouched, and six-role audio at
> 4/6. Native full acceptance stays 18/22, and the positioned-composition prerequisite is
> untouched by any of it.

**How to read that numeric readback (2026-10-03 continuation).** The consumer
above reads the value back through the public host seam
`accessibility.Adapter.lastNumericValue(id)`, which returns an optional `f64`:
`null` for an absent node, `null` for a present node that published no numeric
value, and a **present `0.0`** for numeric zero. `Adapter.lastValue` is the TEXT
channel only and never carries a numeric range. The W21 smoke passed 32/32
headless on that date. All three of these results — the 32/32 headless smoke, the
41/41 core filter and the three-generation consumer — are **core and source
evidence**. None activated a native adapter, reached the accessibility bus or
produced speech, and this reconciliation does not credit them with any.

#### D — Tests, diagnostics and distribution

| Gap | Pkg | Current source (N) | Proof on record | Unfulfilled acceptance |
| D01 | W06 | `src/v7_test/context.zig`, `dispatcher.zig`, `testdata/sim/todo-increment.jsonl` | [W06, 2026-09-29/30](2026-09-26-gpui-api-parity.md#w06--deterministic-test-context) filter green **plus** the gate's real CLI JSON replay: `--sim testdata/sim/todo-increment.jsonl` exited 0, parsed frames 1/2/3 at focus `0/46/46`, `Counter: 0/0/1`, `0 of 2 done`. W06's gate was completed and accepted on that date | **None outstanding inside W06.** |
| D02 | W25 | `src/v7_frame/{offscreen,text_gpu,loader,native}.zig`, `src/v7/headless.zig`, public `src/v7_test/` real-font contexts; public `examples/parity` including `state_pair.zig` and `test_context.zig`; external `examples/consumers/offscreen` | Current [W25](2026-09-26-gpui-api-parity.md#w25--real-text-headlessoffscreen-consumers-and-examples): actual windowless/native paired exits 0, 64 equal model/focus/selection/semantic/geometry fields and 12 equal character pens/advances, both 320×220 GPU images inspected; three geometry mutations each fail and partial shader/native-host failures preserve original errors without reported leaks. The real CPU/windowless-GPU context consumer passes 20/20: pinned widths 10.172/42.078, Oklab L 0.35→0.55 readback and `LiveModels` release/retry teardown. Presented pinned-font field, decoded-image/SVG canvas and two-window shared-model consumers ran and retired their native resources. W11 retains the separate 1,016/1,023-check pixel specimen and prior dated caption evidence. | These examples establish actual rendering, model and lifetime behavior, not native platform input: scenario input is labelled synthetic. W12 IME and W16 full interaction acceptance remain separate; no assistive-technology claim follows from the examples. W26 clean packaged-consumer proof remains separate. |
| D03 | W24 | `inspection.zig`, `host inspector.zig`, `w24_inspector_smoke.zig` | [W24, 2026-10-01](2026-09-26-gpui-api-parity.md#w24--inspector-and-diagnostics): real Oklab/final-sRGB readbacks, 33 native presentations, overlay pick/input agreement and removal, both stale-handle forms, resolved style/restyle, clip rejection, semantic relationships and focus/capture round trips. The saved 520×520 headless image was inspected; surface-before-window teardown exits cleanly. | Inspector acceptance met on private Linux X11 / Vulkan 1.4 / GTX 1660 Ti. Pointer input is explicitly synthetic `App.handle`, not external ingress. Other target runtime is not claimed. |
| D04 | W24 | `perf_counters.zig`, `v7_demo/perf.zig`, `w24_perf_pair_bench.zig`, `tools/run_v7_perf.py`, `w24_inspector_smoke.zig` | [W24](2026-09-26-gpui-api-parity.md#w24--inspector-and-diagnostics): real-clock paired recorder proof plus native GPU queries, 31 written/read/attached and zero refused/unattached; headless 32/32 attached. Real task/action boundaries recorded four completions/six dispatches with bounded 8/4/4 retention and a 16-span GPU ring. Full 1828/1828 test gate is green. | Timing/collector acceptance met on the recorded backend. The paired benchmark remains load-contaminated (load 8–14), and neither arm passed its 120-FPS budget in any of 20 runs. No speedup or FPS claim is made. |
| D05 | W26 | `build.zig`, `build.zig.zon`, `README.md`, `docs/API.md`, `examples/consumers/{core_only,text_only,renderer,host,offscreen,test_support}`, `src/v7_frame/root.zig` | W01's dated external core-only proof and the 2026-10-01 renderer proof remain recorded in [W26](2026-09-26-gpui-api-parity.md#w26--distribution-and-full-acceptance). **2026-10-03:** canonical archive `nogui-0.0.0-CnwuaG3HQAKb0ToiHHC8yGLT3hYbbFZ2TdJxNqSYVCbV`, 6,761,650 bytes, was fetched from an empty cache and extracted to `/tmp/nogui-w26-clean-final-with-witness-20261003/package`. All six consumers passed from that package, each with empty local/global caches before its first command: core-only, text-only, renderer, test-support including its own tests, host on SDL dummy, and offscreen with 32 CPU and 1,016 real windowless-GPU checks. Eleven commands, zero failed consumers; the original controller's incidental wording failure and GPU-only continuation remain explicit. The manifest witness checked 92 declared paths and 39 required paths, with zero undeclared or missing files. An **owned synthetic exclusion file**, temporarily placed under `src/v7_host/accesskit_bridge/target`, was absent from the archive and then removed; this is not claimed as observed Rust build output. README, API guide, both owner-authorized MIT grants and four full font notices are packaged; all four notices match upstream bytes and SHA-256 with no normalization (`/tmp/nogui-font-notice-byte-proof-20261003.json`). The final Linux build passed 113/113 steps, 1,912/1,912 tests, 5,524 fixtures and 581 golden rows; explicit first-party formatting and 126 Python tests passed. | **Package proof and Linux aggregate are closed.** The hash identifies the archived proof, not the later documentation/formatting checkout. Other-target builds and native acceptance remain P15/W23; full W26 native acceptance still requires those SDK/OS/device runs, a **successful** live capture, the Secret Service locked-store read, the six-role screen-reader audio credit and the external-action scenarios. The Linux capture is no longer merely unapproved — the single approved capture ran on 2026-10-04 and ended `CaptureDenied` — so it is now unproven rather than unauthorized, and a further attempt needs renewed point-of-risk approval. The actual X11/GPU remount proof remains 34/34 steps with orderly teardown. |

### Cross-cutting acceptance limits

These are facts about the environment and about work still in flight. They are **not** a
blanket reopening of rows whose own package gate was already completed and accepted: a red
integrated gate elsewhere in the repository, and an absent other-OS runtime, do not retract
evidence a package already produced on this host.
1. **The final settled Linux gate is green.** On 2026-10-03 the parent ran
   `zig build test check fixture layout-check lint -j1 --summary all` with
   display variables unset, `DBUS_SESSION_BUS_ADDRESS=disabled:`,
   `NO_AT_BRIDGE=1` and `GTK_A11Y=none`: **113/113 steps**, **1,912/1,912 tests**,
   **5,524/5,524 fixtures**, zero unsupported, and **581 golden rows** matched.
   Both linters reported zero errors and warnings across **258 files**.
   Five project formatting failures were repaired; generated dependency copies
   were not changed. An invalid manifest-glob argument was replaced with explicit
   first-party paths, and the formatter and **126 Python tests** completed with
   exit 0. This retains the successful build result rather than claiming one
   uninterrupted shell pass. The actual X11/GTX 1660 Ti `--gpu-remount-smoke`
   remains **34/34 steps**; earlier 109/109 and 106/106 gates are dated history.
2. **Owned W07 DPI and host transitions are observed, and a non-1× IME candidate anchor
   is now observed too.** The private Niri output ran
   `1 → 1.25 → 1`: logical `900x620`, device `1125x775` at 1.25, pointer conversion
   `1 → 0.8`, and 119 presentations with no extent mismatch. The separate owned X11
   minimize/restore, peer-window isolation and resource retirement also ran. **2026-10-05:**
   an approved owned X11 output at `-dpi 120` reported `display_scale=1.2500` with
   `pixel_scale=1.0000x1.0000` and drove a real IME candidate window to its anchor at
   distance `0,0` (see T07 and W12). What is still NOT established is a **mid-run scale
   transition** observed by a running client on the X11 IME path: SDL3's X11 backend has no
   true HiDPI window scaling, so there is no X11 candidate anchor that a live transition
   could move.
3. **The complete private IME scenario passed.** One focused XIM context used one explicit
   `libpinyin` engine setter. Real preedit replaced UTF-16 range `11:13` once and committed
   with collapsed selection `13:13`. Wrapped/scrolling caret geometry and suppression
   outside the visible field passed. Real pointer blur cancelled composition.
   Focus return restarted input and opened another real composition.
   The final mapped candidate measured **306×65 at (753,951)** beside anchor **(740,951)**.
   The parent inspected its own capture and the full painted field.
   Window ownership, geometry and panel traffic establish attribution, not pixel differences alone.
4. **Desktop approvals are narrow and synthetic, and one of them has now run.**
    Owned Xvfb `:4` clipboard/PRIMARY mutation and restore, the exact W18 chooser
    target and private Dunst phases were approved and exercised. **2026-10-03
    continuation:** a second narrow approval covered private **Wayland** runs on
    owned Xvfb/private buses/private HOME, and it executed — a whole text +
    1×1 PNG + JSON metadata clipboard item with exact readback and restore, PRIMARY
    supported and read back through an independent `wl-paste --primary` reader that
    reported nothing copied both before and after, and all three real GTK chooser
    endings observed against the current mapped-parent executable in one exit-0
    invocation with zero survivors. See P05 and P06.
    Synthetic Secret Service round-trip/delete, denial and post-shutdown failure
    ran under `nogui-w19-smoke` and new `w19-smoke-*` accounts in private stores.
    The separate read-only in-flight proof used `nogui-w19-inflight-loss` and a new
    missing account; it made no write, delete or Unlock call. The real locked
    fixture stopped at an unanswered Unlock prompt. **Screen capture was approved
    once and that single approval has now been used.** The approved shape was
    exactly one first capture on an owned private Niri/Xvfb `:6` session with
    clipboard sharing disabled, one monitor and one stream, 30 frames, a
    15 000 ms post-approval budget, one PPM and a source a person selects
    manually. *(As of 2026-10-03 that capture had not started. It has since run:
    `CreateSession` and `SelectSources` went out on the real portal and the run
    ended `CaptureDenied` with exit 3, no validated stream and no production PPM.)*
    No automated chooser answer and no second capture are approved; a further
    attempt needs renewed point-of-risk approval at the time it is made. The
    `:6` viewer was preparation for that one capture, not new authorization.
    URL/scheme/open/reveal operations remain unapproved. Any unlock/security
    prompt needs separate interactive approval.
5. **Orca and the test AT-SPI setup have now run, and their acceptance remains
   unmet.** The earlier 2026-10-03 pre-run record correctly described the isolated
   W21 AT-SPI/Orca scope as **approved but unstarted**, not unapproved. It remains
   historical, not a statement about the whole date. The 2026-10-04 continuation
   records the latest real run on an owned private fixture:
   retired completely — private session bus, private accessibility bus with a real
   `at-spi2-registryd`, real private `org.a11y.Status.ScreenReaderEnabled=true`
   readback, private dconf settings, the configured `espeak-ng` module initialized, Orca 50.2 alive, an
   owned clock-paced `parec` capture proving `clock_paced: true`, real 520×760 window
   pixels on disk, and all 32 owned PIDs gone afterwards.
   *(That description is the earlier arm. The 11:16 run on the same private
   scope moved further: all three whole/empty/restore `SetTextContents` writes
   held with the platform reading each whole value back at 21/0/7 characters and
   `getNSelections` 0; Space and Return activation, slider keys, radio movement,
   printable text and caret movement each moved a real published counter; and
   the reader's own object navigator reached the read-only indicator and spoke
   its name and value. Eight non-text client steps failed in that run, and the
   client that ran them did enumerate this time. The 14:09 run supersedes both:
   its main client has no failures, its named-policy client passes 23/23, and
   `Insert+ctrl+Left` is handled as `Left` after 102 ms and presents the progress
   bar, with the untouched-navigation criterion still unestablished.)*
   Speech acceptance is **still deferred**, and that is why this bullet still
   binds: the run credited **0/6 roles with real audio**, because each attributed
   utterance's own capture window never advanced. Real synthesis and clock pacing
   are proved separately and are not in dispute; what is missing is audio
   *ownership* per role. This is real native evidence, but it is not
   screen-reader acceptance. A further run beyond that approved isolated scope
   still needs renewed direct approval, general continuation is still not
   authorization, and no normal desktop accessibility setting changed — the
   operator's own read `false` before and after.
6. **No macOS, Windows or mobile runtime.** No slice of E01–E06 has run on its own OS or SDK.
   `LinuxUnsupported`, a pure mock, an injected driver and a cross-compile are each
   explicitly **not** target acceptance.
7. **W22 stays bounded, and its evidence scope is stated.** The real noapi layer and
   ordinary surfaces render and retire cleanly. Zone `64 → 128` changes ordinary client
   height by exactly 64. Current nested output resize `1280x800 → 1024x768` has matching
   client configure/ack/buffer geometry, noapi target retirement/rebuild and exact
   host/output restoration. Owned Sway proved compositor-delivered `closed` and registry
   output removal, including presentation and teardown. Transformed `Flipped180` input now
   proves empty/bounded/restored delivery with no fixture transform override, and the X11
   popup arm proves an actual server grab, an outside press and immediate parent-close
   ungrab, so those three items are **no longer open**; the missing-layer-global refusal
   ran on a GPU-capable owned Weston. **Evidence scope, stated precisely:** the stale-metadata
   guard was proven against a *simulated* withdrawal — `actual_compositor_global_withdrawal`
   and `compositor_global_withdrawal_observed` are both `false`, so no owned compositor on
   this host delivered a real `wl_registry` `global_remove` for a seat and the runs report
   that they did not witness one. That is what the evidence covers, not an unmet criterion:
   P14's specified acceptance is the scoped native set plus the separate Sway terminal
   verification, both retained, and **no additional IPC reservation, exclusive-extent or
   seat-withdrawal oracle is required here.**
8. **Owner-license grants resolved on 2026-10-02:** Janis Gertulla explicitly authorized MIT
   for the original nogui and noapi code. Both grants are included in the source manifests;
   third-party licenses are unchanged. **Clean packaged-consumer acceptance completed on
   2026-10-03** — six of six consumers built from the canonical archive with empty caches.
   Per-target native release acceptance remains open.

### Scope that is deliberately not a parity row

The [Neovim editor plan](2026-09-25-code-editor-widget.md) and the
[localization plan](2026-09-25-drawctx-localization.md) keep their own goals. Their rules are
reconciled in the companion plan's *Existing-plan reconciliation* section and they contribute
**no** rows to the 66. They are unchanged by this section and this section adds nothing to
them.

On 2026-10-03 the user selected **Keep editor work separate**. The live W12/W18
clauses now exclude Neovim queueing, preedit overlay and RPC clipboard integration.
The existing editor plan retains those requirements. Its implementation is not
claimed here, and the dated 2026-09-26 audit rows below remain unchanged.


### Source findings raised for the parent, with evidence

These are observations from reading the tree during this reconciliation. None is fixed here
and none is a parity verdict; they are items the parent should classify.
1. **The five native harnesses are wired, compiled and each has a dated executed run.** `zig
   build w13-canvas-smoke` and `zig build w23-diagnostics-smoke` exist in
   [build.zig](../../../build.zig) (`w13_canvas_step`, `w23_diagnostics_step`) and both
   binaries are compiled into `check_step`; so are `w09-controls-smoke`, `w10-keyboard-smoke`
   and `w12-ime-smoke`. The 109/109 `test check lint` gate compiles all five against the
   current source, and each already has a real run recorded in its matrix cell with its own
   output — R01–R04 from the windowless 443/443 and native 482/482 canvas arms with inspected
   GPU images, E06 from the 4×4 noapi texture against kernel GPU observations, W09 from the
   mapped private-X11 Todo controller, W10 from the 37-presentation native Todo run, and W12
   from the current real-font private-X11/IBus and clipboard consumers. **No separate re-run
   of these five is owed**, and this section claims none beyond what those cells record. By
   contrast the eight `run-parity-*` steps **have** been run: the W26 record states all eight
   exit 0.
2. **`src/v7_host/root.zig` pulls all three target adapters into the Linux host test
   artifact** (`_ = @import("macos/root.zig"); _ = @import("windows/root.zig");
   _ = @import("mobile/root.zig");`, and `mobile/accessibility.zig` in turn imports
   `w23_mobile_test.zig` while `windows/root.zig` imports `w23_windows_test.zig`). That is
   why `api-w23` now names 129 blocks on Linux. It also means a green `api-w23` result is
   evidence about **contract logic on Linux**, never about macOS, Windows or mobile runtime.
3. **The reusable SDL native text-input adapter is in `src/v7_host/`, not the demo.**
   [window.zig](../../../src/v7_host/window.zig) `nativeTextInput` returns a
   `nogui.text_input.Native` with `nativeStart`, `nativeStop`, `nativeSetArea` and
   `nativeClearComposition`; `textInputActive` reads the state back from SDL; and
   `setTextInputArea` calls `sdl3.keyboard.setTextInputArea` → `SDL_SetTextInputArea`, refusing
   a non-finite area or cursor **before** SDL is called. `translateEvent` converts SDL
   `.text_input` and `.text_editing` into `.text_input` and `.composition` with a preedit
   phase, and [application.zig](../../../src/v7_host/application.zig) dispatches both after a
   window-id check and, after every successful frame, republishes
   `text_input.caretGeometry()` so the line box and caret offset reach SDL automatically.
   As of the 2026-10-01 reconciliation, a **real input method** and an observed
   candidate **window** were T07's missing pieces, not an absent adapter.
   **Superseded 2026-10-03:** real IBus composition and both attributed candidate
   windows were observed and inspected; see the T07 row. **Extended 2026-10-05:** the
   same scenario ran on an approved owned output reporting `display_scale=1.2500`, and a
   real candidate window was attributed at the anchor with distance `0,0`. CJK glyph
   coverage, a mid-run scale transition and other target runtimes remain open.
   The demo-owned
   [w12_ime_smoke.zig](../../../src/v7_demo/w12_ime_smoke.zig) and
   [w12_ime_ink.zig](../../../src/v7_demo/w12_ime_ink.zig) sit on top of that adapter.
4. **The public guide now exists at `docs/API.md`.** It covers allocator/borrow,
   thread, coordinate and error rules at the public module boundaries.
   W25's optional real-font/offscreen contexts have executable proof and the
   guide updates that followed it: the 2026-10-03 real-font native field,
   paired real-window, canvas-view and windowless-context runs recorded under
   W25, with the per-family tables in `docs/API.md`. CJK glyph coverage and
   other target runtimes remain open. Clean packaged-consumer acceptance is a
   separate fact and was completed on 2026-10-03; documentation presence and
   package acceptance do not substitute for one another.
5. **`semantics.Draft` gained `modal: ?bool`**, which reverses the 2026-09-29 finding that
   modality could not be expressed, and the value is wired all the way through:
   `Draft.modal: ?bool` writes `states.modal`, and the owned bridge maps `FLAG_MODAL` to
   `set_modal()`. No recorded run exercises it through a real screen reader **and
   observes it** — the 2026-10-04 renewal credited no announcement at all — so A01/A02
   stay open on that ground alone, and not on expressibility.
6. **`src/v7_demo/svg.zig` is no longer the incomplete parser** the baseline describes, and
   R07's reusable-surface question is **now closed rather than left open**. The demo file
   is a thin re-export of `nogui_host.svg` — `DecodedImage`, `SvgEngine`, `isAvailable`,
   `rasterize` and `max_viewport_edge` — plus its own float4-per-pixel upload writer
   `writeFloats`, its `pixelCount` helper, and the `coverageMask` colour map that drops
   hue and keeps alpha. It carries **no PPM writer**: the demo's PPMs come from
   `v7_frame.writePpm` over a presented frame, which is a separate path. The reusable
   boundary is `src/v7_host/svg.zig`, published as `nogui_host.svg` and already recorded
   in the API guide, so the demo file stays demo-side by design and no API redesign or
   relocation is owed. This closes a classification question only; R07's own cell still
   records full Linux specimen/cache acceptance, and nothing here reopens it.
7. **`build.zig.zon` `.paths` includes `README.md`, the API guide and four full font
   notices**, and clean packaging is now **verified, not assumed**. The owner-authorized
   nogui and noapi MIT grants are resolved. The canonical archive declared 92 paths with
   0 undeclared files and 0 missing declared paths, all four notices
   (`Inter`, `DejaVu`, `FiraCode`, `NerdFonts`) shipped with the authoritative text located
   and packaged earlier, each upstream source cited in `README.md`, and the generated
   AccessKit `target/` tree excluded and confirmed absent from the archive. **2026-10-03:**
   all four notices were then verified byte-identical to those cited upstreams with equal
   SHA-256 and no normalization
   (`/tmp/nogui-font-notice-byte-proof-20261003.json`). Nothing about notice provenance
   remains open.

### What this reconciliation does not do

The original 2026-10-01 source reconciliation ran no checks.
The dated 2026-10-02 and 2026-10-03 entries above record executed gates, native
observations and the clean-cache package run.

It also does **not** retract anything already accepted. Rows whose own package gate was
completed and accepted keep that status, and neither an unrelated red product elsewhere in
the repository nor an absent other-OS runtime reopens them. The 2026-10-02 red integrated
gate this paragraph used to cite is superseded by the green 2026-10-03 run. What this section
adds is the current reading: which items are open inside each package, what proof is dated to
when, and which environment limits still bound the result. The parent attaches the final
integrated proof and the runs currently in flight; a row closes when its own corresponding
check has actually run and been recorded.

### Remaining acceptance prerequisites, and whether each is actionable

This is the consolidated open surface behind the matrix cells. Every row below is either a
prerequisite the row itself names, a recorded approval, or a missing target SDK — **no new
oracle and no new oracle-shaped requirement is introduced here**. The completed
Linux gate and in-flight-loss proof below are recorded separately from open prerequisites.

| Prerequisite | Blocks | Actionable now? |
| --- | --- | --- |
| Final serial settled-source Linux build, corpus/golden, formatter and Python checks | every row's final integrated proof | **Complete as recorded** — 113/113 steps, 1,912/1,912 tests, 5,524 fixtures, 581 rows, first-party format clean and 126 Python tests; no native approval was inferred. These are the dated observations of that run. The 2026-10-03 continuation changed documentation only and re-ran no build, test, lint or formatter, so none of these counts is restated as renewed. A fresh 2026-10-04 canonical gate re-reached every leg green on the landed documentation and frozen source, including the legs the failed attempt never reached, and printed no aggregate Zig test count; it is recorded above and inferred no native approval either. |
| Unexpected **in-flight** Secret Service transport loss through an isolated missing-namespace consumer | P12, W19 shutdown/disconnect clause | **Complete** — actual unanswered `SearchItems`, private broker loss, exactly one `provider_failed/io_error`, zero late completion, worker join, empty store and no survivors; `/tmp/nogui-w19-inflight-loss-scanned-env-20261003/evidence/summary.json` |
| W19 real locked-item read and cleanup | P12 locked-store outcome | **No** — no private keyring UI agent exists and answering the `Unlock` prompt needs separate interactive approval |
| External URL launch, reveal, desktop scheme registration and real file-manager drop | P07, P10 | **No** — unapproved consequential external actions |
| W18/W19/W20 live scope confirmation per consequential action | W18, W19, W20 gates | **Partly discharged.** The approved private X11 W18/W19 scopes, the approved private **Wayland** W18 scope, the approved isolated **W21 Orca/AT-SPI** scope and the single approved **W20 first capture** have all executed; the W20 scope executed and still ended in denial, so execution is not acceptance. Anything beyond an executed scope still needs exact point-of-risk confirmation before it is performed. |
| Orca keyboard/speech session and any restart of the test AT-SPI launcher, bus or broker | A01, A02 | **Executed, acceptance still unmet.** The approved owned fixture attempts ran Orca and retired completely, and the latest run also produced real speech synthesis with a clock-paced 4,140,114-byte monitor. It credited **0/6 roles with real audio**: the reader's own CRLF log holds 102 `SPEECH OUTPUT` lines and 0 proved fragments. What that latest run did add is real: all three whole/empty/restore `EditableText.SetTextContents` writes held with `getNSelections` 0 and exactly one model write each; Space and Return activation, slider keys, radio movement, printable text and caret movement each moved a published model counter; the named-policy client passed 23/23 with two signed named-list activations and zero clicks; and the reader's own object navigator presented `[progress bar: 'W21 Progress']` while the application model stayed unmoved and the indicator stayed non-focusable. That navigation criterion is still unestablished, because the reader's grab agreement could not be read out of its CRLF log, and the CRLF ingress fix is source-only with its replay not yet run. The eight and five client failures recorded elsewhere here belong to the earlier dated runs, not to this one. **A restart outside the approved isolated scope needs renewed direct approval.** |
| Real compositor-driven `wl_registry` `global_remove` for a seat | **nothing** | **Not a gate item — evidence scope only.** The stale-metadata guard is proven against a simulated withdrawal (`actual_compositor_global_withdrawal: false`), so the runs report not witnessing a real global removal. The original P14 acceptance is met by the retained scoped run, the Weston missing-global run and the Sway `closed`/output-removal verification; this reconciliation adds no mandatory withdrawal or IPC-reservation oracle |
| macOS E01/E02, Windows E03/E05, mobile E04/E05 and E06 runtime, including target screen readers | P15, and the target-specific halves of P01–P14, A02 and R08 | **No** — requires the target OS/device and SDK; `LinuxUnsupported`, mocks, injected drivers and cross-compiles are not substitutes |
| W21 `EditableText` composition observed by a screen reader | the A02 cell's own recorded condition | **No — and now for a third, different reason.** The A02 cell used to say the pinned AccessKit SDK exposes no `EditableText` interface; that premise was **retired** when the pins moved to `accesskit 0.25.0` / `accesskit_unix 0.23.0` / `accesskit_atspi_common 0.20.0`, whose Unix provider **does** expose `SetTextContents`. It then stayed open because no whole-value write had ever been observed. *(That reason is now retired too: the 2026-10-04 run made all three whole/empty/restore writes and read each whole value back at 21/0/7 characters with `getNSelections` 0 and exactly one model write each.)* What remains open is **positioned native `EditableText` composition through the published semantic model**, which is this table's **stricter standing criterion**: whole-value `SetTextContents` alone does not close it, an SDL-side IME run does not close it, and the broader W21 Gate wording does not widen it. The parent has appended its own flat task, `Implement and verify positioned native EditableText composition through the published semantic model`, so the row is tracked rather than merely noted. **The wire facts are now derived from the pinned source rather than guessed.** `org.a11y.atspi.EditableText` has six members — `SetTextContents`, `InsertText`, `CopyText`, `CutText`, `DeleteText` and `PasteText` — and the names an earlier revision recorded, `insertTextAtPosition` and `deleteTextBySelection`, exist on no wire, in no specification and nowhere in this repository; that seven-name enumeration was wrong and is withdrawn. The pinned adapter wires only `SetTextContents`, and the other five answer `org.freedesktop.DBus.Error.NotSupported`, so a client sees a loud error rather than a silent `false`. Inside one call the units differ: `InsertText.position` is a character offset while `InsertText.length` is a **byte upper bound** on how much of `text` to insert — not a character count and not a delete count. No `EditableText` member carries a spec-mandated caret result, which is verified silence in the specification rather than an omission here. The obstacle sits in the pinned dependencies rather than in this repository: no AccessKit `ActionData` variant pairs a text offset with text bytes, one request carries exactly one such variant, and `accesskit_unix` is checksum-locked and not vendored. The pinned signatures confirm that shape — `insert_text(position: i32, text: &str, length: i32)` and `delete_text(start_pos: i32, end_pos: i32)`, with `length` a separate `i32` from the string rather than a delete count — so a negative offset or bound widens and has to be refused rather than clamped. **None of this downgrades the criterion:** positioned composition stays owed, the source work comes first and a fresh native approval follows it. **No new core API is verified here:** the positioned-edit core, host, model and Unix-provider units are in flight and not landed, and no native carrier for a client message id has been built or run |
| The conditional macOS Find pasteboard (P06) and Wayland minimize observation (P04) | **nothing** | **Not a gate item.** These are the cells' recorded *conditional / truthfully-unsupported* platform facts, not unmet Linux requirements. **Wayland clipboard selection is no longer in this row:** it was observed on 2026-10-03 (see P06), so only the macOS pasteboard and the Wayland minimize observation remain conditional platform facts |
| IME candidate transitions at non-1× scale | T07's and P03's stated inference limits | **No — and this one is owed, not merely un-inferred.** The cells decline to infer it because producing it needs a scaled candidate observation outside the 1× scenario, which answers actionability from this host rather than obligation. The parent has decided the criterion **is owed** and appended its own blocked item, `Observe a real IME candidate transition under non-1x scale in a freshly approved owned fixture`. It is blocked on the renewed native approval exactly like every other fixture-bound observation here, and nothing in this document substitutes for it |
| CJK font coverage | T07's and P03's stated inference limits | **No new CJK scope — and the distinction is now explicit.** This row is about the library's **caller-provided font mechanism**, not bundled coverage: an application registers the faces it renders, and no bundled CJK face is promised or owed by it. The 2026-10-03 private-X11/IBus runs that reported missing-glyph boxes for CJK absent from the pinned face recorded that mechanism behaving correctly, not a gap. One operational consequence survives: a fixture that wants **inspectable glyph pixels** must register a CJK face for that run. That is a fixture requirement, not a product feature, and it opens no new CJK acceptance row |

The parent owns every executable gate. This table records prerequisites only; it runs no
command, approves nothing, and reopens no completed criterion.

## C — Ownership, contexts, effects, and scheduling

Evidence entry points: [N App](../../../src/v7/app.zig), [components](../../../src/v7/component.zig), [state](../../../src/v7/state.zig); [G contexts](../../../../github-zed-industries-zed/crates/gpui/src/app/context.rs), [entity store](../../../../github-zed-industries-zed/crates/gpui/src/app/entity_map.rs), [executor](../../../../github-zed-industries-zed/crates/gpui/src/executor.rs).

| Gap | Current deficiency and required capability | Source evidence | Primary package |
| --- | --- | --- | --- |
| C01 | **Missing:** owned typed models, strong/weak and erased handles, reservation/insertion, checked read/update, release observation. Borrowed components are not owned models. | G `gpui.rs:164–245`, `app/entity_map.rs:113–171,244–336,411–509,569–620,738–826`; N `component.zig:20–143`, `app.zig:183–203`. | W03 |
| C02 | **Partial:** contextual model/window access and typed listeners; mount a root once and replace it explicitly. Current frame/event calls repeat root type and pointer; `App` also recognizes a magic `frame_count` field. | G `app/context.rs:20–59,247–284`, `gpui.rs:252–305`; N `app.zig:566–589,621–634`, `callback.zig:10–61`. | W03 |
| C03 | **Partial:** distinguish copyable local frame state from persistent resource ownership. Current shallow arena copying is useful but is not a resource-owning state store. | N `state.zig:132–164`, `drawctx.zig:916–928`; G `app/entity_map.rs:569–620`. | W03 |
| C04 | **Missing:** typed observe/emit/subscribe, cancellation, weak owner binding, release observers, self-unsubscribe and reentrant delivery rules. | G `app/context.rs:61–189,228–271,763–779`, `subscription.rs:147–194`; N `callback.zig:10–61`. | W04 |
| C05 | **Missing:** scoped typed globals, observable updates, coalesced notifications, and post-update deferred effects. | G `app.rs:1023–1046,1560–1658,1887–1988`; no equivalent found in N core/runtime/demo searches. | W04 |
| C06 | **Missing:** foreground delivery, background tasks, explicit task ownership/cancellation, timers, timeouts and scoped completion. Do not promise foreground priority ordering: GPUI ignores that priority. | G `executor.rs:9–37,80–167,269–369`, `app/async_context.rs`; N `runtime.zig:13–47` only exposes GPU lifecycle values. | W05 |
| C07 | **Partial:** request-frame/invalidation/deadline contract, dependent-window refresh and sleeping host wakeup. Drawing explicit frame events already works. | G `app.rs:1023–1107`, `window.rs:2338–2345`; N `app.zig:504–507,678–704`, demo frame loop. | W05 |
| C08 | **Partial:** documented frame transaction and teardown across failed draw/layout, view mounts, GPU mounts, models, and tasks. Failed-frame rollback is a contract risk, not a reproduced bug. | N `app.zig:548–555,558–647,711–728`; G `app.rs:1560–1658`. | W02 |

The unused CPU component `deinit` adapter is **not evidence of a leak**: current component pointers are caller-owned. GPU mount cleanup and CPU model destruction require different ownership rules.

## L — Composition, layout, scrolling, and animation

Evidence entry points: [N DrawCtx](../../../src/v7/drawctx.zig), [layout](../../../src/v7/layout/root.zig), [widget geometry](../../../src/v7/widget.zig); [G elements](../../../../github-zed-industries-zed/crates/gpui/src/elements/mod.rs), [element phases](../../../../github-zed-industries-zed/crates/gpui/src/element.rs).

| Gap | Current deficiency and required capability | Source evidence | Primary package |
| --- | --- | --- | --- |
| L01 | **Missing:** user-defined element layout/prepaint/paint, custom containers and child prepaint ordering. Components currently compose a closed set of node kinds. | G `element.rs:47–174,249–473`, `elements/div.rs:1615–1682`; N `widget.zig:188–318`, `drawctx.zig:441–482`, `app.zig:621–645`. | W08 |
| L02 | **Partial:** arbitrary intrinsic leaf measurement under known dimensions and available-space modes. Text/control measurement already exists. | G `taffy.rs:65–108`; N `layout/context.zig:11–21,99–109,208–261`, `layout/dispatch.zig:1246–1348`. | W08 |
| L03 | **Missing:** hidden-but-laid-out visibility, distinct from `display.none` and transparent paint. | G `style.rs:180–190,334–342`; N `style.zig:588–641`, `layout/dispatch.zig:1124–1154`. | W08 |
| L04 | **Partial ergonomics:** geometry-space/unit safety for new public APIs. Existing relative, absolute, visual and clipped geometry operations are real equivalents. | G `geometry.rs:43–112,395–430,723–735,2676–2690`; N `widget.zig:50–110,681–760`. | W02 |
| L05 | **Missing:** nested container query with a post-layout size and bounded child construction; viewport branching alone is insufficient. | G `elements/container_query.rs:13–115`; N `drawctx.zig:351–368`, `app.zig:621–645`. | W15 |
| L06 | **Missing:** uniform lazy lists, visible-range construction, overdraw, and item-based scroll strategies. | G `elements/uniform_list.rs:18–193`; N `widget.zig:131–144`, `app.zig:230–264`. | W15 |
| L07 | **Missing:** variable-height virtual lists with measured-height cache, splice/reset, reveal, logical anchors, and end following. | G `elements/list.rs:21–110,188–205,314–355,503–554,647–690,1014–1130`; no list module or item-range builder in N `src/v7/`. | W15 |
| L08 | **Partial:** anchored fit/flip/snap overlays and deferred prepaint/paint priority with matching hit order and explicit clip escape. Absolute positioning and paint layers exist. | G `elements/anchored.rs:14–76,127–215`, `elements/deferred.rs:6–65`; N `style.zig:588–641,863–903`, `input.zig:13–58`. | W16 |
| L09 | **Partial:** keyed animations, easing, sequences/repeat, reduced-motion policy, and next-frame requests. Built-in hover/press easing exists. | G `elements/animation.rs:12–104,136–208`, `app.rs:1009–1021`; N `app.zig:86–99,678–704`. | W17 |
| L10 | **Partial:** reusable scroll handle for offsets, viewport/content extent, reveal and programmatic scrolling. Raw scroll state and wheel-to-nearest-ancestor already work. | G `elements/div.rs` scroll handles and G list item-scroll APIs above; N `widget.zig:131–144`, `layout/dispatch.zig:1207–1243`, `app.zig:230–264`. | W15 |

Inherited text style belongs to T02; rich paint style belongs to R02/R03. These are not counted twice.

## I — Input, dispatch, focus, and commands

Evidence entry points: [N event contract](../../../src/v7/event.zig), [hit testing](../../../src/v7/input.zig), [identity](../../../src/v7/key.zig); [G input vocabulary](../../../../github-zed-industries-zed/crates/gpui/src/interactive.rs), [keymaps](../../../../github-zed-industries-zed/crates/gpui/src/keymap.rs), [actions](../../../../github-zed-industries-zed/crates/gpui/src/action.rs).

| Gap | Current deficiency and required capability | Source evidence | Primary package |
| --- | --- | --- | --- |
| I01 | **Partial:** full modifiers, logical/physical keys, repeat/down/up, text/composition, click count, pointer identity/cancel, and scroll units/phases. Current `key_up` is ignored by App. | G `interactive.rs:16–310,249–825`; N `event.zig:13–110`, `app.zig:319–320`, demo `window.zig:135–153,2398–2489`. | W09 |
| I02 | **Missing:** capture/bubble, propagation/default control, current target and routed component events. The component event hook exists but core dispatch does not call it; demo forwarding is separate. | G `window.rs:87–116,4807–5028,5299–5433`; N `component.zig:20–34`, `app.zig:223–450`, demo `ui.zig:957–959`. | W09 |
| I03 | **Missing:** typed named actions, registration/discovery, parameter decoding/schema, aliases, availability and dispatch. Demo-local action unions are not an app command system. | G `action.rs:1–127`, `app.rs:2129–2140`, `window.rs:5019–5273`; N `app.zig:329–450`. | W10 |
| I04 | **Missing:** configurable bindings, context predicates, precedence, disabled bindings, chords, timeout and unmatched-key replay. | G `keymap.rs:1–273`, `keymap/binding.rs:10–121`, `keymap/context.rs:10–180`, `key_dispatch.rs:100–580`; N built-in key switch. | W10 |
| I05 | **Partial:** stable widget identity shared by focus, capture, overlays, semantics, tests and animations. Component keys are stable; dense widget IDs are rebuilt each frame. Same-kind revalidation is not identity validation. | G `element.rs:111–136`, `window.rs:467–560`; N `drawctx.zig:441–450,864–910`, `app.zig:656–670`, `id.zig:4–11`. | W02 |
| I06 | **Partial:** focus handles/containment, explicit focus/blur, notifications, tab groups/index, custom focusable leaves and removal policy. Basic control Tab traversal exists. | G `window.rs:467–560,2017–2088`, `tab_stop.rs:1–205`, `app/context.rs:547–642`; N `app.zig:329–484`. | W09 |
| I07 | **Partial:** full pointer capture and semantic click lifecycle. Current controls activate on down, release clears state, and leave cancels drag. A release-based click cutover is an intentional behavior change. | G `window.rs:2751–2771`, `interactive.rs:139–310`, `elements/div.rs:560–605`; N `app.zig:280–326`, README basic-widget contract. | W09 |
| I08 | **Missing:** internal typed drag payloads, drag previews, threshold/can-drop/drop/cancel and external file drag transitions. Mandelbrot panning is not drag-and-drop. | G `elements/div.rs:48–75,330–380,539–605`, `interactive.rs:657–735`, `window.rs:4870–4977`; N event and callback surfaces. | W16 |
| I09 | **Missing:** delayed and hoverable tooltips with owner/timer lifetime and keyboard/semantic description. Hover alpha is not tooltip support. | G `elements/div.rs:48–50,539–678`; N `app.zig:678–704`. | W16 |
| I10 | **Conditional:** raw touch and native gesture API vocabulary. GPUI explicitly says core touch dispatch is pending; a complete portable recognizer suite is not an established parity requirement. | G `interactive.rs:87–135` (especially 114–118), `gestures.rs:1–123`; no equivalent N event variants. | W09 |

The possible focus/press alias after sibling reorder is **source-inferred**, not a reproduced runtime failure in this audit.

## T — Typography, shaping, editing, and IME

Evidence entry points: [N demo text engine](../../../src/v7_demo/text.zig), [reusable shape cache](../../../src/v7_text/shape_cache.zig), [CPU measurement](../../../src/v7_text/measure.zig), [core measure contract](../../../src/v7/layout/context.zig); [G text system](../../../../github-zed-industries-zed/crates/gpui/src/text_system.rs), [text elements](../../../../github-zed-industries-zed/crates/gpui/src/elements/text.rs), [input protocol](../../../../github-zed-industries-zed/crates/gpui/src/input.rs).

| Gap | Current deficiency and required capability | Source evidence | Primary package |
| --- | --- | --- | --- |
| T01 | **Partial/demo-only:** font family/face, weight/style, features, fallback, font addition/listing and metrics. The demo supplies two embedded fonts to the W01 CPU adapter. The shape cache still hard-codes LTR/Latin. | G `text_system.rs:51–168,1051–1098`, `style.rs:433–479`; N `widget.zig:287–320`, demo `text.zig:152–155,854–897`, `src/v7_text/shape_cache.zig:24–29,572–583`. | W11 |
| T02 | **Missing/partial:** inherited typed text styles and overrides; inline runs/highlights, background, underline and strike. Current nodes have one style; typed box text alignment already exists. | G `style.rs:433–500,576–593`, `text_system.rs:986–1002`, `elements/text.rs:390–573`; N `style.zig:588–641`, `drawctx.zig:571–584`, demo `window.zig:1580–1649`. | W11 |
| T03 | **Partial/demo-only:** shared shaped layout for measurement, paint, wrapped lines, byte/position mapping and range bounds. Core measure returns only size. W01 exposes the existing glyph clusters through the reusable cache, not a complete text-layout API. | G `text_system.rs:397–445,509–581`, `elements/text.rs:829–978`, `text_system/line_layout.rs:212–379`; N `layout/context.zig:6–40`, `src/v7_text/shape_cache.zig:79–110,572–630`. | W11 |
| T04 | **Partial:** paragraph glyph alignment, line height, whitespace/no-wrap, line clamp and start/middle/end truncation. Current clip/end-ellipsis and flow measurement are narrower. | G `style.rs:392–500`, `elements/text.rs:660–745`; N `widget.zig:146–147`, `layout/context.zig:48–71`, demo `text.zig:1098–1168`. | W11 |
| T05 | **Missing:** focused editable-text consumer protocol for text, selection, replacement and geometry. GPUI offers a protocol and example-owned fields, not a built-in full editor. | G `input.rs:4–225`, `platform.rs:1606–1744`, `window.rs:4625–4638`, `examples/input.rs:274–405`; N `event.zig:18–62`, `app.zig:329–394`. | W12 |
| T06 | **Partial/underspecified:** explicit UTF-8, UTF-16 and grapheme boundaries across layout and native editing. Planned editor preedit offsets currently omit units. | G `text_system.rs:986–1002`, `elements/text.rs:829–945`, `platform.rs:1590–1696`, `examples/input.rs:210–260`; N current UTF-8 slices and editor plan composition fields. | W11 |
| T07 | **Missing:** preedit/marked range, commit/cancel, selected-range replacement, candidate/caret geometry and coordinate invalidation. No native text-input adapter is wired in the current demo. | G `platform.rs:1486–1530,1618–1716`, `window.rs:4625–4638,5468–5478`; N `event.zig`, demo `window.zig` text-input search. | W12 |
| T08 | **Missing:** copy/cut/paste policy in focused text consumers using one shared clipboard service. Ordinary input must not depend on Neovim. | G `examples/input.rs:144–162`, `app.rs:1333–1351`; no clipboard calls found across N `src`; planned editor RPC bridge is unimplemented. | W12 |

General bidi/script-aware shaping and fallback belong in the text backend, not in the localization formatter. Static labels and all seven current text-bearing controls already exist. The [localization](2026-09-25-drawctx-localization.md) and [Neovim](2026-09-25-code-editor-widget.md) documents are plans, not implemented capability.

## R — Paint, canvas, assets, and surfaces

Evidence entry points: [N draw commands](../../../src/v7/drawcmd.zig), [paint style](../../../src/v7/style.zig), [renderer](../../../src/v7_render/root.zig), [host SVG rasterizer](../../../src/v7_host/svg.zig); [G paths](../../../../github-zed-industries-zed/crates/gpui/src/path_builder.rs), [images](../../../../github-zed-industries-zed/crates/gpui/src/elements/img.rs), [SVG](../../../../github-zed-industries-zed/crates/gpui/src/elements/svg.rs).

| Gap | Current deficiency and required capability | Source evidence | Primary package |
| --- | --- | --- | --- |
| R01 | **Missing/partial:** public canvas/path builder, line/quadratic/cubic/arc, fill/stroke/dashes and frame-owned paint records. Renderer materials and demo emissions already do more than canonical solid draw commands. | G `elements/canvas.rs:10–90`, `path_builder.rs:16–27,85–180,190–260`, `window.rs:4044–4058`; N `drawcmd.zig:65–80`, demo `window.zig:928–1081,1657–1740`. | W13 |
| R02 | **Partial:** unambiguous authored color versus scene color, palette/theme values, two-stop gradient direction/positions and pattern backgrounds. GPUI's gradient has exactly two stops; sRGB interpolation is not required for nogui. | G `color.rs:759–945`, `colors.rs:8–95`; N `style.zig:864–904`, demo Oklab endpoint conversion. | W13 |
| R03 | **Partial:** independent corner radii, border style, structured shadow list with offset/color/spread/inset and opacity. Current shadow is a scalar with fixed appearance and radii collapse in collection. | G `style.rs:280–298,345–389`, `window.rs:3867–4038`; N `drawcmd.zig:250–337`, demo `window.zig:1000–1060`. | W13 |
| R04 | **Missing general contract:** affine paint transforms with specified origin/clip order. GPUI's render transforms do not generally transform layout or hit boxes. | G `scene.rs:608–737`, `path_builder.rs:205–242`, `elements/svg.rs:31–47,186–276`; N demo SVG-specific transform helper. | W13 |
| R05 | **Missing public service:** asset sources/loaders, asynchronous deduplication, invalidation/removal, custom caches and explicit ownership. Raw texture slots are not asset identities. | G `assets.rs:12–85`, `asset_cache.rs:12–53`, `window.rs:3562–3592`, `app.rs:2473–2500`; N `runtime.zig:13–47`, demo `window.zig:466–605,673–820`. | W14 |
| R06 | **Missing reusable image element:** memory/file/URI images, intrinsic dimensions, object fit, grayscale, loading/error content and animated frames. Demo textures/artwork exist. | G `elements/img.rs:37–59,129–246,264–540`, `elements/image_cache.rs:164–324`; N demo upload path above. | W14 |
| R07 | **Demo-only/incomplete:** SVG loading/rendering, monochrome tint and full-color images. Current parser skips quadratic/smooth-quadratic/arc commands and lacks groups/transforms/use/basic shapes. | G `elements/svg.rs:10–160`, `svg_renderer.rs:84–246`, `elements/img.rs:604–735`; N `svg_view.zig:45–55`, `svg_xml.zig:11–24` (both files were removed when the SVG backend moved to the host; the module that replaced them is [svg.zig](../../../src/v7_host/svg.zig)). | W14 |
| R08 | **Conditional/missing public contract:** externally supplied image/video frames with size/format/lifetime. GPUI's CVPixelBuffer surface is macOS-only, not a portable video player. Audio decoding is not video support. | G `elements/surface.rs:1–62`, `platform.rs:399–437`; N demo audio decoder and GPU endpoint contract. | W14 |

Do not copy incidental upstream limits as goals. GPUI `RetainAllImageCache` uses an unbounded map despite an LRU comment; asset removal does not establish worker cancellation. Nogui's 64-clip and 1,536-material paths need observable capacity policy as rich painting becomes public, not silent output loss. Rectangular clipping is already a shared capability; GPUI's `ContentMask` is not an arbitrary path-mask API.

## P — Application host, windows, and native services

Evidence entry points: [G platform contracts](../../../../github-zed-industries-zed/crates/gpui/src/platform.rs), [application](../../../../github-zed-industries-zed/crates/gpui/src/app.rs), [window](../../../../github-zed-industries-zed/crates/gpui/src/window.rs); [N current SDL host](../../../src/v7_demo/window.zig), [GPU seam](../../../src/v7/runtime.zig).

GPUI platform trait declarations establish API breadth, **not uniform support in every backend**. Nogui's current host creates one SDL window and drives App directly. Existing noapi surfaces and DPI conversion are useful substrate, not a reusable window/service API.

| Gap | Current deficiency and required capability | Source evidence | Primary package |
| --- | --- | --- | --- |
| P01 | **Demo-only/partial:** reusable run/embedded-drive host, launch/quit/restart/activate/hide, reopen/URLs/wake and lifecycle callbacks. | G `app.rs:143–320,956–1027,1190–1523`, `platform.rs:124–319`; N demo `window.zig:2030–2113,2334–2540`. | W07 |
| P02 | **Missing reusable API:** multiwindow handles, root replacement, creation/options, close veto/post-close and last-window policy. Window kind, titlebar, minimum size, parent and display are explicit. | G `window.rs:1298–1718,1998–2014`, `platform.rs:1748–2088`; N single demo window and `App` fields. | W07 |
| P03 | **Partial/demo-only:** display enumeration/IDs, primary/work area/bounds, placement, DPI/display changes and logical-to-device conversion. Global coordinates may be unavailable on Wayland. | G `platform.rs:321–352`, `window.rs:2099–2575`; N demo `window.zig:387–400,2302–2307`. | W07 |
| P04 | **Missing public API:** title/size/focus/attention/minimize/maximize/fullscreen, decorations/background, native move/resize/menu and observed state changes. | G `platform.rs:793–953`, `window.rs:2099–2575`; N driver-owned SDL window. | W07 |
| P05 | **Missing:** prompts and open/save/path dialogs, cancellation, filters, multi-select, file/directory scope, reveal/open-system. | G `platform.rs:124–319`, `window.rs:5448–5507`, `window/prompts.rs`; no N public service. | W18 |
| P06 | **Missing:** clipboard items with text/images/metadata, ownership, Linux primary selection and conditional macOS Find pasteboard. | G `platform.rs:298–310,2221–2285,2586–2597`, `app.rs:1333–1351`; no clipboard use found across N `src`. | W18 |
| P07 | **Missing:** native file drag ingress, incoming/open URLs and scheme registration, with launch buffering and copied payloads. | G `interactive.rs:657–735`, `app.rs:1190–1523`, `platform.rs:124–319`; N event and demo SDL translation. | W18 |
| P08 | **Missing:** native menu models/system actions, enabled/checked state, dock/recent-document/jump-list integration. | G `platform/app_menu.rs:1–426`, `app.rs:2239–2349`, `platform.rs:124–319`; N no reusable menu service. | W18 |
| P09 | **Missing public service:** cursors, hide-until-move, keyboard-layout identity/change and layout-aware shortcut display. | G `platform.rs:793–953`, `platform/keyboard.rs:1–39`; N hard-coded demo key mapping. | W10 |
| P10 | **Missing public service:** appearance, titlebar button layout, thermal/scrollbar preferences, compositor information, bundle/auxiliary executable lookup and optional native gesture provider. GPUI has no general system-locale API. | G `platform.rs:124–319,793–953`, `app.rs:1190–1523`, `gestures.rs`; N host-local behavior only. | W18 |
| P11 | **Missing:** native notifications with identity, replacement/dismiss and response actions; distinguish unsupported/denied/provider failure. | G `platform.rs:124–319`, `app.rs:1190–1523`; no N public adapter. | W19 |
| P12 | **Missing:** asynchronous secure credential read/write/delete, no plaintext fallback. | G `platform.rs:124–319`, `app.rs:1190–1523`; no N public adapter. | W19 |
| P13 | **Conditional/missing:** screen-capture sources, permission/selection, frame stream and stop/teardown. | G `platform.rs:354–438`; N no public capture API. | W20 |
| P14 | **Conditional/missing:** Linux native anchored popup roles/grabs, CSD/SSD integration and Wayland layer-shell configuration. An ordinary SDL window is not a layer-shell surface. | G `platform/popup.rs:1–132`, `platform/layer_shell.rs:1–83`, `platform.rs:793–953`; N single ordinary SDL host. | W22 |
| P15 | **Conditional/missing adapters:** macOS tabs/titlebar/Services/Find/character palette/document metadata, Windows identity/jump-list/native interop, mobile safe insets/back/soft keyboard/lifecycle/memory, GPU metadata/subpixel queries. | G `platform.rs:124–438,793–953,1748–2088`, `app.rs:1190–1523,2239–2349`, `gpui.rs:335–346`; N root/runtime and Linux demo. | W23 |

## A — Accessibility

Evidence entry points: [G semantic guide](../../../../github-zed-industries-zed/crates/gpui/src/_accessibility.rs), [native bridge](../../../../github-zed-industries-zed/crates/gpui/src/window/a11y.rs); [N headless semantics](../../../src/v7/headless.zig).

| Gap | Current deficiency and required capability | Source evidence | Primary package |
| --- | --- | --- | --- |
| A01 | **Partial:** typed semantic tree, stable node IDs, roles/names/descriptions/shortcuts/states/ranges/relations, synthetic children, bounds and actions. Current labels and serialized checked/selected/progress values are useful but incomplete. | G `_accessibility.rs:45–105`, `element.rs:111–136`, `elements/div.rs:1219–1418`, `window/a11y.rs:44–97`; N `widget.zig:202–267`, `headless.zig:269–393`. | W21 |
| A02 | **Missing:** native accessibility adapter, activation, incremental updates, focus/actions, window bounds and accessibility bell. JSON output is not an OS bridge. | G `gpui.rs:87–90`, `window/a11y.rs:1–97`, `window.rs:5824–5890`, platform accessibility hooks; no N adapter. | W21 |

> **Superseded 2026-10-01, kept as history.** "Missing" described the tree this audit read on
> 2026-09-26 and does not describe it now: the native adapter, the owned bridge, the tree
> read-back and the five interface round-trips are all recorded above. The accessibility bell
> named in that row is now a **window** call answered by `src/v7_host/system_bell.zig` and
> exercised natively from the window the run opened — `available=true` and `request=rung` on X11
> while the adapter `State` was `inactive` and `screen_reader` was `false`, and
> `available=false` with `request=unsupported` on an owned compositor advertising no
> `xdg_system_bell_v1`. What is still exactly true: no real screen reader, no `EditableText`
> composition, no `List` selection, and no positive Wayland bell proof.
>
> **Superseded again 2026-10-04, kept as history.** Two of those four clauses moved.
> "No real screen reader" is no longer true: Orca 50.2 ran on an owned private
> accessibility bus, submitted speech, and its output was captured through an owned
> clock-paced PCM sink. "No `EditableText` composition" was still true then, but the
> recorded **reason** was already wrong: the pins are now `accesskit 0.25.0`,
> `accesskit_unix 0.23.0` and `accesskit_atspi_common 0.20.0`, and the pinned Unix
> provider does expose `SetTextContents`; no whole-value write had simply ever been
> issued and observed. No `List` selection and no positive Wayland bell proof are
> unchanged, and no screen-reader announcement was yet credited with real audio.
>
> **Superseded again 2026-10-04, later run.** The whole-value-write clause has now
> moved too: the latest native run issued all three whole/empty/restore
> `SetTextContents` writes and the platform read each complete value back at
> 21/0/7 characters with `getNSelections` 0 and exactly one model write each. What
> remains true of these four clauses: **composition** through the partial methods this
> provider does not implement is still unobserved, no `List` selection and no positive
> Wayland bell proof exist, and still **no screen-reader announcement is credited
> with real audio** for any role.

## D — Tests, diagnostics, and distribution

Evidence entry points: [N headless tools](../../../src/v7/headless.zig), [demo modes](../../../src/v7_demo/main.zig), [build](../../../build.zig), [package manifest](../../../build.zig.zon); [G test context](../../../../github-zed-industries-zed/crates/gpui/src/app/test_context.rs), [inspector](../../../../github-zed-industries-zed/crates/gpui/src/inspector.rs), [profiler](../../../../github-zed-industries-zed/crates/gpui/src/profiler.rs).

| Gap | Current deficiency and required capability | Source evidence | Primary package |
| --- | --- | --- | --- |
| D01 | **Partial:** reusable app/window test context, deterministic clock/task schedule, lifecycle cleanup and interaction helpers. Current native tests, explicit events and JSON replay are strong existing foundations. | G `test.rs:43–110`, `platform/test/dispatcher.rs:23–86`, `app/test_context.rs:126–220,494–535,792–889`; N App tests, `headless.zig`, demo `main.zig:291–347`. | W06 |
| D02 | **Partial:** W01 exposes CPU real-font measurement. Reusable windowless offscreen rendering and visual-test support remain missing. | G `app/headless_app_context.rs:1–22,50–68,128–185`; N public measure callback, `src/v7_text/measure.zig`, demo `runShot` mode. | W25 |
| D03 | **Partial:** reusable inspector provider, source metadata, element picking and safe snapshot access. Existing JSON/ASCII/layout verification must remain. | G `inspector.rs:3–56,114–156,209–247`; N `headless.zig` tree JSON, ASCII and layout verification. | W24 |
| D04 | **Partial/demo-only:** reusable frame/task/action timing and bounded frame collectors; separate real-concurrency benchmark context. Existing counters, perf JSONL, Tracy and CPU/GPU timing must not be replaced needlessly. | G `profiler.rs:675–808`, `profiler/actions.rs:208–216`, `app/bench_context.rs:40–145,267–398`; N public CounterSink and demo `perf.zig`. | W24 |
| D05 | **Partial:** W01 verifies selectable module boundaries and an external core-only consumer. Package paths still omit README. Broader API guides, examples, and clean-cache distribution acceptance remain in W26. | G crate metadata, examples and public feature gates; N `build.zig`, `build.zig.zon:66`, README module ownership, W01 acceptance record. | W26 |

## Export coverage and intentional differences

| GPUI root-export family | Coverage / decision |
| --- | --- |
| `action`, keymap, interaction, input, gestures, focus/tab behavior | I01–I10, T05–T08, P09. Touch vocabulary is covered without claiming upstream recognizers work. |
| App, Context, VisualContext, Entity/View/AnyView, global, subscription | C01–C08, P01–P04. Typed Zig callbacks and erased view adapters replace Rust trait/macro syntax. |
| Element/IntoElement/Render/RenderOnce/ParentElement, Div and style builders | L01–L03 plus existing DrawCtx/component composition. No second retained widget tree. |
| Style/refinement, geometry, Taffy layout IDs/available space | Existing typed layout/overrides plus L02–L04, T02, R02/R03. No second layout engine or string-CSS API. |
| List/uniform list/container query/anchored/deferred/animation | L05–L10. |
| Text/text system/font features/fallbacks/interactive text | T01–T07. Links and interactive ranges use I02/I03 and shaped T03 geometry. |
| Canvas/path/color/palette/scene/background/SVG/image/asset cache/surface | R01–R08. Lower-level noapi hooks remain available; render-only transforms stay render-only. |
| Platform/Application/Window/Display/menu/popup/layer-shell | P01–P15. Native capability matrix is in W23; Linux-first is not a claim of other-OS completion. |
| AccessKit types/actions | A01/A02. Stable core semantics rather than exposing a Rust object graph to Zig. |
| Executor, FutureExt/Timeout, block_on, priority channel handles | C06. Use Zig I/O/tasks and explicit UI delivery; do not add a UI-blocking join or clone Rust scheduler internals. |
| SharedString, ArcCow, SharedUri | Ownership in C03/R05/T03 and immutable bytes or typed resource keys. No requirement to reference-count every frame caption. |
| `http_client` dependency re-export | R05 resource-loader seam and real HTTP asset loader. Re-exporting a particular Rust networking package is not a GUI capability requirement. |
| Prelude, derive/test/property-test/bench macros, anyhow/ctor and hidden macro dependencies | Zig imports, comptime descriptors, error unions, native tests and D01/D04/D05. No proc-macro compatibility layer. |
| Inspector/profiler/test-support/bench/headless contexts | D01–D05. GPUI has debug-bounds selectors, not a general role/text test-query framework; core runtime accessibility is separate. |
| Private arena/bounds tree/key dispatcher/Taffy implementation/sealed machinery | Internal implementation choices, not additional public parity targets. |

Preserve these existing equivalents:

- Typed flex/grid/block/float layout, percentages, margins/borders/padding, alignment and overrides. The existing Taffy corpus is the regression gate; its previously documented pass count is not a new result from this audit.
- Component composition, hierarchical component keys and duplicate rejection, checked local state, scoped GPU lifecycle and two frame arenas.
- Relative and visual geometry, rectangular clipping, base scrolling, ordinary control captions and basic keyboard focus.
- Headless replay, semantic JSON, real HarfBuzz/FreeType shaping in the demo, counters and existing performance tooling.
- Oklab intermediate rendering, final sRGB conversion and noapi-only GPU access. GPUI's optional sRGB interpolation does not override this invariant.

Not GPUI parity gaps: a bundled code editor, localization catalogs, a stable 1.0 promise, general application widgets from Zed's separate `ui` crate, arbitrary path clipping, offscreen group-opacity compositing, unlimited caches, or universal zero-copy video. Existing feature plans retain their separate goals.

## Evidence limits

- `find` failed with a provider-credit error; ZLS exited during symbol discovery and no Rust LSP was configured. Scoped literal searches and source reads were used. GPUI's existing graph assisted navigation only; its truncated query was not used to establish absence.
- No GPUI application or native backend was run. The native surface inventory proves declared contracts, not per-OS implementation completeness.
- At the initial audit, frame failure, stale identity and font-ID edge cases were source-inferred risks, not observed failures. W02 later reproduced a same-kind insertion focus-transfer defect; its dated evidence above records the fix. Font-ID behavior remains outside W01–W03.
- Planning-session verification and W01–W03 implementation gates are recorded in the companion plan. W04–W26 acceptance scenarios remain open.
- Everything above this line, including the C/L/I/T/R/P/A/D tables and the 2026-09-29
  evidence sections, is the **2026-09-26 baseline and dated history**. The current reading of
  all 66 rows is the
  [2026-10-01 matrix](#current-implementation-and-acceptance-matrix-2026-10-01), and where the
  two disagree the matrix wins. Neither the matrix nor this document closes a row; the parent
  attaches the final integrated proof.
