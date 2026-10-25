# DiskTrace 下一轮开发交接与复盘

交接日期：2026-10-24。用途：供新的开发对话直接接手。本文是下一轮迭代提案，不代表相关功能已经实现，也不自动改写原始 PRD 的首版与发布门槛。

## 1. 用户真正要解决的问题

用户主要使用各种 Agent 做项目，希望回答：“这一个小时磁盘为什么少了几个 GB？这一段主要来自 Codex，上一段是否主要来自 Claude？具体是什么文件，之后还在不在？”

下一轮目标：选择时间段，看到空间变化、主要落点、软件与用途、相关任务候选和解释不了的部分。必须分开“Codex 自动更新”“Codex 会话数据增长”“Codex 执行某次任务下载依赖”。软件归属不等于任务归因；系统 swap 不因某个 Agent 同时运行就归给它。

## 2. 项目位置、版本与接手入口

- 本地源码：克隆后的工作目录（示例 `~/Projects/DiskTrace`）。
- GitHub：`https://github.com/paimmme/disktrace`。
- 接手前先核实当前分支与 `git log -1`；不假设远端与文档中的旧 HEAD 一致。
- 本机 App（可选）：`~/Applications/DiskTrace Local.app`（由 `scripts/package-local.sh` / `scripts/deploy-interval-slice.sh` 生成）。
- 真实历史库：`~/Library/Application Support/DiskTrace/disktrace.sqlite`。运行中的数据库及 WAL 不可直接删除或覆盖。
- 旧版 App 备份应通过 `scripts/cleanup-local-residuals.sh` 清理，避免 Spotlight 误开旧包。

先读以下文档：
1. `docs/DiskTrace_PRD_v4.0.md`：产品目标与冻结边界。
2. `docs/DiskTrace_Technical_Architecture_Review_v4.0.md`：扫描技术和架构优先依据。
3. `docs/PRODUCT_STATUS.md`、`docs/implementation/REPAIR_RESULT_20261013.md`：当前实现边界及上轮修复。
4. `docs/validation/REPAIR_20261013.md`：已执行验证及未执行门槛。
5. `docs/OPERATIONS.md`、`docs/LIMITATIONS.md`、`docs/PERFORMANCE.md`：部署、迁移、隐私和资源约束。
6. 本文，再按需要读 `ARCHITECTURE.md`、`TEST_MATRIX.md`、`TECHNICAL_GATES.md`。

文档存在版本漂移：README 前半部仍写 50 项测试，旧验收矩阵写 99 项，最新修复摘要记录 110 项；部分旧结论已在文件顶部撤回。不能把旧 README 或矩阵下方“全部闭环”当作产品当前状态。新增执行文档应明确引用证据日期，并统一受影响的说明。

## 3. 已完成什么，为什么仍没解决用户的问题

上轮已建立：Swift/SwiftUI、单用户后台、SQLite 单写者、独立容量采样、库存代次差分、具体文件事件、任务候选、中文只读界面、本地命令回执、暂停恢复、配额与通知基础设施。

2026-10-13 修复重点：宽扫描不误发 Agent 归因提醒；事件更新累积文件并保留用户反馈；库存预算涵盖准备代次；写者锁与采样扫描解耦；安全打包、未知值及分页。历史最终验证为 110 项 / 22 套件通过，另有隔离六场景、release 构建和临时签名检查。这些是历史结果，本次未复测。

仍有四个直接阻碍：
- 覆盖不足：上次审计的六个监控根主要是 Documents 项目和 `.codex`、`.cache`、`.agents`，未覆盖当天主要增长的 `Library/Caches` 更新目录与 VM 交换空间。
- 线索未闭环：`MonitorCoordinator` 已 drain 并持久化 `change_hints`，但未串起及时的逐路径探测和差分；常规事实依赖周期扫描。
- 原因不透明：低空间与库存预算都可能显示 `quotaLimited`，用户看不出是缺空间、行预算还是字节预算。低空间时正好失去最需要的解释能力。
- 真实客户端未验收：Codex 客户端结构、长记录、轮转等尚未闭环；不能凭活动时间和文件夹名称确认任务写入。

2026-10-24 前一轮只读审计快照记录：2,987 个容量样本、262,763 条库存、303 个任务窗口、34,164 条文件变化；2,293 个 storage_events 全为 unknown；9,689 个 pending hints；client_verification 为空；六个 root 为 quotaLimited/pending。**这是当时快照，不是当前读数**。清理后磁盘已有余量，必须重新核实是否自行恢复，不能把当时受限状态作为今天仍失败的证明。

另有构建身份问题：当时 App 0.2.1/build 2，而 local-run.json 仍写 commit 7779285。不能仅凭该文件判断安装二进制等于源码 HEAD。先补可核验构建标识，避免验证错版本。

## 4. 两个真实案例：作为回放验收材料

### 案例 A：短时间空间耗尽

原审计记录：20:06 余量 6.76 GiB，21:45 余量 0.23 GiB，下降约 6.53 GiB。人工回溯主要发现 Codex 更新缓存约 2.39 GiB、新增 swap 约 3 GiB、Harness 更新包约 0.65 GiB；其余约 0.49 GiB 是算术差额，不能声称它全是漏扫文件。

这是人工重建，不是 DiskTrace 当时已经采到的实时归因。没有前值或路径证据的历史不能补造。回放应使用脱敏、小体积 fixture 和注入采样；不要为了模拟故障实际填满磁盘或制造 GB 级 swap。

### 案例 B：清理后为什么目录大小与释放空间不同

本对话实际删除：下载/更新缓存约 1.72 GiB、浏览器旧临时副本约 13.71 GiB、Adobe 相关软件和支持数据约 6.88 GiB。Data 卷 df 可用量从 7.83 GiB 增至 18.32 GiB，净增加 10.48 GiB。目录分配统计不能直接相加当作物理释放量，APFS 共享块和后台写入都会影响结果。Chrome 重启后又生成新临时副本，旧项删除与新项创建必须区分。

本机验收证据应保留在开发者私有目录，**不要**把含用户名、绝对路径或清理清单的原始日志提交公开仓库；需要时在 `Tests/` 或 `docs/validation/` 使用脱敏 fixture。

## 5. 下一轮交付：时间段空间解释闭环

建议工作标题：**时间段空间解释：应用缓存、交换空间与覆盖缺口**。内部按以下顺序推进，不预设必须拆成四个 PR，也不要求重做现有架构。

### A. 先固定运行身份和口径

记录实际 App/后台二进制、源码 commit、构建号、schema、采样配置和客户端适配版本。只读检查当前根健康、积压、缺口及客户端验证记录。

已有 `VolumeSampler.sampleAndMethod` 和 `volume_measurement_context`；不要重复开发“记录采样方法”。需要评估补充：同时保存 statfs 原始可用量与 importantUsage 值、卷/容器身份、查询时方法兼容性。方法切换不能被画成真实空间突变。Data 与 VM 可能共享 APFS 容器；Data 文件净变化与容器可用量不可直接核销。

### B. 补有界采样与最小及时差分

按本机实际存在路径提供软件更新/缓存预设，先覆盖 Codex、Harness，再探测 Claude；只加选定根，不扫整个 Library 或整个磁盘。swap 使用轻量总量采样，区分文件分配量与交换使用量，不宣称单应用责任。

把 `change_hints → 合并去抖 → MetadataProbe → 有效前值比较 → file_changes → EventAssembler → 检查点` 接成最小闭环。保证幂等、有界重试、公平调度、重启恢复；前值未知用 NULL，不当作零。创建、追加、删除、移动、替换与父子目录线索不能重复计数。先利用现有库存索引，不引入第二套全盘索引。

低空间继续停昂贵库存扫描，但保留容量、swap、已知重点路径的有界探测与历史查询。低空间、行预算、字节预算、权限、暂停分别显示；预算不足不得删旧有效基线腾位置。

### C. 把事实变成用户可读的区间报告

入口提供过去一小时、今天、自选时间。展示区间可用空间变化、已观测新增/释放/净变化、软件与用途分组、系统变化，以及未覆盖/不可比较部分。支持下钻具体文件、证据时间、方法、最近校准和覆盖缺口。

同一文件在重叠根或父子聚合中只计一次。首次基线不是新增；恢复窗不是已证实实时写入。软件路径规则只提高软件/用途标签，不提高任务归因强度。不能强行凑成 100% 饼图。

### D. 本轮验收后继续

先完成一个真实 Codex 客户端/版本的脱敏验证，再实现 Claude 适配；Harness、OpenCode 后排。覆盖单 Agent、两 Agent 同项目、手动下载并发、自动更新并发、崩溃/轮转/超长日志。多候选保留多候选，不均摊共享缓存，不因降低证据门槛提高覆盖率。

最后完成通知横幅、登录恢复、休眠唤醒、24 小时资源和发布门槛。PRD 的空闲 CPU <0.5%、常驻内存 <50 MB 是既有待实测目标，不能因当前未测而默默改掉。可选深追仍是原 PRD 范围；本轮不把它作为轻量解释功能的前置条件，也不宣称已满足原 PRD。权限或发布能力受阻时应记录 ADR 和未完成门槛。

## 6. 代码入口与验收标准

优先入口：
- 采样和调度：`Sources/DiskTraceCore/Monitor/VolumeSampler.swift`、`MonitorCoordinator.swift`、`Runtime/AgentRuntime.swift`。
- 路径差分：`Scanner/MetadataProbe.swift`、`Scanner/StreamingScanner.swift`、`Storage/StoreInventory.swift`。
- 聚合与证据：`Policy/EventAssembler.swift`、`Policy/AttributionPolicy.swift`、`Storage/StoreEvents.swift`。
- 存储与界面：`Storage/Migrations.swift`、`Models/Observations.swift`、`Sources/DiskTraceApp/AppModel.swift` 及对应视图。
- 客户端：`Codex/CodexSessionLog.swift`、`Codex/CodexActivitySync.swift`。

第一轮验收必须能证明：
1. 隔离模拟更新下载与解压，显示软件更新，不能确认为某次编码任务。
2. 注入 swap 变化，显示系统交换；监控外增长显示覆盖不足，不能强配给 Agent。
3. 创建、追加、删除、移动、替换，差分正确；重复 hints 与重启不重复计数；无前值显示未知。
4. 注入低于 2 GB 情况仍能保留轻量解释，扫描和队列有界；不真的填满本机。
5. APFS 共享块、不同采样方法与不同卷不被强行相加；无法比较时明确标注。
6. UI 能从时间段下钻来源、文件、证据和缺口；部分查询失败不能用空列表冒充无变化。
7. 不引入误归因 confirmed；用户反馈、原始历史与有效基线保持。

先跑受影响模块已有测试，必要时增加行为回归；一组修改完成后集中验证。阶段验收才扩大集成测试或构建。110 项是旧记录，不代替新功能验收；不要一开始无差别全量测试。纯交接文档不运行代码测试。

## 7. 新对话执行约束和首个动作

这是规划交接；本轮没有改功能、升级 App、改配置、迁移或清空历史库，没有创建定时任务。新对话拿到开发授权后，先做只读复核，写一份精简执行文档，把本轮切片、迁移方案、测试和未执行门槛列清，再实现 A–C 的最小闭环。

保留 Swift/SQLite、单用户后台、只读 UI 与受支持命令通路。不自动清理用户文件，不读任务正文、源码内容、原始命令或认证信息。部署前一致性备份真实库、停止旧写者、确认单写者、保留旧包；不能绕过版本兼容。运行中的数据库不直接改写；使用受支持迁移流程。

本地基线已知时无需重新全盘审计；先读目标文件。此规划任务不建立 CodeGraph。新开发若确实涉及足够大且跨模块的代码关系，再按全局规则判断。

本次验证：一轮文档核查，检查路径、Git 基线、原始需求与历史记录的一致性；未运行代码测试或构建。
