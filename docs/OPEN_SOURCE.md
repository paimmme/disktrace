# 开源发布说明

DiskTrace 目标仓库：[github.com/paimmme/disktrace](https://github.com/paimmme/disktrace)。

## 仓库中应包含

- Swift 源码、`Package.swift`、`LICENSE`（MIT）
- `docs/` 产品状态、架构、门槛与 **未通过** 的发布项（见 `PRODUCT_STATUS.md`、`TECHNICAL_GATES.md`）
- 自动化测试（`swift test`，需 macOS 14+ 与 Swift 6.2 工具链，见 `scripts/toolchain-env.sh`）

## 不要提交

- 本机 `~/Library/Application Support/DiskTrace/` 数据库与 `local-run.json`（含监控路径）
- `artifacts/` 验收证据、清理日志、真实 Codex 路径
- 临时签名 App 二进制（可在 Release 中提供构建说明）

## 克隆后运行

```bash
source scripts/toolchain-env.sh   # 若系统 Swift < 6.2
swift build
swift test
swift run disktrace-agent --once --db /tmp/dt.sqlite --root "$HOME/Documents"
```

## 状态声明

开源代码 **不等于** 原始 PRD 全部完成或正式发布就绪；任务归因、真实客户端验证、系统通知与 24h 资源门槛仍以文档为准。
