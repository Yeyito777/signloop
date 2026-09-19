# Signloop worktree flow

Each task gets a branch and a checkout in `.worktrees/<name>`. The main checkout
stays on `yeyito`; creating a worktree does not switch it or change `main`.

## Setup and daily use

```sh
# One time per clone: enable versioned hooks, without overriding custom hooks.
scripts/dev/setup-worktrees

# Cached MediaPipe binaries/model make subsequent worktrees fast/offline.
bash ios/scripts/bootstrap.sh

# Default base: HEAD of the checkout whose script you invoke.
scripts/dev/create-worktree camera-polish
# Or explicitly start from current remote main (fetch first).
git fetch origin
scripts/dev/create-worktree classifier-client origin/main

scripts/dev/signlooptest camera-polish          # core Swift tests
scripts/dev/signlooptest camera-polish backend  # offline Python backend tests
scripts/dev/signlooptest camera-polish native   # Swift HTTP, DTW and pretrained policy parity
scripts/dev/signlooptest camera-polish build    # unsigned iPhone build
scripts/dev/signlooptest camera-polish open     # open its own Xcode project

cd .worktrees/camera-polish
# Edit, commit and push this task branch as usual.
scripts/dev/signlooptest . core
```

Names must be simple Git branch names (letters, digits, dots, underscores,
hyphens), not paths or slash-separated branch names. Existing branches/paths
are never overwritten. Uncommitted edits in the source checkout are **not**
included: commit the work you need before creating a task checkout.

## Merge and clean

Merge the task branch into `yeyito` or `main`, then:

```sh
scripts/dev/clean-worktree camera-polish
# Also accepts .worktrees/camera-polish or its absolute path.
```

Cleaning removes the task checkout, its ignored build artifacts, and its **local**
branch. It never removes remote branches, `yeyito`, `main`, or arbitrary paths.
The persistent `yeyito` branch is not a disposable worktree.

Cleanup refuses tracked changes, untracked files, locked worktrees, detached or
reassigned branches, and commits not integrated into the main checkout's HEAD,
local `main`, or the locally fetched `origin/main`. A newly created branch with no
new commits is also safe to clean. Fetch after merging on GitHub. Squash/rebase
merges do not preserve ancestry: inspect and manage those task branches manually.
There is intentionally no force-clean switch.

Failed bootstrap attempts are rolled back only when Git can safely remove the
checkout; otherwise the checkout is retained for inspection. Cleanup only manages
worktrees created by these scripts (identified by ignored local metadata).

## What is shared, what is isolated

| Resource | Behavior |
| --- | --- |
| Git objects and refs | Shared normally by Git |
| `ios/Vendor` + MediaPipe models | Seeded if bootstrap scripts and LiteRT source manifest match; APFS clone-copy or regular copy, **not symlinks**. Includes verified header/Swift bindings, never research models/data |
| Xcode project | Generated independently per worktree |
| DerivedData / products | Per-worktree `ios/build` for `signlooptest build` |
| Signing / device deployment | Not automated by this flow; choose your team in Xcode |
| Secrets / `.env` | Never copied or linked; no API credentials needed |
| Runtime services / ports | Camera mode needs none. Optional backend is started explicitly; use a distinct port per worktree |

Build mode explicitly disables signing and never installs, launches, replaces,
or stops an app on your phone. Xcode Run is an intentional separate step. Task
checkouts use the same `com.yeyito.signloop` identifier by default, so deploying
one will replace the existing Signloop app. Use a different bundle identifier
and valid signing configuration if you need simultaneous phone installs.

`post-checkout` is best-effort and offline-only: it regenerates an Xcode project
when the dependencies already exist. It never downloads, signs, installs, or
starts anything. Explicit `create-worktree` skips the hook and performs the full
bootstrap once. The setup script changes only this repository's `core.hooksPath`
and refuses to replace an existing custom hook path.

Scripts work from the main checkout or a managed worktree, including paths with
spaces, on macOS's Bash 3.2. Shared-resource resolution always uses Git's common
directory, avoiding recursive/self-referential worktree layouts. Conventional
non-bare repositories with a `.git` directory are supported.

## Flow smoke test

After committing script changes, with XcodeGen and cached dependencies available:

```sh
scripts/dev/test-worktrees
```

This creates disposable worktrees, runs core tests, checks independent artifacts,
duplicate/path/dirty/unmerged guards, invokes scripts from inside a worktree,
then removes both task checkouts and branches. It never touches remote branches.

For live cloud inference, see [backend setup](backend.md). `.env` files are
never seeded automatically; pass an explicit `--env-file` path. No live samples
or reference recordings are saved. Stop a worktree's backend before cleaning.

Build 11's camera uses the offline [multimodal skeleton](multimodal-skeleton.md).
Seeding includes official hand, gesture, pose-lite and face task bundles.
Legacy cloud research is not connected to the camera UI.

Adapted from Exocortex's `create-worktree`, `clean-worktree`, `worktree-common.sh`,
`post-checkout`, and `exotest`. On this Mac those references were found under
`~/Desktop/Exocortex`; the supplied `~/Workspace/.../record` reference was not
present. No daemon lifecycle or shared-secret behavior was imported into this
camera-only iOS project.
