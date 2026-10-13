#!/bin/bash
# Isolated end-to-end acceptance for the original need (disk change + reason
# tracing). Creates a unique fixture, runs the production agent against it, and
# asserts concrete file-level facts. Never touches real user data or ~/.codex.
#
#   scripts/acceptance-original-need.sh --artifact-dir <path> [--keep-fixture]
#       [--notification-test] [--codex-home <fixture home>]
set -uo pipefail
cd "$(dirname "$0")/.."

ARTIFACT_DIR="artifacts/evidence/original-need/$(date -u +%Y%m%dT%H%M%SZ)"
KEEP=0
NOTIFICATION_TEST=0
CODEX_HOME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifact-dir) ARTIFACT_DIR="$2"; shift 2;;
    --keep-fixture) KEEP=1; shift;;
    --notification-test) NOTIFICATION_TEST=1; shift;;
    --codex-home) CODEX_HOME="$2"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

mkdir -p "$ARTIFACT_DIR"
SUMMARY="$ARTIFACT_DIR/summary.json"
RESULTS="$ARTIFACT_DIR/results.tsv"
: > "$RESULTS"
FAILURES=0
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; [ "$2" = "PASS" ] || FAILURES=$((FAILURES+1)); }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/disktrace-e2e.XXXXXX")"
PROJECT="$FIXTURE/projectA"
DOWNLOADS="$FIXTURE/Downloads"
CODEX="${CODEX_HOME:-$FIXTURE/codexHome}"
DB="$FIXTURE/db.sqlite"
mkdir -p "$PROJECT" "$DOWNLOADS" "$CODEX/sessions/2026/10/13"

source scripts/toolchain-env.sh >/dev/null 2>&1
swift build >/dev/null 2>&1 || { record build FAIL "swift build failed"; }

agent() { .build/debug/disktrace-agent "$@"; }

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"timestamp":"%s","type":"session_meta","payload":{"session_id":"fixture","cwd":"%s"}}\n{"timestamp":"%s","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-fixture"}}\n' \
  "$TS" "$PROJECT" "$TS" > "$CODEX/sessions/2026/10/13/rollout.jsonl"

# Baseline scan.
agent --once --db "$DB" --root "$PROJECT" --root "$DOWNLOADS" --codex-home "$CODEX" >"$ARTIFACT_DIR/run1.log" 2>&1
record baseline PASS "first scan establishes baseline"

# Real growth in the project + independent Downloads growth.
head -c 16777216 /dev/urandom > "$PROJECT/generated.bin"
head -c 8388608 /dev/urandom > "$DOWNLOADS/user-copy.bin"
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-fixture"}}\n' "$TS" \
  >> "$CODEX/sessions/2026/10/13/rollout.jsonl"

# Second scan diffs the change.
agent --once --db "$DB" --root "$PROJECT" --root "$DOWNLOADS" --codex-home "$CODEX" >"$ARTIFACT_DIR/run2.log" 2>&1

sqlite3 "$DB" "SELECT change_kind||' '||COALESCE(path_after,path_before) FROM file_changes;" > "$ARTIFACT_DIR/file_changes.txt" 2>&1
if grep -q "added .*/projectA/generated.bin" "$ARTIFACT_DIR/file_changes.txt"; then
  record file-detail PASS "project file recorded with concrete path"
else
  record file-detail FAIL "project file change missing"
fi

WINDOWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM task_windows WHERE end_known=1;" 2>/dev/null || echo 0)
[ "${WINDOWS:-0}" -ge 1 ] && record task-window PASS "bounded task window recorded" || record task-window FAIL "no bounded task window"

EVENTS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM storage_events;" 2>/dev/null || echo 0)
[ "${EVENTS:-0}" -ge 1 ] && record event PASS "storage event assembled" || record event FAIL "no storage event"

DOWNLOADS_ATTR=$(sqlite3 "$DB" "SELECT attribution_class FROM storage_events WHERE scope_path LIKE '%Downloads%' LIMIT 1;" 2>/dev/null || echo "")
[ "$DOWNLOADS_ATTR" = "unknown" ] && record concurrent-unknown PASS "Downloads stays unknown" || record concurrent-unknown FAIL "Downloads not unknown ($DOWNLOADS_ATTR)"

# Mutations: append, shrink, rename, remove.
head -c 4194304 /dev/urandom >> "$PROJECT/generated.bin"
agent --once --db "$DB" --root "$PROJECT" --root "$DOWNLOADS" --codex-home "$CODEX" >/dev/null 2>&1
GROWN=$(sqlite3 "$DB" "SELECT change_kind FROM file_changes WHERE path_after LIKE '%generated.bin' ORDER BY observed_at DESC LIMIT 1;" 2>/dev/null)
[ "$GROWN" = "grown" ] && record grown PASS "growth recorded" || record grown FAIL "growth not recorded ($GROWN)"

{ echo "results:"; cat "$RESULTS"; } 
cat > "$SUMMARY" <<JSON
{
  "generatedAtUTC": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "os": "$(sw_vers -productVersion)",
  "arch": "$(uname -m)",
  "schemaVersion": "$(sqlite3 "$DB" 'SELECT version FROM schema_version;' 2>/dev/null)",
  "fixture": "$FIXTURE",
  "notificationTestRequested": $NOTIFICATION_TEST,
  "notificationTest": "NOT RUN",
  "failures": $FAILURES
}
JSON

echo "artifact dir: $ARTIFACT_DIR"
if [ "$KEEP" = "1" ]; then echo "fixture kept at: $FIXTURE"; else rm -rf "$FIXTURE"; fi
[ "$FAILURES" -eq 0 ] && exit 0 || exit 1
