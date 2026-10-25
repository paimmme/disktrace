# DiskTrace

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2+-orange.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-116%20suites-brightgreen)](#build-and-run)

**Local-first macOS disk forensics for AI-assisted development.** DiskTrace answers a question ordinary cleaners skip: *when* did free space drop, *where* did monitored directories grow, and is there **bounded evidence** linking growth to an agent session — without reading prompts, commands, or file contents.

> **Status:** Runnable on a real Mac for personal use; **not** a finished product release. Task attribution, full client matrix, notarization, and 24h resource gates remain open. See [`docs/PRODUCT_STATUS.md`](docs/PRODUCT_STATUS.md).

## Why DiskTrace

| Typical disk tools | DiskTrace |
|--------------------|-----------|
| One-time “what is big” | **Timeline** of volume free space |
| Whole-disk scan only | **Monitored roots** you choose (App or config) |
| Guess from folder names | **Facts vs clues**: file deltas, events, optional Codex metadata |
| Silent or noisy alerts | Low-space **system notification once per episode** (optional) |

## Screenshots (UI)

Personal-dev UI (Chinese): **空间概览** with one-line interval summary and charts · **文件与事件** card list · **目录变化** top-5 soft bars (not dense chart spam) · **设置 → 监控目录** without hand-editing JSON.

_Add your own screenshots to `docs/images/` when publishing releases — do not commit private paths or real monitoring data._

## What works today

- **Background agent** (`disktrace-agent`): volume sampling, bounded FSEvents, directory recalibration, SQLite single writer, retention, alert policy.
- **SwiftUI app (read-only)**: overview, events, directory growth, health; Finder reveal; control inbox (pause / calibrate / notifications).
- **App-configured monitor roots**: writes `~/Library/Application Support/DiskTrace/local-run.json` and hot-reloads the agent.
- **Interval explanation** (schema v7): swap samples, path-hint work queue, visual summary panels.
- **Codex reader**: whitelist metadata only; optional `--verify-codex-client` acceptance on your machine.
- **116 automated tests** (`swift test`) — policy, storage, hints, notifications, synthetic flows.

## Architecture

```
 disktrace-agent (MonitorCoordinator)
        │
        ▼
 DiskTraceStore (SQLite, WAL, single writer)
        ▲
        │ read-only
 DiskTraceApp (SwiftUI)
```

Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Build and run

Requires **macOS 14+** and **Swift 6.2** (see [`scripts/toolchain-env.sh`](scripts/toolchain-env.sh) if your Xcode CLT Swift is older).

```bash
git clone https://github.com/paimmme/disktrace.git
cd disktrace
swift build
swift test
swift run disktrace-agent --once --db /tmp/dt.sqlite --root "$HOME/Documents"
open .build/debug/DiskTraceApp   # or package with scripts/package-local.sh
```

### Local install (optional)

```bash
scripts/package-local.sh --output "$HOME/Applications/DiskTrace Local.app" --configuration release --sign-identity -
scripts/deploy-interval-slice.sh   # stops agent, backs up DB, merges roots, restarts
scripts/cleanup-local-residuals.sh # removes old .previous / .before-repair app copies
```

## Open source & privacy

- Do **not** commit your live database, `local-run.json`, or `artifacts/` with real paths. See [`docs/OPEN_SOURCE.md`](docs/OPEN_SOURCE.md).
- DiskTrace does not upload data; Codex integration stores hashed session ids and bounded metadata only. See [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md).

## Documentation map

| Doc | Purpose |
|-----|---------|
| [`docs/PRODUCT_STATUS.md`](docs/PRODUCT_STATUS.md) | Honest shipped vs missing |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | DB location, agent, migrations |
| [`docs/PERSONAL_DEV_ROADMAP.md`](docs/PERSONAL_DEV_ROADMAP.md) | Personal “good enough” checklist |
| [`docs/TECHNICAL_GATES.md`](docs/TECHNICAL_GATES.md) | Radix, FSEvents, notarization gates |

## License

MIT — [`LICENSE`](LICENSE). Third-party notices: [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
