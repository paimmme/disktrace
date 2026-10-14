# DiskTrace 使用说明（面向 Coding Agent 用户）

## 你的问题，这个项目在解决什么

DiskTrace 不是「现在谁最大」的清理工具，而是回答三个问题：

1. **什么时候**磁盘可用空间变少了？
2. **哪些路径**在变大（具体文件，而不只是某个文件夹总数）？
3. 这次增长**有没有可能**和某次 AI Agent 任务有关——并且把**证据强弱**写清楚，而不是瞎猜。

你的场景（Cursor / Codex 等 Agent 跑完后盘又满了）正是 PRD 里的首要用户画像。

## 当前能力边界（诚实说明）

- **已可用**：卷级空间曲线、监控目录内的文件级差分、中文只读 UI、Codex 会话元数据读取、**Cursor Agent JSONL 转录**（本轮新增，仅读 turn 边界与工作区路径，不读对话正文）。
- **仍不完整**：没有进程级写入证明，`agentConfirmed` 不会出现；真实客户端矩阵、系统通知横幅、24 小时资源验收尚未完成。详见 [`PRODUCT_STATUS.md`](PRODUCT_STATUS.md)。

## 推荐本机用法

```bash
# 构建
swift build

# 一次性跑一轮（数据库与监控目录可自定）
swift run disktrace-agent --once \
  --db ~/Library/Application\ Support/DiskTrace/disktrace.sqlite \
  --recommended-roots

# 长期后台（CLI）
swift run disktrace-agent --recommended-roots
```

`--recommended-roots` 会在用户主目录之外，自动加入本机已存在的常见 Agent/构建缓存目录（DerivedData、`.npm`、`.cursor`、`.codex` 等）。

SwiftUI 应用默认只读同一 SQLite；写操作由 `disktrace-agent` 或内嵌 Agent 完成。

## 如何理解「任务归因」

- **目录扫描窗**（默认约 15 分钟）：看见文件事实，但 alone 不会触发「Agent 异常增长」通知。
- **FSEvents 线索 + 即时路径探测**（本轮增强）：在已有扫描基线上，对变更路径做 `stat`，产生 `liveHintWindow` 文件记录，才允许更强的任务候选关联。
- **会话同步**：从 Codex `~/.codex/sessions/*.jsonl` 与 Cursor `~/.cursor/projects/*/agent-transcripts/*/*.jsonl` 增量读取任务时间窗；与工作区路径重合时证据升级，**仅时间重合**仍为 unknown。

在 UI「文件与事件」里：先看净增长与文件列表，再看任务候选与 limitation 文案。

## 隐私

不读文件内容、不上传、不存 prompt。Codex/Cursor 读取均为白名单 JSON 字段；可选 `--hash-codex-paths` 对工作目录做哈希。
