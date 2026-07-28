import Foundation

#if canImport(os)
import os
#endif

/// A minimal mutex used for the very short critical sections on the logging hot
/// path (a reference load, a cached-value read).
///
/// On Apple platforms this wraps `os_unfair_lock`, whose uncontended path is a
/// pair of atomic operations — meaningfully cheaper than `NSLock`, which routes
/// through Objective-C message dispatch. It also donates priority to the lock
/// holder, avoiding the priority inversion `NSLock` can cause when a low-priority
/// thread is preempted mid-log.
///
/// The lock lives in an `UnsafeMutablePointer` rather than as a stored property
/// because `os_unfair_lock_lock` takes its argument `inout`; passing a stored
/// property directly can hand the call a temporary copy, which silently breaks
/// mutual exclusion.
internal final class UnfairLock: @unchecked Sendable {
    #if canImport(os)
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    init() {
        pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
    #else
    private let lock = NSLock()

    init() {}

    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    #endif
}
