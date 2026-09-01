# Debug 120 FPS Calibration Threshold Design

## Status

Approved on 2026-08-30.

## Problem

The original calibration rule allowed a 2% spread between three 120-frame window medians.

Five complete calibration attempts failed this rule. The attempts used default affinity, fixed affinity, and isolated CPU scopes. One attempt also moved the main codedb process away from the measurement cores.

A mechanism run showed stable work counts after frame 600. The clean CPU variation came mainly from the app and layout stage. GPU execution also varied without a frame trend. The evidence does not show cache growth or a changing workload.

The final exact run exceeded 2% at every clean CPU boundary. At boundary 2160, these spreads were present:

- Clean CPU: 3.191%
- GPU-profile CPU: 0.957%
- GPU execution: 3.896%

The 2% rule cannot produce a baseline on this host.

## Decision

Change the maximum spread from 2% to 10%.

Keep all other calibration rules unchanged:

- Use three disjoint 120-frame windows.
- Test boundaries from frame 600 through frame 2160.
- Use a 120-frame boundary step.
- Require the selected boundary and all later boundaries to pass.
- Add a 240-frame guard to the latest selected boundary.
- Cap the warm-up at 2400 frames.
- Stop if any scene has no sustained stable boundary.

The tool must use integer arithmetic. A triplet passes when:

```text
(maximum_median - minimum_median) * 10000 <= minimum_median * 1000
```

The 10% rule changes warm-up selection only. It does not change the 120 FPS budget or any qualification threshold.

## Manifest contract

The warm-up manifest must contain this required object:

```json
{
  "stability_rule": {
    "window_frames": 120,
    "window_count": 3,
    "first_boundary": 600,
    "last_boundary": 2160,
    "boundary_step": 120,
    "maximum_spread_basis_points": 1000,
    "guard_frames": 240,
    "frame_cap": 2400
  }
}
```

The parser must reject a missing or different rule. The baseline report must copy this object and reference the warm-up manifest hash.

Raw diagnostic files remain unchanged. Their hashes continue to identify the source measurements.

## Data flow

1. The calibration runner creates fresh clean and GPU diagnostic blocks.
2. The strict raw parser validates both blocks.
3. The calibration code computes each triplet with the 10% rule.
4. The sustained-boundary selector chooses one boundary for each scene.
5. The selector adds the fixed guard to the latest scene boundary.
6. The runner writes `warmup.json` with the full rule and all raw hashes.
7. The matrix validates the rule before it starts any process block.
8. The baseline report copies the rule and references all source hashes.

A failed calibration must not create `warmup.json`. The matrix must not accept a failed or old manifest.

## Verification

Add tests for these cases:

- A spread below 10% passes.
- A spread equal to 10% passes.
- A spread above 10% fails.
- A zero minimum passes only when all three medians are zero.
- One later unstable boundary rejects an earlier stable boundary.
- The manifest parser rejects the former 2% rule.
- The manifest parser rejects a missing rule.
- The matrix copies the exact accepted rule into its report.

Run calibration from scratch after the code change. Do not reuse the five failed diagnostics as accepted data.

Run the full matrix only after the new calibration passes.

## Non-goals

- Do not change the window size or window count.
- Do not remove the sustained-stability requirement.
- Do not change the 2400-frame cap.
- Do not change frame budgets or candidate acceptance rules.
- Do not hide host variance from the baseline report.
