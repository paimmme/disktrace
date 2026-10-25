# Codex 真实客户端验收（本机）

证据日期：2026-10-24。由 `disktrace-agent --verify-codex-client` 写入 `client_verification`（非运行时自动提升）。

## 命令

```bash
disktrace-agent --verify-codex-client --db "$HOME/Library/Application Support/DiskTrace/disktrace.sqlite" \
  --codex-home "$HOME/.codex"
```

## 判定口径

- 仅解析会话 JSONL 白名单元数据（不读提示词/命令正文）。
- 某 `(clientKind, clientVersion, schemaKind)` 在 **14 天内** 至少观察到 **1 个** `startKnown && endKnown && completed` 的 `codex-envelope` 任务窗口，且 `clientKind != unknown` 时，才写入 `realClientVerified`。
- 否则保持 `unverified`；`AttributionSmoke` 只统计 `pathCandidate` vs `timeOnly`，**不**宣称 confirmed 写入。

## 2026-10-24 本机结果（脱敏摘要）

| 项 | 结果 |
|---|---|
| 写入 `client_verification` | `codexDesktop` / `0.162.0-alpha.17.2` / `codex-envelope` → **realClientVerified**（23 个 completed 有界窗口） |
| 其它 profile | `unknown` 版本等保持 **unverified** |
| 24h 归因烟测 | `pathCandidate=0`，`timeOnly=429`；事件 attribution 仍为 unknown — **未**宣称任务写入证明 |
| schema 迁移 | 生产库 → **v7**；`build_git_commit=f936634` |

## 仍未完成

- Desktop/IDE/CLI 全矩阵、并发 Agent、24h 长跑与通知横幅仍见 `PRODUCT_STATUS.md`。
