import CoreServices
import Foundation

/// A durable FSEvents position. Used to reason about coverage across sleep,
/// restart and event overflow.
public struct FSEventCheckpoint: Sendable, Hashable, Codable {
    public let eventID: UInt64
    public init(eventID: UInt64) { self.eventID = eventID }
    public static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }
}

public enum ChangeMonitorError: Error, Sendable {
    case streamCreationFailed
}

/// A live, bounded FSEvents watcher. It coalesces changes per path and keeps a
/// fixed-capacity FIFO; on overflow it raises an `overflowed` flag so the
/// coordinator can record a `CoverageGap` and schedule a full recalibration
/// instead of trusting a lossy event stream.
///
/// This is a hint source only: it proves *a path changed*, never who wrote it
/// or how many bytes.
public final class ChangeMonitor: @unchecked Sendable {
    public struct Output: Sendable {
        public let hints: [ChangeHint]
        public let overflowed: Bool
        public init(hints: [ChangeHint], overflowed: Bool) {
            self.hints = hints
            self.overflowed = overflowed
        }
    }

    private let lock = NSLock()
    private var pending: [String: ChangeHint] = [:]
    private var insertionOrder: [String] = []
    private var overflowed = false
    private var stream: FSEventStreamRef?

    private let roots: [URL]
    private let capacity: Int
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "app.disktrace.fsevents")
    private let timeSource: TimeSource

    public init(
        roots: [URL],
        capacity: Int = 512,
        latency: CFTimeInterval = 0.2,
        timeSource: TimeSource = SystemTimeSource()
    ) {
        self.roots = roots
        self.capacity = max(1, capacity)
        self.latency = max(0, latency)
        self.timeSource = timeSource
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let sinceWhen = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let createFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)
        let paths = roots.map(\.path) as CFArray

        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                ChangeMonitor.eventCallback,
                &context,
                paths,
                sinceWhen,
                latency,
                createFlags)
        else {
            throw ChangeMonitorError.streamCreationFailed
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw ChangeMonitorError.streamCreationFailed
        }
        stream = created
    }

    public func stop() {
        lock.lock()
        let existing = stream
        stream = nil
        lock.unlock()
        guard let existing else { return }
        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)
    }

    /// Returns and clears the coalesced changes collected since the last drain.
    public func drain() -> Output {
        lock.lock()
        defer { lock.unlock() }
        let hints = insertionOrder.compactMap { pending[$0] }
        let wasOverflowed = overflowed
        pending.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
        overflowed = false
        return Output(hints: hints, overflowed: wasOverflowed)
    }

    fileprivate func ingest(eventID: UInt64, path: String, flag: ChangeFlag) {
        lock.lock()
        defer { lock.unlock() }
        let observedAt = timeSource.now()
        if let existing = pending[path] {
            pending[path] = ChangeHint(
                id: existing.id, eventID: eventID, path: path,
                flag: merge(existing.flag, flag), observedAt: observedAt)
            return
        }
        if insertionOrder.count >= capacity {
            let dropped = insertionOrder.removeFirst()
            pending.removeValue(forKey: dropped)
            overflowed = true
        }
        pending[path] = ChangeHint(
            id: UUID(), eventID: eventID, path: path, flag: flag, observedAt: observedAt)
        insertionOrder.append(path)
    }

    private func merge(_ lhs: ChangeFlag, _ rhs: ChangeFlag) -> ChangeFlag {
        if lhs == rhs { return lhs }
        // A path created and then removed within a window is best described as
        // "modified" for hint purposes; otherwise keep the most recent flag.
        return rhs
    }

    private static let eventCallback: FSEventStreamCallback = {
        _, info, numEvents, eventPaths, eventFlags, eventIDs in
        guard let info else { return }
        let monitor = Unmanaged<ChangeMonitor>.fromOpaque(info).takeUnretainedValue()
        let paths = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
        for index in 0..<numEvents {
            let flags = eventFlags[index]
            let eventID = eventIDs[index]
            let path = paths[index].map { String(cString: $0) } ?? ""
            if ChangeMonitor.isOverflow(flags) {
                monitor.markOverflow()
                continue
            }
            monitor.ingest(eventID: eventID, path: path, flag: ChangeMonitor.map(flags))
        }
    }

    private func markOverflow() {
        lock.lock()
        defer { lock.unlock() }
        overflowed = true
    }

    private static func isOverflow(_ flags: FSEventStreamEventFlags) -> Bool {
        let mask =
            kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagEventIdsWrapped
        return flags & FSEventStreamEventFlags(mask) != 0
    }

    private static func map(_ flags: FSEventStreamEventFlags) -> ChangeFlag {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 { return .created }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 { return .removed }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 { return .renamed }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 { return .modified }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemInodeMetaMod) != 0 { return .metadataModified }
        return .unknown
    }
}
