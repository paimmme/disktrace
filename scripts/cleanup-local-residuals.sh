#!/bin/bash
# Remove old local DiskTrace app copies and stale deploy backups. Keeps the active app and live database.
set -euo pipefail

APP_DIR="$HOME/Applications"
SUPPORT="$HOME/Library/Application Support/DiskTrace"
KEEP_BACKUPS="${KEEP_BACKUPS:-2}"

echo "== quit running DiskTrace =="
osascript -e 'tell application "DiskTrace Local" to quit' 2>/dev/null || true
osascript -e 'tell application "DiskTrace" to quit' 2>/dev/null || true
sleep 1

echo "== remove superseded .app bundles in ~/Applications =="
shopt -s nullglob
for old in \
  "$APP_DIR"/DiskTrace\ Local.previous-*.app \
  "$APP_DIR"/DiskTrace\ Local.before-repair-*.app; do
  echo "  rm -rf $old"
  rm -rf "$old"
done

echo "== trim deploy DB backups (keep newest $KEEP_BACKUPS) =="
if [ -d "$SUPPORT/backups" ]; then
  i=0
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    i=$((i + 1))
    if [ "$i" -gt "$KEEP_BACKUPS" ]; then
      echo "  rm -rf $dir"
      rm -rf "$dir"
    fi
  done < <(ls -1dt "$SUPPORT/backups"/before-interval-slice-* 2>/dev/null || true)
fi

echo "== optional: repo build cache (safe to delete) =="
REPO="$(cd "$(dirname "$0")/.." && pwd)"
if [ -d "$REPO/.build" ]; then
  echo "  rm -rf $REPO/.build"
  rm -rf "$REPO/.build"
fi

echo "done. kept: $APP_DIR/DiskTrace Local.app and $SUPPORT/disktrace.sqlite (if present)"
