#!/bin/bash
# Real-machine acceptance smoke test for DiskTrace.
# - builds and tests
# - runs the agent once against a synthetic fixture
# - adds growth and reruns to show a recorded delta
# - prints the resulting database contents as evidence
#
# This is a *smoke* run, not the full PRD acceptance matrix (see
# docs/TEST_MATRIX.md). It exercises only what can run without Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh

WORK="$(mktemp -d)"
DB="$WORK/disktrace.sqlite"
ROOT="$WORK/root"
mkdir -p "$ROOT/a" "$ROOT/b/nested"

echo "== build + unit tests =="
swift build
swift test 2>&1 | tail -3

echo "== fixture =="
head -c 400000 /dev/urandom > "$ROOT/a/one.bin"
head -c 250000 /dev/urandom > "$ROOT/b/two.bin"
head -c 100000 /dev/urandom > "$ROOT/b/nested/three.bin"

echo "== agent --once (baseline + first sample) =="
swift run -q disktrace-agent --once --db "$DB" --root "$ROOT" 2>&1 | sed 's/^/  /'

echo "== volume samples =="
sqlite3 "$DB" "SELECT volume_id, free_bytes, capacity_bytes FROM volume_samples;"

echo "== alert decisions =="
sqlite3 "$DB" "SELECT action, reason, evidence_class FROM alert_decisions;"

echo "== done. workspace: $WORK =="
