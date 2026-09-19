#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Signloop/Resources
model=Signloop/Resources/hand_landmarker.task
if [ ! -s "$model" ]; then
  download=$(mktemp)
  trap 'rm -f "$download"' EXIT
  curl --fail --location --retry 3 \
    https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task \
    -o "$download"
  mv "$download" "$model"
fi

# Both app shells now share the Gesture Recognizer tracker.
gesture=Signloop/Resources/gesture_recognizer.task
gesture_sha=97952348cf6a6a4915c2ea1496b4b37ebabc50cbbf80571435643c455f2b0482
if [ ! -s "$gesture" ]; then
  download=$(mktemp)
  trap 'rm -f "$download"' EXIT
  curl --fail --location --retry 3 \
    https://storage.googleapis.com/mediapipe-models/gesture_recognizer/gesture_recognizer/float16/1/gesture_recognizer.task \
    -o "$download"
  echo "$gesture_sha  $download" | shasum -a 256 --check
  mv "$download" "$gesture"
  trap - EXIT
fi
echo "$gesture_sha  $gesture" | shasum -a 256 --check
