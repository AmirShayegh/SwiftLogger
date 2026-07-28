import Testing
import Foundation
@testable import Logger

/// Records handler invocations for the tests below.
///
/// A `@convention(c)` function cannot capture context, so the planted handler
/// has to reach a file-scope object rather than a local. One shared instance,
/// reset by each test that uses it — the suite is `.serialized`.
final class HandlerProbe: @unchecked Sendable {
    static let shared = HandlerProbe()
    private let lock = NSLock()
    private var _hits = 0
    private var _reasons: [String] = []

    var hits: Int { lock.withLock { _hits } }
    var reasons: [String] { lock.withLock { _reasons } }

    func record(_ exception: NSException) {
        lock.withLock {
            _hits += 1
            _reasons.append(exception.reason ?? "")
        }
    }

    func clear() {
        lock.withLock {
            _hits = 0
            _reasons = []
        }
    }
}

/// Stands in for a crash reporter that was already installed when the app
/// adopted this logger. Must run exactly once per forwarded exception.
private func plantedPreviousHandler(_ exception: NSException) {
    HandlerProbe.shared.record(exception)
}

/// C function pointers are not `Equatable`, so identity comparisons go through
/// the raw address.
private func address(_ handler: (@convention(c) (NSException) -> Void)?) -> UnsafeRawPointer? {
    handler.map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
}

extension AllLoggerTests {

    /// The uncaught-exception handler is process-global state, so every test
    /// here saves and restores whatever the test host had installed.
    struct ExceptionHandlerTests {

        init() {
            Logger.shared.reset()
            HandlerProbe.shared.clear()
        }

        /// Runs `body` with the process handler saved and restored, so a test
        /// cannot leak a handler into the rest of the run.
        private func withProcessHandlerRestored(_ body: () throws -> Void) rethrows {
            let saved = NSGetUncaughtExceptionHandler()
            defer { NSSetUncaughtExceptionHandler(saved) }
            try body()
        }

        @Test func exceptionHandlerWritesCrashLogAndChainsToPreviousHandler() throws {
            try withProcessHandlerRestored {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("logger-crash-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let url = dir.appendingPathComponent("crash.log")

                // Planted *before* the install, so this is what the logger picks
                // up as its previous handler.
                NSSetUncaughtExceptionHandler(plantedPreviousHandler)

                // Capture the trampoline instead of letting it become the real
                // process handler: invoking it directly is the whole point, and
                // an installed one would also fire on any genuine crash later in
                // the run.
                nonisolated(unsafe) var trampoline: (@convention(c) (NSException) -> Void)?
                Logger.shared.exceptionHandlerRegistrar = { trampoline = $0 }

                Logger.shared.consoleLogging(false)
                // handleException writes through the default "file" label.
                Logger.shared.fileLogging(url: url, label: "file")
                Logger.shared.installExceptionHandler()

                let handler = try #require(trampoline)

                // Buffered, not yet on disk — the crash text must land after it.
                Logger.shared.log("last thing before the crash", level: .info)

                let exception = NSException(
                    name: .genericException,
                    reason: "deliberate test exception",
                    userInfo: nil
                )
                handler(exception)

                // forceSave runs through queue.sync, so no polling is needed:
                // everything is on disk by the time the handler returns.
                let content = try String(contentsOf: url, encoding: .utf8)
                let marker = try #require(content.range(of: "last thing before the crash"))
                let crash = try #require(content.range(of: "deliberate test exception"))
                #expect(marker.lowerBound < crash.lowerBound)
                #expect(content.contains("Stack Trace:"))

                // Chained exactly once — not zero (swallowed) and not twice.
                #expect(HandlerProbe.shared.hits == 1)
                #expect(HandlerProbe.shared.reasons == ["deliberate test exception"])
            }
        }

        @Test func resetReRegistersThePreInstallHandler() {
            withProcessHandlerRestored {
                NSSetUncaughtExceptionHandler(plantedPreviousHandler)

                nonisolated(unsafe) var registered: [(@convention(c) (NSException) -> Void)?] = []
                Logger.shared.exceptionHandlerRegistrar = { registered.append($0) }

                Logger.shared.installExceptionHandler()
                #expect(registered.count == 1)

                Logger.shared.reset()

                // Restored through the registrar that installed, so the fake one
                // above sees the restore and the real process handler — which
                // this registrar never touched — is left alone.
                #expect(registered.count == 2)
                #expect(address(registered.last!) == address(plantedPreviousHandler))
                #expect(address(NSGetUncaughtExceptionHandler()) == address(plantedPreviousHandler))
            }
        }

        @Test func resetRestoresTheAbsenceOfAHandler() {
            withProcessHandlerRestored {
                NSSetUncaughtExceptionHandler(nil)

                nonisolated(unsafe) var registered: [(@convention(c) (NSException) -> Void)?] = []
                nonisolated(unsafe) var registrationCount = 0
                Logger.shared.exceptionHandlerRegistrar = {
                    registered.append($0)
                    registrationCount += 1
                }

                Logger.shared.installExceptionHandler()
                Logger.shared.reset()

                // "No handler before" is a state that has to be restorable too,
                // which is why the registrar takes an optional.
                #expect(registrationCount == 2)
                #expect(address(registered.last!) == nil)
            }
        }

        @Test func resetWithoutInstallDoesNotTouchTheRegistrar() {
            withProcessHandlerRestored {
                nonisolated(unsafe) var registrationCount = 0
                Logger.shared.exceptionHandlerRegistrar = { _ in registrationCount += 1 }

                Logger.shared.reset()
                #expect(registrationCount == 0)

                // And a second reset after an install is a no-op as well: the
                // first cleared the flag.
                Logger.shared.exceptionHandlerRegistrar = { _ in registrationCount += 1 }
                Logger.shared.installExceptionHandler()
                Logger.shared.reset()
                let afterFirstReset = registrationCount
                Logger.shared.reset()
                #expect(registrationCount == afterFirstReset)
            }
        }

        @Test func reinstallAfterResetDoesNotChainToItself() throws {
            try withProcessHandlerRestored {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("logger-crash-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }

                NSSetUncaughtExceptionHandler(plantedPreviousHandler)

                // The real registrar, deliberately: the bug is that install →
                // reset → install reads the *trampoline* as its previous handler
                // when reset failed to restore, and only the real registrar
                // reproduces that. NSGetUncaughtExceptionHandler is what the
                // second install reads.
                Logger.shared.installExceptionHandler()
                Logger.shared.reset()

                nonisolated(unsafe) var trampoline: (@convention(c) (NSException) -> Void)?
                Logger.shared.exceptionHandlerRegistrar = { trampoline = $0 }
                Logger.shared.consoleLogging(false)
                Logger.shared.fileLogging(url: dir.appendingPathComponent("crash.log"), label: "file")
                Logger.shared.installExceptionHandler()

                let handler = try #require(trampoline)
                handler(NSException(name: .genericException, reason: "second install", userInfo: nil))

                // One hit means the chain terminates at the planted handler.
                // Pre-fix this recurses until the stack is exhausted, so simply
                // returning is most of the assertion.
                #expect(HandlerProbe.shared.hits == 1)
            }
        }

        @Test func exceptionHandlerUsesRegistrarAndIsIdempotent() {
            withProcessHandlerRestored {
                nonisolated(unsafe) var registrationCount = 0
                Logger.shared.exceptionHandlerRegistrar = { _ in registrationCount += 1 }

                #expect(!Logger.shared.isExceptionHandlerInstalled)
                Logger.shared.installExceptionHandler()
                #expect(Logger.shared.isExceptionHandlerInstalled)
                Logger.shared.installExceptionHandler()
                #expect(registrationCount == 1)
            }
        }
    }
}
