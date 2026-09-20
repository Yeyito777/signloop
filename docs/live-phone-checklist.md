# Live phone validation — still required

Automated/replayed results are not evidence that the installed phone app is
accurate or responsive. Do not mark the project finished until this check has
actual results. No video, audio, images or landmarks need to be recorded.

## Prerequisites

- Unlock **Yeyito**, open Honk & Tell and allow camera access.
- The mode must say **“Offline research preview · 5 signs + ILY”**. If it says
  ILY only, the private model did not load; report that instead of testing five
  words against the fallback.
- Turn off Wi-Fi and cellular for the offline check. No Mac/server is needed.
- One ASL-fluent person must verify the intended signs; do not treat a
  nonsigner's guessed gesture as a labeled accuracy test.
- Use two consenting people. Person B must not supply examples/tuning feedback
  before their held-out run. Freeze the app version/settings before that run.
- Keep only anonymous aggregate counts and device/build/settings notes, not
  names, biometric observations or media. Do not upload footage to providers.

## Quick functional check

1. Settings → joints on/off, numbers on/off, stats on/off. Confirm the skeleton
   follows your actual hands, not merely that the camera preview moves.
2. Front and rear cameras: joints align with the mirrored/nonmirrored preview.
   Flip while signing: no old word or old skeleton remains on the new view.
3. Remove hands, pause/resume, background/foreground, and lock/unlock.
   Old signs must clear; resuming must recover without restarting the app.
4. Watch for frozen skeletons/status. A detected stall should clear the overlay
   and say it is waiting for fresh camera frames, not retain a “live” result.
5. Settings → tracking rate, tracking duration, frame age and sign inference.
   Record observed ranges, not invented p95 values. Frame age is not total
   sign-display latency. Repeat after ten minutes to check heating/slowdowns.
6. Permission denied → Settings recovery, large text and one-handed access to
   pause/settings should still work.

## Recognition run

For each person, perform ten naturally paced, separate trials of each:
**HELLO, YES, NO, PLEASE, THANK_YOU, ILY handshape**. Use the ASL-fluent person's
validated form. ILY here is a held handshape, not validation of full ASL grammar.

Vary order. Return to a neutral/no-hands position between trials. Include
ordinary light/distance variation without obscuring hands. Do not repeatedly
adjust a failed trial until the app produces the expected answer.

Record this table separately for A and B:

| Intended label | Trials | Correct only | Any wrong word | Unknown/missed | Invalid attempt |
| --- | ---: | ---: | ---: | ---: | ---: |
| HELLO | 10 | | | | |
| YES | 10 | | | | |
| NO | 10 | | | | |
| PLEASE | 10 | | | | |
| THANK_YOU | 10 | | | | |
| ILY | 10 | | | | |

A trial with both correct and wrong words belongs in **Any wrong word**, not
Correct only. Invalid attempts require an ASL-fluent reviewer and stay reported
separately; don't silently drop misses. Note visible delays/flicker. If no
independent timing method is available, call latency observations qualitative.

For each person, spend 30 seconds on each negative condition:
no hands, relaxed visible hands, natural conversation gesticulation, adjusting
clothes, reaching for an object, and ASL signs outside the supported vocabulary.
Record every falsely displayed word, its condition and total exposure time.
Ordinary movements matter: unsupported ASL alone is not a nonsigning test.

## Provisional demo gate — not an accessibility certification

Before calling this a usable limited-vocabulary hackathon demo, seek:

- All six supported items actually work, not just aggregate coverage dominated
  by one easy word. At least 8/10 correct-only trials per label for **both**
  people is an initial engineering target, not a statistically established
  population accuracy claim.
- No wrong word observed in these positive/negative checks. Unknown is safer
  than a confidently wrong caption. Any false display needs investigation.
- No stale word/overlay across lifecycle changes, no backend dependency and
  responsive sustained camera interaction. Quantify actual phone latency/FPS
  before claiming real-time performance numbers.

Passing a small check does not prove universal accuracy, full ASL translation,
or suitability for accessibility-critical conversations. Failed held-out data
may inform the next iteration, but then it becomes development data: recruit
a fresh held-out person for the next validation.

Public distribution also remains gated by confirming pretrained weight rights
or replacing them with clearly distributable weights. The repository does not
bundle those research weights.
