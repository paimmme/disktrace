# DiskTrace — Codex 一次性交付执行 Prompt v4.0

你是承担 DiskTrace 开源 macOS 项目实施的资深 Swift/macOS 工程代理。本任务要求**实际开发并交付可运行的工程**，不是重复规划需求、创建空目录或生成演示 UI。

## 1. 开工前必须读取的材料（按优先级）

同一工作目录中将提供：

1. `DiskTrace_PRD_v4.0.md`：完整产品范围、用户体验、告警规则、验收标准。
2. `DiskTrace_Technical_Architecture_Review_v4.0.md`：源码审查、架构删减、ADR、G1–G7 技术闸门；**架构实现最高优先级**。
3. 本 Prompt：工作方式、交付与报告要求。

**旧文件 `DiskTrace_PRD_v3.2.md` 和 `DiskTrace_Codex_Handoff.md` 已被上述新版本替代。** 如出现冲突，以 v4.0 为准；不要重新开启需求 Grill。用户已明确要求停止重复提问，并倾向一次性开发交付。

## 2. 目标和不可妥协的产品行为

DiskTrace 是 macOS 14+、Apple Silicon/Intel 的 Local-first 磁盘空间溯源工具，首版聚焦 **Codex 等 AI Coding Agent 自主任务造成的持久磁盘增长**：

- **所有可观测空间变化都记录**；用户主动下载、Finder 复制、预期行为通常只在时间线展示，不发 Agent 异常通知。
- 有可靠证据的 Agent 异常增长优先提醒；证据不足时显示未知，不能根据 Downloads、node_modules 或仅时间重叠认定写入者。
- 严重低剩余空间可以独立发中性安全提醒，无论是否由 Agent 造成。
- 监测数据、归因证据、告警决策分别表示和持久化；静默规则永远不能删掉原始变化历史。
- 默认无需高权限，不分析文件正文，不收集 prompt、源代码和 secrets，不上传用户监控数据。
- 用户确认才能开启限时进程深度追踪、移至废纸篓和安装更新。

首版必须真正具备：卷级采样与时间线、目录校准、事件驱动增量更新、Agent-first 证据归因和通知过滤、Codex 优先适配、可选的真实进程观测能力（受平台约束）、健康度、手动操作、持久化与恢复、可构建/安装工程和测试证据。不能伪造任何权限相关能力或监控结果。

## 3. 最简技术架构（避免重复造轮子）

- **只保留**：一个用户级常驻 Agent；一个 SwiftUI App；一个 SQLite；一套扫描后端；少量按需集成。
- **优先复用**：`https://github.com/colinvkim/Radix` 的 `RadixCore`（Swift Package，扫描/增量/快照/APFS/树图），先核对 public API、macOS 14、Swift 6.2/Xcode、无 UI 调用及内存释放。优先依赖，不行最小 vendor/适配；不要直接 Fork 完整 Radix App。
- `https://github.com/137137137/OpenDisk` 只作为扫描性能对照或确有必要的后备**替换**方案，不同时集成第二套扫描器。
- `https://github.com/sjzasada/agentflash` 只借鉴事件/Hook 关联，不引入 Go、WebSocket、HTTP、sudo 常驻组件。
- 使用 Apple 系统框架/成熟组件：FSEvents、SMAppService、Swift Charts、SQLite；更新评估 Sparkle 等成熟方案，不自研更新引擎。
- **禁止**独立 Investigation Engine、多个常驻守护进程、长期保存每次完整文件树、逐次事件都递归扫全盘、自研 AI 意图识别模型、常驻 fs_usage 全盘追踪。
- 上游代码 MIT/其他实际许可证、版权声明、精确 commit 和移植文件必须可追溯，放入 `THIRD_PARTY_NOTICES.md`。

## 4. 工作方式（一次完整任务，允许内部原子提交）

### A. 技术闸门：先验证再编码主系统

先读取候选项目**真实源码与许可证**，记录上游 commit（注意审查文档给的是 Git tree SHA，不是已验证 commit）。实际执行 G1–G7：

- G1：RadixCore 能否在**无 UI 的 macOS 命令行 target**正常编译、扫描 fixtures；public API 是否够用。
- G2：扫描后释放大型文件树，低频 Agent 能否满足内存目标，必要时使用**非常驻**扫描 helper。
- G3：FSEvents 事件溢出、增加/删除/rename、硬链接/APFS clone 时增量结果与完整扫描是否符合口径。
- G4：Codex CLI/IDE/Desktop 逐客户端验证官方支持的本地元数据、通知/事件接口；不能把 `notify` 当作所有客户端的订阅总线。
- G5：确认可供普通 macOS 用户使用并签名分发的**真实进程级**文件操作来源；授权、权限、限制和退出机制都需验证。
- G6：用户下载/Finder 复制、Codex 活动、并发写盘的**误报率及告警证据边界**。
- G7：App 与 LaunchAgent 安装、启动、关闭 UI、升级、卸载、历史迁移路径。

把结果写入 `docs/REUSE_AUDIT.md` 与 `docs/TECHNICAL_GATES.md`，以 `PASS / FAIL / NOT RUN / BLOCKED` 表示。不要为等用户重复确认而停止；采用安全的可验证方案继续工程实现。**涉及平台不可分发的深追，保留明确降级，不得伪造 G5 通过，也不得宣布完整 Release Ready。**

### B. 工程实现

遵循 v4.0 的最小目录原则，结构只按真实职责拆分，不为架构整洁建立无用途的 Package。实施：

1. Agent 的 `MonitorCoordinator`：卷容量采样（初始建议 60s）、FSEvents 变化提示、去抖/合并、有界队列、有界恢复和按需扫描校准；异常短暂增强后自动恢复，不自动提权。
2. RadixCore 薄适配器：用户目录渐进基线、按需增量校准、需要时生成大树供 UI 深度查看；Agent 不长期持有全盘 `FileTreeStore`。
3. SQLite 聚合历史与保留管理：时间线、目录净变化、最小证据、告警决策与静默原因、配置、监控检查点、CoverageGap、迁移；WAL 与缓存计入软配额。
4. 归因与告警政策：纯函数规则，分别表示 `agent_confirmed` / `agent_probable` / `user_confirmed` / `user_probable` / `unknown`，另有独立的数据校准可信度；只存在时间重叠不允许升级成 confirmed。用户反馈可创建、检查、撤销本地规则。
5. Codex 适配：默认只读合法元数据，不收集 prompt/命令正文；增强集成只针对实际支持的客户端，用户同意、配置备份、可逆安装与卸载；无可靠事件时维持 `unknown`。
6. 深度追踪：仅在用户同意后限时运行；用真实、可分发的进程观测后端与完整权限说明；若无法获得权限或端点不可用，**可见地标注不支持**，绝不能用伪造 PID 或仅按文件目录归因冒充真实观测。
7. SwiftUI 页面：时间线 Home（Swift Charts）、增长详情、深度目录（按需 Radix 图形）、健康度、设置；Finder Reveal、风险提示与人工确认移到废纸篓。
8. 用户级后台注册/停用/恢复、休眠与崩溃补扫、App/Agent 通信安全、更新检查和用户确认安装、完整安装/卸载流程。
9. README、权限/隐私说明、许可证、第三方 notices、可复现安装、构建、升级和运维说明。

### C. 测试及证明

必须提供自动化测试和真实 Mac 验收脚本：

- 浏览器下载、Finder 复制等行为入库且默认静默；无证据不写 `user_confirmed`。
- Codex 真实或有证据事件写盘达到阈值才有 Agent 告警；不能用虚假 mock 充当客户端能力证明。Fixture 仅能证明规则算法。
- 并发用户/Agent 写盘保持未知部分、不虚报精确字节归因；APFS 大小口径明确。
- 高频小文件变更、FSEvents 丢事件、睡眠重启、权限拒绝、数据库 WAL 膨胀、超额、崩溃恢复、版本迁移。
- 闲置 30 分钟 CPU 平均低于 0.5%、常驻内存低于 50MB 为待验证目标；UI 和按需扫描 RSS 分开测。
- macOS 14+、Apple Silicon/Intel、签名/公证、Deep Trace 权限、更新安全执行以及移至废纸篓须**真机验证**。

每个验收条目须给出运行命令/设备/日期/结果/证据，标记 `PASS`、`FAIL`、`NOT RUN` 或 `BLOCKED`；不得以模拟运行代替真机。提交 `docs/TEST_MATRIX.md`、`docs/LIMITATIONS.md`、`docs/PERFORMANCE.md`。

## 5. 交付清单

- 真实源码项目与锁定依赖（不要只有文档/原型）。
- `README.md`、`LICENSE`、`THIRD_PARTY_NOTICES.md`、架构 ADR、源代码复用审计。
- 开发构建脚本、安装/卸载脚本或图形流程、可运行的真机验收脚本。
- 单元、集成与系统测试；报告所有执行与未执行测试、真实运行环境。
- 交付总结明确区分：**工程实现状态、Engineering Complete、Release Ready**。遇到无法实测的真实权限/签名问题，注明阻碍及重现步骤，而非自动给 PASS。

## 6. 执行约束

- 不再询问已经决定的产品问题。优先自己核查源码和文档，必要时采用最安全且技术可行的实现选择。
- 不人为拆四个 PR；可正常使用 commits、分支及迭代测试。
- 不修改用户其他项目或现有 Codex 配置（除非用户在软件中明确授权），禁止无确认删文件或获取管理员权限。
- 如果当前环境不是 macOS，仍应完成能完成的工程源码、测试、静态核查和文档；macOS 专有测试保持 `NOT RUN`，不可谎称真实运行。
- 有重大平台阻碍时按真实能力交付最大可工作部分，同时明确 Q20 是否满足；**不能为达成“完成”而降低对真实溯源的要求**。

现在开始执行：首先检查工作区和开发环境，读取 v4.0 两份文件与上游源码，完成复用技术闸门；随后构建并测试 DiskTrace；最后给出逐项证据报告，不需要反复问答式确认。
