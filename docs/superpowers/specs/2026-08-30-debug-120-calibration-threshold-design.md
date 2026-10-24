# Performance measurement protocol

`tools/run_v7_perf.py` uses the Python standard library.
It records runtime identity, instrumentation profiles, raw samples, and manifest hashes.
Measurements from different profiles must remain separate.
CPU compute times exclude GPU waits and do not measure presentation intervals.

## Commands and profiles

| Subcommand | Purpose |
| --- | --- |
| `snapshot` | Build and freeze one instrumentation profile. |
| `calibrate` | Select warm-up frames across all scenes. |
| `matrix` | Collect a multi-profile baseline. |
| `pair` | Compare distinct frozen baseline and candidate manifests. |
| `qualify` | Run the fixed qualification protocol. |

Use the subcommand help for arguments, for example:

```sh
python3 tools/run_v7_perf.py calibrate --help
python3 tools/run_v7_perf.py matrix --help
```

| Profile | Tracy | GPU timestamps | Mechanism counters |
| --- | --- | --- | --- |
| `clean` | false | false | false |
| `tracy` | true | false | false |
| `gpu` | false | true | false |
| `mechanism` | false | false | true |

The corresponding build options are `v7-tracy`, `v7-gpu-timestamps`, and `v7-perf-counters`.
Use fresh output paths. The runner rejects stale or inconsistent artifacts.
A paired comparison requires a positive, even block count.
The qualification protocol requires 300 blocks and 1,000 frames for each of five scenes.
Calibration does not establish a frame-rate qualification.

## Warm-up selection

Calibration records 2,400 diagnostic frames per scene and profile.
It tests boundaries from frame 600 through frame 2,160, in 120-frame steps.
Each boundary compares three disjoint 120-frame window medians.
The integer stability rule is:

```text
(maximum_median - minimum_median) * 10000 <= minimum_median * 1200
```

This permits a 12% spread.
A zero minimum passes only when every median is zero.
A selected boundary and all later boundaries must pass.

If every scene has a sustained boundary, selection adds 240 guard frames to the latest boundary.
The warm-up cannot exceed 2,400 frames.
If any scene lacks a sustained boundary, selection uses 2,400 frames and records `capped_unstable`.
That status records instability at the cap. It must remain visible in later reports.
The rule selects warm-up only and does not change frame budgets.

## Manifest format

A capped manifest contains this rule:

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

The parser rejects missing or different rules.
`stability_status` is `sustained` or `capped_unstable`.
A capped manifest must use 2,400 warm-up frames and contain a scene with a null boundary.
A sustained manifest cannot contain a null boundary.
The baseline report copies the status and rule and references the warm-up manifest hash.

A child-process, parser, runtime-identity, or artifact failure must not produce a warm-up manifest.
A missing sustained boundary produces a valid capped-unstable manifest instead.
Raw file hashes identify the measurements that produced the manifest.
