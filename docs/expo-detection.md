# Unified Expo detection — build 21

The previous main merge preserved two working apps but did not connect the new
matcher to Expo. This change replaces the live Expo ILY-only adapter with the
same native engines used by the standalone scanner:

```
Expo view → SkeletonCameraTracker → hands + pose (+ optional face)
         → BasicLiveRecognition / BasicSignMatcher (11 presentation signs)
         OR AlphabetRecognition (A U R E L I O)
         → capture-tagged completed signs / diagnostics events
         → automatic best-match captions / optional voice
```

No copied matcher, rewritten heuristic, softmax probability or zero-shot model.
The private bank is still outside Git and the binary. WE augmentation, temporal
windows, hand-local geometry, best-guess behavior, score pruning, one-job limits
and stale-result resets remain the shared implementation. Unsupported inputs
can still get a best guess; this is not validated ASL translation.

## Assets and setup

From `mobile/`: `npm ci`, `npm run camera:assets`,
`npx expo prebuild --platform ios --no-install`, then `cd ios && pod install`.
CocoaPods requires a UTF-8 locale (`LANG=en_US.UTF-8`).
The Expo pod compiles shared Swift files directly and bundles only the public
landmark models and the attributed static alphabet model, plus an optional
checked personal expression profile. The pipeline accepts
an injected model bundle (default `.main` for the standalone app).

Install the **Release** Expo app, `com.signloop.mobile`, to run without Metro.
The existing standalone app is `com.yeyito.signloop`; it is a different container.

## Private word references (required)

**Missing ASL files in a fresh clone are intentional, not a Git merge conflict.**
The code and attributed alphabet model are committed. Word matching needs a
separate coordinate reference bank. Without it the app reports unavailable
references; tracking/spelling still run, but words cannot be recognized.

[Microsoft's ASL Citizen license](https://www.microsoft.com/en-us/research/project/asl-citizen/dataset-license/)
§1(c) prohibits distributing the data **or modifications**; §2(e) prohibits sharing
the materials. Use is limited to noncommercial, non-revenue-generating research.
Our derived coordinates are not a workaround. **Do not commit, upload to GitHub
releases, send to teammates/providers, or distribute a binary containing them.**
Each eligible researcher must separately obtain the sources and generate their
own local data. Public/commercial distribution needs appropriate permission or
replacement data collected with suitable consent and rights.

On macOS, install Xcode command-line tools and Python 3.12, then from the repo root:

```sh
# Read the linked license first. The flag is required, never assumed.
bash scripts/dev/setup-expo-references --accept-research-license
```

The command creates an isolated pinned Python environment, fetches the public
MediaPipe models, selects the **11 presentation signs**, downloads only selected
video entries via range requests (not the 46 GB archive), extracts temporal
hand/pose/face coordinates, and packs original **training-only** references with
the existing Swift matcher. It checks the corpus manifest and never trains on
validation/test clips. Allow tens of minutes on a laptop. An interrupted
extraction resumes; a download failing its range/size checks fails closed.
Use `--plan-only` to inspect source sizes before video extraction.

Output: `.runtime/expo-references/basic-references-packed.json`. All source clips,
coordinates and generated banks remain ignored under `.runtime`; temporary
downloaded clips are discarded after extraction. The default corpus is
`.runtime/presentation-signs-v1`. The published matching parameters are copied
from the existing development policy, not newly claimed accuracy calibration.

Install the Expo app first, connect/unlock your own iPhone, then provision:

```sh
xcrun devicectl list devices
bash scripts/dev/setup-expo-references --accept-research-license --device YOUR_IPHONE_ID
```

This targets **`com.signloop.mobile`**, not the standalone app. It does not build
or install the app. Reopen Expo after provisioning. Subsequent runs reuse the
local extraction. If you already generated your **own** complete corpus, use
`--existing-corpus /absolute/path/to/.runtime/your-corpus` to avoid extraction.
Do not use another researcher's copy.

For a local simulator, copy your generated packed JSON into that app's
`Documents/basic-references.json`; simulator camera capture is still unavailable.
Loading marks the bank excluded from cloud backups.

## Data boundary

No landmarks/pixels are sent to JS or the backend. Only display guesses,
distances, numeric timing and optional expression labels cross the bridge.
The former unused `getRecentFrames` / SignEngine event API is no longer the live
Expo interface; legacy research implementations remain in the repository.

## UI and lifecycle

- Caption area: Signs / Spell name. The recognition-version-5 bridge supplies
  rolling/completed attempts. Signs show one live guess and automatically caption
  and speak the best match on completion, with duplicate-attempt suppression.
  Stale previews expire after one second. Name letters
  require Add, followed by Confirm spelled name. No automatic name completion.
- Conversation menu: Detection settings (hands, body, face, match distances).
- Expression lab: existing SwiftUI teaching, six-expression checks, numeric
  profile/setup import/export. It uses the same camera owner while visible,
  not a second simultaneously running camera. Conversation is paused on entry;
  return and Resume. Profiles are local to the Expo app's container.
- Pause, sheet entry, backgrounding and mode changes reset native work and reject
  previous-generation events. Explicitly composed spelling remains in RAM only.
- Preview is aspect-fit so Expo's wide camera region does not crop away the
  chest/hands needed for body-relative matching. Overlays use the same transform.
- Face tracking starts enabled and can be turned off in Detection settings.
  Stable taught expression labels drive the listening goose and are attached to
  completed signs for automatic speech delivery. Expressions alone do not create
  speech or infer feelings. See [expression integration](goose-expression-integration.md).

Expo's goose, design tokens, caption correction, transcript, voice consent and
server proxy remain. Completed signs or confirmed spelled names and their expression
labels reach optional voice.

## Regression checks

`npm run typecheck` and `npm test` in `mobile/` exercise all supported labels,
candidate-only semantics, old epochs, stale inputs, explicit restricted spelling,
pause/sheet guards and the existing caption/voice path. The prebuild plugin has
a regression for literal control characters in generated Xcode shell scripts.
`bash ios/scripts/test-core.sh` exercises the unchanged shared engines.

`ExpoIntegrationUITests` is an opt-in **simulator-only** suite in the standalone
Xcode test runner. Install the real Release Expo app on that disposable simulator
first, then run only that class with `TEST_RUNNER_TEST_SIGNLOOP_EXPO=1`. It opens
`com.signloop.mobile` (not the standalone app), checks actual bundled alphabet
loading, manual name confirmation/transcript, settings and the embedded
expression lab. Never run camera screenshot tests on a physical phone.

Handoff status: after resolving concurrent main changes, TypeScript checking,
all **73 mobile tests**, and Swift bridge syntax parsing passed. The licensed
bank setup was exercised locally.
The default setup produced the 11-sign training-only bank, and every packed
reference matched the previous development bank's corresponding reference.
Full Expo native builds were interrupted to merge teammates' concurrent main
changes and publish this integration promptly, as requested. **The merged Expo
Release binary and opt-in Expo UI tests have not yet been verified or installed.**
Do not interpret source-level tests as phone tracking accuracy.
