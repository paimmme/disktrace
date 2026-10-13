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
- `RadixScannerBackend` is a compile-time placeholder that always reports
  unavailable; wiring it requires the vendored+patched upstream described in
  `docs/REUSE_AUDIT.md`.

## Session sync & retention (reviewed behaviours)

- **Event type names are unverified.** The recognised Codex event `type` values
  (session/task start/end) are a configurable default; real client names must be
  confirmed per client (G4). Until then, real task windows may degrade to an
  open, lower-confidence session window.
- **Cross-restart partial line.** The cursor is persisted at a line boundary;
  a trailing partial record is re-read after a restart, so no *complete* record
  is lost, but a record mid-write at crash time is only recovered once complete.
- **Session identity and working directory persist across restarts** (schema v3),
  but **open-task state is in memory only**: if the agent restarts while a task
  is open, its start event was already consumed and is not re-read, so the
  eventual completion still produces an activity but with an approximate window.
- **auto_vacuum only applies to new databases.** An existing database keeps its
  `auto_vacuum` setting; space reclamation then relies on WAL checkpoint and row
  deletion (freelist), not `incremental_vacuum`. A full `VACUUM` is never run
  automatically — converting an old database is a separate, manual maintenance
  step so a low-disk machine is not surprised by a large rewrite.
- **Directory recalibration is periodic full-scan**, not event-driven subtree
  splicing (see G3).
- **`claudeCode`** is modelled in the enum but has no adapter.
