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

A fresh 10% calibration also failed. Its last two GPU spreads were 10.869% and 10.889%. The clean CPU spreads were below 4% at those boundaries.

## Decision

Change the maximum spread from 2% to 12%.

Keep all other calibration rules unchanged:

- Use three disjoint 120-frame windows.
- Test boundaries from frame 600 through frame 2160.
- Use a 120-frame boundary step.
- Require the selected boundary and all later boundaries to pass.
- Add a 240-frame guard to the latest selected boundary.
- Cap the warm-up at 2400 frames.
- If any scene has no sustained boundary, use the capped-unstable fallback.

The tool must use integer arithmetic. A triplet passes when:

```text
(maximum_median - minimum_median) * 10000 <= minimum_median * 1200
```

The 12% rule changes warm-up selection only. It does not change the 120 FPS budget or any qualification threshold.

The fallback sets the global warm-up to 2400 frames. It does not claim that the host became stable. The matrix can run, but all reports must keep the unstable status.

## Manifest contract

The warm-up manifest must contain this required object:

```json
{
  "stability_status": "capped_unstable",
  "warmup_frames": 2400,
  "stability_rule": {
    "window_frames": 120,
    "window_count": 3,
    "first_boundary": 600,
    "last_boundary": 2160,
    "boundary_step": 120,
    "maximum_spread_basis_points": 1200,
    "guard_frames": 240,
    "frame_cap": 2400
  }
}
```

The parser must reject a missing or different rule. `stability_status` must be `sustained` or `capped_unstable`. A capped manifest must use 2400 warm-up frames and contain at least one scene with a null boundary. The baseline report must copy the status and rule, then reference the warm-up manifest hash.

Raw diagnostic files remain unchanged. Their hashes continue to identify the source measurements.

## Data flow

1. The calibration runner creates fresh clean and GPU diagnostic blocks.
2. The strict raw parser validates both blocks.
3. The calibration code computes each triplet with the 12% rule.
4. The sustained-boundary selector returns one boundary or null for each scene.
5. If all scenes have boundaries, the selector adds the fixed guard to the latest boundary.
6. If any scene has a null boundary, the selector uses 2400 frames and marks the run capped-unstable.
7. The runner writes `warmup.json` with the status, full rule, boundary spreads, and all raw hashes.
8. The matrix validates the status and rule before it starts any process block.
9. The baseline report copies the status and rule, then references all source hashes.

A child, parser, identity, or artifact failure must not create `warmup.json`. A missing sustained boundary is not hidden as success. It creates a valid capped-unstable manifest. The matrix must not accept a malformed or old manifest.

## Verification

Add tests for these cases:

- A spread below 12% passes.
- A spread equal to 12% passes.
- A spread above 12% fails.
- A zero minimum passes only when all three medians are zero.
- One later unstable boundary rejects an earlier stable boundary.
- The manifest parser rejects the former 2% rule.
- The manifest parser rejects a missing rule.
- The matrix copies the exact accepted rule into its report.
- A missing scene boundary selects 2400 frames and `capped_unstable`.
- A capped manifest without a null boundary is rejected.
- A sustained manifest with a null boundary is rejected.

Run calibration from scratch after the code change. Do not reuse the five failed diagnostics as accepted data.

Run the full matrix only after the new calibration writes a valid sustained or capped-unstable manifest.

## Non-goals

- Do not change the window size or window count.
- Do not remove the sustained-stability requirement.
- Do not change the 2400-frame cap.
- Do not change frame budgets or candidate acceptance rules.
- Do not hide host variance from the baseline report.
