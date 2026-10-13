# Third-Party Notices

DiskTrace is an independent MIT project. It is **not** a fork of any upstream.
This file records the upstream projects reviewed for reuse, their exact commits,
licenses and what (if anything) was copied. No third-party source is currently
vendored into this repository; the one intended reuse path (RadixCore) is gated
by [`docs/REUSE_AUDIT.md`](docs/REUSE_AUDIT.md).

## Reviewed for reuse

### Radix — `colinvkim/Radix` — MIT
- Commit inspected: `df1235bfb05acb7a678718166491bcc27817d95d`
- License: MIT, Copyright (c) 2026 Colin Kim.
- Intended use: scanning, incremental rescan, snapshot/tree models, APFS
  accounting and depth visualization (`SunburstGeometry`, `TreemapGeometry`).
- Status: **not vendored.** Gate G1 found RadixCore exposes no `public` API and
  requires the macOS 26 / Xcode 26 SDK. If it is later vendored or adapted, MIT
  requires preserving the copyright notice and documenting changed files here.

### OpenDisk — `137137137/OpenDisk` — MIT
- Commit inspected: `f7551cf21a5c35a963c607401ba5705ec0869b64`
- License: MIT, Copyright (c) 2026 137137137.
- Intended use: **benchmark / alternative backend only** (ADR-02). Not integrated,
  not copied. No second scanner is built.

### agentflash — `sjzasada/agentflash` — MIT
- Commit inspected: `d8c905b2787c218ec43c077b2a01974136171731`
- License: MIT, Copyright (c) 2026 Stefan Zasada.
- Intended use: **concept reference only** for agent event/Hook association and
  idempotent config merge. No Go runtime, HTTP, WebSocket or browser UI is
  adopted. Not copied.

## System components

- **SQLite**: used through the macOS system `SQLite3` module (public domain).
- **Swift Testing / Swift Charts / SwiftUI / FSEvents / CryptoKit**: Apple
  platform frameworks included with the toolchain and OS; not redistributed.
