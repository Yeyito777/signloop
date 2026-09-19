#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary=$(mktemp -t signloop-tests)
trap 'rm -f "$binary"' EXIT
swiftc Signloop/Recognition.swift Tests/main.swift -o "$binary"
"$binary"
