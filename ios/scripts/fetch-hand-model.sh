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
