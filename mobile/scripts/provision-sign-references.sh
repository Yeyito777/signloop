#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'Usage: npm run camera:references -- /absolute/path/basic-references.json DEVICE_ID' >&2
  exit 2
fi
reference_file="$1"
device_id="$2"
# Resolve before changing directory, preserving paths containing spaces.
reference_file="$(cd "$(dirname "$reference_file")" && pwd)/$(basename "$reference_file")"
cd "$(dirname "$0")/../.."
validation_dir=$(mktemp -d)
trap 'rm -rf "$validation_dir"' EXIT
swiftc -O -parse-as-library -module-cache-path "$validation_dir/cache" \
  ios/Signloop/Skeleton.swift ios/Signloop/BasicSignMatcher.swift \
  ios/Tools/ValidateBasicReferences.swift -o "$validation_dir/validate"
"$validation_dir/validate" "$reference_file"
xcrun devicectl device copy to --device "$device_id" --source "$reference_file" \
  --destination Documents/basic-references.json \
  --domain-type appDataContainer --domain-identifier com.signloop.mobile --timeout 60
echo 'References installed for the goose app. Open it and tap Retry recognition setup (or Resume).'
