#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc "Managed View/KioskConfiguration.swift" Tests/main.swift -o "$test_dir/configuration-tests"
"$test_dir/configuration-tests"
