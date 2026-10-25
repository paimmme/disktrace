# Operations（启停、配置、迁移、回退）

本文件说明如何在本机运行、暂停、停止和回退 DiskTrace。所有路径均相对于
`~/Library/Application Support/DiskTrace/`，除非另有说明。

## 组件

- **DiskTraceApp**：SwiftUI 只读界面（`Sources/DiskTraceApp`）。
- **disktrace-agent**（CLI）：隔离测试与本地脚本用（`Sources/DiskTraceAgent`）。
- **DiskTraceAgentApp**：嵌入式无主窗口后台 app，持有系统通知身份（`Sources/DiskTraceAgentApp`）。
- **DiskTraceStore**：唯一的 SQLite 写者（WAL）。

同一数据库同一时刻只能有一个写者；`SingleWriterLock`（POSIX `flock`）保证第二个 Agent 以非零状态退出。

## 构建与测试

```bash
cd '$HOME/Documents/DiskTrace'
export DISKTRACE_SWIFT_TC='/private/tmp/swift-6.2-expanded/swifttc/swift-6.2-RELEASE-osx-package.pkg/Payload'
source scripts/toolchain-env.sh          # 复用已安装工具链，不下载
swift build
swift test
```

若该工具链路径不存在，请设置 `DISKTRACE_SWIFT_TC` 指向本机已展开的 Swift 6.2 payload，
或在有网络时让 `scripts/toolchain-env.sh` 重新下载（约 1.7 GB）。

## 运行（本地 CLI）

```bash
swift run disktrace-agent --db "$HOME/Library/Application Support/DiskTrace/disktrace.sqlite" \
    --root "$HOME/Documents" --root "$HOME/Downloads" --codex-home "$HOME/.codex"
```

- `--once` 只跑一个周期（start + 一次循环）。
- 未提供 `--root` 时默认监控 home（不建议，范围过大）。

## 打包本地 App（临时签名）

```bash
scripts/package-local.sh --output "build/DiskTrace Local.app" --configuration release --sign-identity -
```

生成嵌套 bundle（主 App + `Contents/Library/LoginItems/DiskTraceAgent.app` + LaunchAgent plist），
并从内到外 `codesign`。**`-` 为临时签名，不是可分发的正式签名。**

## 登录恢复（用户操作）

界面中使用 `SMAppService.agent(plistName: "local.disktrace.agent.plist")` 注册用户级后台服务。
注册是用户显式动作；`requiresApproval` 时必须到「系统设置 → 通用 → 登录项」批准。
本机真实登录恢复验收为 **NOT RUN**（见 `docs/ORIGINAL_NEED_ACCEPTANCE.md`）。

## 暂停 / 恢复 / 完全停止

- **暂停**：保留卷采样与心跳，停止目录与任务采集，并打开 `manualPause` 缺口；恢复时先校准。
- **完全停止**：由 App 取消注册服务并等待进程退出；CLI 停止仅在服务被禁用后安全退出。

## 数据库迁移

- 当前 schema 版本：**v7**（v6 事件/关联/通知 → v7 双口径卷采样、swap 样本、`limitation_kind`）。
- 历史 v6 见上一版说明（v1–v6 链不变）。
- 每个版本一个事务；`PRAGMA foreign_keys=ON`。写者拒绝比自身更新的 schema（不迁移未来版本）。
- 升级前建议用 SQLite [Online Backup API](https://sqlite.org/backup.html) 生成一致性备份
  （含已提交 WAL），不要复制正在写入的单个 `.sqlite` 文件。

## 回退

- 新版 runtime 失败：先禁用/停止新服务，保存错误证据，避免 KeepAlive 重启竞态。
- v6 数据库不能交回旧版（v3）Agent 写入；回退必须使用升级前备份恢复到独立路径，由用户确认后再切回。
- 若安全回退空间不足：保留数据、停止写入、标记 **BLOCKED**，不采取删库捷径。

## 隐私

- 不读取被监控文件正文；不保存提示词、命令、消息或工具载荷。
- Codex 日志按字节流式读取，仅解码结构白名单元数据（哈希会话/任务 ID、时间、工作目录、客户端种类）。
- 不创建额外常驻服务、HTTP/WebSocket、云端组件。
