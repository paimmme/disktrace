# DiskTrace 原始需求闭环：OpenCode 执行规格

版本：1.0；编写日期：2026-10-13；目标环境：macOS 14+、Swift 6.2、SwiftUI、SQLite。

本文是实施规格，不是已完成功能说明。所有新默认值、数据表和接口均为待执行的设计决定。执行方按本文实现、测试、在本机验证，不再自行扩展产品范围或重新做需求问卷。

## 阅读导航

- 0. 执行前必须知道的事
- 1. 最终交付与验收分级
- 2. 必须先消除的已知缺陷
- 3. 固定技术结构
- 4. 配置合同与默认值
- 5. SQLite 迁移及数据合同
- 6. Codex 日志解析与同步算法
- 7. FSEvents 与检查点
- 8. 单一扫描器的流式改造
- 9. 具体文件差分规则
- 10. 事件组织与避免重复计数
- 11. 原因线索与归因矩阵
- 12. 卷级变化与目录变化的对照
- 13. 提醒政策与实际送达
- 14. 登录恢复、暂停与单写者
- 15. 存储、低空间保护与保留
- 16. UI 执行规格
- 17. 必须实现的接口和文件分工
- 18. 实施顺序与每阶段完成条件
- 19. 自动化测试矩阵（不得删减核心场景）
- 20. 隔离的端到端验收脚本
- 21. 真实 Mac 与真实 Codex 验收
- 22. 性能验收
- 23. 构建、安装、迁移和回退操作
- 24. 交付物与停止条件
- 25. 官方技术依据与本机观察的边界
- 26. 给执行模型的最后约束


## 0. 执行前必须知道的事

### 0.1 唯一核心目标

用户的磁盘本来就紧张；Codex 等 Code Agent 在自动任务中下载依赖、生成产物、留下文件，导致磁盘清理后很快又满。软件必须帮助用户回答：

1. 剩余空间何时下降，下降多少？
2. 增长落在哪些目录和具体文件？
3. 哪些增长与某次 Agent 任务存在可核验关联，哪些原因仍然未知？
4. 哪些相关文件在任务结束后仍然存在，在哪里能找到？
5. 能否及时提醒，并在重新登录后继续积累历史？

“原因”至少拆成**文件类型/位置线索**和**写入来源/任务关联**。`node_modules` 变大只能说明依赖目录变化，不能单凭目录名认定 Codex 下载；文件在任务后仍存在也不能证明它无用或可安全删除。

### 0.2 代码与正在运行的环境

- 实际源码：`$HOME/Documents/DiskTrace`；不是 `Documents/Default Project`。
- Git 基线 HEAD：`7779285815dd25ee1d92f862b1db9e4e02cd7a80`。
- HEAD 之后有已完成且未提交的 UI、只读连接、测试和文档改动。它们是工作基线的一部分，不是垃圾。不得 reset、checkout 覆盖、清理或重建掉这些改动。
- 重要未提交文件：`Sources/DiskTraceApp/AppModel.swift`、`DiskTraceApp.swift`、`Sources/DiskTraceCore/Storage/DiskTraceStore.swift`、`SQLite.swift`、`Tests/DiskTraceCoreTests/ReadOnlySnapshotTests.swift`、`docs/PRODUCT_STATUS.md`、`README.md`、`docs/LIMITATIONS.md`。
- 当前本机应用：`~/Applications/DiskTrace Local.app`。
- 当前数据库：`~/Library/Application Support/DiskTrace/disktrace.sqlite`，WAL 和 SHM 是同一数据库的组成部分。
- 当前临时后台：`launchctl` 标签 `local.disktrace.monitor`。它未配置登录自动启动。
- 当前启动配置：同目录的 `local-run.json`；启动/停止脚本：`Start DiskTrace.command`、`Stop DiskTrace.command`。
- 当前只监控 Documents/Codex、Documents/Default Project、Documents/DiskTrace、.codex、.cache、.agents。不要把这个范围误认为全盘。
- 现有可用工具链曾位于 `/private/tmp/swift-6.2-expanded/swifttc/swift-6.2-RELEASE-osx-package.pkg/Payload`。先检查存在性；不能因为脚本默认路径不同就重下约 1.7 GB 的工具链。
- 用户剩余空间此前约 7.6 GB，这是历史快照，执行时重新测量；不得据此自行清理任何用户文件。

本目录附带 `SOURCE_BASELINE.json`（当前 45 个源码/测试/脚本等文件的 SHA-256）和 `DOCUMENT_VALIDATION.json`（文档结构与 SQL/JSON 校验结果）；它们用于识别基线，不是新功能已通过验收的证据。执行第一步：核对这些摘要，再保存 `git status --short`、HEAD 和当前 diff 的本地副本到本次验收目录。检查所有适用 AGENTS.md。本文只要求保存状态，不要求替用户提交；不得自动推送。

### 0.3 文档优先级及范围

用户本次明确诉求与本文的可执行闭环优先。原始产品参考为 `docs/DiskTrace_PRD_v4.0.md`，现状参考为 `docs/PRODUCT_STATUS.md`；旧文档中“Engineering Complete”的历史说法不可当作已验收事实。

本文完成的是**原始磁盘变化与原因定位闭环**，不是完整商业发布。原 PRD 的进程深追、正式签名公证、双架构发布、自动更新等仍须单独标记。不得以本闭环通过来宣称整个 v4.0 PRD 全部通过。

需要 ADR 的决定已固定：保留一个用户级 Agent、一个 App、一个 SQLite；新增有界的当前文件元数据索引，限于用户监控范围，不保存整盘树或每轮全树历史，不把整树放入常驻内存。将此补充为 ADR-10。它用于实现用户明确要求的文件追溯，不引入新的调查服务或第三个常驻进程。

### 0.4 硬性禁止

- 不自动删除用户文件，不判断“垃圾”，不提供一键清空会话或缓存。
- 不读取被监控文件正文，不保存提示词、消息、命令、工具参数、工具输出。Codex 日志需要流式读取原始字节，但只解码结构白名单元数据；跳过载荷不生成内容字符串、不入库或日志。
- 不修改 Codex 配置、会话日志或认证；不靠写入假的真实会话记录验收。
- 不伪造 PID、任务名称、下载行为或因果关系；FSEvents 不是写入者证明。
- 不做 HTTP/WebSocket 服务、root daemon、长期 syscall 跟踪、额外 watchdog、独立 Investigation Engine。
- 不引入云数据库、云上传、LLM 归因或新的付费服务。
- 不绕过系统通知、后台项目或目录权限的用户授权。
- 不直接复制正在写入的单独 `.sqlite` 文件作为“完整备份”，不删真实 WAL/SHM。
- 不停止在“框架已搭好”。必须交付真实文件明细、可解释事件、可用提醒与持续运行证据；确因系统限制受阻的项准确列 BLOCKED。

## 1. 最终交付与验收分级

### 1.1 必须交付的能力

| 编号 | 能力 | 必须能观察到的结果 |
|---|---|---|
| F01 | 卷级容量历史 | 曲线、时间筛选、下降量、采样口径和时效 |
| F02 | 目录净变化 | 配置范围内增长/释放、最近校准、覆盖状态 |
| F03 | 具体文件变化 | 新增/变大/缩小/删除/可证明移动；路径、前后大小、时间窗 |
| F04 | Codex 任务元数据 | 真实事件信封、增量续读、持久任务状态、真实客户端覆盖标识 |
| F05 | 可信关联 | 关联任务、依据、限制、并发歧义；未知保持未知 |
| F06 | 任务结束后仍存在的文件 | 持续存在的相关文件、最后一次检查时间；不声称无用 |
| F07 | 主动提醒 | 原因中性的低空间通知、证据足够的“可能相关”增长通知、冷却 |
| F08 | 日常持续运行 | App 关窗后仍采集，用户启用后登录恢复，暂停/恢复/停止有真实效果 |
| F09 | 资源自限 | 有界队列、元数据索引、历史配额，低空间时降载，展示监控自身占用 |
| F10 | 中文 UI 闭环 | 趋势窗口进入事件，再进入文件/任务证据，再定位 Finder |

### 1.2 完成判定

以下状态分别报告，不可合并成一个模糊的 PASS：

- `ENGINEERING_PASS`：实现和所有确定性自动化测试通过。
- `MAC_LOCAL_PASS`：在用户 Mac 上真实采集、文件变化、后台关窗、通知和权限场景通过。
- `CODEX_CLIENT_PASS(kind, version)`：指定真实客户端与版本的任务开始/结束、工作目录和关联流程通过。
- `LOGIN_RECOVERY_PASS`：经过真实退出登录或重启验证，不用进程内 restart 代替。
- `RELEASE_READY`：本任务不得宣称，除非另有正式签名、公证、双架构和发布验收授权及证据。

UI 的“已观测变化”不依赖 Codex 是否可用；没有 Codex 日志也必须正常监控空间和文件。

## 2. 必须先消除的已知缺陷

| 编号 | 现有位置 | 已确认问题 | 固定修复要求 |
|---|---|---|---|
| B01 | CodexJSON.swift | 真实事件为 `event_msg.payload.type`，现实现只识别顶层任务类型 | 支持确切信封与直接载荷白名单 |
| B02 | CodexActivitySync.swift | 文件大小没变就跳过，即使 offset 尚未读到 EOF | 依据 committed/read position 判断积压，持续推进 |
| B03 | CodexActivitySync.swift / SessionSyncState.swift | 存储了读取位置，内存半行跨重启丢失 | 持久化完整行边界或明确的丢弃状态 |
| B04 | MonitorCoordinator.evaluate | `nonOverlapping` 先去掉项目子目录，归因只剩根目录时间重合 | 逐个具体范围归因，展示汇总再去重 |
| B05 | sessionFiles() | 最旧前 200 文件固定选择，更多文件可能永久饥饿 | 持久化公平游标与活跃优先队列 |
| B06 | CodexJSONScanner.skipValue | 跳过字符串调用 readString，仍创建正文字符串 | byte-level skipString，不解码被跳过内容 |
| B07 | MonitorCoordinator.attribution | `windowIsTaskBounded` 没参与证据强度；任意进程证据与任意任务组合也可升级 | 按本规格的任务状态和身份/路径绑定矩阵判断 |
| B08 | MonitorCoordinator.runOnce | 串行完整扫描/日志同步使 60 秒采样与信号处理延迟 | 独立容量循环、短写事务、可取消扫描 |
| B09 | Scanner incomplete | 初始扫描不完整可能既无基线也无持久缺口；失败扫描可能每周期重试 | 明确每 root 状态、缺口与退避，不伪造零值 |
| B10 | FSEvents drain | 线索只计数，未落库；checkpoint 不能支持真实恢复 | 有界持久线索、持久处理检查点和恢复扫描 |
| B11 | Retention | 仍可能因有效页本批未下降提前退出；活动和未关闭缺口可累积 | 以删除进度/行预算退出，明确关闭与保留策略 |

这些问题要写成正式回归测试。不能只修改现有夹具以适应错误实现，也不能删掉 UI 和只读连接测试。

## 3. 固定技术结构

### 3.1 进程与模块

```text
DiskTrace App（SwiftUI、只读查询、配置编辑、权限操作）
  config.json + commands/（本地原子写；不写历史 DB）
  DiskTraceStore(readOnly: true)（分页读历史）

DiskTrace Agent（当前用户、唯一 DB 写者）
  AgentRuntime
    CapacityLoop（独立 60 秒采样）
    WorkLoop（1 秒调度，所有重任务受预算）
      ChangeMonitor -> 持久 change_hints -> 路径探测 / 目录校准
      AgentActivitySync -> 任务窗口和游标
      ScannerBackend -> 流式元数据 -> 有界当前索引 / 文件变化
      EventAssembler -> 原因候选 / Evidence / AlertDecision
      NotificationDelivery -> 本地系统通知
      RetentionPolicy -> 裁剪 / 回收 / 降载
  一个 DiskTraceStore actor + WAL
```

`EventAssembler` 是 Core 内部纯计算/小型组件，不是新进程或独立引擎。复用现有 scanner 遍历代码，增加流式回调；不要再实现第二套目录遍历器。Radix 接入与上游 SDK 风险不在此任务的关键路径。

### 3.2 固定运行节奏

| 工作 | 默认预算 / 节奏 | 超限行为 |
|---|---|---|
| 卷采样 | 立即一次，之后每 60 秒；单次目标 <2 秒 | 记录不可用，不中断其他工作 |
| 心跳/控制请求 | 5 秒心跳；1 秒检查命令 | 超过 15 秒未处理显示控制延迟 |
| FSEvents | latency 1 秒；内存最多 4096 路径 | 记录 overflow，优先校准受影响范围 |
| 活跃路径 stat | 每轮最多 256 路径；最多 200 ms | 持久待处理任务，下一轮继续 |
| Codex 同步 | 每 5 秒，512 KiB 全局字节预算；每文件 64 KiB | 未完成游标留待下一轮；不能丢积压 |
| 历史日志初始补读 | 仅最近修改的 7 天；每轮同一预算 | 标记 backlog 和最老待处理时间 |
| 周期完整校准 | 每 root 15 分钟；同时 1 个扫描 | root 独立时钟，失败退避 |
| 事件触发校准 | 路径去抖 3 秒；同目录最多每 30 秒 | 合并 dirty scopes，不重复入队 |
| 扫描批提交 | 256 行；目标持有写事务 <50 ms | 让出给容量采样和控制写入 |
| UI 刷新 | 15 秒，回前台刷新 | 查询任务可取消，禁止重入 |
| 历史维护 | 每 1 小时 / 占用跨软阈值 | 每轮最多 20,000 行 / 1 秒，分批继续 |
| 文件持续存在检查 | 任务结束后 10 分钟、24 小时 | 每轮最多 100 文件，补检查标明实际时间 |

硬件慢时允许扫描更久，但必须显示耗时/延迟，不能拖住容量采样。稳定状态采样间距目标 ≤75 秒；恢复或系统睡眠例外必须留 gap。容量循环按有效 roots 的唯一 volumeID 采样，并始终保留 home 所在卷；每卷选择一个当前可访问路径。无法访问的卷记录 unavailable，不用 home 的容量冒充该卷。首版最多 8 个用户显式选择的卷，超出配置校验拒绝并说明，不无限扩大采样工作量。

### 3.3 目录与文件布局

```text
~/Library/Application Support/DiskTrace/
  disktrace.sqlite{,-wal,-shm}
  config.json                  # UI 原子替换；Agent 校验后应用
  commands/<UUID>.json         # 有界一次性控制请求
  receipts/<UUID>.json         # Agent 回执，最多保留 24 小时
  logs/agent.log               # 滚动；只含操作计数、错误码
  backups/                    # 升级前最多一份有效备份
```

目录权限 0700、数据库/配置/命令/日志 0600；只对 DiskTrace 自己目录收紧权限，不递归修改任何被监控目录。以 POSIX `flock` 在自身 lock 文件取得单写者租约；第二个 Agent 明确退出非零，不打开写连接。

## 4. 配置合同与默认值

### 4.1 config.json

使用 Codable 严格验证；版本不支持时保持旧配置，写错误回执，不能悄悄覆盖用户配置。下面是字段合同示例，路径占位由实际 home 解析；不得把 `$HOME` 写死进可分发程序。

```json
{
  "schemaVersion": 1,
  "revision": 1,
  "monitoringEnabled": true,
  "roots": [],
  "exclusions": [],
  "volumeSampleSeconds": 60,
  "calibrationSeconds": 900,
  "codex": {
    "enabled": true,
    "home": "~/.codex",
    "lookbackDays": 7,
    "byteBudget": 524288,
    "perFileBudget": 65536,
    "maxRecordBytes": 524288,
    "hashDisplayPaths": false
  },
  "notifications": {
    "enabled": true,
    "agentGrowthBytes": 128000000,
    "agentGrowthWindowSeconds": 300,
    "agentCooldownSeconds": 1800,
    "lowFreeBytes": 10000000000,
    "lowFreeFraction": 0.05,
    "criticalFreeBytes": 2000000000,
    "criticalFreeFraction": 0.01,
    "safetyCooldownSeconds": 1800,
    "criticalCooldownSeconds": 300,
    "quietHours": null,
    "criticalBypassesQuietHours": true
  },
  "storage": {
    "softTotalBytes": 384000000,
    "hardTotalBytes": 512000000,
    "maxInventoryRows": 200000,
    "inventoryBudgetBytes": 192000000,
    "fileDetailDays": 7,
    "eventSummaryDays": 90,
    "hintDays": 2
  }
}
```

- roots/exclusions 的 JSON 形状为绝对路径字符串数组；只扩展当前用户的 `~`，不展开环境变量、glob 或其他用户的 `~name`。rootID 固定为 `root-v1|canonicalPath` 的稳定 UUID；同路径换卷后按 volumeIdentity 变化重建基线。
- 根目录为空：进入 onboarding/未配置状态，仅采样 home 所在卷，不自动全 home 递归。
- 本机升级时导入 `local-run.json` 已有 roots，保持现有范围；在 UI 提供建议目录供用户勾选扩展。
- 建议目录：`~/Documents/Codex`、用户项目目录、`~/Downloads`、`~/.codex`、`~/.cache`、`~/Library/Caches`；存在且可访问才添加，未授权目录显示状态。
- 不自动启用整个 `~/Library`、系统卷、云盘全量目录、外接卷；不默认打开 root 权限或全磁盘访问。
- 默认排除 DiskTrace 自身数据目录、lock/commands/receipts/logs、自己的构建验收临时目录；不排除 `node_modules`、`.venv`、`.build`、模型缓存等用户关心的增长来源。
- 重叠 roots 规范化为一个实际扫描范围，保留用户显示项到有效 root 的映射，避免同一文件被重复扫描和汇总。
- 根路径绝不能跨符号链接递归；用户显式选择符号链接 root 时，显示并确认其真实路径后按目标范围处理。
- 时间配置的合法范围：采样 15–3600 秒，校准 60–86400 秒；测试专用参数允许更短，但不能写入正式配置。
- `hashDisplayPaths` 只决定显示/导出脱敏；内部授权范围的路径匹配需要真实本地路径。不能把哈希字符串当路径做 prefix 匹配；日志不打印路径正文。

### 4.2 本机控制请求

不用实现网络 IPC。现有 IPCProtocol 扩展为文件命令合同，读取查询仍走只读 DB。

```json
{
  "version": 2,
  "requestID": "UUID",
  "issuedAt": 1791880000,
  "expiresAt": 1791880060,
  "command": "calibrate",
  "rootID": "UUID"
}
```

允许命令固定为：`authorizeNotifications`、`pause`、`resume`、`calibrate(rootID)`、`reloadConfiguration(revision)`、`confirmUser(eventID)`、`watchSource(path)`、`revokeRule(ruleID)`、`notificationTest`、`stop`。不允许任意 shell、SQL、URL 或文件删除请求。

UI 在临时文件写完后同目录 rename 为 `<UUID>.json`。Agent 校验 owner、权限、≤16 KiB、非 symlink、UUID/版本/有效期/路径范围；无效请求回执，不执行。`command_receipts` 中已有 UUID 则返回同一结果。请求已过期或最大排队 100 个时返回明确信息。

`stop` 的实际进程停止由 App 的 ServiceManagement 操作完成；命令只负责可恢复的 flush 与暂停状态，不能在仍有 KeepAlive 的情况下造成无限重启。暂停期间保留卷采样与心跳，停止目录/任务采集并打开 `manualPause` gap；恢复后先校准。

## 5. SQLite 迁移及数据合同

### 5.1 总体规则

当前 schema v3。实现 v4、v5、v6，分别对应任务同步、文件变化、事件与通知。使用现有迁移设施，每一版本一个事务。拒绝未来版本写入，UI 提示版本不兼容；不得自动降级 schema。

在添加旧表列前，将所有 `INSERT ... VALUES` 改为显式列名，避免列数变化破坏插入。时间均为 UTC Unix seconds 的 REAL；内部计时/超时使用 ContinuousClock。字节为 Int64，显示采用十进制 GB/MB；NULL 表示未知，不能写 0 冒充已测值。

旧观察表保留，旧活动不会自动升级为已验证。新的查询必须区分 legacy 记录和新证据版本。所有主键稳定且幂等：使用 SHA-256 的前 16 字节构建 UUID，键由版本前缀和规范化字段组成；不要冒称这是随机 UUID。

### 5.2 v4：任务窗口与完整行游标

`session_sync.byte_offset` 从 v4 起只表示完整处理的行边界；旧偏移不能证明处于行边界。迁移只标 cursor_version=0，不在 schema 事务内读会话文件。同步器首次接触旧游标时将旧偏移回退到前一个换行（向前最多 512 KiB；未找到则从 0 重读），开启一次 `legacyCursorRepair` gap；同批提交修复游标并设 cursor_version=1。新文件从完整行 0 开始，直接采用版本 1。稳定 activity ID 防止重复。

新增 SQL（真实 migration 应以此为合同，列名可直接使用）：

```sql
ALTER TABLE session_sync ADD COLUMN cursor_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE session_sync ADD COLUMN discarding_oversized INTEGER NOT NULL DEFAULT 0;
ALTER TABLE session_sync ADD COLUMN first_event_at REAL;
ALTER TABLE session_sync ADD COLUMN last_event_at REAL;
ALTER TABLE session_sync ADD COLUMN last_error TEXT;
ALTER TABLE session_sync ADD COLUMN retry_after REAL;
ALTER TABLE session_sync ADD COLUMN last_scheduled_at REAL;

CREATE TABLE task_windows (
    activity_id TEXT PRIMARY KEY,
    session_hash TEXT NOT NULL,
    task_hash TEXT NOT NULL,
    client_kind TEXT NOT NULL,
    client_version TEXT,
    lifecycle_state TEXT NOT NULL,
    start_known INTEGER NOT NULL,
    end_known INTEGER NOT NULL,
    last_event_at REAL NOT NULL,
    schema_kind TEXT NOT NULL,
    verification_state TEXT NOT NULL,
    source_log_path TEXT NOT NULL,
    event_start_offset INTEGER,
    event_end_offset INTEGER,
    FOREIGN KEY(activity_id) REFERENCES agent_activities(id) ON DELETE CASCADE
);
CREATE INDEX idx_task_windows_session_task ON task_windows(session_hash, task_hash);
CREATE INDEX idx_task_windows_recent ON task_windows(last_event_at, lifecycle_state);
CREATE TABLE client_verification (
    client_kind TEXT NOT NULL,
    client_version TEXT NOT NULL,
    schema_kind TEXT NOT NULL,
    result TEXT NOT NULL,
    verified_at REAL,
    evidence_reference TEXT,
    PRIMARY KEY(client_kind, client_version, schema_kind)
);
```

`lifecycle_state` 固定枚举：`running`、`completed`、`aborted`、`interrupted`、`unknownStart`。`verification_state`：`unverified`、`fixtureOnly`、`realClientVerified`、`legacyUnverified`。未知版本或未知 originator 保持 unknown，不一律写 codexCLI。

当前活动表沿用 started_at / ended_at / working_directory / task_id_hash；`start_known=0` 时 started_at 只作查询边界占位，UI 不展示为精确开始时间，归因不得据此构造完整任务窗口。

### 5.3 v5：范围、线索与文件元数据

```sql
CREATE TABLE monitored_roots (
    id TEXT PRIMARY KEY,
    canonical_path TEXT NOT NULL UNIQUE,
    volume_id TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    config_revision INTEGER NOT NULL,
    created_at REAL NOT NULL
);
CREATE TABLE root_scans (
    id TEXT PRIMARY KEY,
    root_id TEXT NOT NULL,
    started_at REAL NOT NULL,
    ended_at REAL,
    state TEXT NOT NULL,
    entry_count INTEGER NOT NULL DEFAULT 0,
    incomplete_reason TEXT,
    start_event_id TEXT,
    end_event_id TEXT,
    FOREIGN KEY(root_id) REFERENCES monitored_roots(id)
);
CREATE INDEX idx_root_scans_root_time ON root_scans(root_id, started_at);
CREATE TABLE root_health (
    root_id TEXT PRIMARY KEY,
    active_scan_id TEXT,
    state TEXT NOT NULL,
    last_success_at REAL,
    next_retry_at REAL,
    open_gap_id TEXT,
    inventory_coverage TEXT NOT NULL DEFAULT 'pending',
    FOREIGN KEY(root_id) REFERENCES monitored_roots(id)
);
CREATE TABLE change_hints (
    id TEXT PRIMARY KEY,
    root_id TEXT NOT NULL,
    volume_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    path TEXT NOT NULL,
    flags INTEGER NOT NULL,
    first_observed_at REAL NOT NULL,
    last_observed_at REAL NOT NULL,
    replayed INTEGER NOT NULL DEFAULT 0,
    processing_state TEXT NOT NULL,
    FOREIGN KEY(root_id) REFERENCES monitored_roots(id),
    UNIQUE(volume_id, event_id, path)
);
CREATE INDEX idx_hints_pending ON change_hints(processing_state, first_observed_at);
CREATE TABLE event_checkpoints (
    volume_id TEXT PRIMARY KEY,
    stream_kind TEXT NOT NULL,
    volume_identity TEXT NOT NULL,
    last_durable_event_id TEXT NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE file_inventory (
    root_id TEXT NOT NULL,
    scan_id TEXT NOT NULL,
    path TEXT NOT NULL,
    file_identity TEXT NOT NULL,
    kind TEXT NOT NULL,
    logical_bytes INTEGER,
    allocated_bytes INTEGER,
    modified_at REAL,
    birth_at REAL,
    observed_at REAL NOT NULL,
    link_count INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(root_id, scan_id, path),
    FOREIGN KEY(root_id) REFERENCES monitored_roots(id),
    FOREIGN KEY(scan_id) REFERENCES root_scans(id)
);
CREATE INDEX idx_inventory_identity ON file_inventory(root_id, scan_id, file_identity);
CREATE TABLE file_changes (
    id TEXT PRIMARY KEY,
    root_id TEXT NOT NULL,
    scan_id TEXT,
    path_before TEXT,
    path_after TEXT,
    identity_before TEXT,
    identity_after TEXT,
    change_kind TEXT NOT NULL,
    window_start REAL NOT NULL,
    window_end REAL NOT NULL,
    observed_at REAL NOT NULL,
    before_logical INTEGER,
    after_logical INTEGER,
    before_allocated INTEGER,
    after_allocated INTEGER,
    delta_allocated INTEGER,
    measurement_state TEXT NOT NULL,
    timing_precision TEXT NOT NULL,
    evidence_version INTEGER NOT NULL,
    FOREIGN KEY(root_id) REFERENCES monitored_roots(id),
    FOREIGN KEY(scan_id) REFERENCES root_scans(id)
);
CREATE INDEX idx_file_changes_root_time ON file_changes(root_id, observed_at);
CREATE INDEX idx_file_changes_paths ON file_changes(path_after, observed_at);
CREATE TABLE pending_path_work (
    root_id TEXT NOT NULL,
    path TEXT NOT NULL,
    work_kind TEXT NOT NULL,
    first_dirty_at REAL NOT NULL,
    last_dirty_at REAL NOT NULL,
    next_attempt_at REAL NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(root_id, path, work_kind)
);
```

- UInt64 FSEvents ID 以十进制字符串存储，不能强转有符号 Int64。数值比较使用 Swift UInt64，不能按 TEXT 字典序排序。
- inventory 仅保留每 root 的一个有效代次和至多一个准备代次，旧 inventory 代次发布后删除；不是历史全树快照。root_scans 的小型事实记录在 file_changes 引用存续时保留；active 代次和关联的目录摘要不被历史年龄裁剪。
- `kind`：`regularFile`、`directory`、`symlink`、`other`。索引文件大小时只统计 regularFile，symlink 不跟随。
- `change_kind`：`added`、`grown`、`shrunk`、`removed`、`moved`、`replaced`、`metadataOnly`、`firstObserved`。
- `measurement_state`：`measured`、`beforeUnknown`、`coverageGap`、`unstable`、`quotaLimited`。
- `timing_precision`：`liveHintWindow`、`scanWindow`、`recoveryWindow`。回放历史事件没有精确操作时间，不用当前回调时间假装刚刚写入。
- 实际文件 identity 使用设备 ID、inode、birthtime（可用时），不能仅用 inode 推断长期身份；路径保留原始大小写和 Unicode，不强行 lowercased。
- `delta_allocated`：只有两端已知且口径相同才有值，否则 NULL；逻辑大小单独显示。
- file_changes 必须可以显示路径已不存在的历史；Finder 按现有 UI 逻辑打开最近存在的父目录。

### 5.4 v6：用户能理解的事件、关联与通知

```sql
CREATE TABLE storage_events (
    id TEXT PRIMARY KEY,
    root_id TEXT NOT NULL,
    scope_path TEXT NOT NULL,
    window_start REAL NOT NULL,
    window_end REAL NOT NULL,
    gross_added_bytes INTEGER,
    gross_removed_bytes INTEGER,
    net_bytes INTEGER,
    measurement_state TEXT NOT NULL,
    reason_category TEXT NOT NULL,
    attribution_class TEXT NOT NULL,
    candidate_count INTEGER NOT NULL DEFAULT 0,
    unassigned_bytes INTEGER,
    status TEXT NOT NULL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    FOREIGN KEY(root_id) REFERENCES monitored_roots(id)
);
CREATE INDEX idx_storage_events_time ON storage_events(window_end, root_id);
CREATE TABLE event_files (
    event_id TEXT NOT NULL,
    change_id TEXT NOT NULL,
    PRIMARY KEY(event_id, change_id),
    FOREIGN KEY(event_id) REFERENCES storage_events(id) ON DELETE CASCADE,
    FOREIGN KEY(change_id) REFERENCES file_changes(id) ON DELETE CASCADE
);
CREATE TABLE task_links (
    event_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    link_state TEXT NOT NULL,
    link_basis TEXT NOT NULL,
    candidate_bytes INTEGER,
    algorithm_version TEXT NOT NULL,
    limitation TEXT NOT NULL,
    PRIMARY KEY(event_id, activity_id, algorithm_version),
    FOREIGN KEY(event_id) REFERENCES storage_events(id) ON DELETE CASCADE,
    FOREIGN KEY(activity_id) REFERENCES agent_activities(id) ON DELETE CASCADE
);
CREATE TABLE presence_checks (
    change_id TEXT NOT NULL,
    scheduled_at REAL NOT NULL,
    checked_at REAL,
    result TEXT NOT NULL,
    current_identity TEXT,
    current_allocated INTEGER,
    PRIMARY KEY(change_id, scheduled_at),
    FOREIGN KEY(change_id) REFERENCES file_changes(id) ON DELETE CASCADE
);
CREATE TABLE notification_outbox (
    id TEXT PRIMARY KEY,
    decision_id TEXT NOT NULL,
    event_id TEXT,
    category TEXT NOT NULL,
    delivery_state TEXT NOT NULL,
    created_at REAL NOT NULL,
    expires_at REAL NOT NULL,
    attempted_at REAL,
    delivered_at REAL,
    failure_code TEXT,
    FOREIGN KEY(decision_id) REFERENCES alert_decisions(id) ON DELETE CASCADE,
    FOREIGN KEY(event_id) REFERENCES storage_events(id) ON DELETE SET NULL
);
CREATE INDEX idx_notification_pending ON notification_outbox(delivery_state, expires_at);
CREATE TABLE notification_policy_state (
    key TEXT PRIMARY KEY,
    severity TEXT NOT NULL,
    last_sent_at REAL,
    recovered_samples INTEGER NOT NULL DEFAULT 0,
    updated_at REAL NOT NULL
);
CREATE TABLE command_receipts (
    request_id TEXT PRIMARY KEY,
    command TEXT NOT NULL,
    result TEXT NOT NULL,
    detail_code TEXT,
    applied_revision INTEGER,
    processed_at REAL NOT NULL
);
```

- `unassigned_bytes` 表示文件变化中未获得关联候选的部分，不等于“卷级未知空间”。两种差额在 UI 分开。
- `candidate_bytes` 是关联候选文件的测量净变化，不是已经证明的“Agent 写入字节数”；UI 不可把这个字段改名成确定因果指标。
- `reason_category` 固定：`dependencies`、`buildOutputs`、`modelCache`、`sessionArtifacts`、`temporaryFiles`、`downloadsFolder`、`mixed`、`unknown`。路径分类规则见第 11 节。
- `status`：`collecting`、`ready`、`partial`、`detailExpired`。事件详情过期后保留摘要及明确标签，不保留断链假详情。
- `link_state`：`timeOnly`、`pathCandidate`、`ambiguous`、`userConfirmed`、`verifiedWriter`。当前任务没有进程级能力，不生产 `verifiedWriter`。
- `delivery_state`：`pending`、`acceptedByOS`、`denied`、`deferredQuietHours`、`expired`、`failed`。OS API 接受不是用户已看到，不显示“用户已收到”。

## 6. Codex 日志解析与同步算法

### 6.1 精确支持的 JSON 形状

生产默认仅启用已观察到的格式；旧测试的顶层 `task_started/task_completed` 可作为 `legacyFixture` parser 单独保留，不据此宣称真实客户端兼容。

```json
{"timestamp":"2026-10-13T10:00:00Z","type":"session_meta","payload":{"id":"session-id","session_id":"session-id","cwd":"/tmp/project","originator":"client-origin","source":"client-source"}}
{"timestamp":"2026-10-13T10:01:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-id"}}
{"timestamp":"2026-10-13T10:02:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-id"}}
```

顶层只解码 `type`、`timestamp`。`session_meta.payload` 只读取 `id`、`session_id`、`cwd`、`originator`、`source`、`cli_version`（字段不存在保持未知，不猜版本）。`event_msg.payload` 先只读取 `type`，仅当是 `task_started`、`task_complete`、`turn_aborted` 时读取 `turn_id`；其他内容整体跳过。中断类型没真机验证前仍属于未验证兼容，不从字段名称推断成功。

`session_id` 与 `id` 同时存在且不一致时记录 schemaConflict，禁止关联，不能随意选一个。未知客户端类型只存 unknown；client_verification 只有验收程序明确写入真实测试结果后才为 realClientVerified，不能代码启动时自动设 PASS。

禁止提取或展示原始会话标题；用户界面用“Codex 会话 abcdef12 / 任务 1234abcd”、工作目录和时间定位。不能从消息正文生成名称。

### 6.2 JSON scanner 的强制修复

- 新增 `skipString()`：按字节跳过直到未转义结束引号，校验转义长度，不构造 String/字符数组。
- `skipObject/skipArray` 对未知字段调用 skipValue；未知对象的键也可用 skipString，不物化任意正文键值。
- 只有白名单 key/value 使用 readString；限制单个元数据值 4096 字节、嵌套深度 64。
- 遇到不合法控制字符、非法转义、截断 surrogate、未消耗输入、重复冲突关键字段，返回 typed parse error；不得无限循环或把畸形 JSON 当有效窗口。
- ISO 时间支持有/无小数秒；拒绝 NaN、无穷、明显未来时间（超过 now+5 分钟）作为可靠窗口。时钟变化打 `clockDiscontinuity` gap，不能让负时长升级置信度。
- 测试以注入的 decoder spy/解码计数证明正文未解码；仅测试“输出里没有 secret”不够。

### 6.3 两种位置必须区分

- `readPosition`：内存中已经读取到的字节位置。
- `committedOffset`：最后一个已完整处理、并与任务状态一起成功提交的行边界。

普通半行不更新 committedOffset；重启从 committedOffset 重读。内存 carry 上限 maxRecordBytes。日志元数据 `file_size` 只是当时观测大小，不能作为已读完判断。

```text
read a bounded chunk
append to bounded carry
for each complete line:
    if oversized/discard mode: skip without decode; one gap per oversized record
    otherwise parse whitelist event and update draft task map
    advance draft committedOffset to newline boundary
transaction:
    upsert activities + task_windows
    save committedOffset + discard state + metadata
    insert deduplicated gaps
on success: publish draft runtime
on failure: keep old runtime and old durable cursor; retry later
```

超长行超过 maxRecordBytes 且尚无换行：进入 `discarding_oversized=1`，丢弃载荷，允许提交已丢弃字节位置；重启继续跳过直到换行，不能把后缀当新 JSON。每条超长记录最多一条 gap。完整行已经有换行时也必须检查长度，不能只检查 trailing carry。

只有 `readPosition >= currentSize`、无待处理完整行、文件 identity/mtime 未变时，才能跳过；carry 未完成但没有追加字节时等待追加，不能 busy loop。

### 6.4 任务状态机

| 输入 | 现有状态 | 动作 |
|---|---|---|
| start(taskID) | 无 | 建 running，start_known=1，end_known=0 |
| 重复 start 同时间同 ID | running/closed | 幂等忽略，不重开已结束任务 |
| end(taskID) | running | 关闭为 completed，end_known=1，时间顺序合法才 bounded |
| abort(taskID) | running | 关闭为 aborted；UI 表示中断，不称完成 |
| end(taskID) | 无 | 建 unknownStart，start_known=0；不构造确定任务窗口 |
| start 缺 taskID | 任意 | 记 schemaMissingTaskID gap；保留会话活动线索，不捏造秒级 taskID |
| start 新 taskID | 另一个 running | 支持多个并发 task，不覆盖前一个；最多每会话 128 个打开任务，超限降级并标 gap |
| 日志被截断/替换 | 任意 | 旧 running 标 interrupted，记录缺口；新 identity 从头读取 |
| Agent 重启 | durable running | 从 task_windows 恢复 start/ID，不能只恢复 cwd |
| 只有 session_meta | 无任务 | 保存元数据，不创建跨整个会话寿命的“活跃任务” |

存储范围重合查询对 running 使用有限 `last_event_at` 的时效政策：最近活动 5 分钟内可作为“正在运行的候选”，超过后显示“任务状态未更新”，不能把无限 ended_at=NULL 归给以后所有变化。没有明确 end 的窗口不成为 agentProbable 的唯一证据。

### 6.5 公平调度与资源限制

发现器每 30 秒枚举一次最近修改 7 天的日志，支持最旧待处理游标；非每 5 秒全树重新枚举。候选列表只持有路径和 stat 元数据，不加载正文。

每轮 512 KiB：活跃日志 75% 预算（按 lastProcessed 升序轮转），积压日志 25%（按上次服务时间轮转）；没有一类时全额让给另一类。每文件最多 64 KiB，至少给最老一个积压文件服务。maxFilesPerSync=200 是单轮服务数，不是永久候选集合截断。

日志总数很多时，枚举分批且保存 discovery cursor，不能内存保存无限列表。单次文件权限失败使用 5 秒、30 秒、5 分钟退避；不把错误吞成成功。存储/解析错误显示于健康页，保存错误码，不保存包含正文的原始错误行。

积压严重时，事件可先展示未知，补齐任务元数据后新增证据版本；不覆盖原始文件事实，不补发超过 30 分钟的旧 Agent 通知。

## 7. FSEvents 与检查点

### 7.1 只接受线索，不把 flags 当因果

扩展 ChangeHint 保留原始 flags、firstObservedAt、lastObservedAt、volumeID、replayed。现在的单一 ChangeFlag 会丢掉组合语义；map 不能优先 created 后丢掉 removed，至少保留 rawFlags。

回调只做有界 coalesce 和 enqueue，不访问 SQLite、不 stat、不扫描、不解析日志。事件 path 经过范围校验后进入处理队列。线索溢出必须有 gap，不允许静默丢失。

### 7.2 持久化顺序

1. drain 有界输出。
2. 在一个短事务插入/更新 change_hints，并把可重放的路径工作写入 pending_path_work。
3. 同事务推进 last_durable_event_id。
4. 只有事务成功才确认内存 batch；失败留待重试，不能丢事件再推进检查点。
5. stat / 扫描完成后，将工作状态与 file_changes、inventory 更新一起提交。

last_durable_event_id 表示线索和待做工作已持久化，不等于目录已校准。校准时间与事件检查点分开显示。

### 7.3 恢复策略

保持现有 per-host stream 以最小改动支持本机固定卷；持久记录 stream_kind=host 和当前挂载卷身份。启动时卷身份一致可从持久 checkpoint 请求历史；卷集合改变、event ID wrapped、RootChanged、history 不可用则开 gap，重建该范围基线。不得把 host event ID 直接用于 per-device stream；未来外接卷支持需要单独 ADR。

`MustScanSubDirs` / `UserDropped` / `KernelDropped`：标 gap、安排受影响 root 的完整校准。回放事件 `replayed=1`，文件变化时间为恢复窗口，不是当前任务的新变化。休眠/恢复使用 NSWorkspace 通知开闭 gap，并重新采样；没有可靠 history 时明示历史缺失。

Apple 将事件历史视为建议性线索，仍需周期校准；相关语义见第 25 节官方来源。每个 overflow episode 只保留一个开放 gap，校准成功后关闭，避免每秒增加一条永久未关闭记录。

## 8. 单一扫描器的流式改造

### 8.1 接口合同

新增文件 `Scanner/ScanEntry.swift`、`Scanner/MetadataProbe.swift`，改造现有 FixtureScanner，禁止保留两套不同语义的扫描实现。

```swift
public enum ScanEntry: Sendable {
    case file(FileMetadata)
    case directory(DirectorySize)
    case inaccessible(path: String, code: Int32)
}

public struct FileMetadata: Sendable {
    public let path: String
    public let fileIdentity: String
    public let kind: FileKind
    public let logicalBytes: Int64?
    public let allocatedBytes: Int64?
    public let modifiedAt: Date?
    public let birthAt: Date?
    public let observedAt: Date
    public let linkCount: Int
}

public protocol ScannerBackend: Sendable {
    func scan(root: URL, excluding: [String]) async throws -> ScanResult
    func scanEntries(
        root: URL, excluding: [String], limits: ScanLimits,
        onEntry: @escaping @Sendable (ScanEntry) async throws -> Void
    ) async throws -> ScanCompletion
}
```

`scan()` 为现有小型测试/兼容接口，在同一个 scanEntries 遍历上收集目录摘要；最多 20,000 目录，超限返回明确的 resourceLimited，而不是无界数组。生产 Agent 使用 scanEntries，消费方维护最多 256 项的 actor 隔离批缓冲，满批 await Store 提交后才允许生产方继续。生产方 await onEntry 形成反压，不能用默认无界 AsyncThrowingStream，也不能用会丢事件的 bufferingNewest 代替。ScanCompletion 包含起止时间、complete、entryCount、checkpoint 和 typed terminationReason。

遍历改为逐项枚举，不能 `contentsOfDirectory` 一次构造超大目录的全部 URL 数组。固定使用 Darwin 的 opendir/readdir/lstat 逐项遍历，沿用已存在的 FilePaths 范围处理；DFS 栈最多 64 层/64 个打开目录句柄，超过时标记 inaccessible/resourceLimited。每个 frame 只保存当前目录自己的大小和已完成子树总数，子目录完成即向父 frame 累加并 emit directory，不持有所有文件或所有目录的字典。

容量口径继续使用 URL 的 allocated size 元数据（取不到为未知），逻辑大小来自 stat；不得读文件正文或计算内容 hash。获取单个文件元数据用同一个 MetadataProbe，扫描和事件 stat 不得形成两套不同口径。

### 8.2 当前索引代次与发布

1. 建 root_scans(state=preparing)，捕获开始时间和事件检查点，active_scan_id 不变。
2. files 分批写入准备代次 inventory；目录摘要分批写入已有 directory_changes 的临时计算流程，正式事实在扫描成功后发布。
3. root 的完整遍历最多 120 秒、受索引总空间预算限制；扫描可取消，取消后删除准备代次而不修改有效代次。
4. 同一 root 的 live probes 在本次 full scan 期间只入待处理队列；其他 root 可继续探测。新 hints 持久化，不因扫描丢弃。
5. 成功扫描后，把旧/新代次按 `(root, path)` 做 SQL 分页合并差分，最多 256 条一批。相关 file_changes 绑定准备 scan_id；UI 只查询 root_scans(state=completed) 的完整扫描事实。
6. 最终短事务发布 root_health.active_scan_id，标 root_scans completed，发布目录差分和其对应观察窗口。批量旧代次回收放到事务之后；UI 没有中间空白状态。
7. 发布后优先处理扫描期间积压路径；不能宣称全树在某一时刻原子一致。新增/消失竞态由下一轮探测修正，必要时标 unstable。
8. 完整性不足不发布删除推断，不推进可信基线；根级 gap 与下一次 retry 持久化。

目录摘要不能在扫描未完成时以 calibrated 进入正式查询。实现方式固定：新增 `scan_directory_summaries(scan_id, path, allocated_bytes, file_count)` 临时表，主键 `(scan_id,path)`；同样计入配额。成功发布时和旧有效摘要分批计算 DirectoryDelta，再与 scan 状态共同可见。为旧 directory_changes 增加 nullable `scan_id`（v5 migration），查询只接受 NULL legacy 或 completed 代次。注意先改显式 INSERT 列名。

扫描过程中发生权限错误时，保留旧完整基线，设置 root_health.state=needsRebaseline；恢复后的第一次完整扫描只重建基线，不跨缺口制造可信增长。每 root 独立状态，不用全局 lastCalibration。

### 8.3 首次启动与索引不足

- 容量立即采样，UI 可先展示卷级历史；每个 root 显示 pending，不等完整遍历才设置“运行”。
- 第一次文件出现于基线时，只作为 existing baseline，不把已有 100 GB 算成新增。
- 索引达到 200,000 行或 192 MB 时，不无界扩张：优先保留最近变化路径与当前任务工作范围，淘汰最久未变化的索引项；记录 inventoryCoverage=quotaLimited。
- 被淘汰路径后来再次出现：beforeUnknown，不能因为索引没有行就认为刚创建。
- 校准完整性和文件索引覆盖率分开：目录总量可测得，但文件明细可能只覆盖部分。UI 必须分别显示。
- 目录摘要和准备代次也算索引预算；空间不足以建立完整准备代次时，降级到 dirty paths 文件探测，保留旧基线并标 quotaLimited；不能先删旧基线再尝试。
- 不得为了保持详细文件索引扩大原始全盘范围。被禁用 root 保留历史，停止新采集；用户重新启用时重建基线。

### 8.4 权限和错误退避

ENOTDIR/ENOENT 与 EACCES/EPERM 分开处理。只有可靠的不存在状态可推断删除；权限失败不能写零大小。

退避固定为 30 秒、2 分钟、10 分钟、30 分钟，成功一次恢复正常 15 分钟节奏。只显示事实：“部分路径不可访问”，不能自动声称获得全磁盘访问。发起系统设置跳转可以，但用户自行授权。

root 状态枚举：`pending`、`scanning`、`ready`、`needsRebaseline`、`permissionDenied`、`quotaLimited`、`paused`、`unavailable`。最近成功校准、最近尝试、下次重试是独立字段。

## 9. 具体文件差分规则

### 9.1 对照表

| before | after | 结果 | allocated delta |
|---|---|---|---|
| 完整基线确认不存在 | 新 regular file | added | after allocated（若已知） |
| 已知同 identity | 大小增加 | grown | after-before |
| 已知同 identity | 大小减少 | shrunk | after-before |
| 已知存在 | 可靠 ENOENT / 完整新基线不存在 | removed | -before（口径是路径内分配空间，不保证卷释放） |
| 同路径、identity 不同 | 新文件替换 | replaced | after-before，两端分别保存 |
| 同 identity，old path 不存在，new path 出现，linkCount=1 | 同卷 moved | moved | 范围内净变化为 0；旧/新路径保存 |
| identity 匹配但多硬链接/证据不够 | 不推断 moved | 分别记录路径观测并标歧义 | 汇总按 identity 去重或标未知 |
| before 不知道 | 任何可读 after | firstObserved | NULL，显示当前大小 |
| 任一端权限/元数据不可用 | 不完整 | coverageGap | NULL |
| 前后相同 | 无大小变化 | metadataOnly 或不生成容量事件 | 0 |

同一次探测连续两次 stat 的 identity/大小不同，视为正在写入，标 unstable，3 秒后重试；最多 3 次，仍不稳定则保留观察值与不确定标记，不触发确定增长提醒。后续稳定后可以补充新事实，不能改写原观察值。

### 9.2 并发、移动与空间口径

- 变化指净分配空间，不是累计写 I/O。创建后删除且两次观察之间完全消失的文件可能只有事件线索，大小未知；不凭空补字节。
- 同卷同 identity 移动只有在一个观察窗口能证明旧路径消失和新路径存在时才标 moved；否则保留 added/removed 或 beforeUnknown。
- 跨卷移动按源减少、目标增加，不能称同 identity；卷样本分别显示。
- 硬链接对汇总按稳定文件 identity 去重；链接别名的路径变化仍可展示。其他链接是否在范围外不可知时，不把路径删除量说成卷释放量。
- APFS clone 可能共享物理块，不从相同大小推断 clone，也不把 metadata allocated sum 说成全盘实际消耗。
- 源内容不变而修改时间变化不等于新增大小；禁止用 mtime 单独推断下载。
- symlink 只保存链接元数据与范围线索，不跟随目标、不跨范围 stat 目标。

### 9.3 FSEvents 路径 probe

单文件 hint：查询当前有效 inventory、读取新元数据并应用上表。目录 created/renamed/MustScanSubDirs：安排该子树有界扫描；不能只 stat 目录 inode 大小代替子树占用。

文件更新和当前索引更新在一个短事务提交。file_change ID 以 evidenceVersion、rootID、before/after identity、路径、对应 durable hint ID 或 scan ID 构建，重复处理相同 hint 不产生第二条事实。重试时先查 stable ID，不能仅凭当前随机 observedAt 生成新记录。

无法从事件得知准确写入时间，窗口下界为上一次可靠观察，上界为本次可靠观察；liveHintWindow 还附带回调观察时间作为线索。15 分钟校准窗不能被缩短成某个任务的 30 秒窗口。

## 10. 事件组织与避免重复计数

### 10.1 构建 StorageEvent

新建纯函数 `EventAssembler.assemble(changes:tasks:rules:coverage:version:)`，输入有界分页数据，输出 StorageEvent、TaskLink、Evidence 和待评估 Observation；存储由 Store 负责。

- 按 5 分钟 UTC 固定桶、有效 root、scopePath 分组。
- scopePath 优先是范围内已知项目工作目录；没有可靠工作目录则取变化路径的首个分类目录（例如 node_modules、.build）或所在直接父目录，clamp 到有效 root。
- 桶 ID 固定：`storage-v1|rootID|scopePath|bucketStart|configRevision` 的稳定 hash。
- 同一个 file_change 可用于层级浏览，但只属于一个主事件，不能同时记入根事件和项目事件的可加总数值。
- 首次观测而 beforeUnknown 的文件单列“当前发现大小”，不加入已测净增长。
- 同一文件 identity 在桶内多次变化，用最早可靠 before 与最后可靠 after 计算净值；gross added/removed 是各已测正负变化之和，不能当下载总量。
- 聚合不足或硬链接歧义时 measurementState=partial；UI 展示已测部分与未知项数，不补零。
- 根目录与子目录的 DirectoryDelta 继续完整保留，用于层级浏览；它们不是可直接相加的总量。

### 10.2 修复祖先过滤问题

删除归因前 `ScanResult.nonOverlapping(deltas)` 的使用。依次：

1. 为具体文件/具体项目范围生成候选与证据。
2. 在该 scope 上计算政策，保存其判定。
3. 展示层按事件归属去重。
4. 根目录只展示总量事实和各子事件，不继承某个子项目的 Agent 类别。

不能简单地把“变化路径是工作目录祖先”也视为路径命中；否则整个 home 的增长都会被一个项目认领。

### 10.3 事件迟到与证据版本

文件变化先到、任务元数据后到时，事件最初为未知。同步补齐后在同一 eventID 下新增 TaskLink/Evidence 的算法版本并更新当前分类；原 file_changes 不修改。UI 显示证据更新时间。

过期的提醒不因补齐证据重复发送。被用户明确确认的事件不被后续推测覆盖；用户撤销反馈后重新按事实评估，并保存规则版本。

## 11. 原因线索与归因矩阵

### 11.1 路径分类（只能说“在哪里/哪类文件”）

按完整 path segment 匹配，不用字符串 contains 误匹配 `my_node_modules_backup`。

| 分类 | 路径规则 | UI 文案 |
|---|---|---|
| dependencies | node_modules、.venv、venv、用户已配置依赖缓存范围 | 依赖目录增长 |
| buildOutputs | .build、.next、dist、build、target、DerivedData | 构建产物目录增长 |
| modelCache | 用户配置的 ~/.cache/huggingface、~/.ollama/models 等 | 模型缓存目录增长 |
| sessionArtifacts | .codex 内明确的 artifacts/outputs/visualizations、配置的任务输出目录 | 会话/任务产物目录增长 |
| temporaryFiles | 用户勾选的临时输出范围 | 临时目录变化，不保证可删除 |
| downloadsFolder | 用户选择的 Downloads root | 下载目录增长，不保证浏览器或 Agent 下载 |
| mixed | 一个事件包含多个主要分类 | 多类目录共同增长 |
| unknown | 其余 | 类型未知 |

一个用户自己创建的 dist 文件夹也只命中分类，不证明是构建进程。分类必须可在 UI 查看匹配规则，用户可以撤销自己添加的规则。路径规则不升级来源置信度。

### 11.2 关联候选的精确条件

任务候选需同时满足：真实客户端/格式验证状态、工作目录已知、规范化路径边界匹配、时间窗口有重合。对任务类型/版本未验证的数据，只展示“未验证活动线索”，不进入主动 Agent 提醒。

path match：`filePath == cwd || filePath.hasPrefix(cwd + "/")`，root 为 `/` 时另写边界判断。对于 cwd 外的全局 pip/model cache，现有输入不能证明来源，保持未知；可以列出同时活跃任务，但不把缓存字节计入其 candidateBytes。

多个 task 同时命中同路径/时间：所有候选标 ambiguous，不凭最近开始时间选唯一写入者。父子工作目录重合也不自动选择最深路径作为因果证据。

### 11.3 来源等级表

| 输入事实 | 分类 | 通知资格 |
|---|---|---|
| 只有卷下降 | unknown | 只有中性低空间提醒 |
| 只有目录名/缓存位置 | unknown | 静默 Agent |
| 只有任务时间重叠 | unknown/timeOnly | 静默 Agent |
| 有路径匹配，但任务未结束/状态过期/客户端未验证/变化仅来自恢复扫描 | unknown，候选可见 | 静默 Agent |
| 完整且已验证的任务窗口、live hints 命中 cwd 内文件、唯一任务候选、测量可靠且无相关 gap | agentProbable/pathCandidate | 达阈值可发“可能相关” |
| 15 分钟 scanWindow 与任务重合 | unknown 或低强度候选 | 不把整个扫描窗字节认给任务；静默 Agent |
| 两个任务候选或用户并发线索无法拆分 | unknown/ambiguous | 静默 Agent |
| 用户明确确认某事件是自己操作 | userConfirmed | 静默 Agent，低空间仍独立 |
| 真正验证的进程身份、任务身份、路径和操作都绑定 | agentConfirmed/verifiedWriter | 本任务不产生该等级；缺能力不能伪造 |

窗口关联不是写入证明。即使 probable，也只能说“这段任务期间相关目录净增 X，可能有关”，不能说“Codex 下载了 X”。live hint 和 scan diff 两类证据必须明确区分。

`Evidence` 必须绑定同一个 subjectID；关联不同任务的 `processOperation` 与弱时间线索不能合并成 confirmed。确认级别需要同一进程链/任务身份的显式关系，本任务没有这条输入时应始终不生产 confirmed。

### 11.4 任务后持续存在

对有 task_link 的 added/grown 文件安排两次 presence_checks：任务结束+10 分钟、+24 小时。查询只做 stat，不读正文。

- 存在且 identity 一致：显示“任务结束后仍存在，最近检查时间…”。
- identity 不同：显示“路径仍存在，但文件已被替换”，不认定原文件遗留。
- 不存在：显示“此路径已不存在”；不能保证由用户清理或空间已释放。
- 无权限/未执行：显示“尚不能确认”。
- 关联只是候选时，标题用“与该任务存在关联线索的文件”，不能简化成“该任务留下的文件”。
- 10 分钟/24 小时未运行而后补检时，保存实际 checked_at，不伪造准点检查；UI 标注补检查。

## 12. 卷级变化与目录变化的对照

不强制守恒对账。UI 分别显示：

1. 卷级可用空间变化（important-usage 或 statfs 口径）。
2. 已监控范围、同一时间窗口内的已测净分配变化（层级去重、硬链接处理）。
3. 未覆盖/不可直接对账部分及原因说明。

新增 `VolumeMeasurementContext(sample_id, method)` 表或等效伴随表，method 固定 `importantUsage` / `statfsAvailable`；两个不同方法间不计算伪精确下降量，图上标记口径变化。旧样本没有 context 时显示“历史口径未记录”，不猜测；汇总按 volumeID+method 分组，新摘要同时写 context，不跨方法平均。

比较时只选同卷、时间上下界误差≤采样周期的观察；扫描时间太宽则标“时间范围不同，不能精确对照”。不允许将 `free reduction - sum(all directory rows)` 显示成准确未解释空间。

APFS 快照、purgeable、clone、范围外目录与权限缺口都可能使数值不同。UI 给固定解释，不自动调用快照清理或系统私有接口。无法匹配时显示“尚未解释”，不能显示“系统占用”作为猜测答案。

## 13. 提醒政策与实际送达

### 13.1 事件政策

保留 AlertPolicy 为纯函数，扩展输入为 EventObservation，不把所有提醒放在 UI。Agent 关闭 UI 后仍评估并发送系统通知。

- 普通相关增长阈值：5 分钟桶内已测 positive net ≥128,000,000 字节，至少 agentProbable，才进入 Agent 增长提醒。
- 未知来源普通增长默认记录、静默；即使名称含 Codex/node_modules，也不得发送 Agent 归因通知。
- 当前卷可用 <10,000,000,000 字节或 <5% 为 low；<2,000,000,000 字节或 <1% 为 critical。
- low 与 critical 始终原因中性，不受用户“我主动操作”的反馈抑制。
- Agent 提醒按 `agent-growth|scopePath` 冷却 30 分钟；同桶内更新不增加通知。
- low 同卷 30 分钟最多一次，critical 同卷 5 分钟最多一次；从 low 升 critical 可以立即发送一次。
- 从低空间恢复要求两次有效采样均 >12 GB 且 >6%；重置 episode，不被阈值附近抖动反复提醒。
- quietHours 可选本地时间区间，low/Agent 提醒延期到结束并检查有效期；critical 允许突破免打扰，UI 必须在设置中清楚说明并允许用户关闭突破。
- 测量不完整、任务不完整、并发歧义、客户端未验证，一律不升级为 Agent 主动提醒。
- 用户 `silenceSource` 只是静默通知，不等于 userConfirmed；只有明确 confirmUser 反馈才改变来源分类。

将 safety cooldown 真正传入和持久化。目前 UI 合并显示重复决策不能代替后台通知冷却。重复评估可保留 observation，决策中写 cooldownActive，不删除空间历史。

### 13.2 通知文案合同

允许：

- “磁盘可用空间偏低：剩余 7.6 GB。点击查看近期增长目录。”
- “磁盘空间紧张：剩余 1.8 GB。部分增长尚未找到原因。”
- “可能与 Codex 任务有关：项目 A 在相关时段净增 180 MB。点击查看文件与证据。”

禁止：“Codex 偷偷下载了…”、“发现 180 MB 垃圾”、“已经定位全部原因”、“可放心删除”。

锁屏默认不显示完整用户路径、session ID 或文件名；使用目录末级名称，详情在 App 查看。用户可在设置启用更详细通知；不上传任何内容。

### 13.3 持久 outbox 与幂等

AlertDecision + notification_outbox 同事务写入，outbox ID=`notification-v1|decisionID` 的稳定 hash。发送前检查授权、quiet hours、expiresAt、持久 cooldown；决策已经静默的不进入 outbox。

调用 `UNUserNotificationCenter.add`，request identifier 使用 outbox ID；崩溃重试同 ID 不创建多个独立提醒。成功只记 acceptedByOS。查看 `getPendingNotificationRequests` / delivered notifications 可辅助恢复，仍不能声称用户看过。

失败重试最多 3 次（5 秒、30 秒、5 分钟），之后 failed 并在 UI 展示。低空间通知有效期 10 分钟，Agent 通知有效期 30 分钟；重启后不狂发过期历史。授权 denied 不重复请求系统授权，UI 提供打开通知设置的操作。

### 13.4 真实通知必须有可识别的 App 身份

通知不能依赖一个没有应用身份的裸 CLI。固定采用**嵌入式 Agent 应用包**，仍只有 UI 和 Agent 两个常驻进程：

```text
DiskTrace Local.app/
  Contents/Info.plist                          # local.disktrace.app
  Contents/MacOS/DiskTraceApp                  # SwiftUI UI
  Contents/Library/LaunchAgents/local.disktrace.agent.plist
  Contents/Library/LoginItems/DiskTraceAgent.app/
    Contents/Info.plist                        # local.disktrace.agent
    Contents/MacOS/DiskTraceAgent              # 无主窗口后台 App
```

新增 SwiftPM executable target `DiskTraceAgentApp`（输出再复制为 DiskTraceAgent），它仅负责 AppKit 生命周期和通知身份，调用共享的 AgentRuntime。原 `disktrace-agent` CLI 仍用于隔离测试，但两者不能同时打开同一写数据库。不要复制两套 MonitorCoordinator 逻辑。

Agent App `LSUIElement=true`；无主窗口、不占 Dock。主线程运行 NSApplication event loop，后台异步启动 AgentRuntime；UNUserNotificationCenter delegate 和权限回调在此进程处理。不得直接在 POSIX signal handler 里锁 NSLock。

UI 的“启用系统通知”明确告诉用户授权对象为“DiskTrace 后台监控”，发送 `authorizeNotifications` 控制请求，由 Agent App 在用户主动操作后请求 `.alert`，默认不请求声音/角标。将实际 authorizationStatus 回报给 UI。只有系统返回允许，才显示已授权；UI App 自身授权不能被误认为 Agent bundle 已授权。

通知点击由 Agent delegate 验证 event UUID，打开主 App 注册的 `disktrace://event/<UUID>`；App 校验 UUID 后查询 DB，不执行 URL 中的文件/脚本，不自动清理。没有对应历史时显示“详情已过保留期”。

这是确定的实现路线；最终效果必须在 macOS 14 上实测。若系统拒绝本地签名包的通知，保留错误码与 App 身份证据，将通知验收标 BLOCKED；不能偷偷换 osascript 或假通知，也不能把“add 没抛错”当作横幅已验证。

## 14. 登录恢复、暂停与单写者

### 14.1 SMAppService 注册

UI 使用 `SMAppService.agent(plistName: "local.disktrace.agent.plist")`。plist 位于 UI bundle 的 `Contents/Library/LaunchAgents/`，BundleProgram 是相对于 UI bundle 的嵌入式 Agent 可执行路径。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.disktrace.agent</string>
  <key>BundleProgram</key>
  <string>Contents/Library/LoginItems/DiskTraceAgent.app/Contents/MacOS/DiskTraceAgent</string>
  <key>ProgramArguments</key><array><string>DiskTraceAgent</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
```

不在 plist 的 StandardOutPath 写死用户名；Agent 自己向 support/logs 滚动日志。App 在 ~/Applications 可以本机测试；移动 bundle 后显示需要重新注册，不悄悄留下旧路径服务。

注册是用户开启“登录后继续监控”的直接动作。处理 `.enabled`、`.requiresApproval`、`.notRegistered`、`.notFound` 和异常；requiresApproval 时给出系统设置操作入口，不伪造 enabled。不通过直接修改系统数据库或通知权限实现。

启用新服务前探测旧 `local.disktrace.monitor`，保存旧配置并协调停止旧写者；成功取得写者锁后才迁移。新服务注册/启动失败则恢复旧本地启动脚本，不能两个 Agent 争写或让用户丢失全部监控。

### 14.2 生命周期与控制语义

- 关主窗口：UI 可退出/不退出都不影响 Agent；Agent 自己送通知，不能依赖 UI 轮询通知 outbox。
- 暂停：保留容量/心跳，目录和任务不采集，记 gap；按钮显示“恢复文件监控”。
- 恢复：结束暂停 gap，恢复 FSEvents 并做有限回放/重建基线。
- 完全停止：App unregister 服务并等待进程退出；CLI stop 只能在服务禁用后安全退出； UI 显示“后台已停止”。
- 退出登录/休眠：存游标、检查点、当前任务状态；唤醒后先采样和记录空窗，不把空窗内全部变化归给当下任务。
- 崩溃重启：flock 由 OS 释放；准备代次不可作为有效基线；恢复持久未完成工作、任务和 outbox。
- SIGTERM/SIGINT：先忽略默认处理，再用 DispatchSourceSignal 在普通执行上下文取消任务、短时 flush、关闭 DB；不要在 C signal handler 用锁、分配内存或 async。
- 致命启动错误返回非零 exit status；非法 interval/未知 CLI 参数显式 usage error，不启动无限快速循环。

### 14.3 健康快照

Agent 每 5 秒在 monitor_state 写版本化 JSON 小快照，包含：heartbeat、running/paused、root 数、各 root 状态/最近成功扫描、pending paths、sync backlog bytes/最老时间、notification authorization、空间降载、当前索引行数/字节、总自身占用、schema/evidenceVersion、最近 typed error。

UI 以 heartbeat 判断 Agent 存活、以 latest sample 判断容量采样时效、以 root lastSuccess 判断目录覆盖，三者不互相代替。后台死亡但数据库存在时必须显示停止/过期。

## 15. 存储、低空间保护与保留

### 15.1 总量口径

预算包括 DB、WAL、SHM、索引准备代次、日志、控制文件、备份和临时扫描文件。`effectiveBytes` 用于判断裁剪进度，`totalFileBytes + externalOwnedFiles` 用于磁盘实际保护，两者都显示。

默认软总量 384 MB、硬总量 512 MB，相较旧默认 1 GB 更适合该用户。不是严格文件系统配额：临时事务可能短时超限，必须测量并报告峰值；超过硬阈值立即暂停新增文件明细，仍保留容量和最小健康状态。

### 15.2 保留顺序

1. 已处理 hints 保留 2 天，明细 file_changes/evidence/presence_checks 默认 7 天。
2. StorageEvent 和通知摘要保留 90 天；明细被删除后标 detailExpired，保留 aggregate 与原因限制。
3. 任务窗口保留 90 天；被保留详情引用的任务不得先删除造成断链。早于 90 天且仍 running 的陈旧状态先 interrupted，再按策略裁剪。
4. 关闭 gaps 90 天；长期开放同类 gap 合并，保留最近健康摘要而非无界逐秒新增。
5. 当前 inventory 按覆盖预算和最近活跃度裁剪；不算“必须永久保留的用户文件”，但淘汰后标 beforeUnknown。
6. volume 近 7 天明细、90 天小时摘要、之后每日摘要；摘要保留 min/max/freeFirst/freeLast/count/method，不能反复无权重平均小时均值，导致低空间峰值消失。
7. rolling logs 每份 2 MB，最多 3 份；receipts 24 小时、最多 1000 份。
8. 升级备份默认只保留最近一份；它计入本次升级的临时预算，保留至验收通过后由明确的应用数据维护策略处理，不删除用户自己的其他备份。

SQL DELETE 顺序遵循 FK：事件明细关联、presence、evidence 等先裁剪或 cascade；同步维护详情状态。用户规则和确认反馈不因空间不足悄悄撤销。

### 15.3 裁剪与回收算法

- 使用小批事务，按确实删除的行数和耗时推进，不因为这一批 freelist/page_count 没变就退出。
- 每轮 20,000 行/1 秒；未达目标则设置 maintenancePending，下轮继续，避免 UI/容量等待长事务。
- 回收单独做 WAL checkpoint，检查返回的 busy/log/checkpointed 结果；busy 不算成功，延期重试。
- 仅 auto_vacuum=INCREMENTAL 的 DB 运行 incremental_vacuum，限制页数与耗时；现有 NONE DB 不自动全量 VACUUM。
- 旧数据库若需转换，界面提供明确维护操作、空间预检和备份，不在低空间后台悄悄复制整库。
- 不靠截断 WAL、删 DB 或删除用户被监控文件达配额。

### 15.4 低空间降载

可用空间 <2 GB：停止新完整索引准备代次、日志历史补读和非必要文件明细；继续容量采样、已有 pending 任务的有限处理、关键低空间通知。inventoryCoverage=quotaLimited，不能在 UI 继续写“全部正常”。

<512 MB：进入 emergency，只写最小容量/心跳/单条状态变化，检查 DB 写失败并明确提示；不无限重试导致更多日志。恢复到 >3 GB 连续两次采样后逐步恢复，不立即全盘扫描。

## 16. UI 执行规格

保留上一轮中文 UI、侧栏与只读连接，不回退到裸 TabView。新增以下真正可用的交互，不能做未连接的演示按钮。

### 16.1 空间概览

- 当前可用、总容量、所选时段变化、最新容量采样时间和口径。
- 图表点选/拖选时间窗；更新下面事件列表和目录/文件查询上下界。
- 1 小时/24 小时/7 天快捷范围；记录少时明确起始时间，不假装已积累 7 天。
- 事件行：时间窗、scope、净变化、分类线索、来源等级、数据完整性；未知不能从列表消失。
- 卷下降明显但没有对应范围内事实时，显示“该时段空间减少，当前监控范围未解释”，附范围与权限入口。
- 低空间决策合并成持续状态，同时显示真正的系统通知授权/发送状态。

### 16.2 事件与文件详情

事件详情必须包含：

1. 测量窗口、scope、已测净变化、未知项数。
2. 具体文件列表：路径、changeKind、before/after allocated、净变化、logical bytes、timingPrecision。
3. 任务候选列表：客户端/版本/验证状态、匿名 ID、cwd、开始/结束、是否完整窗口。
4. 依据与限制：live hint/扫描窗/仅时间关联、是否多个任务；未解释部分。
5. 任务后存在状态和实际检查时间。
6. Finder 定位、复制路径、“这是我主动操作”、撤销该反馈；不增加删除按钮。

默认分页 100 条、每页最大 200，按变化量/时间排序，可搜索路径。不能一次查询七天所有文件进入 @Published 数组。数据库使用只读、短读事务；所有列表 detailExpired 时显示摘要，不抛空白页。

### 16.3 目录变化

- 单独展示目录子树总量；父子不能直接相加，保留已有说明。
- 可以按层级下钻到 file_changes，不能把目录 inode 大小作为目录内容大小。
- 展示索引覆盖率和最近成功扫描；明细不足时显示“部分文件未建立前值”。
- source=未知的目录依然排名显示，不能为了追求 Agent 界面而隐藏真实增长。

### 16.4 监控状态和设置

- root 添加/禁用/排除、权限检查、手动校准；设置通过原子 config 与命令回执生效。
- 明确区分“保存中”“Agent 已应用 revision N”“应用失败”；UI 本身不能假设写了文件就是生效。
- 采样/任务同步延迟、gap、当前自占空间、降载、通知权限、登录服务状态。
- 通知开关与阈值、quiet hours、登录恢复、暂停/恢复/完全停止。
- 设置路径错误/版本不支持时保留旧有效配置与详细错误。
- 健康没有 gaps 只能说“无已记录缺口”，不能保证完整覆盖。

## 17. 必须实现的接口和文件分工

以下新增接口是编译合同的方向；公共 Swift 类型按已有命名风格补齐，异步/Sendable 隔离必须通过 Swift 6 检查，不用全局 unchecked Sendable 掩盖错误。

| 文件 | 必须承担的工作 |
|---|---|
| Codex/CodexJSON.swift | 白名单事件信封、byte skipString、严格错误与上限 |
| Codex/CodexSessionLog.swift | committed/read positions、complete lines、超长丢弃状态 |
| Codex/CodexActivitySync.swift | 公平增量同步、draft transaction、任务状态恢复 |
| Models/SessionSyncState.swift | 新游标字段，不把 fileSize 等同已读 EOF |
| Models/AgentActivity.swift | lifecycle/验证伴随上下文，保持稳定身份 |
| Monitor/FSEvents.swift | 原始 flags、可恢复批确认、检查点、回放标记 |
| Scanner/FixtureScanner.swift | 唯一流式遍历实现、兼容 scan 包装 |
| Scanner/MetadataProbe.swift | lstat/allocated 元数据、路径范围、typed failure |
| Models/FileMetadata.swift / FileChange.swift | 元数据、可空前后值、测量与时间精度 |
| Monitor/MonitorCoordinator.swift | root 状态与工作编排，独立容量调度，不在归因前去子目录 |
| Monitor/AgentRuntime.swift | loops、取消、心跳、信号、单写者、睡眠恢复 |
| Monitor/PathWorkScheduler.swift | 持久 dirty paths、去抖、退避、扫描预算 |
| Policy/EventAssembler.swift | 纯事件聚合、去重、稳定事件身份 |
| Policy/AttributionPolicy.swift | 固定矩阵、任务候选、并发歧义，不产生假 confirmed |
| Policy/AlertPolicy.swift | 事件阈值、安全 episode、冷却、用户规则 |
| Storage/Migrations.swift | v4–v6 + 后述补充表，显式列名、未来版本拒绝 |
| Storage/DiskTraceStore.swift | 短事务、分页快照、批 staging、atomic cursor/task/hint commits |
| Storage/RetentionPolicy.swift | 总自身占用、逐表保留、细节过期、低空间降载 |
| IPC/IPCProtocol.swift | 文件控制合同 v2；不实现 HTTP/XPC 双套方案 |
| Configuration/MonitorConfiguration.swift | 校验、revision、导入旧 local-run、范围映射 |
| Configuration/CommandInbox.swift | owner/size/version 校验、幂等 receipt |
| Notifications/NotificationDelivery.swift | outbox、授权、幂等 request、失败/quiet hours |
| Sources/DiskTraceAgent/main.swift | 解析参数、调用共享 runtime、正确 exit status |
| Sources/DiskTraceAgentApp/main.swift | 嵌入式 Agent App 身份、AppKit event loop、通知 delegate |
| Sources/DiskTraceApp/AppModel.swift | 只读分页、事件/文件/任务查询、真实命令回执 |
| Sources/DiskTraceApp/DiskTraceApp.swift | 保留现有 UI，新增事件/文件 drill-down 与服务设置 |
| App/BackgroundServiceController.swift | SMAppService 注册、旧服务切换、后台状态 |
| scripts/package-local.sh | 构建嵌套 bundle、plist、从内到外签名与校验 |
| scripts/acceptance-original-need.sh | 隔离 fixture、可重复断言、状态证据 |
| docs/ORIGINAL_NEED_ACCEPTANCE.md | 每项 PASS/FAIL/NOT RUN/BLOCKED、证据与限制 |

Store 必须提供下列能力，不能让 UI 执行原始 SQL 或绕过唯一写者：

```text
applySessionBatch(activities, taskWindows, syncStates, gaps) -> committed result
persistHintBatch(hints, pendingWork, checkpoint) -> durable acknowledgement
stageScanBatch(scanID, entries) -> row/budget report
publishScan(scanID) -> completed/needsRebaseline/quotaLimited
applyPathObservation(before, after, hintID) -> FileChange?
upsertEvent(event, fileIDs, taskLinks, evidence, decisions, outbox) -> atomic result
queryEvents(window, root, cursor, limit) -> Page<StorageEvent>
queryFileChanges(eventID, cursor, limit) -> Page<FileChange>
queryTaskCandidates(eventID) -> [TaskCandidate]
queryHealth() -> MonitorHealthSnapshot
applyControl(request) -> CommandReceipt
```

分页使用 `(sort_time,id)` 或 `(sort_bytes,id)` keyset，稳定排序；不使用大 OFFSET 翻深页。UI 改变范围/搜索时取消旧任务，防止慢查询覆盖新范围。

## 18. 实施顺序与每阶段完成条件

按顺序执行。每阶段通过后继续下一阶段，不把“准备了下一步”当交付。某个系统权限验收受阻，继续所有不依赖它的代码和离线测试，最终单独列阻塞。

### M0：锁定基线、可重复构建

- [ ] 保存当前工作区 diff、源文件摘要、HEAD；读 AGENTS。
- [ ] 复用已安装 Swift 6.2，确认 SDK 和 linker shim；首次不下载依赖。
- [ ] 原有 50 测试运行一次，保存输出；若基线失败，记录并定位，不能删测试。
- [ ] 建立 `artifacts/evidence/original-need/<UTC timestamp>/`，只放脱敏证据。
- [ ] 在临时 DB 上完成旧 schema 1/2/3 构造与迁移测试骨架。

通过条件：现有 UI 还可构建，旧历史没有改动，基线证据完整。

### M1：真实 Codex 元数据链路

- [ ] B01/B02/B03/B05/B06/B07 同步修复。
- [ ] v4 migration、完整行偏移、任务状态 map、draft 提交回滚、公平调度。
- [ ] 导入本机已观察元数据格式：originator=`codex_work_desktop`、source=`vscode`、cli_version=`0.162.0-alpha.17.2`。originator 表明 Desktop，不能只因 source=vscode 标成 IDE；这只是识别规则，不等于整条关联已真机通过。
- [ ] 窗口上下文和 legacyUnverified 分开；不再用 session 首尾时间代表整个活跃任务。
- [ ] 所有 C 类测试通过。

通过条件：长日志能最终读到尾；重启可恢复已开始任务；正文没有解码或入库；无权限时其他监控继续。

### M2：独立容量循环与持久线索

- [ ] AgentRuntime、CapacityLoop、短事务、typed failures、DispatchSourceSignal。
- [ ] FSEvents batch acknowledgement、durable hint/checkpoint、pending work。
- [ ] 每 root 基线、完整性、退避与 needsRebaseline。
- [ ] v5 中 scope/hint/root tables，独立健康快照。
- [ ] FSEvents/恢复/容量延迟测试通过。

通过条件：人为延迟 scanner 2 分钟时容量采样仍在预算内，overflow 有明确 gap，无虚假完整状态。

### M3：文件变化的可观测事实

- [ ] 单 scanner 流式遍历、MetadataProbe、代次发布与有界当前索引。
- [ ] 新增/增长/缩小/删除/替换/移动/unknownBefore 差分。
- [ ] hard link、symlink、权限错误与扫描取消保护。
- [ ] v5 file tables、补充临时目录摘要表和 VolumeMeasurementContext。
- [ ] 文件明细分页可查询，所有 D 类测试通过。

通过条件：在独立 fixture 中生成/删除/移动文件，数据库能列出正确路径与可验证大小；不是仅多了一条根目录增长。

### M4：事件、任务候选与用户反馈

- [ ] v6 events/links/presence；按固定聚合和关联矩阵实现。
- [ ] B04 修复：项目子目录先归因；root 不继承子任务归因。
- [ ] 候选补齐、并发歧义、late evidence version、持续存在检查。
- [ ] confirmUser 事件反馈及撤销；silence 不改成“用户确认”。
- [ ] E 类测试通过。

通过条件：同一 fixture 中明确区分“项目任务相关候选”和“并行用户 Downloads 变化”；不能整个窗口归给 Codex。

### M5：原生 UI 闭环

- [ ] 从现有 UI 继续，不重写成 WebView。
- [ ] 点选时间窗、事件列表、文件分页、任务证据详情、配置/回执状态。
- [ ] 支持 unknown、partial、detailExpired、stale、permissionDenied、quotaLimited 视觉状态。
- [ ] Finder 入口真实有效，已消失路径打开父目录；不增加删除功能。
- [ ] UI smoke 和查询分页测试通过。

通过条件：用户能从空间下降进入具体文件，再看到原因候选和限制，不需要开发者查询 SQL。

### M6：系统提醒与后台登录恢复

- [ ] 嵌入式 Agent bundle、共享 runtime、ServiceManagement plist 和本地打包脚本。
- [ ] outbox、native authorization、cooldown、quiet hours、通知跳转。
- [ ] 暂停/恢复/完全停止与关窗采集真实工作。
- [ ] 将当前旧临时服务安全切换，不丢旧历史。
- [ ] N/L 类离线测试，随后真实通知/关窗验收。

通过条件：主 UI 不运行时，Agent 能采集并发送已授权系统通知；登录恢复需要真实登录证据单列。

### M7：配额与异常恢复

- [ ] B11 修复、保留关联完整性、低空间降载、滚动日志。
- [ ] 配额统计包括 DB/WAL/staging/backup/日志，监控自己的数据排除事件反馈循环。
- [ ] 故障注入、迁移回滚、崩溃恢复和性能测试通过。

通过条件：长压测不持续增长自占空间，满额时明确降级，不吞历史、不清用户文件。

### M8：本机真实验收与交付

- [ ] 按第 20–23 节执行，保存实际输出、版本、截图与限制。
- [ ] 更新 PRODUCT_STATUS、LIMITATIONS、TEST_MATRIX 和 README，不能留虚假完成说明。
- [ ] 交付本地安装、启停与服务状态说明，列出未覆盖目录和未验证客户端。

通过条件：用户可以继续运行软件，且知道它已经解释了什么、尚未解释什么。

## 19. 自动化测试矩阵（不得删减核心场景）

固定时钟、可注入文件/错误提供器、临时目录与内存/临时 SQLite。所有 unit/integration tests 无真实账号依赖，不写用户真实会话。新增测试数量不是完成依据，下列断言才是。

### 19.1 日志与任务 C01–C18

| ID | 场景 | 必须断言 |
|---|---|---|
| C01 | 真实 event_msg 信封 | task_started/task_complete + turn_id 被识别，sessionMeta cwd 正确 |
| C02 | 日志 4984 B、每次 256 B、30 次同步 | committedOffset 最终到最后完整换行，尾部任务存在 |
| C03 | 单日志 10 MB、512 KiB 总预算 | 每轮读量不超预算，最终完成；不能文件大小不变就停 |
| C04 | 先完整 meta+半个 start，重启后追加后半行 | start 仅出现一次，任务 ID 和开始时间正确 |
| C05 | meta UTF-8 字符跨 chunk | 中文/Unicode cwd 正确，无 replacement 引起的路径错配 |
| C06 | 完整超长行带换行+后续有效任务 | 超长行跳过，一条 gap，后续任务仍正常 |
| C07 | 超长无换行跨重启 | discard 状态恢复，不把后缀解析为新事件 |
| C08 | 读/写过程中 truncate/replace inode | 重置游标，旧任务 interrupted，gap 仅一条 |
| C09 | 同一 task 重复 start/end | 一条活动，结束时间不回退，重读幂等 |
| C10 | applySync 事务故障注入 | DB 游标与内存 draft 都不前进；重试不漏不重 |
| C11 | 开始任务后 Agent 重启，再收到 end | 原始开始时间恢复，窗口完整，不近似成结束时刻 |
| C12 | 缺失开始仅收到 end | unknownStart，不允许主动 Agent 提醒 |
| C13 | session 同时两个 task | 两个独立窗口，关闭一个不覆盖另一个 |
| C14 | 正文/参数含诱饵 cwd/id/type | 不提取，不解码正文，不含 secret 输出/DB/日志 |
| C15 | JSON 非法转义、超深嵌套、未来时间 | 有界失败/typed gap，没有 hang/高置信度 |
| C16 | >200 日志（至少 401），最新任务在末尾 | 所有有限积压最终得到服务，最新任务不是永久遗漏 |
| C17 | 一个持续追加大日志+很多小日志 | 小日志也推进，活跃/积压两类不饥饿 |
| C18 | Desktop originator + vscode source | 不错标 CLI/IDE；只有真实验收才 realClientVerified |

### 19.2 文件与扫描 D01–D18

| ID | 场景 | 必须断言 |
|---|---|---|
| D01 | 首次扫描已有文件 | 基线，不出现全量 added/growth |
| D02 | 基线后新增 regular file | 路径、前后值、allocated 元数据与实际 probe 一致 |
| D03 | 文件增长再缩小 | 两条正确有符号变化，UI 不只查正值 |
| D04 | 删除整个子目录 | 子目录/具体文件负变化均可追溯，无漏记 |
| D05 | 同路径原子替换 | identity 改变，记 replaced，不当单纯 grown |
| D06 | 同卷单链接 rename | old/new 路径，moved，事件净值不双算 |
| D07 | 硬链接两个路径 | 不重复汇总分配大小，不把别名删除当精确释放 |
| D08 | symlink 指向 root 外 | 不跟随、不读目标；范围外路径无伪归因 |
| D09 | 权限丢失 | 无零值/删除推断，gap 和退避持久化 |
| D10 | 权限恢复 | 第一次完整扫描重建基线，无虚假新增 |
| D11 | 初始 root 不可读 | pending/permissionDenied 与 gap 可见，不写 ready |
| D12 | 扫描中取消/崩溃 | 有效代次保持，preparing 不被 UI 查询 |
| D13 | 扫描期间持续写入 | marked timing/unstable 与后续补探测，不假装原子快照 |
| D14 | 达 inventory 行/字节上限 | beforeUnknown 降级，容量历史继续，内存不无限增 |
| D15 | 文件存在但 allocated 元数据不可用 | NULL；不得以 logical bytes 冒充 allocated |
| D16 | 文件变化后全部消失于采样间隔 | 只有 hint/未知大小，不编造下载字节 |
| D17 | 重叠 roots、重复 hints | 一套有效扫描归属、相同观察幂等 |
| D18 | 流式大目录 | 不创建所有 URL/file 字典，句柄/栈/时间预算生效 |

### 19.3 关联与 UI 查询 E01–E14

| ID | 场景 | 必须断言 |
|---|---|---|
| E01 | root=/fixture，task cwd=/fixture/project，项目增长 | 项目事件保留候选，不因根目录存在而被删 |
| E02 | 项目与 Downloads 同时增长 | 两事件，Downloads 不被认领 |
| E03 | 同目录两个任务并发 | ambiguous，不选择最近任务，不发 Agent 通知 |
| E04 | 仅任务时间重合，路径不同 | unknown/timeOnly |
| E05 | cwd 外模型缓存 | 类型线索可见，来源未知 |
| E06 | open/陈旧任务 | 不当完整窗口，不唯一支撑 probable |
| E07 | recovery/宽 scanWindow | 不把整个窗口字节认给一个短任务 |
| E08 | 名称 hint+巨大增长 | 仍 unknown，不能自动确认 Agent |
| E09 | 文件先到、任务元数据迟到 | 原观察不变，新增证据版本，旧通知不重复 |
| E10 | 别的进程证据+弱 Agent 时间线索 | 不升级 confirmed |
| E11 | 用户确认/撤销事件 | 只改变指定 scope，低空间政策仍运行 |
| E12 | 任务后 10 分钟/24 小时存在/替换/丢失 | 结果与真实 stat 一致，不标“垃圾/安全删除” |
| E13 | 事件/文件 keyset 翻页+同时写入 | 稳定顺序，无重复/跳页；每次≤200 条 |
| E14 | 明细过期/原路径消失 | 摘要仍可见，detailExpired；Finder 到存在父目录 |

### 19.4 生命周期、通知与配额 N01–N16

| ID | 场景 | 必须断言 |
|---|---|---|
| N01 | scanner 延迟 120 秒 | CapacityLoop 不等 scan，正常时采样≤75 秒 |
| N02 | 4096 容量队列注入 10,000 路径 | 不越界，持久 overflow episode，安排重校准 |
| N03 | hint 落库失败 | checkpoint 不推进；重试相同 batch 不漏 |
| N04 | crash 后 replay + volume identity 改变 | 有恢复标记，不能用当前时间归给当前任务 |
| N05 | SIGTERM + 正在扫描 | 无 signal-handler 锁，有限时间退出并可恢复 |
| N06 | 第二 Agent 同 DB | 写者锁拒绝，非零退出，不同时迁移 |
| N07 | 新增服务替换旧临时服务 | 任一时刻最多一个写者，失败有旧运行恢复方案 |
| N08 | 通知授权 denied/notDetermined | 无假送达，无反复系统弹窗，UI 状态准确 |
| N09 | 低空间持续 60 次采样 | 只按 episode/cooldown 通知，不每分钟刷屏 |
| N10 | low->critical->恢复->low | 升级即时、恢复两样本、重新进入新 episode |
| N11 | outbox add 前后崩溃 | 同 identifier 重试，无多个不同 ID 提醒 |
| N12 | quiet hours/过期 pending | 延迟或过期，不补发大量旧提醒 |
| N13 | 某批 DELETE 后有效页暂未降 | 仍按行预算继续，不提前错误 break |
| N14 | 总 quota + WAL + staging + logs | 全部计入，超硬阈值降载，不删用户数据 |
| N15 | <2 GB / <512 MB 模拟 | 只保留必要采样/状态，恢复有迟滞 |
| N16 | v1/v2/v3->v6 与未来版本 | 旧历史保留、幂等、失败回滚；未来版本拒绝写 |

另保留现有只读测试：UI 不能插入/建库；silent decisions 和 evidence 可查询。增加配置无效、命令重复/过期/symlink、暂停/恢复、用户反馈只作用指定事件的测试。

## 20. 隔离的端到端验收脚本

新增 `scripts/acceptance-original-need.sh`，参数合同：

```text
--artifact-dir <path>
--keep-fixture
--notification-test          # 必须已有明确系统授权；否则记录 NOT RUN
--codex-home <fixture path>  # 默认脚本创建 synthetic home，不指向真实 .codex
```

脚本行为固定：

1. `mktemp` 建唯一 fixture，里面有 projectA、Downloads、source、codexHome、db、reports；所有写入路径 guard 必须在 fixture 下。
2. 使用 production 二进制和扫描链路，`--db`/`--codex-home`/`--root` 指向 fixture；测试配置采样 1 秒、目录 5 秒、Agent 阈值 1 MB、禁用 fixture 的容量安全提醒，以免真实机器本来低空间干扰。
3. 写入 synthetic session_meta/task_started，明确标 schemaKind=fixtureOnly。policy 单元测试可注入“客户端已验证”，但真实 UI/真实 client_verification 不能设 PASS。
4. 项目新增 16 MiB 文件，Downloads 同时新增 8 MiB 文件；结束任务后等待事件处理。
5. 断言 DB 有具体文件路径和测量事实；项目有候选、Downloads unknown；fixtureOnly 不主动发生产 Agent 通知。
6. 对项目文件追加 4 MiB、缩小 2 MiB、rename、remove 子目录；assert 每一步类型/符号/路径。
7. 制造半行、重启隔离 Agent、补完整行，assert 任务恢复；额外用 401 个小日志验证公平。
8. 注入 overflow/scan timeout/storage error，assert gap/恢复，不依靠巨大真实目录制造压力。
9. 对 presenceChecks 使用注入时钟触发 10 分钟与 24 小时逻辑，报告“时钟驱动自动化”，不能冒充真实运行 24 小时。
10. 自动化输出 `summary.json`、精简 SQL 结果、test log；每项 stable ID 与 PASS/FAIL，脚本任何 assert 失败 exit 非零。
11. trap 只停止本脚本启动的 PID。默认移除自己创建的临时 fixture；`--keep-fixture` 则明确报告路径与占用。不得杀用户现有 Agent，也不得删除外部路径。

单次 fixture 文件正文总量限制 64 MiB，启动前可用空间≥512 MiB；否则跳过有盘写测试并标 BLOCKED。压力测试使用内存注入，不下载 GB 级测试数据。生成随机或非稀疏内容时以 allocated probe 验证，不用稀疏文件/压缩全零数据假装真实占用。

## 21. 真实 Mac 与真实 Codex 验收

### 21.1 证据记录格式

每项保存：操作系统/CPU 架构、App/Agent commit+工作区摘要、schema/evidenceVersion、实际配置、开始/结束时间、操作、DB 查询摘要、屏幕截图（可用时）、PASS/FAIL/NOT RUN/BLOCKED、限制。

只能保存脱敏元数据夹具；不得复制真实原始 rollout JSONL 到仓库或截图提示词。真实测试的 session/task ID 用 hash，cwd 在公开证据中替换成 fixture 路径占位；本地 DB 保存授权路径用于定位。

### 21.2 必测操作

| ID | 真实操作 | 通过标准 |
|---|---|---|
| R01 | 本地安装新 bundle，App 与后台启动 | 一个写者，容量历史持续，UI 读取正常 |
| R02 | 关闭主窗口至少 3 分钟 | 新增≥2 次有效容量采样，后台不依赖窗口 |
| R03 | 完全退出 UI，后台已授权发测试通知 | 可见系统通知；点击回到正确测试事件，不是模拟弹窗 |
| R04 | 暂停 1 分钟、恢复 | 卷采样继续，文件 gap 明确，恢复重建正确 |
| R05 | 主动停止，再启动 | 停止有真实效果，启动不重复服务/写者 |
| R06 | 实际 Codex 在选定 fixture 执行小任务 | 日志自动发现真实 task/window/client，不手改日志 |
| R07 | Codex 写文件同时用户复制文件到独立 Downloads fixture | 独立文件事实，非 Codex 路径保持未知 |
| R08 | 更改目录权限再恢复 | 不制造负增长/虚假新增，gap 可见 |
| R09 | 强制结束隔离 Agent，再恢复 | 旧事实不丢、半行/任务/准备代次处理正确 |
| R10 | 用户启用登录后台后真实退出登录/重启 | 恢复采样/基线/任务状态；没有做则 NOT RUN |
| R11 | 持续真实运行 24 小时 | 有容量/目录/事件历史，资源和自占用记录完整 |
| R12 | 通知拒绝、服务 requiresApproval | UI 准确显示，没有虚假成功或无限弹框 |

R10 的系统登录操作由用户完成；不要为了验收自行退出用户会话。R11 不能靠改系统时钟或单元测试替代。实现工作可以完成，但未真实经过时标 NOT RUN。

### 21.3 真实 Codex 小任务的固定内容

执行方在用户已有 Codex 客户端、经授权的任务目录中运行下面指令；这是一段测试任务，不是让 DiskTrace 采集提示词。不可为了验收绕过认证、注册新账户或修改真实会话日志。

```text
工作目录是本次验收创建的 projectA。请只在这个目录内操作：
1. 建 outputs 目录。
2. 从 https://raw.githubusercontent.com/paimmme/disktrace/main/README.md 下载到 outputs/downloaded-readme.md。
   限制下载最大 1 MiB、超时 30 秒；失败则记录网络失败，不重试大文件。
3. 生成 outputs/generated.bin，内容为 16 MiB 的非稀疏随机字节。
4. 列出这两个文件的大小，不删除它们，不修改任何其他目录。
```

真实下载小 README 用于证明“发生了下载的实际操作”这一测试背景；DiskTrace 自身仍不能根据文件元数据知道网络来源，UI 不得因此一般性宣称所有新增文件是下载。

测试框架知道任务内容，可作为验收 ground truth；产品不存任务内容。R06 通过要求真实 task/window 正确、文件事实正确、候选路径与时间可核验，不要求凭 cwd/time 升级 confirmed。

并行对照：另由普通文件复制将 fixture/source/user-copy.bin 放入 fixture/Downloads，不在 Codex cwd 内。两者都必须记录，不能全归 Codex。真实 client verification 需记录实际 originator/source/version 与任务开始/结束字段是否存在；只读到 session_meta 不算通过。

网络失败不阻塞文件生成与关联测试；下载子项单列 FAIL/NOT RUN。依赖下载/模型缓存等大体量任务用已有真实使用观察验收，不为了测试增加用户磁盘压力。

## 22. 性能验收

测量 App 和 Agent 分开。原 PRD 目标：Agent 空闲平均 CPU <0.5%、常驻内存 <50 MB；这是待实测目标，不能因为单个 ps 快照良好写 PASS。

- 稳定空闲至少 30 分钟，1 秒采样一次 CPU、RSS、心跳、容量间隔；记录均值/p95/峰值，区分进程启动和扫描窗口。
- 使用现有本机工作目录测正常校准，记录每 root 用时、文件数、索引行数、DB/WAL增长；不下载第三方巨型源码作测试。
- 注入 100,000 hints 测队列峰值/overflow、调度延迟和退避；真实盘只创建最多 5,000 个小文件且总量≤64 MiB。
- 测试 large JSON line、401 日志、持续新日志时 CapacityLoop 最大延迟。
- 配额压测使用临时小 quota 触发，不真的把用户磁盘写满。
- 模拟低空间通过注入 sampler，禁止实际灌盘到 512 MB。

嵌入式 Agent App 加载通知框架可能增加基线 RSS，必须真实测量。如果功能链路通过但资源目标未达，报告 `FUNCTIONAL_PASS / PERFORMANCE_FAIL` 并优化；不得偷偷改口径或把 App/Agent 内存混成另一数字宣称达标。

## 23. 构建、安装、迁移和回退操作

### 23.1 构建合同

在 Package.swift 明确列出 UI App 和嵌入式 Agent App 的 executable products，保留 DiskTraceCore 与原 CLI。编译目标仍为 macOS 14，不能因为 ServiceManagement 引入 macOS 26 下限。

```bash
cd '$HOME/Documents/DiskTrace'
export DISKTRACE_SWIFT_TC='/private/tmp/swift-6.2-expanded/swifttc/swift-6.2-RELEASE-osx-package.pkg/Payload'
# 先检查上面目录存在；不存在则检查已安装 toolchain，不直接下载。
source scripts/toolchain-env.sh
swift build
swift test
```

这些命令在本机已有工具链条件下使用；路径不存在时记录真实错误并查可用已安装 Swift，不把 shell 默认 Swift 5.10 当作 6.2。构建脚本增加 `--no-download` 支持，默认本任务验收不下载新工具链。

本地打包脚本参数：`--output <path> --configuration debug|release --sign-identity <identity>`；本机默认 `--sign-identity -` 为临时签名，不能称正式分发签名。Info.plist 设置最低系统 14.0，CFBundleVersion 使用源码版本/构建序号；UI/Agent bundle ID 分别固定 local.disktrace.app / local.disktrace.agent。

先构建到验收 staging 目录，检查动态库依赖，不把整个 Swift 工具链或测试框架复制进应用。嵌套 Agent bundle 从内到外 codesign，最后主 App；校验 `codesign --verify --deep --strict`。`spctl` 对 ad-hoc 的拒绝是分发限制，不能关闭 Gatekeeper 或改系统安全设置。

### 23.2 真实数据库升级顺序

1. 保存旧 app/runtime/config/服务信息，确认没有用户未保存的 UI 编辑。
2. 停止旧写者并等待退出，检查 flock；不得只看旧 PID 是否存在就假设已停止。
3. 在旧 DB 上用 SQLite Online Backup API 生成有效备份，包含当时已提交 WAL 事务；备份连接和目标正确关闭，运行 integrity_check。
4. 预检可用空间：至少 `备份估算 + 新索引准备预算 + 1 GB 安全余量`；不满足时不迁移真实 DB。隔离代码与测试仍继续完成，并给出空间阻塞原因；不能清用户历史腾空间。
5. 用新 Agent 唯一写者事务迁移 v4–v6；检查 version、必要索引、foreign_key_check、旧表行数未意外减少。
6. 新 App 只读连接可处理 v3 状态“等待 Agent 升级”和 v6 新界面，不能由 UI 迁移。
7. 启动新服务，至少观察两次容量采样、一次小范围文件事实、通知/权限状态和 UI读取。
8. 成功后保留旧备份与回退说明；不自动删除用户数据和旧会话。

更新真实 App 时使用本地 staging 安装，旧 App 先退出，后台先按上述迁移顺序协调；不能向正在执行的可执行文件路径直接覆盖写入。包安装完成再注册并启动。

### 23.3 回退

- 新 runtime 失败：先禁用/停止新服务，避免 KeepAlive 重启竞态；保存错误证据。
- v6 DB 不能交给 v3 老 Agent 写。旧版本回退必须使用升级前备份恢复到独立恢复路径，核验后由用户明确选择切回；不能直接覆盖含新历史的真实 DB。
- 同时保留失败升级后的 DB，新历史不能默默丢弃。
- 回退旧本地脚本也必须明确使用旧 schema 对应 DB；如果安全回退空间不足，保留数据、停止写入、标 BLOCKED，不采取删库捷径。
- 新配置不合法时无需回滚 DB：使用最近成功 revision，UI 标配置错误。

### 23.4 补充 schema 合同

将下面两部分分别并入 v5/v6 migration，不新建无编号的临时 schema，也不要让 App 按需偷偷建表。

v5：

```sql
ALTER TABLE directory_changes ADD COLUMN scan_id TEXT;
CREATE TABLE scan_directory_summaries (
    scan_id TEXT NOT NULL,
    path TEXT NOT NULL,
    allocated_bytes INTEGER,
    file_count INTEGER NOT NULL,
    PRIMARY KEY(scan_id, path),
    FOREIGN KEY(scan_id) REFERENCES root_scans(id) ON DELETE CASCADE
);
CREATE TABLE volume_measurement_context (
    sample_id TEXT PRIMARY KEY,
    method TEXT NOT NULL,
    FOREIGN KEY(sample_id) REFERENCES volume_samples(id) ON DELETE CASCADE
);
```

v6：

```sql
CREATE TABLE event_feedback (
    id TEXT PRIMARY KEY,
    event_id TEXT NOT NULL,
    feedback_kind TEXT NOT NULL,
    created_at REAL NOT NULL,
    revoked_at REAL,
    FOREIGN KEY(event_id) REFERENCES storage_events(id) ON DELETE CASCADE
);
CREATE INDEX idx_feedback_active ON event_feedback(event_id, revoked_at);
```

event_feedback.kind 本任务仅 `confirmUser`，撤销填 revokedAt；同一事件确认幂等。用户只静默来源时保留 UserRule.silenceSource，不写 confirmUser。

### 23.5 数据库读写兼容

- writer 仅接受 schema≤currentVersion，未来版本不执行 PRAGMA 修改/迁移；先只读检查版本再取得允许写权限。
- reader 在 schema v3 时沿用现有容量/目录/原因基础显示，新表功能显示“待升级”；不得因为查询新表失败而把整个历史界面清空。
- schema v6 的 readers 在一个短读事务取得分页快照，结束即释放；不让 Chart 长期持有 SQLite statement 导致 WAL 无法 checkpoint。
- DB 被删/移动/permission changed 时，清除 cached connection 并显示错误；不能继续展示旧连接但标“采样正常”。
- 显式 readOnly=true 不创建 DB/WAL schema、不启动写迁移，保持现有测试。

## 24. 交付物与停止条件

### 24.1 必须留下的文件

- 全部源代码、migration、单元/集成测试与本地打包/验收脚本。
- `docs/ORIGINAL_NEED_ACCEPTANCE.md`：F01–F10、R01–R12 状态矩阵，逐条证据。
- `artifacts/evidence/original-need/<timestamp>/summary.json`，包含 commit、workspaceDigest、OS、schema、test summary、真实客户端验证结果、资源结果、未完成项。
- `docs/OPERATIONS.md`：如何启用/禁用登录监控、暂停/恢复、完全停止、通知授权、范围配置、迁移和回退。
- 更新 `docs/ARCHITECTURE.md`（ADR-10、文件索引边界）、PRODUCT_STATUS、LIMITATIONS、TEST_MATRIX 和 README。
- 可运行的本机 App bundle；本地签名与正式发布限制如实标注。

### 24.2 代码完成审查清单

- [ ] 原有 UI 和用户未提交改动得到保留。
- [ ] 现有测试与 C/D/E/N 核心场景通过。
- [ ] JSON 跳过正文不创建内容 String，原始日志不进证据包。
- [ ] 任何地方都不凭 cwd/time 生产 confirmed。
- [ ] 文件前值未知用 NULL，不用 0；权限/重启/回放缺口明确。
- [ ] 父子目录不重复累计，不牺牲子目录证据。
- [ ] 所有队列、query、scanner、log、inventory、outbox 有上限。
- [ ] 真实后台与系统通知不依赖 UI 窗口。
- [ ] 索引、WAL、日志、备份等自身总占用可见，低空间不灌盘。
- [ ] App 只读 DB，配置写入和业务状态由 Agent 验证应用。
- [ ] 单写者、升级备份、未来版本拒绝、失败回滚有测试。
- [ ] 未测试/受阻能力没有写 PASS。

### 24.3 最终给用户的报告结构

1. 现在能回答哪些真实问题：时间、目录、文件、任务候选、仍存在文件。
2. 这台 Mac 上实际通过的场景和当前运行状态。
3. 真实 Codex 客户端/版本覆盖；其他客户端保持未验证。
4. 系统通知、登录恢复、长期资源验收分别是什么状态。
5. 尚未解释的情况（范围外缓存、APFS、并发、没有前值），如何在 UI 查看。
6. 启停、配置和回退入口。

不得只汇报“新增 N 个类、N 项测试通过”。如核心功能没有真实文件明细或原因候选，必须直说仍未达到原始需求，不宣布完成。

## 25. 官方技术依据与本机观察的边界

以下链接用于 API 语义，不用于声称本项目已通过验收：

- Apple 的 [FSEvents 使用与历史恢复指南](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)：持久事件位置、回放、丢失事件与校准要求。事件仍是线索，不是精确写入者证明。
- Apple 的 [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) 与 [agent(plistName:)](https://developer.apple.com/documentation/servicemanagement/smappservice/agent%28plistname%3A%29)：注册应用包内的用户级后台服务。
- Apple 的 [通知授权](https://developer.apple.com/documentation/UserNotifications/asking-permission-to-use-notifications) 与 [本地通知调度](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)：用户授权和系统请求链路。
- SQLite 的 [Online Backup API](https://sqlite.org/backup.html)：一致性备份；不能复制单一正在写入的 DB 文件冒充完整备份。
- SQLite 的 [WAL](https://www.sqlite.org/wal.html)、[PRAGMA](https://sqlite.org/pragma.html) 与 [VACUUM](https://www.sqlite.org/lang_vacuum.html)：checkpoint、空闲页、增量回收与物理文件大小的区别。

Codex 的事件信封和 originator/version 来自本机白名单元数据观察，不是所有版本的稳定公共合同。任何未见字段或新版本必须降级并补验证，不能猜测兼容。嵌入式 Agent 通知与登录恢复的方案必须经真实 Mac 验收；官方 API 存在不代表当前本地签名环境一定通过。

## 26. 给执行模型的最后约束

把本文当成实施任务，不再输出泛化架构方案。先完成 M0，再按 M1–M8 实施。产品决策、默认值与核心数据语义已经给定；常规实现细节自行处理，只有新的不可逆操作、系统授权或确切环境阻塞需要用户介入。

发现源码较本文更新时，先验证对应缺陷是否已修复，保留正确实现，按同一验收目标补齐；不要为了对齐文件名而回退更新。迁移版本若已被其他工作占用，顺延并记录映射，不修改已发布迁移。

不发新需求问卷、不重做 UI 风格、不以正式签名或深追尚不可用为理由停掉容量、文件事实和候选关联。按已有权限完成全部可执行工作，逐项留下证据。用户需要的是能在这台 Mac 上持续解释磁盘变化的软件。
