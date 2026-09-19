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
if [ ! -f Signloop/Resources/hand_landmarker.task ]; then
  curl --fail --location --retry 3 \
    https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task \
    -o Signloop/Resources/hand_landmarker.task
fi
gesture=Signloop/Resources/gesture_recognizer.task
gesture_sha=97952348cf6a6a4915c2ea1496b4b37ebabc50cbbf80571435643c455f2b0482
if [ ! -f "$gesture" ]; then
  temporary=$(mktemp)
  trap 'rm -f "$temporary"' EXIT
  curl --fail --location --retry 3 \
    https://storage.googleapis.com/mediapipe-models/gesture_recognizer/gesture_recognizer/float16/1/gesture_recognizer.task \
    -o "$temporary"
  echo "$gesture_sha  $temporary" | shasum -a 256 --check
  mv "$temporary" "$gesture"
  trap - EXIT
fi
echo "$gesture_sha  $gesture" | shasum -a 256 --check
xcodegen generate
