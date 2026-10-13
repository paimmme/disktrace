# Architecture

DiskTrace keeps a **minimal deployment shape**: one user-level Agent, one
SwiftUI App, one SQLite database, one scanner backend, and a few on-demand
adapters. There is no root daemon, no HTTP/WebSocket service, no separate
investigation engine, and no long-term full-file-tree storage.

## Module map

```
Sources/DiskTraceCore/
  Models/      Observation, Evidence, AlertDecision, CoverageGap, UserRule,
               AgentActivity, ScanResult, FilePaths (canonicalization), Time
  Policy/      AlertPolicy (pure function) + PolicyVersion
  Storage/     SQLite wrapper, Migrations, DiskTraceStore (actor), RetentionPolicy
  Monitor/     VolumeSampler, ChangeMonitor (FSEvents), MonitorCoordinator (actor)
  Scanner/     ScannerBackend protocol, FixtureScanner, RadixScannerBackend (gated)
  Codex/       CodexSessionReader (read-only), AgentActivityIndex
  IPC/         versioned IPCRequest/IPCResponse contract
Sources/DiskTraceAgent/   disktrace-agent entry point
Sources/DiskTraceApp/     read-only SwiftUI app
```

## Data model (fact vs inference)

| Type | Meaning |
|---|---|
| `VolumeSample` | `(volumeID, observedAt, freeBytes, capacityBytes, status)` — volume time-series fact. |
| `DirectoryDelta` | windowed net allocated change for a normalized path, with `CalibrationStatus` (independent of attribution). |
| `ChangeHint` | a bounded, coalesced FSEvents clue: *a path changed* — never who or how many bytes. |
| `SessionSyncState` | per-session-log cursor: file identity, byte offset, size, last processed. |
| `Evidence` | `(subject, source, scope, strength, identity, limitation)` — attribution support. |
| `AlertDecision` | `(ruleVersion, subject, action, reason, evidenceClass, evidenceIDs, cooldownKey, evaluatedAt)`. |
| `CoverageGap` | an interval that could not be fully observed, with cause and severity. |

Free-space reduction, monitored-directory net growth and write I/O bytes are
**distinct** metrics and are never reconciled into one number. APFS clones,
hard links, snapshots and purgeable space mean the numbers will not always add
up — DiskTrace reports the difference rather than forcing a total.

## Decision flow

`MonitorCoordinator.runOnce()`:

1. **Volume sampling** (never blocked by attribution).
2. **Drain changes**; an overflow becomes a `CoverageGap(.fseventsOverflow)` and forces recalibration of every root.
3. **Incremental session sync** (`AgentActivitySync`): reads only the appended bytes of each Codex session log, upserts activities under a stable id, and commits activities + cursors + gaps in one transaction — before attribution.
4. **Per-root recalibration**: each root has its own baseline and calibration clock. If either the previous or the current scan is incomplete, **no** trusted delta is produced; a gap is recorded and the last complete baseline is kept so recovery diffs against it.
5. **Retention**: history pruning and space reclamation run as separate steps.

## Alert policy (pure function)

`AlertDecision = evaluate(StorageObservation, Evidence[], UserRules, PolicyVersion)`

- **Confirmed** agent alert requires a verified process operation *and* an agent task event; path-scoped agent task events alone are **probable**.
- **Time overlap only** is `unknown` and silent.
- Directory-name/cache hints alone are `unknown`.
- Finder/browser hints are `userProbable` and silent.
- Matching user rules (`silenceSource`/`confirmUser`) suppress and classify as `userConfirmed`.
- Growth below threshold, active cooldown, or uncertain calibration are silent.
- **Low space is a separate neutral safety alert**, independent of cause.
- The policy decides notification only; it never deletes observation history.

## Attribution inputs

- A session log is parsed by a **structure-aware, whitelist** JSON scanner: it
  reads only named keys from the top level and, for recognised event types, from
  a `payload` object — never from message/command bodies, and never by searching
  a whole line for key names. Only hashed session/task ids, a time window, an
  optional (optionally hashed) working directory and a client kind are stored.
- An activity window comes from explicit task start **and** end events. An
  open-ended window (which may include idle time) lowers evidence strength and
  cannot by itself reach `agent_probable`.

## ADRs (as implemented)

- **ADR-01** Independent MIT project, not a fork. Reuse `RadixCore` first, minimal vendor/adapt otherwise. *(G1: direct reuse blocked — see REUSE_AUDIT.)*
- **ADR-02** One scanner backend. OpenDisk is benchmark/alternative only.
- **ADR-03** One user-level Agent + one SwiftUI App + one SQLite store; no root daemon, Go service or HTTP server.
- **ADR-04** FSEvents = change clue; directory scan = capacity calibration; task Hook = relevance evidence. Not interchangeable.
- **ADR-05** Notification policy is separate from monitoring facts; unknown/expected activity is silent; low space is independent.
- **ADR-06** Deep trace is on-demand and time-limited; `fs_usage` is not a production guarantee.
- **ADR-07** Depth views load on demand; aggregates live in SQLite; the Agent never holds a full-disk tree.
- **ADR-08** Prefer SMAppService, SQLite, Swift Charts and a mature updater over bespoke system code. *(SMAppService registration and the updater are not yet built.)*
- **ADR-09** Engineering Complete ≠ Release Ready; unverified process attribution and hardware/permission capabilities are never presented as passing.
