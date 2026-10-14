import os

/// A value guarded by a lock: the subset of `Synchronization.Mutex` this package uses, available on
/// macOS 14 (the standard library's `Mutex` needs macOS 15). Don't import `Synchronization` next to it.
public final class Mutex<Value>: @unchecked Sendable {
    // @unchecked: `value` is only touched inside `withLock`, under `lock`.
    private let lock = OSAllocatedUnfairLock()
    private var value: Value

    public init(_ initialValue: Value) {
        value = initialValue
    }

    /// Runs `body` with exclusive access to the value.
    public func withLock<Result, E: Error>(_ body: (inout Value) throws(E) -> Result) throws(E) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
