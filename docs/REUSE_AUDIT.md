# Source Reuse Audit

**Method.** The candidate projects were cloned at their current default-branch
HEAD and their real source, `Package.swift` and licenses were read. The
"tree SHAs" quoted in the v4.0 review are in fact real **commit** IDs: cloning
each repository at HEAD reproduced exactly those SHAs, so the review's revision
pins are valid.

| Repo | Commit (verified) | License | Decision |
|---|---|---|---|
| Radix `colinvkim/Radix` | `df1235bfb05acb7a678718166491bcc27817d95d` | MIT (Colin Kim) | Primary scan/depth source — **gated (see G1)** |
| OpenDisk `137137137/OpenDisk` | `f7551cf21a5c35a963c607401ba5705ec0869b64` | MIT (137137137) | Benchmark / alternative only |
| agentflash `sjzasada/agentflash` | `d8c905b2787c218ec43c077b2a01974136171731` | MIT (Stefan Zasada) | Concept reference only |

Environment used for the audit: macOS 14.6 (build 23G80), arm64, **no Xcode**;
Command Line Tools only (default `swift` 5.10, default SDK `MacOSX15.0.sdk`);
a Swift 6.2 toolchain was extracted locally and paired with the CLT 15.0 SDK.

## Radix — the decisive findings

### 1. `RadixCore` exposes no `public` API

The `RadixCore` library target compiles the curated file list in
`Package.swift`, but **none of those files declares anything `public`** (or
`open`). Verified: zero `public` declarations across `Radix/Services`,
`Radix/Models`, `Radix/ViewModels`; every type is internal, e.g.
`nonisolated final class IncrementalScanService`, `actor ScanEngine`. The 78
test files consume them via `@testable import RadixCore` (72 occurrences).

**Consequence:** `RadixCore` cannot be consumed as an external SwiftPM
dependency — an importing module sees an empty API. Direct reuse (ADR-01's
first option) is **not possible** without either an upstream public-API change
or a vendored, visibility-patched copy.

### 2. Radix requires the Xcode 26 / macOS 26 SDK

A headless `swift build` of upstream Radix against the CLT macOS 15 SDK fails.
Root causes:

- `Radix/Services/ScanDirectoryDescriptorPool.swift` uses `O_RESOLVE_BENEATH`,
  which is **absent from every CLT SDK here** (`MacOSX13.3/14.4/14.5/15.0`); it
  ships only in the macOS 26 SDK.
- Swift 6.2 strict-concurrency interactions with the default
  `.defaultIsolation(MainActor.self)` (e.g. a main-actor-isolated `Transferable`
  conformance; `mach_task_self_` in the test support).

### 3. It *can* be built headless after 4 small patches (evidence)

With the Swift 6.2 toolchain + CLT 15.0 SDK, `swift build` of upstream
`RadixCore` **succeeds** after exactly four changes:

1. a compatibility shim defining `O_RESOLVE_BENEATH` (absent from the CLT SDK);
2. `nonisolated let` on that shim (default-actor isolation);
3. `nonisolated struct DiscardPileDragPayload` (isolated `Transferable`;
   `FileDragController.swift`);
4. rewriting one `withContiguousStorageIfAvailable { … } ?? …` expression whose
   result type inferred to `Bool?` under this SDK (`ScanPathIndex.swift`).

The upstream **test target** does not build here (benchmark support uses
`mach_task_self_` and `Int`/`Int64` literal inference differences), so its
suite could not be run as-is.

## G3 probe against the real Radix incremental path

A focused test was added to the Radix package (its own private test target) that
scans a fixture, captures an FSEvents checkpoint, mutates the tree, and rescans
incrementally versus a fresh full scan. Result on this machine:

```
since=31651218 after=31651287 historyEvents=0
rescan modes: [incrementalNoChanges]
incremental: alloc=65536 files=3 dirs=4
full       : alloc=122880 files=3 dirs=4
```

The OS records events (the global FSEvents id advanced 31651218 → 31651287),
but `DarwinFileSystemEventHistoryProvider.history(for:since:through:)` returned
**zero** events for the target directory. The service therefore chose
`incrementalNoChanges` and returned a **stale** snapshot whose allocated total
diverged from a full scan. This is both a correctness failure on this
environment and a **safety concern**: an empty/uncertain history should force a
full recalibration, not be treated as "no changes".

Contrast: DiskTrace's own **live** `ChangeMonitor` (a persistent FSEvents stream
with file-level flags, not a historical replay) captured writes reliably in the
test suite (`capturesWrites`, `boundedQueue` both pass).

## Conclusion

- Do **not** take a direct dependency on `RadixCore` (no public API).
- The viable reuse path is a **vendored + visibility-patched** copy built with
  the macOS 26 SDK, or an upstream public-API contribution — neither is done here.
- DiskTrace therefore ships a **dependency-free fixture scanner** and a protocol
  (`ScannerBackend`) so the backend is replaceable, plus a
  `RadixScannerBackend` that honestly reports unavailability (recording a
  `CoverageGap`) rather than fabricating scan data.
