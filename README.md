# Logger

A thread-safe Swift logging library with hierarchical subsystems, scoped correlation IDs, structured metadata, and a fluent configuration API.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/user/Logger.git", from: "1.0.0")
]
```

Then add `"Logger"` to your target's dependencies:

```swift
.target(name: "MyApp", dependencies: ["Logger"])
```

**Platforms:** iOS 15+, macOS 12+
**Swift:** 5.9+

## Quick Start

```swift
import Logger

// Log a message (defaults to .info level)
Log("app launched")

// Log with a specific level
Log("cache miss", level: .warning)

// Global convenience functions
logDebug("request sent")
logError("connection failed")
```

## Configuration

All configuration methods return `self` for chaining and can be called at any time:

```swift
Log.minimumLevel(.info)
   .consoleLogging(true)
   .fileLogging(true)
   .installExceptionHandler()
```

### Options

| Method | Default | Description |
|---|---|---|
| `minimumLevel(_:)` | `.debug` | Global severity threshold. Messages below this level are discarded. |
| `consoleLogging(_:)` | `true` | Toggles `print()` output. |
| `fileLogging(_:)` | `false` | Toggles writing to `Documents/app.log`. The file handle is created lazily. Check `isFileLoggingActive` to verify it opened successfully. |
| `installExceptionHandler()` | off | Installs an `NSUncaughtExceptionHandler` that logs the crash and flushes to the log file. Chains to any previously installed handler. Idempotent. |

## Log Levels

Levels are ordered by severity. The logger discards any message below the effective minimum.

| Level | Emoji | Typical Use |
|---|---|---|
| `.verbose` | `🟣` | Fine-grained tracing (decode loops, packet reads) |
| `.debug` | `🔵` | Development diagnostics |
| `.info` | `🟢` | Normal operational events |
| `.warning` | `⚠️` | Recoverable issues worth attention |
| `.error` | `⛔️` | Failures |
| `.todo` | `🚧` | Marks incomplete work. Highest severity so it always surfaces. |

## Subsystem Hierarchy

Subsystems are logical categories independent of file names. They support dot-separated hierarchy so a parent level applies to all descendants unless overridden:

```swift
Log.subsystem("ffmpeg", level: .info)
   .subsystem("ffmpeg.decoder", level: .debug)

Log("packet read", level: .info, subsystem: "ffmpeg.demuxer")
// "ffmpeg.demuxer" has no explicit level -> walks up to "ffmpeg" -> .info -> passes

Log("frame decoded", level: .debug, subsystem: "ffmpeg.decoder")
// "ffmpeg.decoder" has explicit .debug -> passes

Log("encoding stats", level: .debug, subsystem: "ffmpeg.encoder")
// walks up to "ffmpeg" -> .info -> .debug < .info -> filtered
```

### Level Resolution Order

When a log message is emitted, the effective minimum level is determined by:

1. **Subsystem level** (exact match, then walk up the hierarchy)
2. **Per-file override** (`logLevel(_:forFile:)`)
3. **Global minimum** (`minimumLevel(_:)`)

The first match wins.

## Scoped Loggers

When multiple jobs run concurrently, scoped loggers tag every message with a correlation ID so you can tell them apart:

```swift
let job = Log.scoped(correlation: "job-\(id)", subsystem: "decoder")
job.info("started")
job.debug("keyframe decoded", metadata: ["pts": 42])
job.error("decode failed")
```

Output:

```
🟢 [INFO] [2025-01-15 10:30:45.123] [job-abc123] [decoder] (Pipeline.swift:42) process()
    ┗━▶ started
```

Scoped loggers are `Sendable` value types with no mutable state -- safe to pass across tasks. They provide convenience methods for each level: `.verbose()`, `.debug()`, `.info()`, `.warning()`, `.error()`, `.todo()`.

### Nesting

A child scope inherits the parent's subsystem unless explicitly overridden:

```swift
let pipeline = Log.scoped(correlation: "pipeline-1", subsystem: "pipeline")
let decode   = pipeline.scoped(correlation: "decode-1")              // keeps "pipeline"
let io       = pipeline.scoped(correlation: "io-1", subsystem: "io") // overrides to "io"
```

## Structured Metadata

Attach key-value pairs to any log call. They render as sorted `{key=value}` after the message:

```swift
Log("frame decoded", metadata: ["pts": 42, "size": 1024, "keyframe": true])
```

Output:

```
🟢 [INFO] [2025-01-15 10:30:45.123] (Decoder.swift:88) decode()
    ┗━▶ frame decoded {keyframe=true, pts=42, size=1024}
```

Values use the `LogValue` enum which conforms to Swift literal protocols, so `42`, `3.14`, `true`, and `"text"` all work naturally at the call site. Metadata is `Sendable` and type-safe.

## Per-File Controls

### Level Overrides

Set a specific log level for an individual source file:

```swift
Log.logLevel(.verbose, forFile: "NetworkLayer.swift")
   .logLevel(.error, forFile: "NoisyModule.swift")
```

Reset to fall back to the global minimum:

```swift
Log.resetLogLevel(forFile: "NoisyModule.swift")
```

### Highlighting

Prefix all output from a file with a magnifying glass for visual scanning:

```swift
Log.highlight("AuthManager.swift")
// Output: 🔍 🔵 [DEBUG] [timestamp] (AuthManager.swift:12) ...

Log.removeHighlight("AuthManager.swift")
```

## Exception Handling

The logger can optionally install a process-wide uncaught exception handler:

```swift
Log.installExceptionHandler()
```

This captures the exception name, reason, and stack trace, logs it at `.error` level, flushes to the log file, and then forwards to any previously installed handler.

This is **opt-in** and **idempotent**. For signal-based crash reporting (SIGSEGV, SIGABRT, etc.), use a dedicated crash reporter such as Firebase Crashlytics or Sentry.

## Output Format

```
🔵 [DEBUG] [2025-01-15 10:30:45.123] [correlation] [subsystem] (File.swift:42) function()
    ┗━▶ message {key=value, key=value}
```

Components:
- **Emoji + level** -- color-coded severity
- **Timestamp** -- millisecond precision, `yyyy-MM-dd HH:mm:ss.SSS`
- **Correlation ID** -- present when using scoped loggers (omitted otherwise)
- **Subsystem** -- present when specified (omitted otherwise)
- **Source location** -- file name, line number, function name
- **Message** -- the log message
- **Metadata** -- sorted key-value pairs (omitted when empty)

Highlighted files add a magnifying glass prefix before the emoji.

## API Reference

### Logging

| API | Description |
|---|---|
| `Log("message")` | Log via `callAsFunction` (default level: `.info`) |
| `Log.log("msg", level:subsystem:metadata:correlation:)` | Full-parameter log call |
| `logVerbose("msg")` | Global function at `.verbose` level |
| `logDebug("msg")` | Global function at `.debug` level |
| `logInfo("msg")` | Global function at `.info` level |
| `logWarning("msg")` | Global function at `.warning` level |
| `logError("msg")` | Global function at `.error` level |
| `logTODO("msg")` | Global function at `.todo` level |

All message parameters are `@autoclosure` -- the string is not allocated when the level is filtered out.

All global functions accept optional `subsystem:` and `metadata:` parameters.

### Configuration

| API | Description |
|---|---|
| `Log.minimumLevel(_:)` | Set global minimum level |
| `Log.consoleLogging(_:)` | Toggle console output |
| `Log.fileLogging(_:)` | Toggle file logging |
| `Log.subsystem(_:level:)` | Set subsystem level |
| `Log.resetSubsystem(_:)` | Remove subsystem level |
| `Log.logLevel(_:forFile:)` | Set per-file level |
| `Log.resetLogLevel(forFile:)` | Remove per-file level |
| `Log.highlight(_:)` | Add highlight prefix for a file |
| `Log.removeHighlight(_:)` | Remove highlight |
| `Log.installExceptionHandler()` | Install crash handler |

All configuration methods return `Logger` for chaining.

### Scoped Loggers

| API | Description |
|---|---|
| `Log.scoped(correlation:subsystem:)` | Create a scoped logger |
| `scope.log(_:level:metadata:)` | Log with scope context |
| `scope.verbose/debug/info/warning/error/todo(_:)` | Level-specific convenience |
| `scope.scoped(correlation:subsystem:)` | Create a child scope |

### State Queries

| API | Description |
|---|---|
| `Log.isFileLoggingActive` | `true` if file logging is enabled with a valid file handle |
| `Log.isExceptionHandlerInstalled` | `true` if the exception handler has been installed |

## Thread Safety

All logger state is protected by an internal lock. `Logger` is `@unchecked Sendable` with all mutable fields accessed exclusively under that lock. `ScopedLogger` is a `Sendable` value type with no mutable state. `DateFormatter` instances are thread-local to avoid contention. File writes are serialized on a dedicated dispatch queue.

## License

MIT
