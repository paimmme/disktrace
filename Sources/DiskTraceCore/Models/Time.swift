import Foundation

/// Injectable time source so policy, monitor and storage logic can be tested
/// deterministically without sleeping.
public protocol TimeSource: Sendable {
    func now() -> Date
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> Date { Date() }
}

/// Manual clock for deterministic tests.
public final class ManualTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 0)) {
        current = start
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    public func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }
}
