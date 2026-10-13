# Technical Gates (G1–G7)

Each gate is reported as `PASS / FAIL / NOT RUN / BLOCKED` with the environment,
what was actually executed, and the evidence. `NOT RUN` is never reported as a
pass.

Environment: macOS 14.6 (23G80), arm64, no Xcode; a Swift 6.2 toolchain paired
with the Command Line Tools `MacOSX15.0.sdk`. (The CLT-default `swift` is 5.10
and its SDK is built with Swift 6.0, so a stock `swift build` cannot compile
Swift 6.2 sources — see `scripts/toolchain-env.sh`.)

---

## G1 — RadixCore in a no-UI macOS target — **FAIL (direct) / PASS (patched)**

- **Direct dependency:** FAIL. `RadixCore` declares **no `public` symbols**
  (verified: zero `public`/`open` in its target sources; all 78 tests use
  `@testable import`). A consumer module sees an empty API.
- **Headless compile of upstream:** PASS *after four patches*. With the Swift 6.2
  toolchain + CLT 15.0 SDK, `swift build` of `colinvkim/Radix@df1235bf`
  succeeds after: an `O_RESOLVE_BENEATH` shim (missing from every CLT SDK),
  `nonisolated` on that shim, `nonisolated struct DiscardPileDragPayload`, and a
  `withContiguousStorageIfAvailable ??` type-inference rewrite. It otherwise
  requires the macOS 26 SDK. The upstream **test target** does not build here.
- **Decision:** reuse is gated. `ScannerBackend` keeps the backend swappable;
  `RadixScannerBackend` reports unavailable and records a `CoverageGap`.
- **Evidence:** `docs/REUSE_AUDIT.md`, `artifacts/evidence/`.

## G2 — Memory release / <50 MB resident — **NOT RUN**

- The Agent never holds a full-disk tree (aggregates only), and the scanner runs
  as a short-lived detached task, but **RSS has not been measured** on either
  the fixture scanner or (if built) a Radix workload. No claim is made.
- Method to run it: `docs/PERFORMANCE.md`.

## G3 — FSEvents incremental correctness — **FAIL (Radix) / PASS (DiskTrace full-recalibration path)**

- **Radix historical replay:** FAIL on this machine. A focused probe over an
  advanced event-id range (`since=31651218 after=31651287`) returned
  `historyEvents=0`; the service chose `incrementalNoChanges` and returned a
  stale snapshot (`alloc=65536` vs full scan `122880`).
- **DiskTrace path:** PASS. `MonitorCoordinator` compares a fresh scan to the
  previous `ScanResult` in canonicalized paths; the end-to-end test
  (`records silent deltas, then alerts when an agent activity overlaps`) adds
  files on disk and verifies the recorded deltas. The live `ChangeMonitor`
  (persistent FSEvents stream) is covered by `capturesWrites` and
  `boundedQueueNeverExceedsCapacity`, both passing.
- **Residual risk:** DiskTrace's directory path uses periodic **full**
  recalibration (not event-driven subtree splicing), which is correct but does
  more I/O than an incremental splice would. An incremental splice is a future
  optimization, gated on a reliable event source.

## G4 — Codex client coverage — **NOT RUN**

- No `codex` or `claude` binary is installed in this environment, so no real
  client was exercised. `CodexSessionReader` is implemented and unit-tested
  against synthetic logs (`docs`/`Tests`), extracting only a whitelist of keys.
- Only **`codexCLI`** is modelled; IDE/Desktop coverage is unverified. `notify`
  is explicitly **not** treated as a universal event bus.

## G5 — Shippable process-level tracer — **BLOCKED / NOT SHIPPABLE**

- No distributable entitlement/authorization path for process-level file
  observation was verified here (Endpoint Security requires entitlements;
  `fs_usage` requires elevated privileges and is high-noise). Per ADR-06 this is
  **not** presented as production-safe and no fabricated PID evidence is
  produced. Q20 (a real process-level trace) is therefore **not** satisfied.

## G6 — Silence-rule accuracy — **PARTIAL**

- The full decision matrix from the PRD §3.3/§3.3 table is implemented as a pure
  function and covered by 12 policy tests (confirmed/probable/overlap-only/
  directory-name/user-probable/rule-suppressed/below-threshold/cooldown/
  calibration/low-space). This proves the **algorithm**, not real-world
  false-positive rates. No browser-download / Finder-copy measurement was run.

## G7 — Install / upgrade / uninstall — **BLOCKED**

- Requires Xcode, an app bundle with `Info.plist`, `SMAppService` registration,
  code signing and notarization, none of which are possible without Xcode 26
  here. Not implemented or claimed.

---

## Summary

| Gate | Result |
|---|---|
| G1 | FAIL (direct) / PASS (patched headless build) |
| G2 | NOT RUN |
| G3 | FAIL (Radix) / PASS (DiskTrace full-recalibration + live monitor) |
| G4 | NOT RUN |
| G5 | BLOCKED — NOT SHIPPABLE |
| G6 | PARTIAL (algorithm verified, real-world rates unmeasured) |
| G7 | BLOCKED |

Because G5 cannot be satisfied and G7 is blocked, this delivery is
**Engineering Complete, Release Not Ready**.
