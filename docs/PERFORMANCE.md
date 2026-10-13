# Performance

**Status: NOT RUN.** No idle-CPU or resident-memory measurement has been made.
The Q12 targets (idle CPU < 0.5 %, agent RSS < 50 MB) are design goals, not
verified results. This file records the intended method so the claim can be
earned later.

## Design intent

- The Agent stores **aggregates** in SQLite and never keeps a full-disk tree in
  memory (ADR-07). Scanning runs as a short-lived detached task; large trees are
  released after a `ScanResult` is folded into `DirectoryDelta`s.
- Directory recalibration is bounded (the coordinator evaluates at most the 200
  largest movers per cycle).
- The FSEvents change queue is bounded (`MonitorConfig.changeCapacity`, default
  512) and coalesces per path; overflow raises a `CoverageGap` rather than
  growing without limit.
- Volume sampling is a cheap `statfs`/`URLResourceValues` call on a 60 s cadence.

## How to measure (to be executed)

1. **Idle CPU/RSS.** Run the agent against a quiet root and sample:
   ```bash
   swift run disktrace-agent --db /tmp/dt.sqlite --root ~/Documents &
   AGENT_PID=$!
   for i in $(seq 1 180); do ps -o rss=,pcpu= -p "$AGENT_PID"; sleep 10; done
   ```
   Report machine model, macOS build, sample window and the aggregation method
   (mean CPU over 30 min; RSS in the `RSS`/physical-footprint sense).
2. **Scan peak RSS.** Measure the agent process while it scans a large tree;
   report peak separately from steady state, and note whether the scan ran in a
   short-lived worker.
3. **Event pressure.** Create 100 k+ small-file changes and record the queue's
   maximum length, any overflow/`CoverageGap`, RSS and recalibration latency.

No numbers are quoted here until these are actually run.
