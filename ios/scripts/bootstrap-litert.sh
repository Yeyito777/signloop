#!/bin/bash
# Pinned headers + official Swift wrapper, NOT another inference binary/model.
set -euo pipefail
cd "$(dirname "$0")/.."
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
mkdir -p Vendor/TensorFlowLiteHeaders Vendor/TensorFlowLiteSwift Signloop/Resources
if [ ! -f Vendor/TensorFlowLiteHeaders/TensorFlowLiteC/c_api.h ]; then
  archive="$temporary/sdk.tar.gz"
  curl --fail --location --retry 3 \
    'https://dl.google.com/tflite-release/ios/prod/tensorflow/lite/release/ios/release/32/20240729-115310/TensorFlowLiteC/2.17.0/0c10b3543e01f547/TensorFlowLiteC-2.17.0.tar.gz' \
    -o "$archive"
  echo "9667b476015f136e5b332ce040e12822c4ac6d5c58947882ddc809cdff0fb99e  $archive" | shasum -a 256 --check
  headers=TensorFlowLiteC-2.17.0/Frameworks/TensorFlowLiteC.xcframework/ios-arm64/TensorFlowLiteC.framework/Headers
  tar -xzf "$archive" -C "$temporary" "$headers"
  cp -R "$temporary/$headers" Vendor/TensorFlowLiteHeaders/TensorFlowLiteC
fi
for name in Delegate Interpreter InterpreterError Model QuantizationParameters SignatureRunner SignatureRunnerError Tensor TensorFlowLite; do
  file="Vendor/TensorFlowLiteSwift/$name.swift"
  if [ ! -f "$file" ]; then
    curl --fail --location --retry 3 \
      "https://raw.githubusercontent.com/tensorflow/tensorflow/v2.17.0/tensorflow/lite/swift/Sources/$name.swift" \
      -o "$temporary/$name.swift"
    expected=$(awk -v path="TensorFlowLiteSwift/$name.swift" '$2 == path { print $1 }' scripts/litert-sources.sha256)
    echo "$expected  $temporary/$name.swift" | shasum -a 256 --check
    mv "$temporary/$name.swift" "$file"
  fi
done
if [ ! -f Vendor/TensorFlowLite-LICENSE.txt ]; then
  curl --fail --location --retry 3 \
    https://raw.githubusercontent.com/tensorflow/tensorflow/v2.17.0/LICENSE \
    -o "$temporary/LICENSE"
  echo "71c6915d04265772a0339bed47276942c678b45cc01534210ebe6984fd1aec65  $temporary/LICENSE" | shasum -a 256 --check
  mv "$temporary/LICENSE" Vendor/TensorFlowLite-LICENSE.txt
fi
(cd Vendor && shasum -a 256 --check ../scripts/litert-sources.sha256)
cp Vendor/TensorFlowLite-LICENSE.txt Signloop/Resources/TensorFlowLite-LICENSE.txt
