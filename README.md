# DiskTrace

**Local-first macOS disk-space forensics for AI coding agents.** DiskTrace answers a question ordinary disk cleaners do not: *when* did the drive fill up, *where* did the growth land, and is there real evidence it was an autonomous Codex / Claude Code task — separate from the downloads and copies you made yourself.

It is **not** a "what is big right now" cleaner. It keeps a low-overhead history of volume free space, monitored-directory net change and bounded filesystem change clues, then attributes changes with explicit, explainable evidence. Expected user activity is recorded but stays silent by default.

> Status: **Engineering Complete, Release Not Ready.** See [`docs/TECHNICAL_GATES.md`](docs/TECHNICAL_GATES.md) and [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md). Nothing here claims a real signed/notarized install, a shippable process-level tracer, or a verified Codex client matrix.

## What works today (verified)

- **Single background Agent** (`disktrace-agent`) that samples volume capacity, watches changes with a bounded, coalescing FSEvents stream, periodically recalibrates directories, evaluates an alert policy and writes everything to one SQLite store.
- **Separation of fact and inference**: `Observation` (volume samples, directory deltas, change hints), `Evidence` and `AlertDecision` are distinct, and a silent rule never deletes observation history.
- **Agent-first alert filtering** as a pure function: time overlap alone can *never* become a confirmed agent alert; low disk space is a neutral, cause-agnostic safety alert.
- **Codex read-only metadata integration** that is privacy-structural — it scans session logs for a whitelist of keys only and never materializes prompt, command or file content.
- **Tiered retention** (detail → hourly → daily) with a soft quota that includes WAL/index overhead.
- A read-only **SwiftUI app layer** (timeline, growth, health, settings).
- **36 automated tests pass** (`swift test`), covering the policy matrix, storage/migration idempotence, retention, the privacy reader, the fixture scanner and a filesystem-backed end-to-end attribution test.

## Explicitly out of scope / not verified

- No cloud account, network service, root daemon, HTTP/WebSocket surface, or automatic deletion.
- No real process-level tracer is shipped; `fs_usage`/Endpoint Security are **not** presented as production-safe. Deep trace is marked `NOT SHIPPABLE`.
- The upstream Radix scanner is **not** wired in (see G1 below). The default backend is a dependency-free fixture scanner.

## Architecture (one agent, one app, one SQLite, one scanner)

```
                +---------------------+        +--------------------------+
                |  disktrace-agent    |        |  DiskTrace app (read-    |
                |  MonitorCoordinator |        |  only SwiftUI/Charts)    |
                +----------+----------+        +------------+-------------+
                           |                                |
   VolumeSampler --+       |                                |
   ChangeMonitor --+--> DiskTraceStore (SQLite, WAL, single writer)
   ScannerBackend -+       |                                |
   CodexSessionReader --+  |                                |
                           v                                v
                     observations/evidence/alerts   read-only snapshots
```

- **Agent** (`Sources/DiskTraceAgent`): volume sampling (default 60 s), bounded FSEvents change coalescing, periodic recalibration, attribution, alert decisions, retention.
- **Core** (`Sources/DiskTraceCore`): models, policy, storage, monitoring, scanner adapters, Codex reader, IPC contract.
- **App** (`Sources/DiskTraceApp`): read-only timeline/growth/health/settings.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the ADRs and the data model.

## Build and run

Requires **macOS 14+** and a **Swift 6.2** toolchain. Upstream Radix needs Xcode 26; DiskTrace core does **not** — it builds with the Command Line Tools SDK (see the toolchain note in `scripts/toolchain-env.sh`).

```bash
swift build          # builds DiskTraceCore, disktrace-agent, DiskTraceApp
swift test           # 36 tests
swift run disktrace-agent --once --db /tmp/dt.sqlite --root ~/Documents
```

The agent entry point accepts `--db <path>`, `--root <path>` (repeatable), `--exclude <path>` (repeatable), `--interval <seconds>` and `--once`.

## Technical gates (summary)

| Gate | Result | Note |
|---|---|---|
| G1 RadixCore no-UI use | **FAIL (direct) / PASS (patched)** | No `public` API; requires macOS 26 SDK. Builds headless after 4 small patches. |
| G2 memory release | **NOT RUN** | RSS not yet measured; low-memory isolation is designed but unbuilt. |
| G3 FSEvents incremental correctness | **FAIL (Radix path) / PASS (our full-recalibration path)** | Radix history replay returned 0 events here; our live monitor + delta calibration verified by test. |
| G4 Codex client coverage | **NOT RUN** | Reader implemented + unit-tested against fixtures; no real client install here. |
| G5 shippable process tracer | **BLOCKED / NOT SHIPPABLE** | No distributable entitlement path verified. Not faked. |
| G6 silence-rule accuracy | **PARTIAL** | Policy matrix unit-tested; no real-world false-positive measurement. |
| G7 install/upgrade | **BLOCKED** | Requires signing/notarization/Xcode. |

Details and raw evidence: [`docs/TECHNICAL_GATES.md`](docs/TECHNICAL_GATES.md), [`docs/REUSE_AUDIT.md`](docs/REUSE_AUDIT.md), `artifacts/evidence/`.

## Privacy

DiskTrace does not read file contents, does not collect prompts, commands, source or secrets, and does not upload monitoring metadata. The Codex reader stores only a hashed session id, a time window, an optional (optionally hashed) working directory and a client kind. See [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md).

## License

MIT — see [`LICENSE`](LICENSE). Third-party reuse and its exact upstream commits are recorded in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
