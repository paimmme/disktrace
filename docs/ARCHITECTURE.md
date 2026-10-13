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
2. **Drain changes**; an overflow becomes a `CoverageGap(.fseventsOverflow)` and forces recalibration.
3. **Recalibration** (periodic or forced): scan, diff against the last `ScanResult`, persist `DirectoryDelta`s, build evidence, evaluate policy, persist `AlertDecision`s.
4. **Retention** (periodic): down-sample old volume samples, delete reconstructable rows, enforce the soft quota.

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
