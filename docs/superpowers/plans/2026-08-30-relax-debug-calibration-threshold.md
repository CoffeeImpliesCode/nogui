# Relax Debug Calibration Threshold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unusable 2% calibration spread with the approved 10% rule, then complete the Task 7 baseline.

**Architecture:** Keep the existing three-window sustained-stability algorithm. Store one canonical rule object in the Python runner, validate it at every manifest boundary, and copy it into the baseline report. Run new diagnostics after the code change. Do not accept any earlier failed diagnostic.

**Tech Stack:** Python 3 standard library, Zig 0.16.0, Jujutsu, JSONL raw artifacts, Tracy.

## Global Constraints

- Use a maximum spread of 1000 basis points, which equals 10%.
- Keep three disjoint 120-frame windows.
- Keep boundaries 600 through 2160 with a 120-frame step.
- Require the selected boundary and all later boundaries to pass.
- Keep the 240-frame guard and the 2400-frame cap.
- Keep all 120 FPS budgets and candidate acceptance rules unchanged.
- Use integer arithmetic for spread checks.
- Reject a missing or different stability rule in `warmup.json`.
- Do not reuse the five failed calibration attempts as accepted data.
- Do not run the matrix until a fresh calibration passes.
- Keep the existing uncommitted Task 7 instrumentation and behavior locks.
- Commit the complete Task 7 change as `perf(v7): establish Debug frame baseline`.

---

### Task 1: Amend calibration and complete the baseline

**Files:**
- Modify: `tools/run_v7_perf.py`
- Modify: `tools/test_run_v7_perf.py`
- Modify: `docs/superpowers/plans/2026-08-30-debug-120fps-optimization.md`
- Modify: the existing uncommitted Task 7 source files
- Create: `docs/perf/debug-120-baseline.json`
- Create: `docs/perf/debug-120-roadmap.md`
- Evidence: `~/projects/nogui/.superpowers/sdd/task-7-report.md`

**Interfaces:**
- Produces `CALIBRATION_STABILITY_RULE`, a JSON-compatible mapping with the exact approved values.
- Produces `warmup.json.stability_rule` with that exact mapping.
- Requires the matrix loader to validate and copy the rule.
- Leaves raw JSONL sample schemas and frame budgets unchanged.

- [ ] **Step 1: Add failing threshold tests**

Add direct tests for the existing triplet helper. Each window contains 120 equal values.

```python
below = [1000] * 120 + [1050] * 120 + [1099] * 120
at_limit = [1000] * 120 + [1050] * 120 + [1100] * 120
above = [1000] * 120 + [1050] * 120 + [1101] * 120

self.assertTrue(run_v7_perf._stable_triplet(below, 360))
self.assertTrue(run_v7_perf._stable_triplet(at_limit, 360))
self.assertFalse(run_v7_perf._stable_triplet(above, 360))
```

Add tests that reject a missing rule and the former 2% value. Add a matrix-report test that checks exact rule copying.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```text
python3 -m unittest \
  tools.test_run_v7_perf.ProtocolReviewRegressionTests.test_calibration_accepts_ten_percent \
  tools.test_run_v7_perf.ProtocolReviewRegressionTests.test_warmup_requires_stability_rule \
  tools.test_run_v7_perf.ProtocolReviewRegressionTests.test_matrix_copies_stability_rule
```

Expected: failures because the helper still uses 2% and manifests omit the rule.

- [ ] **Step 3: Define one canonical rule**

Add this immutable mapping near the calibration constants:

```python
CALIBRATION_STABILITY_RULE = {
    "window_frames": 120,
    "window_count": 3,
    "first_boundary": 600,
    "last_boundary": 2160,
    "boundary_step": 120,
    "maximum_spread_basis_points": 1000,
    "guard_frames": 240,
    "frame_cap": 2400,
}
```

Use the mapping values in boundary generation, window slicing, the spread formula, guard selection, and cap validation. The spread formula is:

```python
(maximum - minimum) * 10_000 <= minimum * maximum_spread_basis_points
```

Keep the existing all-zero special case.

- [ ] **Step 4: Validate and propagate the rule**

Write `stability_rule` into `warmup.json`. Make the warm-up loader require exact key and value equality with `CALIBRATION_STABILITY_RULE`.

Copy the rule into `docs/perf/debug-120-baseline.json`. Include the accepted `warmup.json` SHA-256 in the baseline report. Do not add this rule to raw frame records.

- [ ] **Step 5: Update the approved master plan**

In Task 7 Step 2, replace the 2% limit with 10%. Link the committed design:

```text
docs/superpowers/specs/2026-08-30-debug-120-calibration-threshold-design.md
```

Do not change the windows, boundaries, sustained requirement, guard, cap, matrix size, or budgets.

- [ ] **Step 6: Run focused tests and builds**

Run:

```text
python3 -m unittest tools/test_run_v7_perf.py
zig build test -Dv7-perf-counters=true -Dtest-filter='counters'
zig build test -Dv7-perf-counters=false -Dtest-filter='counters'
zig build -Doptimize=Debug -Dv7-perf-counters=true
zig build -Doptimize=Debug -Dv7-perf-counters=false
```

Expected: all commands pass. The Python suite must include the 10% boundary and manifest tests.

- [ ] **Step 7: Run fresh calibration**

Delete only the owned failed acceptance directory. Keep the separately named failed diagnostics for evidence.

Run the exact command:

```text
python3 tools/run_v7_perf.py calibrate \
  --frames 2400 \
  --seed 0x4e4f475549313230 \
  --out /tmp/nogui-perf/calibration
```

Expected: `warmup.json` exists, every raw hash resolves, and each scene has a sustained boundary under the 10% rule.

- [ ] **Step 8: Run the complete matrix**

Run:

```text
python3 tools/run_v7_perf.py matrix \
  --warmup-from /tmp/nogui-perf/calibration/warmup.json \
  --blocks 10 \
  --frames 1000 \
  --seed 0x4e4f475549313230 \
  --report docs/perf/debug-120-baseline.json \
  --out /tmp/nogui-perf/baseline
```

Expected: every requested cell has ten valid process blocks. Every Tracy block has a trace hash, CSV hash, and valid sample-root attribution.

- [ ] **Step 9: Complete the roadmap and gates**

Generate `docs/perf/debug-120-roadmap.md` only from the accepted report. Give every Task 8-18 hypothesis one measured state. Select exactly one first candidate.

Run the fixture oracle, ten shot hashes, two layout hashes, and scoped formatting. Update the Task 7 report with the accepted calibration, matrix hashes, candidate decision, and full commit ID.

- [ ] **Step 10: Commit**

Run:

```text
jj commit -m "perf(v7): establish Debug frame baseline"
```

Expected: one complete Task 7 commit above design commit `d2db2c21`, followed by a clean working copy.
