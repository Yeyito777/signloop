#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Signloop/Resources
fetch_model() {
  local name="$1" digest="$2" url="$3" target temporary
  target="Signloop/Resources/$name.task"
  if [ ! -s "$target" ]; then
    temporary=$(mktemp)
    if ! curl --fail --location --retry 3 "$url" -o "$temporary" ||
       ! echo "$digest  $temporary" | shasum -a 256 --check; then
      rm -f "$temporary"
      return 1
    fi
    mv "$temporary" "$target"
  fi
  echo "$digest  $target" | shasum -a 256 --check
}
fetch_model hand_landmarker \
  fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1 \
  https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task
fetch_model pose_landmarker_lite \
  59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a \
  https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task
