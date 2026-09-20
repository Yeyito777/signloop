#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Signloop/Resources
fetch() {
  local name="$1" sha="$2" url="$3" target="Signloop/Resources/$1.task"
  if [ ! -s "$target" ]; then
    local temp
    temp=$(mktemp)
    trap 'rm -f "$temp"' RETURN
    curl --fail --location --retry 3 "$url" -o "$temp"
    echo "$sha  $temp" | shasum -a 256 --check
    mv "$temp" "$target"
    trap - RETURN
  fi
  echo "$sha  $target" | shasum -a 256 --check
}
fetch hand_landmarker fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1 \
  https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task
fetch pose_landmarker_lite 59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a \
  https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task
fetch face_landmarker 64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff \
  https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
