import Foundation

/// Adapter for the upstream Radix scanner.
///
/// **Gate G1 result** (see `docs/REUSE_AUDIT.md`): upstream `RadixCore` exposes
/// no `public` symbols, so it cannot be consumed as an external SwiftPM
/// dependency, and it requires the macOS 26 / Xcode 26 SDK
/// (`O_RESOLVE_BENEATH`). Until an upstream public API exists — or a
/// vendored-and-patched copy is built against that SDK — this backend reports
/// `.unavailable`. The `MonitorCoordinator` reacts by recording a
/// `CoverageGap` and falling back to periodic full recalibration with the
/// fixture backend, rather than fabricating scan data.
public struct RadixScannerBackend: ScannerBackend {
    public init() {}

    public func scan(root: URL, excluding: [String] = []) async throws -> ScanResult {
        throw ScannerUnavailableError(
            reason: """
                RadixCore exposes no public API and requires the macOS 26 SDK \
                (G1 FAIL). See docs/REUSE_AUDIT.md and docs/TECHNICAL_GATES.md.
                """)
    }
}
