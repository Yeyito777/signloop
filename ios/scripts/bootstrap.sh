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
done
if [ ! -f Signloop/Resources/hand_landmarker.task ]; then
  curl --fail --location --retry 3 \
    https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task \
    -o Signloop/Resources/hand_landmarker.task
fi
xcodegen generate
