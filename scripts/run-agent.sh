#!/bin/bash
# Runs the background agent once (or continuously) against a root.
# Usage: scripts/run-agent.sh [--once] [<root>...]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh

DB="${DISKTRACE_DB:-$HOME/Library/Application Support/DiskTrace/disktrace.sqlite}"
once_flag=""
roots=()
for arg in "$@"; do
  if [ "$arg" = "--once" ]; then once_flag="--once"; else roots+=("$arg"); fi
done
if [ "${#roots[@]}" -eq 0 ]; then roots=("$HOME"); fi

args=("--db" "$DB")
for r in "${roots[@]}"; do args+=("--root" "$r"); done
[ -n "$once_flag" ] && args+=("--once")

swift run disktrace-agent "${args[@]}"
