#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'Usage: npm run camera:expressions -- /absolute/path/DemoExpressionProfile.json DEVICE_ID' >&2
  exit 2
fi
expression_file="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
expression_device="$2"
cd "$(dirname "$0")/../.."
bash ios/scripts/check-expression-profile.sh "$expression_file"
xcrun devicectl device copy to --device "$expression_device" --source "$expression_file" \
  --destination Documents/DemoExpressionProfile.json \
  --domain-type appDataContainer --domain-identifier com.signloop.mobile --timeout 60
echo 'Checked expression profile installed for the goose app. Pause and resume to load it.'
