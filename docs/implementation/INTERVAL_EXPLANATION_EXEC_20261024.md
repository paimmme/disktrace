# 时间段空间解释 — 技术执行文档

证据日期：2026-10-24。源码基线：`feat/original-need-closed-loop` @ `f936634`（接手时 HEAD，交接文档 `NEXT_ITERATION_HANDOFF_20261024.md` 未提交）。

## 本轮切片（A–C）

| 阶段 | 交付 | 不在本轮 |
|---|---|---|
| A 运行身份与口径 | `build_*` 写入 `monitor_state`；卷采样同时持久化 statfs 与 importantUsage；只读复核真实库；`limitation_kind` 区分低空间/行预算/字节预算 | 正式签名、公证、Intel |
| B 有界采样与 hint 闭环 | 可选监控预设（Codex/Harness/Claude 缓存路径）；swap 轻量采样；`change_hints → pending_path_work → MetadataProbe → file_changes`；低空间仍跑有界路径探测 | 全盘 Library 扫描、第二套索引 |
| C 区间报告 UI | 概览页「时段解释」：可用空间、swap、按软件/用途分组、未覆盖差额与缺口；方法不一致时不强行相减 | 100% 饼图、任务 confirmed |

## 迁移与部署（真实库）

1. **只读核验**：`PRAGMA integrity_check`、schema 版本、pending hints、root 状态、构建标识（不写入）。
2. **备份**：停止旧写者 → SQLite backup API → `integrity_check`（见 `docs/OPERATIONS.md`）。
3. **升级**：单写者持锁 → 迁移 v6→v7 → 新 Agent/App 二进制；保留 `DiskTrace Local.before-*` 回退包。
4. **禁止**：运行中直接覆盖 DB/WAL、清空历史、自动删用户文件、采集提示词/命令正文。

## 测试计划

- 定向：`PathHintProcessorTests`（差分、去重、幂等）、`IntervalReportTests`（分组、方法不可比、swap 展示）。
- 回归：原 `FileChangeTests` hint 用例、低空间 `ResourceAndRestartTests` 相关项。
- **不**以历史 110 项代替本切片验收；全量 `swift test` 在定向通过后执行一次。

## 仍未通过的 PRD / 发布门槛（显式保留）

- 真实 Codex/Claude 客户端矩阵与 `client_verification` 填充
- 系统通知横幅、登录恢复、休眠唤醒长测
- 24h CPU &lt;0.5%、常驻 RSS &lt;50 MB 实测
- Intel 构建、公证、正式发布
- 可选深追（fs_usage/ES）仍为 NOT SHIPPABLE

**不宣称**原始需求全部完成或正式发布就绪。

## GitHub 开源适配（并行）

- 保持 `LICENSE`、`.gitignore` 排除本机 DB/artifacts；README 状态与 `PRODUCT_STATUS.md` 对齐；不提交含本机路径的清理证据。
- 见 `docs/OPEN_SOURCE.md`。

## 2026-10-24 只读核验与测试（本切片）

| 项 | 结果 |
|---|---|
| Git HEAD | `f936634`（`feat/original-need-closed-loop`，与交接一致） |
| 已安装 App | `~/Applications/DiskTrace Local.app`（`local.disktrace.app`，**未**含本切片二进制） |
| 真实库 schema | **v6**（`integrity_check=ok`）；`limitation_kind` / `swap_samples` 待新写者迁移 v7 |
| pending `change_hints` | 13,542（2026-10-24 只读计数） |
| `build_*` monitor_state | 无（旧写者未写入；新 Agent 启动后会写入） |
| 定向 + 全量测试 | **116** tests / 24 suites 通过（Swift 6.2，~1s） |

部署本切片前：按 `OPERATIONS.md` 停写者 → backup → 换 Agent/App → 单写者验证；**不要**让旧 App 直接写 v7 库。
