# DiskTrace

**Local-first macOS disk-space forensics for AI coding agents.** DiskTrace answers a question ordinary disk cleaners do not: *when* did the drive fill up, *where* did the growth land, and is there real evidence it was an autonomous Codex / Claude Code task — separate from the downloads and copies you made yourself.

It is **not** a "what is big right now" cleaner. It keeps a low-overhead history of volume free space, monitored-directory net change and bounded filesystem change clues, then attributes changes with explicit, explainable evidence. Expected user activity is recorded but stays silent by default.

> Status: **Runnable prototype; core attribution incomplete; release not ready.** The local UI and capacity history run on a real Mac, but task attribution still has verified defects, file-level history and system notifications are missing. See [`docs/PRODUCT_STATUS.md`](docs/PRODUCT_STATUS.md), [`docs/TECHNICAL_GATES.md`](docs/TECHNICAL_GATES.md) and [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md).

## What works today (verified)

- **Single background Agent** (`disktrace-agent`) that samples volume capacity, watches changes with a bounded, coalescing FSEvents stream, periodically recalibrates directories, evaluates an alert policy and writes everything to one SQLite store.
- **Separation of fact and inference**: `Observation` (volume samples, directory deltas, change hints), `Evidence` and `AlertDecision` are distinct, and a silent rule never deletes observation history.
- **Agent-first alert filtering** as a pure function: time overlap alone can *never* become a confirmed agent alert; low disk space is a neutral, cause-agnostic safety alert.
- **Codex read-only metadata integration** that stores whitelisted metadata. Its structure-aware parser still needs real-client correctness and privacy hardening; see the current product status.
- **Tiered retention** (detail → hourly → daily), per-table pruning and physical storage metrics including WAL/SHM. Quota pruning is based on in-use database pages; it is not a strict cap on all files.
- A query-only **SwiftUI app layer** with Chinese navigation, space history, time filters, automatic refresh, directory changes, evidence details, Finder reveal and monitoring status.
- **50 automated tests pass** (`swift test`), covering the policy matrix, storage/migration idempotence, retention, the privacy reader, scanner, read-only UI queries and synthetic end-to-end attribution. Passing these tests does not establish real-client attribution correctness; see the product status report.

## Explicitly out of scope / not verified

- No cloud account, network service, root daemon, HTTP/WebSocket surface, or automatic deletion.
- No real process-level tracer is shipped; `fs_usage`/Endpoint Security are **not** presented as production-safe. Deep trace is marked `NOT SHIPPABLE`.
- The upstream Radix scanner is **not** wired in (see G1 below). The default backend is a dependency-free fixture scanner.

## Architecture (one agent, one app, one SQLite, one scanner)

```
                +---------------------+        +--------------------------+
                |  disktrace-agent    |        |  DiskTrace app (read-    |
                |  MonitorCoordinator |        |  only SwiftUI/Charts)    |
                +----------+----------+        +------------+-------------+
                           |                                |
   VolumeSampler --+       |                                |
   ChangeMonitor --+--> DiskTraceStore (SQLite, WAL, single writer)
   ScannerBackend -+       |                                |
   CodexSessionReader --+  |                                |
                           v                                v
                     observations/evidence/alerts   read-only snapshots
```

- **Agent** (`Sources/DiskTraceAgent`): volume sampling (default 60 s), bounded FSEvents change coalescing, periodic recalibration, attribution, alert decisions, retention.
- **Core** (`Sources/DiskTraceCore`): models, policy, storage, monitoring, scanner adapters, Codex reader, IPC contract.
- **App** (`Sources/DiskTraceApp`): read-only timeline/growth/health/settings.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the ADRs and the data model.

## Build and run

Requires **macOS 14+** and a **Swift 6.2** toolchain. Upstream Radix needs Xcode 26; DiskTrace core does **not** — it builds with the Command Line Tools SDK (see the toolchain note in `scripts/toolchain-env.sh`).

```bash
swift build          # builds DiskTraceCore, disktrace-agent, DiskTraceApp
swift test           # 50 tests
swift run disktrace-agent --once --db /tmp/dt.sqlite --root ~/Documents
```

The agent entry point accepts `--db <path>`, `--root <path>` (repeatable), `--exclude <path>` (repeatable), `--interval <seconds>`, `--recommended-roots`, `--codex-home <path>`, `--hash-codex-paths` and `--once`.

With `--recommended-roots` and no `--root`, the agent watches the home folder plus common coding-agent caches (Xcode DerivedData, `~/.npm`, `~/.cursor`, `~/.codex`, etc.) that exist on disk. Session sync reads **Codex** JSONL under `~/.codex/sessions` and **Cursor Agent** transcripts under `~/.cursor/projects/*/agent-transcripts/` (metadata only — no message bodies).

## Technical gates (summary)

| Gate | Result | Note |
|---|---|---|
| G1 RadixCore no-UI use | **FAIL (direct) / PASS (patched)** | No `public` API; requires macOS 26 SDK. Builds headless after 4 small patches. |
| G2 memory release | **NOT RUN** | RSS not yet measured; low-memory isolation is designed but unbuilt. |
| G3 FSEvents incremental correctness | **FAIL (Radix path) / PASS (our full-recalibration path)** | Radix history replay returned 0 events here; our live monitor + delta calibration verified by test. |
| G4 Codex client coverage | **NOT RUN** | Reader implemented + unit-tested against fixtures; no real client install here. |
| G5 shippable process tracer | **BLOCKED / NOT SHIPPABLE** | No distributable entitlement path verified. Not faked. |
| G6 silence-rule accuracy | **PARTIAL** | Policy matrix unit-tested; no real-world false-positive measurement. |
| G7 install/upgrade | **BLOCKED** | Requires signing/notarization/Xcode. |

Details and raw evidence: [`docs/TECHNICAL_GATES.md`](docs/TECHNICAL_GATES.md), [`docs/REUSE_AUDIT.md`](docs/REUSE_AUDIT.md), `artifacts/evidence/`.

## 原始需求进度与本地修复

已有容量历史、具体文件差分、任务候选与提醒基础设施；**尚未完整实现可靠定位到某次 Agent 任务的原始目标**。常规文件事实来自扫描窗口，实时逐路径差分与真实客户端验证仍未完成。

- **具体文件事实**：流式 `MetadataProbe`/`StreamingScanner` 建立有界的当前文件索引代次，代次差分产生
  `file_changes`（added/grown/shrunk/removed/replaced/moved），前值未知写 NULL，绝不写 0 冒充（ADR-10）。
- **Codex 任务元数据解析**：`session_meta` / `event_msg.payload.type` 事件信封、`turn_id`、字节级白名单元数据
  （正文不解码）、完整行游标 + 跨重启恢复 + 任务状态机 + 公平调度。
- **可核验关联**：`EventAssembler` 按 (root, scope, 5 分钟桶) 聚合事件，`AttributionPolicy` 按验证状态/路径/时间
  打候选；时间或目录重合不升级 `agentConfirmed`；未验证客户端不发 Agent 主动提醒。
- **系统提醒链路**：持久 `notification_outbox`（幂等 ID）、冷却、quiet hours、到期；`UNUserNotificationCenter` sink
  位于嵌入式 `DiskTraceAgentApp`（真实送达未验证）。
- **中文只读 UI 闭环**：侧栏「空间概览 / 文件与事件 / 目录变化 / 监控状态」，事件 → 具体文件 → 任务候选 → Finder，
  含未知测量值、文件分页、命令回执和各监控目录状态。
- **自限**：有界 FSEvents 队列、库存行/字节预算、软/硬配额、低空间暂停新索引、WAL checkpoint 重试。

验收分级（工程/本机/真实客户端/登录恢复/发布）与逐项证据见
[`docs/ORIGINAL_NEED_ACCEPTANCE.md`](docs/ORIGINAL_NEED_ACCEPTANCE.md)；启停/配置/迁移/回退见
[`docs/OPERATIONS.md`](docs/OPERATIONS.md)。**真实客户端、系统通知、登录恢复、24 小时资源为 NOT RUN，发布未就绪。**

本轮先按执行文档修复，再在用户 Mac 上备份升级并运行；最终全量 110 项通过。
执行与真机结果见 [`REPAIR_EXECUTION_2191371.md`](docs/implementation/REPAIR_EXECUTION_2191371.md) 和
[`REPAIR_RESULT_20261013.md`](docs/implementation/REPAIR_RESULT_20261013.md)。

## Privacy

DiskTrace does not read file contents, does not collect prompts, commands, source or secrets, and does not upload monitoring metadata. The Codex reader stores only a hashed session id, a time window, an optional (optionally hashed) working directory and a client kind. See [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md).

## License

MIT — see [`LICENSE`](LICENSE). Third-party reuse and its exact upstream commits are recorded in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
