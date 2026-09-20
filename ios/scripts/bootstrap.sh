#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Vendor Signloop/Resources
for name in MediaPipeTasksCommon MediaPipeTasksVision; do
  if [ ! -d "Vendor/$name/frameworks" ]; then
    archive=$(mktemp)
    curl --fail --location --retry 3 \
      "https://dl.google.com/cpdc/20250131-063213/$name-0.10.21.tar.gz" -o "$archive"
    mkdir -p "Vendor/$name"
    tar -xzf "$archive" -C "Vendor/$name"
    rm "$archive"
  fi
  cp "Vendor/$name/LICENSE" "Signloop/Resources/$name-LICENSE.txt"
done
bash scripts/fetch-hand-model.sh
echo "fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1  Signloop/Resources/hand_landmarker.task" | shasum -a 256 --check
fetch_tracking_model() {
  local name="$1" digest="$2" url="$3" target temporary
  target="Signloop/Resources/$name.task"
  if [ ! -f "$target" ]; then
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
fetch_tracking_model pose_landmarker_lite \
  59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a \
  https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task
fetch_tracking_model face_landmarker \
  64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff \
  https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
bash scripts/bootstrap-litert.sh
xcodegen generate
