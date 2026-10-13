# Test Matrix

Legend: **PASS** (executed here), **NOT RUN** (not executed), **BLOCKED**
(cannot be executed in this environment). Automated results come from
`swift test` (36 tests, all passing). The acceptance IDs mirror PRD v4.0 §8.

| ID | Requirement | Status | Where / why |
|---|---|---|---|
| T01 | First launch & background run; pause/resume/stop semantics | **PARTIAL** | `MonitorCoordinatorTests` (`start`, `runOnce`, gap on unavailable scanner). No LaunchAgent registration or pause/resume UI is built. |
| T02 | Add/delete/move/hardlink/clone accounting | **PARTIAL** | `FixtureScannerTests` (subtree sizes, exclusions, incomplete-on-permission) + `MonitorCoordinator` end-to-end delta. APFS clone/hardlink accounting not specifically verified (fixture scanner counts allocated size per file). |
| T03 | Finder/browser user actions recorded but not mislabelled | **PASS (algorithm)** | `AlertPolicyTests.finderHintIsUserProbable`; no path is ever auto-labelled `userConfirmed` without explicit feedback. No real Finder run. |
| T04 | Evidence-backed Codex task growth alerts | **PARTIAL** | `AlertPolicyTests` (confirmed/probable) + `MonitorCoordinator` end-to-end with an overlapping activity. **G4 NOT RUN** — no real Codex client. |
| T05 | Concurrent user + agent activity keeps unknown unknown | **PASS (algorithm)** | `concurrentEvidenceNeverAccuses` — time overlap + cache hint + 50 GB growth stays `unknown`/silent. |
| T06 | Deep trace runs only when authorized, degrades safely | **BLOCKED** | G5 blocked; not faked. |
| T07 | Event-pressure: dedup, bounded queue, gaps | **PASS** | `ChangeMonitorTests.boundedQueueNeverExceedsCapacity` (capacity 2, 40 files) and coalescing in `capturesWrites`. |
| T08 | Sleep/interrupt & self-heal; no silent history overwrite | **PARTIAL** | `recordGap` persists a `CoverageGap`; retention never rebuilds a corrupt DB (it only deletes reconstructable rows). Sleep/wake and crash recovery not executed. |
| T09 | Alert filtering: silent expected, neutral low-space, revocable rules | **PASS (algorithm)** | `AlertPolicyTests` matrix + `UserRuleTests` (scoped/glob/revoked/expired). |
| T10 | Privacy: no prompt/command/secret persisted | **PASS (unit)** | `CodexReaderTests.extractsMetadataOnly` writes a `SUPER-SECRET` prompt/command into a log and asserts the produced `AgentActivity` contains only hashed id + window + cwd. |
| T11 | Idle performance & retention quota | **NOT RUN** | See `docs/PERFORMANCE.md`. Retention itself is covered by `RetentionTests`. |
| T12 | Distribution, update, dual-arch | **BLOCKED** | G7. |
| T13 | Health view & manual cleanup | **PARTIAL** | `MonitorHealth` is implemented and returned; Finder reveal / Trash confirmation are not built. |

## Automated inventory (`swift test`)

- `AlertPolicyTests` — 12 cases covering the decision matrix.
- `UserRuleTests` — subtree, glob, revoked/expired.
- `StoreTests` — migration idempotence, sample round-trip/range, delta filter, notifying decisions, rules, state + last-alert.
- `RetentionTests` — downsampling + evidence deletion, quota pruning.
- `CodexReaderTests` — privacy (content never stored), hashing, missing home, key whitelist.
- `FixtureScannerTests` — subtree sizes, exclusions, incomplete-on-permission.
- `MonitorCoordinatorTests` — silent→alert end-to-end, unavailable-scanner gap, explicit gap.
- `ChangeMonitorTests` — live FSEvents capture, bounded queue.
- `VolumeSamplerTests` — real volume sample.

Raw evidence: `artifacts/evidence/tests-*.txt`.
