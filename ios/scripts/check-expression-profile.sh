#!/bin/bash
set -euo pipefail
expression_root=$(cd "$(dirname "$0")/.." && pwd)
expression_profile=${1:-"$expression_root/Signloop/Resources/DemoExpressionProfile.json"}
if [ ! -s "$expression_profile" ]; then
  echo 'error: Teach and export your expression profile in Expression lab, then run ios/scripts/bundle-expression-profile.sh /path/to/DemoExpressionProfile.json before building HonkAndTellDemo.' >&2
  exit 1
fi
expression_work=$(mktemp -d -t expression-profile-validator)
expression_validator="$expression_work/validator"
trap 'rm -rf "$expression_work"' EXIT
expression_sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx swiftc -sdk "$expression_sdk" -module-cache-path "$expression_work/cache" -parse-as-library \
  "$expression_root/Signloop/Skeleton.swift" \
  "$expression_root/Signloop/ExpressionCues.swift" \
  "$expression_root/Signloop/ExpressionMeasurements.swift" \
  "$expression_root/Signloop/TaughtExpressionProfile.swift" \
  "$expression_root/Tools/ValidateExpressionProfile.swift" -o "$expression_validator"
"$expression_validator" "$expression_profile"
