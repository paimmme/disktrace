# DiskTrace PR #1 — Review Fix Report

Baseline: `head=5e7f1597d711ba23e6ec83f3300162eb7bf5221d`, `base=7779285815dd25ee1d92f862b1db9e4e02cd7a80`.
Environment: macOS 14.6 (23G80), arm64, Swift 6.2 (extracted toolchain) + CLT 15.0 SDK.
All fixes are on the same PR branch; no force-push, no history rewrite, no user data touched.

Verification now: `swift build` OK · `swift test` → **99 tests / 20 suites PASS** ·
`scripts/acceptance-original-need.sh` → all assertions PASS · SQLite `integrity_check=ok`,
`foreign_key_check` empty.

Machine-readable status: [`acceptance-results.json`](acceptance-results.json).

---

## WP0 — Repository protection & baseline

Confirmed branch/head/PR, captured environment, `git status`, schema/index/PRAGMA snapshot,
build/test/acceptance raw logs and an isolated temp database. No reset/clean; the only prior
untracked content was local evidence (now de-indexed, see WP7).

## WP1 (P0) — Cross-root directory-summary deletion

**Root cause.** `publishScan()` ran `DELETE FROM scan_directory_summaries WHERE scan_id<>?`
with no root scope. `scan_directory_summaries.scan_id` points at a generation, and one database
holds several monitored roots, so publishing root B erased root A's summaries and corrupted A's
next diff.

**Change.** Cleanup is now scoped through `root_scans`:
`DELETE FROM scan_directory_summaries WHERE scan_id IN (SELECT id FROM root_scans WHERE root_id=? AND id<>?)`,
and `file_inventory` cleanup is `WHERE root_id=? AND scan_id<>?`. The previous active generation
is only trusted when `scanOwner(previous) == rootID`; a mis-referenced health row can no longer
drive a cross-root diff or delete.

**Tests (MR01–MR06).** Multi-root isolation (publish B keeps A's summaries), 20 alternating
publishes with integrity/fk checks, root-B failure mid-scan, same-relative-subdir roots, reopen,
and subdir removal in one root. **Rollback:** revert the two DELETE statements and the ownership
guard (isolated to `publishScan`).

## WP2 (P1) — Inventory diff memory

**Root cause.** `loadInventory` materialised both generations into `[String: InventoryRow]`, then
`Set(before.keys).union(after.keys)` — publish memory grew with the file count even though the
scan is streaming.

**Change.** `forEachDiffRow()` streams a single parameterised
`UNION ALL` (new `LEFT JOIN` old, and old `LEFT JOIN` new) that walks the `(root_id, scan_id, path)`
primary key and probes the other generation by index. Changed rows are written in batches of 500
as they stream; additions/removals are held only by identity (bounded by the change set). A
same-identity 1:1 pair with `link_count<=1` on both sides becomes one `moved`; multiple paths
sharing an identity (hardlinks) are **not** merged. Unknown allocated/logical bytes stay `NULL`.

**Evidence.** `EXPLAIN QUERY PLAN` shows both subqueries use index `SEARCH` (no full scan, no temp
sort). `MEM01` (10,000 files) peak test-process RSS ≈ 72 MB; `MEM05` (hardlink identity reuse) does
not fabricate a move. `D01–D17` and `MR01–MR06` still pass, so file semantics are unchanged.

**Limitations.** 100k/500k/1M datasets and real APFS clone/hardlink behaviour are **NOT RUN** on
this machine (15 GB free). **Rollback:** restore `loadInventory` + `Self.diff` + `mergeMoves`.

## WP3 (P1) — Low-space ladder

**Root cause.** `for root where !lowSpace` skipped **all** directory calibration below the
threshold, removing exactly the file facts needed when space is scarce.

**Change.** A `ResourceMode` (normal / constrained / critical) derived from the last free space.
Volume sampling and the neutral low-space safety alert always continue; in constrained/critical
the inventory staging is suspended and each root is marked `RootState.quotaLimited` (never
`ready`), and Codex metadata sync continues. Recovery resumes scans; the interval is a
`recoveryWindow`, not a precise write.

**Tests.** LS01/LS02 (volume + safety alert kept, inventory suspended, health quota-limited, no
file-change growth), LS06 (recovery window semantics). **Rollback:** restore the single `where`.

## WP4 (P1) — Startup baseline recovery

**Root cause.** `start()` unconditionally `scanAndPublish`-ed every root, so a restart/login/UI
close forced a full scan before doing anything useful.

**Change.** `start()` samples volume and enables events immediately; a root that already has an
active generation owned by it (`validActiveGeneration`) is **not** rescanned — the periodic
calibration picks up changes as a `recoveryWindow`. Only roots without a valid generation are
scanned at startup. `publishScan` gained a `timing` parameter, and the first post-start
calibration is stamped `recoveryWindow`.

**Tests.** RE01 (restart with no changes → no spurious facts), RE02 (offline change → recorded with
`timing==.recoveryWindow`). **Rollback:** remove the `validActiveGeneration` early-continue.

## WP5 (PARTIAL) — Notification permission, idempotency, delivery

The outbox already has stable ids, cooldown, quiet hours and expiry (`N09/N11/N12` pass), the
`DiskTraceAgentApp` owns a real bundle identity and `UNUserNotificationCenter` sink, and copy is
privacy-preserving (directory basename; "OS accepted" ≠ "user saw"; never "下载/垃圾/可放心删除"
— `copyContract` test). The **first-run authorization prompt, in-app status display and
"open System Settings" guidance** are the remaining gap. Real authorization/delivery is
`NOT RUN` (no interactive device). **Rollback:** none needed; additive.

## WP6 (P2) — Time / unknown-value semantics & dead code

- The streaming scanner now reports `sizeComplete=false` when any regular file's allocated size is
  unavailable; such generations mark directory deltas `coverageGap` instead of a precise
  `calibrated`, so totals are never presented as exact when they are a lower bound.
- Removed the dead, self-contradictory `AttributionPolicy.scopeDirectory()` /
  `windowCandidateDirectory()` (one filter was always true, the other always returned nil).

## WP7 (P2) — Packaging, docs, evidence hygiene

- `package-local.sh` no longer swallows `codesign --verify` with `|| true`: it captures exit
  codes, fails on any non-zero, and prints a clear ad-hoc-vs-notarized warning.
- `artifacts/` is de-indexed and git-ignored; local absolute paths/usernames were removed from
  tracked docs and evidence. `acceptance-results.json` is sanitized.
- Test-count references corrected to the runner's actual **99 / 20**.

---

## Residual risk / not run

- **G5** process-level tracing: BLOCKED / NOT SHIPPABLE — never faked.
- Real Codex client, real notifications, login recovery, 24h resources, 100k–1M perf, APFS
  hardlink/clone specifics: **NOT RUN / BLOCKED** (see `acceptance-results.json`).
- Live-hint per-path probing (`pending_path_work`) is scaffolded but not wired; file facts
  currently come from periodic generation diffs.

## Merge recommendation

**ENGINEERING_READY_FOR_MERGE** — the P0 cross-root corruption is fixed with regression tests, the
P1 memory/startup/low-space items are addressed, and offline engineering verification is green.
`RELEASE_READY` is **NO**: signing, notarization, dual-arch and real-client/hardware acceptance
remain open.
