# Watcher

A Swift package for monitoring folders and files on Apple platforms. Wraps
`FSEventStream` (folder watching, macOS) and `DispatchSource` (single-file
watching, all Apple platforms) behind a single `Session` actor that exposes
events as an `AsyncThrowingStream`.

No raw pointers, no `Unmanaged`, no `FSEventStream*` types in the public API —
only `URL`, `Duration`, Swift enums, and `Sendable` values. Compiles clean
under Swift 6 strict concurrency.

## Requirements

- Swift 6.3+
- macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, visionOS 2+

Folder watching is macOS-only (FSEventStream is unavailable on the other Apple
platforms). Single-file watching works everywhere.

## Installation

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/brennanMKE/Watcher.git", branch: "main"),
```

…and depend on the `Watcher` product from any target.

## Usage

```swift
import Watcher

var options = Watcher.Options()
options.throttle = .milliseconds(200)

#if os(macOS)
options.scope = .all
options.depth = .infinite
#endif

let session = try await Watcher.Session(path: folderURL, options: options)

do {
    for try await event in session.events {
        switch event {
        case .fileAdded(let url):         print("+ \(url.path)")
        case .fileDeleted(let url):       print("- \(url.path)")
        case .fileChanged(let url):       print("~ \(url.path)")
        case .refreshRequired(let scope): rescan(under: scope)
        }
    }
    // Reached: clean termination — Session was released or stop()'d,
    // or a single-file session's file was deleted.
} catch let error as WatcherError {
    // Reached: OS-initiated teardown — folder root deleted or renamed.
    print("watcher torn down: \(error)")
}
```

The `Session` reference is the lifetime token. Drop it (or call
`await session.stop()`) and the stream finishes.

## Public API

`Session`, `Event`, and `Options` are nested under the `Watcher` namespace; refer to them as `Watcher.Session`, `Watcher.Event`, and `Watcher.Options`. `WatcherError` stays top-level.

| Type                | Purpose                                                          |
| ------------------- | ---------------------------------------------------------------- |
| `Watcher`           | Namespace. Holds the public types plus `logSubsystem`.           |
| `Watcher.Session`   | Public actor. Owns the watcher; exposes `events` AsyncStream.    |
| `Watcher.Event`     | `Sendable`, `Hashable` enum: `.fileAdded`, `.fileDeleted`, `.fileChanged`, `.refreshRequired(scope:)`. |
| `Watcher.Options`   | Throttle window (all platforms); `scope`, `depth`, `latency` (macOS). |
| `WatcherError`      | Construction and runtime errors thrown by `init`/`events`.       |

### Options

- **`throttle`** — Trailing throttle window over the event stream. Bursts
  coalesce; sustained load delivers at most one batch per window. Clamped
  internally to `[150 ms, 5 s]`. Default 150 ms. Available on every
  Apple platform.
- **`scope`** *(macOS)* — `.fileAddedOrDeleted`, `.fileChanged`, or `.all`.
  Default `.all`.
- **`depth`** *(macOS)* — `.immediate`, `.levels(N)`, or `.infinite`.
  Post-filter on path components. Default `.infinite`.
- **`latency`** *(macOS)* — Hint forwarded to FSEventStream. Default 200 ms.

### Termination

- **Clean finish** — Session released, `stop()` called, or a single-file
  session's file was deleted.
- **Throws `WatcherError.rootInvalidated(URL)`** — folder root deleted or
  renamed, or single-file root renamed.

## Logging

All package logging routes through `os.Logger`. Default subsystem is the
host bundle identifier; override before constructing any `Session`:

```swift
Watcher.logSubsystem = "com.example.MyApp.fswatch"
```

Categories: `Session`, `Core.Folder`, `Core.File`. Path interpolations are
`privacy: .private`; flags, IDs, and counts are `.public`.

## Design

Two documents capture the design baseline. They live at the repo root:

- **[PRD.md](PRD.md)** — public API contract, platform matrix, lifecycle,
  open questions.
- **[Concepts.md](Concepts.md)** — FSEventStream and DispatchSource mental
  models; what makes the C-bridge tricky and how this package handles it.

## License

[MIT](LICENSE)
