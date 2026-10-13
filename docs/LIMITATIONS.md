# Limitations

Honest, current limits. None of these is hidden behind marketing language.

## Not verified / not built

- **No direct RadixCore dependency.** It has no public API and needs the macOS 26
  SDK. DiskTrace ships its own fixture scanner and a gated Radix adapter.
- **No incremental subtree splicing.** Directory recalibration is a periodic
  **full** scan of each monitored root, diffed against the previous result. This
  is correct but does more I/O than an event-driven splice.
- **No real process-level tracer.** Deep trace is `NOT SHIPPABLE`. No PID or
  path-write evidence is produced, and time overlap alone is never upgraded to a
  confirmed attribution.
- **No real Codex client validation.** Only a read-only metadata reader exists,
  tested against synthetic logs; CLI/IDE/Desktop coverage is unverified.
- **No packaging, signing, notarization, `SMAppService` registration, updater,
  or Universal build.** The app target compiles but is not a runnable bundle here.
- **No memory or idle-CPU measurement.** The `<50 MB` / `<0.5 % CPU` targets are
  unmeasured.
- **No sleep/wake or crash-recovery execution.** Coverage-gap recording exists but
  the recovery flow was not exercised on a real machine.

## Design boundaries (deliberate)

- DiskTrace cannot reliably detect "the user personally clicked download". It
  records expected activity and stays silent, and reserves confirmed user
  attribution for explicit feedback/rules. When it cannot attribute a change it
  says `unknown`.
- Free space, monitored-directory net growth and write I/O bytes are different
  metrics; they are not forced to reconcile. APFS clones, hard links, snapshots
  and purgeable space can make them diverge.
- Low-space is a neutral safety alert, never attributed to an agent.
- The policy decides notifications only; it never deletes observation history.

## Known rough edges in this repo

- `DiskTraceApp` compiles but has not been run as a bundle.
- `estimatedDatabaseBytes()` reports SQLite page size; the retention soft quota
  does not yet include the WAL/SHM files themselves (the caller is expected to).
- `RadixScannerBackend` is a compile-time placeholder that always reports
  unavailable; wiring it requires the vendored+patched upstream described in
  `docs/REUSE_AUDIT.md`.
