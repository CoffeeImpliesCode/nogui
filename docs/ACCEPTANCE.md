# Acceptance status

What this repository proves today, and what it does not. Read this before
claiming parity with any reference implementation.

Verified on 2026-10-06. Every number below came from a run of the command
next to it.

## Proven

| Claim | Command | Result |
| --- | --- | --- |
| The house gate is green | `zig build test check fixture layout-check lint` | 115/115 steps, 2048/2048 tests |
| Layout matches the pinned Taffy corpus | `zig build fixture` | 5524 passed, 0 failed, 0 unsupported |
| The application layout golden matches | `zig build layout-check` | the 74-row `testdata/layout-golden.json` matches; `layout-check` also dumps a 581-row map for inspection, and that map size is not the golden size |
| No lint findings | `zig build lint` | ziglint and zlint, 0 errors and 0 warnings across 258 files |
| Formatting is clean | `zig fmt --check src build.zig build.zig.zon` | no diff |
| The Python tool suite passes | `python3 -m unittest discover -s tools -p 'test_*.py'` | 180 tests, OK |

Per-package gates also pass individually: `api-w12` 53/53, `api-w14` 80/80,
`api-w15` 46/46, `api-w16` 45/45, `api-w19` 71/71, `api-w20` 118/118,
`api-w21` 115/115,
`api-w24` 51/51.

## Not proven

These are open, and no cross-compile or refusal closes them.

### Absent SDKs and devices

macOS, Windows and mobile runtime acceptance (E01-E05, and the W23 gate). This
workstation is Linux x86_64 with no toolchain for any of them. The adapters are
implemented and compile-verified where a cross-compile is possible; what is
missing is the run on the target and the target's own accessibility client
speaking.

- **macOS E01** — tabs, titlebar, document metadata, Services
- **macOS E02** — Find pasteboard, character palette, Dock/recent documents,
  Keychain, notifications, dialogs, CVPixelBuffer frames
- **Windows E03** — AppUserModelID, jump list, native window interop
- **Windows E05 / mobile E05** — UI Automation and the mobile semantic adapter
- **Mobile E04** — safe area, back request, soft keyboard, text state,
  background/resume, memory pressure

### Interactive approval that an agent must not give itself

- **W19** — secret-store read/write/delete needs a private keyring UI agent
  present on the host, plus approval for the provider Unlock prompt. No agent
  may answer that prompt.
- **W20** — capture needs one interactive chooser selection for one named
  output. A single approval was already spent on the first capture; it is not
  re-spendable by an agent.
- **W21** — the screen-reader session needs renewed authorisation to restart
  Orca and enable its setting. Orca stays off meanwhile.

### Environment

The cold-package re-run reached `core_only` green and then failed in
`text_only` on an environment network fault fetching freetype. That is not a
code defect, but it does mean the remaining consumers are unproven here.

## Where the acceptance evidence lives

**Not in this repository.** The acceptance harnesses for W18-W22 are
untracked scripts, and the W21 evidence roots are real screen-reader
recordings. Neither is version controlled here.

Consequences for a reader:

- The Zig tests in `src/` are the contract. They are reproducible from a clone.
- The native acceptance layer above them is not. The round-trip and still-alive
  proofs, the PCM attribution harness and the Unlock fixture live outside the
  package, so their results cannot be re-checked from a clone.
- Recording the locked-screen-reader evidence requires retaining large
  recordings that are deliberately not committed.

If you need to re-run any of it, obtain the harness separately. Do not assume a
missing harness means a missing check; it means the check does not travel with
the source.

## Rules this project holds itself to

- A capability is not complete when its type compiles. It needs a consumer, a
  running scenario, and a documented outcome.
- `Unsupported`, denial, cancellation and provider failure are four different
  answers and must stay four.
- A cross-compile that reached link is a cross-compile. A platform reporting
  `Unsupported` is a refusal. Neither is runtime evidence.
- An item closes only on direct evidence from the tree as it stands. A tracker
  entry, a comment, or a passing narrow check is not sufficient.