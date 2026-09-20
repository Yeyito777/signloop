#!/bin/bash
set -euo pipefail
expression_root=$(cd "$(dirname "$0")/.." && pwd)
if [ "$#" != 1 ]; then
  echo 'Usage: bash ios/scripts/bundle-expression-profile.sh /path/to/DemoExpressionProfile.json' >&2
  exit 1
fi
bash "$expression_root/scripts/check-expression-profile.sh" "$1"
mkdir -p "$expression_root/Signloop/Resources"
expression_target="$expression_root/Signloop/Resources/DemoExpressionProfile.json"
# Stage the validated export atomically; do not leave a half-written bundle asset.
expression_staged=$(mktemp "$expression_root/Signloop/Resources/.demo-profile.XXXXXX")
trap 'rm -f "$expression_staged"' EXIT
cp "$1" "$expression_staged"
mv "$expression_staged" "$expression_target"
echo 'Checked demo profile staged. Standalone: run HonkAndTellDemo. Goose/Expo: reinstall pods and rebuild to bundle this profile. Neither demo needs teaching UI.'
