#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo 'Usage: npm run camera:recover-expressions -- DEVICE_ID' >&2
  exit 2
fi
expression_device="$1"
cd "$(dirname "$0")/../.."
expression_work=$(mktemp -d)
trap 'rm -rf "$expression_work"' EXIT
# Read the saved checked profile without modifying the standalone scanner.
xcrun devicectl device copy from --device "$expression_device" \
  --source 'Library/Application Support/Signloop/demo-expressions.json' \
  --destination "$expression_work/DemoExpressionProfile.json" \
  --domain-type appDataContainer --domain-identifier com.yeyito.signloop --timeout 30
bash ios/scripts/bundle-expression-profile.sh "$expression_work/DemoExpressionProfile.json"
echo 'Checked profile recovered into the gitignored bundle asset. Reinstall pods and rebuild the goose app to include it.'
