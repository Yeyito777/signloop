# Rolling calibration and handedness experiment — 2026-09-19

**Still not accurate enough for a multi-sign demo.** This experiment improves
rejection and tests a narrow handedness augmentation without changing the
installed app, raising API-call frequency, or relaxing confidence safeguards.

## Two controlled changes

1. Calibrate on the same **rolling-window display protocol** being evaluated:
   1,200 ms windows, 250 ms polling, two agreeing decisions, immediate reset on
   unknown/no hands, phases 0/83/166 ms. Responses are simulated as immediate.
2. `reference-dtw-v3-mirror` adds globally reflected copies of the 27 training
   references (54 vectors, **not 54 independent recordings**). It swaps
   handedness and reflects x, preserving finger articulation and motion order.
   Original references win exact ties.

Reflection is restricted to HELLO, YES, NO, PLEASE and THANK_YOU. This is an
experimental dominant-hand hypothesis for these labels, not permission to
reflect arbitrary signs: spatial/directional meaning can change.

Both V2 and V3 use a fixed distance/margin grid and maximize correct displayed
calibration runs subject to **zero wrong displayed runs**. Unlike the original
whole-clip policy, this constrains both wrong-known labels and unsupported false
accepts. Reject-all is allowed and must not be mistaken for a successful model.

Test geometry is not consumed until thresholds are selected. No thresholds
were changed after observing the results below.

## Data and scope

Same V2 corpus SHA-256:
`fc86b68b116b31d593af34b2c5b436b8a190f42d4c9c56c0a6d0e4865cec794b`.

- Calibration: 32 clips / 4 signers, giving 51 supported and 45 unsupported
  clip/phase runs.
- Diagnostic test: 29 **previously inspected** clips / 9 other signers, giving
  42 supported and 45 unsupported runs.
- Phases of a clip are correlated, not independent trials.
- Clip processing trims no-hand edges and uses at most a center three-second
  crop. This is not continuous signing, natural transitions, nonsigning behavior,
  or a phone validation session. No annotated sign-onset times are available.
- No research corpus or per-clip outputs are distributed or sent to providers.

## Results

| Policy | Calibration correct supported runs | Calibration wrong displayed runs | Diagnostic correct supported runs | Diagnostic wrong displayed runs |
| --- | ---: | ---: | ---: | ---: |
| V2, rolling calibration: distance .40 / margin .40 | 12/51 | 0/96 | 8/42 | 0/87 |
| V3 mirrored, rolling calibration: distance .45 / margin .40 | 13/51 | 0/96 | 13/42 | 0/87 |

For context, the earlier V2 **whole-clip-calibrated** .55/.10 policy at this
250 ms cadence displayed correct labels in 24/42 supported runs but also
displayed false labels in 8/45 unsupported runs. Stricter calibration trades
recall for fewer observed errors; zero observed errors is not a guarantee.

V3 diagnostic correct display by label:

| Label | Correct clip/phase runs |
| --- | ---: |
| HELLO | 4/9 |
| YES | 0/6 |
| NO | 0/9 |
| PLEASE | 6/6 |
| THANK_YOU | 3/12 |

The mirror hypothesis has a modest aggregate benefit here, not a solution.
Calibration recognition for NO actually drops from 3/9 to 0/9; YES and NO remain
unusable at the selected V3 operating point. More feature/context work and
fresh signer evaluation are needed. This does not establish an independent
held-out improvement or justify enabling five words in the app.

## Reproduce

Six new synthetic tests cover reflection/involution, label restrictions,
wrong-known constraints, reject-all behavior, test-independent selection and
server profile mismatch. All 44 backend tests passed; the real Swift display
filter also matched all **904 events** across both experimental replay reports.

```sh
python3 -m backend.stream_calibrate path/to/corpus-v2.json \
  --model reference-dtw-v2 --out .runtime/stream-cal-v2.json
python3 -m backend.stream_calibrate path/to/corpus-v2.json \
  --model reference-dtw-v3-mirror --out .runtime/stream-cal-v3.json
python3 -m unittest backend.test_stream_calibrate -v
```

Per-clip outputs stay local/ignored. The CLI prints only aggregates.
The legacy live server deliberately refuses these rolling-calibration reports:
its existing client cadence/filter does not implement this experimental profile.
The native Swift engine remains V2; V3 has not been silently substituted.
