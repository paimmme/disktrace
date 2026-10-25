#!/bin/bash
# Stop writer → backup DB → package app → merge optional cache roots → start agent.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/DiskTrace"
DB="$SUPPORT/disktrace.sqlite"
APP="$HOME/Applications/DiskTrace Local.app"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$SUPPORT/backups/before-interval-slice-$STAMP"
COMMIT="$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

export DISKTRACE_GIT_COMMIT="$COMMIT"
export DISKTRACE_SWIFT_TC="${DISKTRACE_SWIFT_TC:-$HOME/.cache/disktrace-toolchain/expanded/swifttc/swift-6.2-RELEASE-osx-package.pkg/Payload}"

echo "== stop background writer =="
launchctl remove local.disktrace.monitor 2>/dev/null || true
for _ in {1..30}; do
  if pgrep -f 'DiskTraceAgent.app/Contents/MacOS/DiskTraceAgent' >/dev/null; then
    sleep 1
  else
    break
  fi
done
pkill -f 'DiskTraceAgent.app/Contents/MacOS/DiskTraceAgent' 2>/dev/null || true
sleep 2

echo "== backup database =="
mkdir -p "$BACKUP_DIR"
if [ -f "$DB" ]; then
  sqlite3 "$DB" ".backup '$BACKUP_DIR/disktrace.sqlite'"
  sqlite3 "$BACKUP_DIR/disktrace.sqlite" "PRAGMA integrity_check;" | grep -q '^ok$'
  cp -a "$DB"-wal "$DB"-shm "$BACKUP_DIR/" 2>/dev/null || true
  echo "backup ok: $BACKUP_DIR"
fi

echo "== merge monitor roots (optional caches) =="
python3 - "$SUPPORT/local-run.json" "$COMMIT" <<'PY'
import json, os, pathlib, sys
path, commit = pathlib.Path(sys.argv[1]), sys.argv[2]
data = json.loads(path.read_text()) if path.exists() else {}
extra = []
home = pathlib.Path.home()
for rel in [
    "Library/Caches/com.openai.codex",
    "Library/Caches/Codex",
]:
    p = home / rel
    if p.is_dir():
        extra.append(str(p))
roots = list(dict.fromkeys(data.get("roots", []) + extra))
data["roots"] = roots
data["commit"] = commit
data["buildSlice"] = "interval-explanation-20261024"
data["app"] = str(pathlib.Path.home() / "Applications/DiskTrace Local.app")
path.write_text(json.dumps(data, indent=2) + "\n")
print("roots:", len(roots), "added:", len(extra))
PY

echo "== package app =="
cd "$REPO"
scripts/package-local.sh --output "$APP" --configuration release --sign-identity -

echo "== migrate + codex acceptance (single writer) =="
BIN="$REPO/.build/release/disktrace-agent"
"$BIN" --verify-codex-client --db "$DB" --codex-home "$HOME/.codex"

echo "== start agent =="
mkdir -p "$SUPPORT/logs"
launchctl submit -l local.disktrace.monitor \
  -o "$SUPPORT/logs/agent.stdout.log" \
  -e "$SUPPORT/logs/agent.stderr.log" \
  -- "$APP/Contents/Library/LoginItems/DiskTraceAgent.app/Contents/MacOS/DiskTraceAgent"

echo "deploy complete; commit=$COMMIT backup=$BACKUP_DIR"
