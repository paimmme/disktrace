#!/bin/bash
# Builds DiskTrace and runs the automated test suite.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
echo "== swift build =="
swift build
echo "== swift test =="
swift test
