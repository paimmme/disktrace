# Limitations

Honest, current limits. None of these is hidden behind marketing language.

## Not verified / not built

- **No direct RadixCore dependency.** It has no public API and needs the macOS 26
  SDK. DiskTrace ships its own fixture scanner and a gated Radix adapter.
- **No incremental subtree splicing.** Directory recalibration is a periodic
  **full** scan of each monitored root, diffed against the previous result. This
  is correct but does more I/O than an event-driven splice.
- **No real process-level tracer.** Deep trace is `NOT SHIPPABLE`. No PID or
  path-write evidence is produced, and time overlap alone is never upgraded to a
  confirmed attribution.
- **No real Codex client validation.** Only a read-only metadata reader exists,
  tested against synthetic logs; CLI/IDE/Desktop coverage is unverified.
- **No production packaging, signing, notarization, `SMAppService` registration, updater,
  or Universal build.** A locally ad-hoc-signed app bundle now runs on the development Mac; this does not establish distributable installation.
- **No memory or idle-CPU measurement.** The `<50 MB` / `<0.5 % CPU` targets are
  unmeasured.
- **No sleep/wake or crash-recovery execution.** Coverage-gap recording exists but
  the recovery flow was not exercised on a real machine.

## Design boundaries (deliberate)

- DiskTrace cannot reliably detect "the user personally clicked download". It
  records expected activity and stays silent, and reserves confirmed user
  attribution for explicit feedback/rules. When it cannot attribute a change it
  says `unknown`.
- Free space, monitored-directory net growth and write I/O bytes are different
  metrics; they are not forced to reconcile. APFS clones, hard links, snapshots
  and purgeable space can make them diverge.
- Low-space is a neutral safety alert, never attributed to an agent.
- The policy decides notifications only; it never deletes observation history.

## Known rough edges in this repo

- `DiskTraceApp` runs as a local bundle with a read-only database connection and automatic refresh. Real task attribution, file-level history and system notifications remain incomplete; see `PRODUCT_STATUS.md`.
- `RadixScannerBackend` is a compile-time placeholder that always reports
  unavailable; wiring it requires the vendored+patched upstream described in
  `docs/REUSE_AUDIT.md`.

## Session sync & retention (reviewed behaviours)

- **Event type names are unverified.** The recognised Codex event `type` values
  (session/task start/end) are a configurable default; real client names must be
  confirmed per client (G4). Until then, real task windows may degrade to an
  open, lower-confidence session window.
- **Cross-restart partial line is currently lost.** The cursor is persisted at the read position, not necessarily a complete-line boundary, while the partial record is in memory only. A regression check reproduced failure to recover the task event after restart.
- **Session identity and working directory persist across restarts** (schema v3),
  but **open-task state is in memory only**: if the agent restarts while a task
  is open, its start event was already consumed and is not re-read, so the
  eventual completion still produces an activity but with an approximate window.
- **auto_vacuum only applies to new databases.** An existing database keeps its
  `auto_vacuum` setting; space reclamation then relies on WAL checkpoint and row
  deletion (freelist), not `incremental_vacuum`. A full `VACUUM` is never run
  automatically — converting an old database is a separate, manual maintenance
  step so a low-disk machine is not surprised by a large rewrite.
- **Directory recalibration is periodic full-scan**, not event-driven subtree
  splicing (see G3).
- **`claudeCode`** is modelled in the enum but has no adapter.

## 原始需求闭环（本轮新增）的已知限制

- **真实客户端未验证**：Codex 事件信封与 `originator/source/cli_version` 来自本机白名单观察，不是稳定公共合同；未观察到的版本一律降级为 unknown，不猜兼容。`client_verification` 只有验收程序能写 `realClientVerified`。
- **live hint 的逐路径探测**：2026-10-24 切片起，`change_hints` 会写入 `pending_path_work`，由 `PathHintProcessor` + `MetadataProbe` 产生 `liveHintWindow` 的 `file_changes`（有界、可幂等）。**周期扫描仍是主覆盖**；hint 闭环不保证捕获扫描间隔内的短命文件；真实客户端任务归因仍见 `PRODUCT_STATUS.md`。
- **目录校准为周期全量扫描**，不是事件驱动的子树拼接；正确但 I/O 更多。
- **任务窗口的开放式/未结束**不会成为 `agentProbable` 的唯一证据；`agentConfirmed` 在本任务**永不产生**（无进程级能力）。
- **presence checks** 为时钟驱动；真实 10 分钟/24 小时经过未运行。
- **系统通知**：sink 已实现（`UNUserNotificationCenter`），outbox 幂等、冷却、quiet hours 可测；真实横幅可达性与授权在本地签名环境**未验证**（README/验收矩阵标 NOT RUN）。
- **配额/降载**：软/硬配额、WAL checkpoint 重试、incremental vacuum、低空间暂停新索引；30 分钟空闲 CPU/RSS 未测。
- **索引边界（ADR-10）**：每 root 仅保留一个有效代次 + 至多一个准备代次；被淘汰路径再现时标 `beforeUnknown`。

