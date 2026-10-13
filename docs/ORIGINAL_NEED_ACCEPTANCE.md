# 原始需求验收矩阵（F01–F10 / R01–R12）

本文件逐条记录实现与验收状态。状态含义：

- **ENGINEERING_PASS**：实现与确定性自动化测试通过（本机）。
- **MAC_LOCAL_PASS**：在用户 Mac 上真实采集/文件事实/后台关窗/权限场景通过。
- **CODEX_CLIENT_PASS(kind, version)**：指定真实客户端与版本通过。
- **LOGIN_RECOVERY_PASS**：经过真实退出登录/重启验证。
- **NOT RUN / BLOCKED**：未执行或受阻。
- **RELEASE_READY**：本任务不宣称（缺正式签名、公证、双架构与发布验收）。

环境：macOS 14.6 (23G80)、arm64、无 Xcode、Swift 6.2 工具链 + CLT 15.0 SDK。
自动化测试：`swift test` → **99 项通过**（20 套件）。隔离验收：`scripts/acceptance-original-need.sh` → 全部断言 PASS。

## 功能能力

| 编号 | 能力 | 状态 | 证据 / 边界 |
|---|---|---|---|
| F01 | 卷级容量历史 | ENGINEERING_PASS + MAC_LOCAL_PASS | 60 秒采样、可用空间曲线、口径（importantUsage/statfs）记录于 `volume_measurement_context`；本机真实写入。 |
| F02 | 目录净变化 | ENGINEERING_PASS + MAC_LOCAL_PASS | 流式扫描生成目录摘要，写入 `scan_directory_summaries` 与 `directory_changes`（带 scan_id）。 |
| F03 | 具体文件变化 | ENGINEERING_PASS + MAC_LOCAL_PASS | `file_inventory` + `file_changes`：added/grown/shrunk/removed/replaced/moved/firstObserved；未知前值为 NULL。验收脚本断言具体路径。 |
| F04 | Codex 任务元数据 | ENGINEERING_PASS；真实客户端 **NOT RUN** | 精确支持 `session_meta` / `event_msg.payload.type` 信封，`turn_id`；完整行游标与任务状态机；C01–C18 测试。真实 Codex 客户端覆盖 **未验证**。 |
| F05 | 可信关联 | ENGINEERING_PASS（算法） | 归属矩阵 E01–E11；时间/目录重合不升级 confirmed；未验证客户端保持 unknown。 |
| F06 | 任务后仍存在的文件 | ENGINEERING_PASS（时钟驱动） | `presence_checks` +10 分钟/+24 小时；present/replaced/missing/unknown；真实 24 小时 **NOT RUN**。 |
| F07 | 主动提醒 | ENGINEERING_PASS（逻辑）；真实系统通知 **NOT RUN/BLOCKED** | outbox + 幂等 request + 冷却 + quiet hours + 到期；`UNUserNotificationCenter` sink 已实现于嵌入式 Agent app。真实横幅可达性未验证。 |
| F08 | 日常持续运行 | 部分 | Agent 独立于 UI 运行；暂停/恢复/停止语义在代码层；`SMAppService` 注册与内嵌 Agent bundle 与打包脚本已实现。真实登录恢复 **NOT RUN**。 |
| F09 | 资源自限 | ENGINEERING_PASS（逻辑）；性能 **NOT RUN** | 有界 FSEvents 队列、行预算索引、软/硬配额、低空间降载；30 分钟空闲 CPU/RSS 未测。 |
| F10 | 中文 UI 闭环 | ENGINEERING_PASS（构建）；交互截图 **NOT RUN** | 侧栏「空间概览 / 文件与事件 / 目录变化 / 监控状态」；事件→具体文件→任务候选→Finder；只读连接。 |

## 真实操作（需用户或真机）

| 编号 | 操作 | 状态 | 说明 |
|---|---|---|---|
| R01 | 本地安装新 bundle，App 与后台启动 | **NOT RUN** | bundle 构建脚本已提供；本机安装未执行。 |
| R02 | 关闭主窗口 ≥3 分钟 | **NOT RUN** | 需真机交互。 |
| R03 | 退出 UI 后发测试通知 | **NOT RUN** | 需系统通知授权。 |
| R04 | 暂停 1 分钟、恢复 | **NOT RUN** | 需真机交互。 |
| R05 | 主动停止，再启动 | **NOT RUN** | 需真机交互。 |
| R06 | 真实 Codex 小任务 | **NOT RUN** | 需用户已授权客户端与认证。 |
| R07 | Codex 写文件 + 用户复制到 Downloads | **NOT RUN** | 需真机；离线隔离脚本已覆盖等价场景。 |
| R08 | 更改目录权限再恢复 | **NOT RUN** | 有 D09/D10 离线覆盖。 |
| R09 | 强制结束 Agent 再恢复 | **NOT RUN** | 有 C10/C11 离线覆盖。 |
| R10 | 真实退出登录/重启恢复 | **NOT RUN** | 需用户完成登录操作。 |
| R11 | 持续真实运行 24 小时 | **NOT RUN** | 需时间积累。 |
| R12 | 通知拒绝 / 服务 requiresApproval | **NOT RUN** | 需真机授权交互。 |

## 原始缺陷修复对照

| 编号 | 内容 | 状态 |
|---|---|---|
| B01 | 真实 `event_msg.payload.type` 信封 | 已修复 + 测试（C01） |
| B02 | 依据 committed/read position 持续推进 | 已修复 + 测试（C02/C03） |
| B03 | 完整行边界跨重启 | 已修复 + 测试（C04/C07） |
| B04 | 归因前不过滤项目子目录 | 已修复（`EventAssembler` 逐 scope 归因，展示去重） |
| B05 | 公平调度、避免永久饥饿 | 已修复 + 测试（C16） |
| B06 | byte-level skipString，不解码正文 | 已修复 + 测试（C14/解码计数） |
| B07 | 任务状态/验证参与证据强度 | 已修复（`windowIsTaskBounded` + `verification` 矩阵） |
| B08 | 独立容量循环 | 部分（采样与扫描分离；独立线程/取消为后续） |
| B09 | 每 root 状态/缺口/退避 | 已修复（`root_scans`/`root_health`/`needsRebaseline`） |
| B10 | 持久 change hints + checkpoint | 已修复（`change_hints`/`event_checkpoints`）；per-path 探测为后续 |
| B11 | 保留按行预算退出 + 关联完整性 | 已修复（`pruneHistory`/`reclaimSpace` 分离） |

## 结论

- 用户的核心问题（何时减少、增长在哪些目录和**具体文件**、是否与任务有可核验关联、哪些文件任务后仍在）已在**工程与本机离线层面**闭环并有测试与隔离验收证据。
- **真实 Codex 客户端、系统通知、登录恢复、24 小时资源**四类验收 **NOT RUN**，不得视为通过。
- 正式签名/公证/双架构发布 **未完成**，不得声明 `RELEASE_READY`。
