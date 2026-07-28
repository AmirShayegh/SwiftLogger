<p align="center">
  <img src="extra/banner.png" alt="SwiftLogger" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9+-F05138?style=flat&logo=swift&logoColor=white" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/Platforms-iOS%2015+%20|%20macOS%2012+-333333?style=flat" alt="Platforms">
  <img src="https://img.shields.io/badge/SPM-Compatible-4FC08D?style=flat" alt="SPM Compatible">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=flat" alt="License">
</p>

<br>

## Install

```swift
.package(url: "https://github.com/AmirShayegh/SwiftLogger.git", from: "2.1.0")
```

```swift
.target(name: "MyApp", dependencies: ["Logger"])
```

## Usage

```swift
import Logger

Log("app launched")
Log("cache miss", level: .warning)

logDebug("request sent")
logError("connection failed")
```

Message expressions are `@autoclosure` -- interpolations and other message work are not evaluated when the level is filtered out.

## Configuration

All configuration methods return `self` for chaining:

```swift
Log.minimumLevel(.info)
   .consoleLogging(true)
   .fileLogging(true)
   .installExceptionHandler()
```

| Method | Default | Description |
|---|---|---|
| `minimumLevel(_:)` | `.debug` | Messages below this level are discarded |
| `consoleLogging(_:)` | `true` | Toggle `print()` output |
| `fileLogging(_:)` | `false` | Toggle file output to `Library/Logs/app.log`. Check `isFileLoggingActive` to verify. |
| `fileLogging(url:label:minimumLevel:rotation:)` | -- | File logging to a custom URL with optional rotation |
| `logLevel(_:forFile:)` | -- | Override level for a specific source file |
| `highlight(_:)` | -- | Prefix output from a file with `>>>` |
| `installExceptionHandler()` | off | Log uncaught `NSException`s. **Not a crash reporter** — use Crashlytics or Sentry for signal-based crashes (SIGSEGV, SIGABRT, etc.). |

## Levels

`verbose` < `debug` < `info` < `warning` < `error` < `todo`

Messages below the effective minimum are discarded.

## Subsystems

Dot-separated hierarchy. A parent level applies to all children unless overridden.

```swift
Log.subsystem("network", level: .info)
   .subsystem("network.api", level: .debug)

Log("request sent", subsystem: "network.socket")   // inherits .info from "network"
Log("parsed body", level: .debug, subsystem: "network.api")  // uses own .debug
```

Resolution order: exact subsystem match > parent subsystem > per-file override > global minimum.

## Scoped Loggers

Tag concurrent work with correlation IDs.

```swift
let job = Log.scoped(correlation: "job-\(id)", subsystem: "sync")
job.info("started")
job.debug("record processed", metadata: ["count": 42])
```

Scoped loggers are `Sendable` value types with convenience methods for each level. They nest -- a child inherits the parent's subsystem unless overridden.

```swift
let pipeline = Log.scoped(correlation: "pipeline-1", subsystem: "pipeline")
let decode   = pipeline.scoped(correlation: "decode-1")              // keeps "pipeline"
let io       = pipeline.scoped(correlation: "io-1", subsystem: "io") // overrides to "io"
```

## Metadata

Type-safe key-value pairs via `LogValue`. Supports string, integer, float, and boolean literals directly.

```swift
Log("request done", metadata: ["status": 200, "cached": false, "ms": 142.5, "path": "/home"])
```

Metadata keys are sorted alphabetically in the output.

## Custom Destinations

Implement the `LogDestination` protocol to send logs anywhere -- a database, a network service, or an analytics pipeline.

```swift
final class MyDestination: LogDestination, @unchecked Sendable {
    let label = "my-dest"
    var isEnabled: Bool { true }
    var minimumLevel: LogLevel? { .warning }

    func write(_ entry: LogEntry) {
        // entry.level, entry.message, entry.metadata, entry.subsystem, etc.
    }
}
```

Register and remove destinations by label:

```swift
Log.addDestination(MyDestination())
Log.removeDestination(label: "my-dest")
```

`addDestination` replaces any existing destination with the same label. Destinations must be `Sendable` and handle their own synchronization -- `write()` and `flush()` may be called concurrently from arbitrary threads.

### Per-Destination Level Filtering

Each destination can declare a `minimumLevel`. Messages that pass the global gate but fall below a destination's minimum are skipped for that destination.

```swift
let console = ConsoleDestination(minimumLevel: .debug)
let file = FileDestination(url: logURL, minimumLevel: .warning)!

Log.addDestination(console)
   .addDestination(file)

Log("verbose detail", level: .debug)   // console only
Log("disk-worthy warning", level: .warning) // both
```

### Built-in Destinations

| Destination | Label | Description |
|---|---|---|
| `ConsoleDestination` | `"console"` | `print()` output + optional test sink. Always present by default. |
| `FileDestination` | `"file"` | Persistent `FileHandle` with async writes on a serial queue. |
| `OSLogDestination` | `"oslog"` | Apple's unified logging via modern `os.Logger` API. |

## File Logging

Basic file logging to `Library/Logs/app.log`:

```swift
Log.fileLogging(true)
```

File logging to a custom URL with rotation:

```swift
let logURL = documentsDir.appendingPathComponent("myapp.log")
Log.fileLogging(
    url: logURL,
    rotation: FileRotationConfig(maxFileSize: 5_000_000, maxArchivedFilesCount: 3)
)
```

`maxFileSize` is a soft post-write threshold -- a file may exceed it by up to one batch (see below). Archives are named with a UTC timestamp and short UUID (e.g. `myapp.log.20250515T121530Z_a1b2c3d4`) and pruned to `maxArchivedFilesCount`. Set `maxArchivedFilesCount` to `0` to retain no archives.

The file handle is kept open for the lifetime of the destination -- no open/close overhead per write.

### Buffering and backpressure

Entries are buffered and written in batches -- one `write` syscall per batch instead of one per entry. A batch is written when it reaches 4 KB or after 100 ms, whichever comes first. With rotation configured the size trigger is clamped to `maxFileSize`, so the file cannot overshoot by more than a batch.

The buffer holds at most 1000 entries. Past that, **new entries are dropped** rather than blocking the caller -- logging never stalls your app because the disk is slow. Dropped entries are counted, and the count is written to the log as a warning once the buffer drains:

```
 WARN | 12:15:30.842 | FileDestination.swift:0 | [Logger] dropped 42 messages — write buffer full
```

Call `Log.flush()` to drain the buffer synchronously; it is also drained when the destination is deallocated, so entries are not lost when you swap destinations out. At process exit, call `flush()` from `applicationWillTerminate` or an `atexit` handler.

## OSLog

Route logs to Apple's unified logging system alongside your custom destinations.

```swift
Log.osLogDestination(subsystem: Bundle.main.bundleIdentifier!, category: "networking")
```

Or add directly:

```swift
Log.addDestination(OSLogDestination(subsystem: "com.myapp", category: "sync", minimumLevel: .info))
```

Level mapping: verbose/debug -> `.debug`, info -> `.info`, warning -> `.default`, error -> `.error`, todo -> `.fault`. All content is logged with public privacy. Available on Apple platforms only.

## swift-log Integration

SwiftLogger includes a `LogHandler` for Apple's [swift-log](https://github.com/apple/swift-log) ecosystem. Messages from swift-log are routed through the full destination pipeline with subsystem filtering -- the swift-log `label` becomes the subsystem.

```swift
import Logging
import Logger

LoggingSystem.bootstrap { label in
    SwiftLogHandler(label: label)
}

// Now any swift-log Logger routes through SwiftLogger's destinations
let logger = Logger(label: "com.myapp.network")
logger.info("request sent")
```

Level mapping: trace -> verbose, debug -> debug, info -> info, notice -> info, warning -> warning, error -> error, critical -> error. Metadata is bridged to `LogMetadata` with all values converted to strings — dictionary values are sorted by key for deterministic output, array values keep their original order.

## Thread Safety

All logger state is lock-protected. Each destination manages its own synchronization. `ScopedLogger` is a `Sendable` value type. File writes are serialized on a dedicated dispatch queue. `DateFormatter` instances are thread-local to avoid contention.

Custom destinations must be `Sendable`. `write()` and `flush()` may be called concurrently from arbitrary threads.

## License

MIT
