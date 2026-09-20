#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary=$(mktemp -t signloop-tests)
trap 'rm -f "$binary"' EXIT
swiftc Signloop/Recognition.swift Signloop/CaptureLifecycle.swift Tests/main.swift -o "$binary"
"$binary"
swiftc -parse-as-library Signloop/Recognition.swift Signloop/LiveWindowPolicy.swift Tests/LiveWindowTests.swift -o "$binary"
"$binary"
swiftc -parse-as-library Signloop/Recognition.swift Signloop/LiveWindowPolicy.swift Signloop/CaptureCadence.swift Tests/CaptureCadenceTests.swift -o "$binary"
"$binary"
swiftc -parse-as-library Signloop/CaptureFreshness.swift Signloop/CaptureCadence.swift Tests/CaptureFreshnessTests.swift -o "$binary"
"$binary"
swiftc -parse-as-library Signloop/Skeleton.swift Tests/SkeletonTests.swift -o "$binary"
"$binary"
swiftc -parse-as-library Signloop/Skeleton.swift Signloop/ExpressionMeasurements.swift Signloop/ExpressionCues.swift Tests/ExpressionCueTests.swift -o "$binary"
"$binary"
swiftc -parse-as-library Signloop/Skeleton.swift Signloop/ExpressionMeasurements.swift Signloop/ExpressionCues.swift Signloop/TaughtExpressionProfile.swift Signloop/ExpressionTeacher.swift Tests/TaughtExpressionTests.swift -o "$binary"
"$binary"
swiftc -parse-as-library Signloop/Skeleton.swift Signloop/ExpressionMeasurements.swift Signloop/ExpressionCues.swift Signloop/TaughtExpressionProfile.swift Signloop/ExpressionTeacher.swift Tests/NoseScrunchTests.swift -o "$binary"
"$binary"
swiftc -parse-as-library Signloop/Recognition.swift Signloop/SignEngineFeatures.swift Signloop/SignSegmenter.swift Signloop/SignEngine.swift Tests/SignEngineParity.swift -o "$binary"
"$binary" Tests/Fixtures/sign_engine_golden.json
