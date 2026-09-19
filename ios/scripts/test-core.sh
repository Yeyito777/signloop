#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary=$(mktemp -t signloop-tests)
trap 'rm -f "$binary"' EXIT
swiftc Signloop/Recognition.swift Tests/main.swift -o "$binary"
"$binary"
swiftc -parse-as-library Signloop/Recognition.swift Signloop/LiveWindowPolicy.swift Tests/LiveWindowTests.swift -o "$binary"
"$binary"
swiftc -parse-as-library Signloop/Recognition.swift Signloop/LiveWindowPolicy.swift Signloop/CaptureCadence.swift Tests/CaptureCadenceTests.swift -o "$binary"
"$binary"
