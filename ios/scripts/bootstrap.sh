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
bash scripts/fetch-hand-model.sh
xcodegen generate
