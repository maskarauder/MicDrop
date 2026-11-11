import Foundation

/// A value guarded by an `NSLock`.
///
/// MicDropKit is built and tested on Linux, where `OSAllocatedUnfairLock` does not exist (port-rules "Naming and access
/// control"). Every portable type that needs mutual exclusion uses this wrapper. The lock is not recursive: never call
/// back into the same `Locked` from inside `withLock`.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    public init(_ value: Value) {
        storage = value
    }

    /// Runs `body` with exclusive access to the stored value.
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }

    /// A snapshot read, or a locked replacement.
    public var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    /// Replaces the value and returns the previous one, atomically.
    @discardableResult
    public func exchange(_ newValue: Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let previous = storage
        storage = newValue
        return previous
    }
}
