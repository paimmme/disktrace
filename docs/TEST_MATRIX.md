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
- `RetentionTests` — per-table pruning, open-gap/rule protection, quota + space report.
- `CodexSyncTests` — privacy (decoys ignored, no content stored), idempotent re-sync, incremental append, truncation reset + gap, oversized-record skip, parser escapes/unicode/nesting, hashed working directory.
- `DeltaTests` — deleted-directory union, rename = two records, add+delete same window, incomplete ⇒ no delta, non-overlapping selection.
- `MonitorCompletenessTests` — incomplete recalibration gap + recovery diff, per-root state independence.
- `FixtureScannerTests` — subtree sizes, exclusions, incomplete-on-permission.
- `MonitorCoordinatorTests` — silent→alert end-to-end, unavailable-scanner gap, explicit gap.
- `FullFlowTests` — start agent → append session log + write directories → calibration → database holds the matching activity, delta and decision.
- `ChangeMonitorTests` — live FSEvents capture, bounded queue.
- `VolumeSamplerTests` — real volume sample.

48 tests in 12 suites, all passing. Raw evidence: `artifacts/evidence/tests-*.txt`.

| Guarantee | Covered by |
|---|---|
| No duplicate collection on repeated sync | `CodexSyncTests.idempotentResync` |
| No missed new task in appended log | `CodexSyncTests.incrementalAppend`, `FullFlowTests` |
| Permission recovery is not counted as growth | `DeltaTests.incompleteYieldsNothing`, `MonitorCompletenessTests.incompleteThenRecovery` |
| Truncation/rotation recorded, not silently absorbed | `CodexSyncTests.truncationResets` |
| Database occupancy is explainable and bounded | `RetentionTests.quotaPrunes` (effective pages + file size) |

## 原始需求闭环（本轮新增，99 tests / 20 suites）

新增测试套件覆盖规格的 C/D/E/N 场景：

- `CodexEnvelopeTests`（C01–C18）：真实 `event_msg` 信封、256B/轮读到最后完整行、全局预算受限、半行跨重启、超长行跳过、discard 跨重启、重复 start/end 幂等、重启保留原始开始时间、缺失开始=unknownStart、并发任务、诱饵正文不解码、malformed 失败闭合、desktop originator 不误标、401 日志无饥饿。
- `FileChangeTests`（D01–D17）：基线不产生变化、新增/增长/缩小、删除整棵子树、同路径替换、同 identity 重命名=一条 moved、硬链接共享 identity、瞬时文件无事实、hint 幂等、symlink 不跟随。
- `EventAssemblyTests`（E01–E12）：项目候选不被根吞并、Downloads 保持 unknown、同目录两任务 ambiguous、仅时间重合=timeOnly、cwd 外缓存类型可见来源未知、node_modules 名称线索仍 unknown、用户确认/撤销、presence present/replaced/missing。
- `NotificationTests`（N09/N11/N12 等）：outbox 幂等、冷却抑制、quiet hours 延期、到期丢弃、critical 突破免打扰、`acceptedByOS` 语义、文案合同不含“下载/垃圾/可放心删除”。

- `MetadataProbe` / `StreamingScanner`：`FixtureScannerTests` + `FileChangeTests.D08`（symlink 不跟随）。

**99 tests in 20 suites, all passing.** 隔离端到端：`scripts/acceptance-original-need.sh`（全部断言 PASS）。原始证据：`artifacts/evidence/original-need/`。

真实机器 / 真实客户端 / 通知 / 登录恢复 / 24 小时资源：见 `docs/ORIGINAL_NEED_ACCEPTANCE.md`（NOT RUN/BLOCKED）。
