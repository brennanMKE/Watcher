# Watcher — Product Requirements Document

A Swift package for monitoring folders and files on Apple platforms. Wraps the
C-based system APIs (`FSEventStream`, `DispatchSource`) and exposes only
modern, `Sendable`, async/await-friendly Swift types.

> **Status:** Draft. Iterating until approved.

---

## 1. Background and Motivation

Apple platforms expose two file-system-monitoring primitives, both with
C-shaped APIs that are awkward to use directly from modern Swift:

- **FSEventStream** (macOS only) — best for watching a directory tree,
  including in-place modifications to files inside the tree. Reports per-file
  events when configured with `kFSEventStreamCreateFlagFileEvents`.
- **DispatchSource file system object source** (all Apple platforms) — best
  for watching a single file descriptor for inode-level changes (write,
  rename, delete, attribute change).

A reference implementation (`/Users/brennan/Developer/brennanMKE/Issues/Issues/Services/FolderWatcher.swift`)
shows the FSEventStream path working but leaks C-isms: raw pointers,
`Unmanaged`, `FSEventStreamEventFlags` bit math, `@MainActor` callbacks,
`DispatchWorkItem` debouncing. We want to keep that implementation's
correctness while presenting a clean Swift façade.

Existing OSS that informs this design:

- **Witness** — closure-based wrapper around FSEventStream. Simple API,
  but uses `unsafeBitCast`, run-loop scheduling, and pre-Swift-Concurrency
  patterns. Not `Sendable`.
- **FileMonitor** (`aus-der-Technik`) — delegate + `AsyncStream` API,
  cross-platform (macOS + Linux/inotify). Closer to our target shape, but
  its event normalization on macOS uses snapshot-diffing, which is brittle
  for in-place edits.

Watcher should learn from both: an `AsyncStream`-first API like FileMonitor,
the directness of Witness, and the in-place-modification correctness of the
reference `FolderWatcher`.

---

## 2. Goals

- **G1.** A single Swift package, `Watcher`, with a clear public API.
- **G2.** Expose only Swift-native types: `URL`, `String`, `Date`, `Duration`,
  Swift enums, `AsyncSequence`, `Sendable` closures. No `FSEventStream*`,
  `Unmanaged`, raw pointers, or CF types in the public surface.
- **G3.** Support both **folder watching** (recursive tree, in-place
  modifications) and **single-file watching** (point file).
- **G4.** Strict concurrency: every public type is `Sendable`; every callback
  closure is `@Sendable`. Compiles cleanly under Swift 6 strict concurrency.
- **G5.** Primary delivery shape is an `AsyncSequence` exposed as the
  `events` property of a `Session`. No closure/delegate API in v1; both
  can be added later as thin wrappers if asked.
- **G6.** Deterministic, debounced event delivery — bursts coalesce.
- **G7.** Lifecycle is owned by the `Session` reference. Releasing the
  session terminates the sequence; no retain cycle between the session
  and the consumer's iteration.
- **G8.** Useful diagnostics via `os.Logger` under a configurable subsystem.

## 3. Non-Goals (initial release)

- **NG1.** Linux / Windows. `inotify` and `ReadDirectoryChangesW` are out of
  scope; the package is Apple-only. (Revisit later behind `#if os(Linux)`.)
- **NG2.** Cloud / network volume guarantees beyond what the OS provides.
- **NG3.** Content diffing, hashing, or snapshot-based reconciliation. We
  surface events; consumers decide what to do with them.
- **NG4.** A SwiftUI integration layer. (Easy to layer on top later.)
- **NG5.** Persistence of `FSEventStreamEventId` for replay across launches.
  (Add in v2 if requested.)

---

## 4. Target Users

- App developers who need to react to changes in a user-selected folder
  (Issues-style apps, sync clients, hot-reloaders, log tailers).
- Package authors who want a dependency that won't drag CF/raw-pointer
  noise into their codebase.

---

## 5. Platform Support

| Platform   | Folder watch  | Single-file watch | `Options` surface                        |
| ---------- | ------------- | ----------------- | ---------------------------------------- |
| macOS 13+  | FSEventStream | DispatchSource    | full: `throttle`, `scope`, `depth`, `latency` |
| iOS 16+    | unsupported   | DispatchSource    | `throttle` only                          |
| iPadOS 16+ | unsupported   | DispatchSource    | `throttle` only                          |
| tvOS 16+   | unsupported   | DispatchSource    | `throttle` only                          |
| watchOS 9+ | unsupported   | DispatchSource    | `throttle` only                          |
| visionOS 1+| unsupported   | DispatchSource    | `throttle` only                          |

- `Package.swift` declares all Apple platforms.
- macOS-only fields (`scope`, `depth`, `latency`) and the `Scope` /
  `Depth` types are gated behind `#if os(macOS)` and are simply not
  visible to non-macOS code. Cross-platform consumers reference only
  `throttle`; folder-specific configuration must be wrapped in
  `#if os(macOS)`.
- `Session(path:)` is universal at the source level, but at runtime
  on non-macOS platforms it throws
  `WatcherError.unsupportedPlatformFeature("folder watching")` if the
  resolved path is a directory. File paths work everywhere.

---

## 6. Public API

The package exposes a single primary type — `Session` — created with a
path and options. Each session has an `events` property that is an
`AsyncSequence` of `Event` values. Releasing the session terminates the
sequence.

```swift
import Foundation

// MARK: - Event

public enum Event: Sendable, Hashable {
    case fileAdded(URL)
    case fileDeleted(URL)
    case fileChanged(URL)
    /// The kernel signaled it dropped events under this scope — the
    /// consumer should rescan to reconcile. Edge case under heavy
    /// load (e.g. unzipping a large archive into the watched tree);
    /// in normal use this case never fires.
    case refreshRequired(scope: URL)
}

// MARK: - Options

public struct Options: Sendable {
    /// Throttle window. Events accumulate during this window; on
    /// expiry the deduplicated batch is yielded to `events`. A new
    /// window opens on the next incoming event (trailing throttle —
    /// not debounce — so sustained load cannot starve the consumer).
    /// Clamped internally to `[150 ms, 5 s]`. Available on all
    /// Apple platforms.
    public var throttle: Duration = .milliseconds(150)

    #if os(macOS)
    /// What kinds of changes are reported. Combine `.folderChanges`
    /// and `.fileChanges`, or pick one. Default is both.
    /// **macOS-only** — folder watching is unavailable on iOS, tvOS,
    /// watchOS, and visionOS, so this option is compiled out there.
    public var scope: Scope = .all

    /// How deep into the subtree we surface events. Only meaningful
    /// when `path` is a directory; ignored for single-file sessions.
    /// **macOS-only.**
    public var depth: Depth = .infinite

    /// Latency hint forwarded to FSEventStream. **macOS-only.**
    public var latency: Duration = .milliseconds(200)
    #endif

    public init() {}

    #if os(macOS)
    public struct Scope: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Files added or deleted within the watched tree. (Renames
        /// decompose into a delete + an add and are admitted by this
        /// option.)
        public static let fileAddedOrDeleted = Scope(rawValue: 1 << 0)
        /// In-place modifications to existing files within the tree.
        public static let fileChanged        = Scope(rawValue: 1 << 1)

        /// Both kinds. The default; expected to be the common case.
        public static let all: Scope = [.fileAddedOrDeleted, .fileChanged]
    }

    public enum Depth: Sendable, Hashable {
        /// Direct children of the watched path only (depth 0 below root).
        case immediate
        /// Up to N path components below the watched root. `levels(0)`
        /// is equivalent to `.immediate`.
        case levels(Int)
        /// No depth limit — full subtree. (Default.)
        case infinite
    }
    #endif
}

// MARK: - Session

public actor Session {
    /// Async sequence of file-system events.
    ///
    /// - **Finishes cleanly** when the user releases the session or
    ///   calls `stop()`, and when a single-file session's file is
    ///   deleted (the deletion is emitted as `.fileDeleted` first).
    /// - **Throws `WatcherError.rootInvalidated(URL)`** when the OS
    ///   tears down the watcher externally — folder root deleted or
    ///   renamed, or a single-file root renamed to a new path.
    ///
    /// **Single-consumer.** `AsyncThrowingStream` is a single-iterator
    /// sequence; concurrent iteration from two tasks splits events
    /// between them rather than broadcasting. Callers needing fan-out
    /// should create a separate `Session` per consumer (cheap — each
    /// owns its own FSEventStream / DispatchSource), or multicast in
    /// their own code.
    nonisolated public let events: AsyncThrowingStream<Event, Error>

    /// The canonical, symlink-resolved URL the session is watching.
    /// Computed at init via `realpath(3)`; all emitted event URLs are
    /// rooted at this path.
    nonisolated public let canonicalRoot: URL

    /// Watch a folder or a single file.
    ///
    /// **Async.** Init does file I/O (`realpath(3)`, security-scope
    /// negotiation, FSEventStreamCreate/Start) and is `async` so it
    /// won't block the calling thread on slow volumes or extension
    /// proxies. Construction takes microseconds on a healthy local
    /// volume but can block on sleeping disks or NFS.
    ///
    /// The supplied `path` is canonicalized via `realpath(3)` at
    /// construction. Throws:
    /// - `WatcherError.pathNotFound` if the path does not exist.
    /// - `WatcherError.notReadable` for any other `realpath` failure
    ///   (e.g. `EACCES`); the underlying `POSIXError` is attached.
    /// - `WatcherError.streamCreationFailed` / `.streamStartFailed`
    ///   if the OS rejects the watcher.
    ///
    /// **Security-scoped resources.** Session takes ownership of the
    /// security scope for the supplied `path`. At init it calls
    /// `startAccessingSecurityScopedResource()`; on `stop()` / `deinit`
    /// (and on init failure) it calls
    /// `stopAccessingSecurityScopedResource()`. Callers do **not** need
    /// to balance these calls themselves; the bookmark must remain
    /// valid (i.e. resolved from a stored bookmark via
    /// `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`),
    /// but Session manages its own start/stop pairing.
    public init(path: URL, options: Options = .init()) async throws

    /// Stop watching and finish the `events` sequence. Idempotent and
    /// safe to call from multiple tasks (actor isolation serializes).
    ///
    /// Behavior:
    /// - Flushes any buffered throttle events to `events` before
    ///   finishing the stream — no events are silently dropped.
    /// - Tears down the FSEventStream / DispatchSource synchronously
    ///   via `Core.stop()`; after this returns, no callback can fire.
    /// - Releases the security-scoped resource if Session acquired it.
    /// - A second call is a no-op.
    ///
    /// Equivalent to dropping the Session reference, except `stop()`
    /// gives deterministic timing — useful when the caller wants to
    /// keep the Session reference around for inspection but stop
    /// receiving events.
    public func stop() async

    /// Force any pending events to be delivered through `events`
    /// before this call returns. Two layers are flushed:
    /// 1. **Kernel.** For folder sessions, calls
    ///    `FSEventStreamFlushSync` to make the OS dispatch any events
    ///    it's batching. (No-op for single-file sessions.)
    /// 2. **Throttle buffer.** Yields the deduplicated buffer
    ///    immediately, skipping the remaining throttle wait.
    ///
    /// Useful in tests (deterministic ordering), in app-suspension
    /// hooks (process pending events before background), and before
    /// state-on-demand reads.
    public func flush() async
}

// MARK: - Errors

public enum WatcherError: Error, Sendable {
    case pathNotFound(URL)
    case notReadable(URL, underlying: Error?)
    case streamCreationFailed(URL)
    case streamStartFailed(URL)
    case unsupportedPlatformFeature(String)
    /// Watcher torn down externally — folder root deleted or renamed,
    /// or single-file root renamed. Thrown into `events`.
    case rootInvalidated(URL)
}
```

### Usage

```swift
var options = Options()
options.scope = .all
options.depth = .infinite

let session = try await Session(path: folderURL, options: options)

do {
    for try await event in session.events {
        switch event {
        case .fileAdded(let url):              print("+ \(url.path)")
        case .fileDeleted(let url):            print("- \(url.path)")
        case .fileChanged(let url):            print("~ \(url.path)")
        case .refreshRequired(let scope):      rescan(under: scope)
        }
    }
    // Reached here = clean end (Session released or .stop()'d, or a
    // single-file session's file was deleted).
} catch let error as WatcherError {
    // Reached here = OS-initiated teardown (e.g., root deleted).
    print("watcher torn down: \(error)")
}
```

### Why `AsyncThrowingStream<Event, Error>`

- Lets callers distinguish **clean termination** (Session released or
  `stop()` called) from **OS-initiated teardown** (root deleted /
  renamed) without a parallel notification channel.
- Construction-time failures still surface through
  `init(path:options:) throws`; runtime teardown surfaces through the
  stream's throw.
- The `try await` syntax cost is one keyword; consumers who don't care
  about the distinction can `try?` or wrap in a single `do/catch`.
- File-deletion in a single-file session does **not** throw — it emits
  `.fileDeleted(canonicalRoot)` and finishes cleanly. The throw is
  reserved for cases without an in-band event representation.

### Lifecycle and the no-retain-cycle invariant

The reference graph is one-way:

```
Caller ──strong──▶ Session ──strong──▶ Engine ──strong──▶ Continuation
                                              ──strong──▶ FSEventStreamRef / DispatchSource

(FSEventStream context uses Unmanaged.passUnretained(Engine)
 — no extra strong reference back to Engine.)

(Consumer's `for await` holds the AsyncStream, which holds an
 internal buffer fed by the Continuation. It does NOT hold the
 Session or the Engine.)
```

When the caller drops their `Session` reference:

1. `Session.deinit` calls `engine.stop()`.
2. Engine cancels the FSEventStream / DispatchSource and finishes the
   continuation.
3. The consumer's `for await` loop exits naturally.

There is no path from the engine, continuation, or stream back to the
session, so dropping the session is sufficient to tear everything down.

### Mapping platform events to `Event`

The native APIs report a richer set of changes than the three cases
above. The session collapses them as follows (open question — see §11):

| Native signal                              | Reported as            |
| ------------------------------------------ | ---------------------- |
| FSEvent `ItemCreated` / DS `.write` on new | `.fileAdded`           |
| FSEvent `ItemRemoved` / DS `.delete`       | `.fileDeleted`         |
| FSEvent `ItemModified` / DS `.write`       | `.fileChanged`         |
| FSEvent `ItemRenamed`                      | pair: deleted + added  |
| Metadata-only flags (xattr, finder info)   | dropped (or `.fileChanged` — TBD) |
| Root changed (folder moved/deleted)        | sequence finishes      |

`Scope.folderOnly` filters to events whose target is a direct child of
the watched root *and* whose flags indicate a directory-list change
(create/remove/rename). `Scope.filesAndFolders` admits in-place file
modifications throughout the tree.

### Depth filtering (post-filter, not native)

FSEventStream has no native depth control — it always reports the full
subtree. `Depth.immediate` and `Depth.levels(N)` are implemented as a
**post-filter** on path components relative to the watched root:

```
let relativeDepth = changedPath.pathComponents.count
                  - rootPath.pathComponents.count
guard relativeDepth <= maxDepth else { return }
```

This is honest but not free: we still receive (and discard) deeper
events. For very large trees with shallow interest, callers should
prefer watching a more specific subdirectory.

For single-file sessions, `depth` is ignored entirely — DispatchSource
watches one inode.

---

## 7. Architecture

```
┌──────────────────────────────────────────────────────────┐
│                       Public API                         │
│            Session · Event · Options · Errors            │
└────────────────────────────┬─────────────────────────────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │  Session  (public actor)     │
              │  • nonisolated `events`      │
              │  • throttle / dedup buffer   │
              │  • yields to Continuation    │
              │  • holds Core (strong)       │
              └──────────────┬───────────────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │  Session.Core  (final class) │
              │  • @unchecked Sendable       │
              │  • private serial queue      │
              │  • owns FSEventStreamRef     │
              │    or DispatchSource         │
              │  • weak ref → Session        │
              │  • C callback → Task hop     │
              │  • nonisolated stop()        │
              └──────────────────────────────┘
```

- **`Session` (public actor):** the public concurrency boundary.
  Picks the C-API path inside `Core` based on whether the canonical
  path resolves to a directory or a regular file. Owns the throttle
  buffer and dedup set; yields normalized events to the AsyncStream
  continuation. Holds `Core` strongly. Calls `core.stop()` from its
  nonisolated `deinit` for synchronous teardown.
- **`Session.Core` (nested `final class`, `@unchecked Sendable`):**
  the C-API-shaped boundary. Owns either the `FSEventStreamRef` or the
  `DispatchSource`, plus a private utility-QoS serial dispatch queue.
  Holds **a weak reference back to Session** to avoid a retain cycle.
  The C callback (or DispatchSource event handler) runs on Core's
  queue; it does minimal work and hops back into the actor via
  `Task { [weak owner] in await owner?.didObserve(batch) }`.
- **`stop()` (on Core):** nonisolated, synchronous, idempotent.
  Sequence is `FSEventStreamStop → FSEventStreamInvalidate → Release`;
  `Invalidate` synchronously drains in-flight C callbacks before
  returning. After `stop()` returns, no callback can ever fire again.

### Concurrency rules

- **Session uses actor isolation** for all serialization. No locks.
- **Core's mutable state is queue-confined** (its private serial
  DispatchQueue); marked `@unchecked Sendable` with that invariant.
- **The FSEventStream context's `info` pointer references Core**, not
  Session. Core is alive because Session retains it strongly.
- **The Core → Session reference is weak.** Without this, the C
  callback's `Task` capture would form a retain cycle and the
  Session would never deinit.
- **`Session.deinit` is nonisolated** and calls `core.stop()`
  synchronously. Pending throttle Tasks captured `self` weakly and
  no-op when self deallocates.
- **No `@MainActor` callbacks** in the public API. Consumers iterate
  `events` from any context they like and hop to MainActor themselves
  if they need UI updates.
- **File-scope loggers must be `nonisolated private let`** so engine
  code on Core's queue can use them without isolation hops.

---

## 8. Event Semantics

### Folder watch (FSEventStream)

- Events arrive in batches; we coalesce per debounce window.
- `kFSEventStreamCreateFlagFileEvents` is always set so we get per-file
  events, not just per-directory.
- `kFSEventStreamCreateFlagWatchRoot` is always set so we detect the root
  being moved or deleted; that surfaces as `WatcherError.rootInvalidated`
  on the stream and the stream finishes.
- `kFSEventStreamCreateFlagNoDefer` is set so the first event in a quiet
  period fires immediately rather than after `latency`.
- `kFSEventStreamCreateFlagUseCFTypes` is always set so paths are
  `CFArray<CFString>` and bridge cleanly to `[String]`.

### File watch (DispatchSource)

- `[.write]` → `.modified`
- `[.rename]` → `.renamed` (caller chooses follow-path vs follow-inode)
- `[.delete]` → `.removed`, then stream finishes
- `[.attrib]` → `.metadataChanged`

### Scope filtering (post-filter on FSEvents)

`Scope` is a post-filter, not a watcher reconfiguration —
`kFSEventStreamCreateFlagFileEvents` is always set so we always have
the granularity to distinguish kinds.

| Native flags                | Public `Event`         | Admitted by             |
| --------------------------- | ---------------------- | ----------------------- |
| `ItemCreated`  (file/dir)   | `.fileAdded(url)`      | `.fileAddedOrDeleted`   |
| `ItemRemoved`  (file/dir)   | `.fileDeleted(url)`    | `.fileAddedOrDeleted`   |
| `ItemRenamed`  (file/dir)   | `.fileDeleted(old)` + `.fileAdded(new)` | `.fileAddedOrDeleted` |
| `ItemModified` (file)       | `.fileChanged(url)`    | `.fileChanged`          |
| Metadata-only flags         | dropped                | (always)                |

- An event passes only if its target membership is in `options.scope`.
  `Scope.all` admits everything.
- Single-file sessions (DispatchSource) ignore `Scope` — a file watch
  always reports its inode-level events; filtering would conflict with
  the explicit `Session(path: file, ...)` contract.
- The three `file*` `Event` cases keep their names even when the
  target is a directory. Naming is consistent across kinds; the
  `URL` is the source of truth.

**Drop signals → `.refreshRequired(scope:)`.** When FSEvents reports
`MustScanSubDirs`, `UserDropped`, or `KernelDropped`, the kernel is
telling us it dropped events under some subtree. Watcher emits a
single `.refreshRequired(scope: url)` so the consumer can rescan that
subtree and reconcile. This event:

- **Bypasses throttle and dedup.** It's the signal that something was
  missed; suppressing it in a busy window would defeat the purpose.
- **Is folder-only.** DispatchSource has no equivalent drop signal,
  so single-file sessions never emit it.
- **Is rare in normal use.** Only fires under heavy filesystem load
  (large unzip, `git checkout` of a huge repo, Time Machine restore).
  Consumers that don't care about strict consistency can pattern-match
  on the other three cases and let `default:` swallow it.

### Depth filtering (post-filter)

FSEventStream has no native depth control — it always reports the full
subtree. `Depth` is implemented as a post-filter using canonical-path
component counts:

```
relativeDepth = eventPath.components.count - canonicalRoot.components.count - 1
```

The `-1` measures depth of the file itself, not its parent directory.

| `Depth`        | Admitted `relativeDepth` |
| -------------- | ------------------------ |
| `.immediate`   | `0` (direct children)    |
| `.levels(N)`   | `0...N`                  |
| `.infinite`    | any                      |

- `.levels(0)` is equivalent to `.immediate` — no separate handling.
- For very large trees with shallow interest, we still receive and
  discard the deeper events. Callers who care about cost should watch
  a more specific subdirectory rather than a shallow root.
- Directory creation edge case: a new subdirectory at the root fires
  one `.fileAdded(newdir)` (depth 0). Files later created inside it
  fire at depth 1+. Under `.immediate`, the consumer sees the
  directory creation but not the contents — that's correct behavior;
  the consumer is responsible for scanning if they want a snapshot.
- Single-file sessions ignore `Depth` (DispatchSource watches one
  inode; depth is meaningless).

### Init sequence and failure unwinding

`Session.init` is `async throws` and acquires several resources in
order. Actor init failure does **not** invoke `deinit`, so anything
already acquired must be released by the init itself before
re-throwing.

Ordered steps:

1. `path.startAccessingSecurityScopedResource()` — first because
   `realpath` and watcher creation need filesystem access in
   sandboxed apps.
2. `realpath(path)` → `canonicalRoot`. Throws `pathNotFound` /
   `notReadable` on failure.
3. Probe `canonicalRoot` to determine file vs folder. On non-macOS,
   throw `unsupportedPlatformFeature` for folders.
4. Construct `Core`. Throws `streamCreationFailed` if
   `FSEventStreamCreate` returns nil or `open(O_EVTONLY)` fails.
5. Allocate `AsyncThrowingStream` + continuation; assign `events`.
6. `core.start(owner: self)` — registers the C callback and starts
   the watcher. Throws `streamStartFailed` if `FSEventStreamStart`
   returns false.

Any `throw` from steps 2–6 runs an inline cleanup that mirrors the
acquisition order in reverse:

- If Core was constructed (step 4 succeeded) but `start` failed
  (step 6), Core's `stop()` must be called to release the
  FSEventStream / FD. Core tracks a `started: Bool` so this is safe
  on a never-started stream.
- The AsyncStream continuation, if allocated, is dropped with the
  partially-constructed actor — safe because no consumer is yet
  iterating.
- Security scope is released last via
  `stopAccessingSecurityScopedResource()` if step 1 returned `true`.

### Security-scoped resource ownership

Session manages the security scope of the supplied URL across its
own lifetime. The implementation pattern:

```swift
public actor Session {
    private let scopedURL: URL?   // non-nil iff we acquired scope at init

    public init(path: URL, options: Options = .init()) throws {
        // 1. Acquire scope first — needed for realpath / FSEventStreamCreate
        //    to succeed in sandboxed apps with user-picked URLs.
        let didStart = path.startAccessingSecurityScopedResource()
        self.scopedURL = didStart ? path : nil

        do {
            // 2. realpath, FSEventStream / DispatchSource setup, etc.
        } catch {
            // 3. Actor init that throws does NOT run deinit. Release
            //    scope manually before rethrowing.
            if didStart { path.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    nonisolated deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }
}
```

Notes:

- `startAccessingSecurityScopedResource()` returns `false` when the
  URL doesn't need scope (e.g., a path inside the app's container);
  in that case we skip the `stop` call to avoid an unbalanced release.
- The original (pre-realpath) URL is used for both start and stop —
  scope is per-URL and the canonical URL may not carry the bookmark.
- Calls are reference-counted under the hood, so callers who also
  manage scope around the Session do no harm; both sets of start/stop
  pairs balance independently.
- If `init` throws after `start` succeeded, scope is released
  manually — actor init failure does not invoke `deinit`.

### Path canonicalization

- The `path` passed to `Session.init` is canonicalized exactly once,
  via `realpath(3)`, at construction. The result is exposed as
  `Session.canonicalRoot` and is used as the FSEventStream root /
  DispatchSource open path.
- **No per-event realpath.** Deletion events arrive *after* the file is
  gone, so `realpath` would fail. Instead we trust FSEvents to emit
  event paths rooted at the same canonical volume path (which is what
  it does — its internal canonicalization matches `realpath(3)`).
- Add/Delete cancellation in the throttle window relies on this: the
  same file produces byte-equal URL strings for both create and delete,
  so they hash to the same `Event` key.
- For DispatchSource (single-file) sessions, the canonical URL is
  computed at init and used for every emitted event; the source itself
  watches an inode and doesn't carry a path.
- **Invariant:** future contributors must not realpath per event.
  A regression test asserts the create-then-delete sequence within one
  throttle window emits zero events.

### Throttling and deduplication

Throttle and dedup live **inside the actor** (not in `Core`). Core
hops one batch at a time into the actor via `await session.didObserve(batch)`;
the actor accumulates, dedupes, and yields.

- **Throttle, not debounce.** First raw batch opens a window of length
  `options.throttle`. Subsequent batches during the window accumulate
  but **do not extend** the window. On expiry, the actor yields the
  deduplicated buffer and closes the window. The next incoming batch
  opens a new window. This guarantees emission at least every
  `throttle` interval under sustained load.
- **Throttle clamping.** `options.throttle` is clamped to
  `[150 ms, 5 s]` when the Session is constructed. Below 150 ms thrashes
  on file save bursts; above 5 s stops feeling responsive.
- **Dedup at the `Event` layer.** The accumulator uses
  `Set<Event>` — `Event` is `Hashable`, so 100 raw `ItemModified`
  flags on the same URL collapse to one `.fileChanged(url)`.
- **Add/Delete cancellation.** Within a single window, an incoming
  `.fileDeleted(url)` whose matching `.fileAdded(url)` is already in
  the buffer **removes both** (the file appeared and disappeared
  before the consumer ever saw it — net effect is nothing). This is an
  edge case but cheap to handle.
- **Cancellation on Session release.** The throttle Task captures
  `self` weakly. When the user drops the Session, weak `self` becomes
  nil; the Task wakes from `Task.sleep`, sees nil, no-ops. No explicit
  cancellation from `deinit` is required.

---

## 9. Lifecycle and Cancellation

The `Session` reference is the lifetime token. The `events` sequence
ends in one of two ways: **clean finish** (consumer's `for try await`
exits the loop normally) or **thrown error** (`for try await` throws
`WatcherError.rootInvalidated(URL)`).

| Scenario                                           | `events` ends with                             |
| -------------------------------------------------- | ---------------------------------------------- |
| Caller releases `Session`                          | `finish()` — clean                             |
| Caller calls `Session.stop()`                      | `finish()` — clean (idempotent with deinit)    |
| Folder root deleted (`RootChanged`)                | `finish(throwing: .rootInvalidated(root))`     |
| Folder root renamed (`RootChanged`)                | `finish(throwing: .rootInvalidated(root))`     |
| Single-file root deleted (DispatchSource `.delete`) | emit `.fileDeleted(root)`, then `finish()` clean |
| Single-file root renamed (DispatchSource `.rename`) | `finish(throwing: .rootInvalidated(root))`     |

Internal teardown sequence — `await session.stop()` and OS-initiated
teardown both run inside the actor, so they share this path:

1. Core's queue handles the triggering signal (RootChanged flag,
   DispatchSource event, or external `stop()`).
2. Core hops to the actor: `Task { [weak owner] in await owner?.handleTeardown(...) }`.
3. Actor checks an `didStop` guard; if already torn down, no-op.
4. Actor flushes the throttle buffer (yielding remaining events),
   then calls `continuation.finish()` or
   `continuation.finish(throwing: .rootInvalidated(root))`.
5. Core's `stop()` runs `FSEventStreamStop → Invalidate → Release`
   (or cancels the DispatchSource); `Invalidate` synchronously drains
   any in-flight C callback before returning.
6. After `Session.deinit` completes, no callback can ever fire again.

`Session.deinit` is nonisolated and synchronous — it cannot `await`,
so it does not run the actor-side flush. It calls `Core.stop()`
directly (idempotent — does nothing if the actor's `stop()` ran
first) and releases the security-scoped resource. Any pending
throttle events still buffered when the user drops the Session are
dropped along with the Session. Callers who care about flushing the
final batch should call `await session.stop()` before releasing.

Construction errors (`pathNotFound`, `notReadable`,
`unsupportedPlatformFeature`, `streamCreationFailed`,
`streamStartFailed`) are thrown by `init`, not by the stream.

---

## 10. Logging

### Subsystem

```swift
public enum Watcher {
    /// Subsystem used by all file-scope loggers in the package.
    /// Defaults to the host app's bundle identifier so Watcher logs
    /// naturally sort under the consuming app in Console.app.
    /// Configurable at app launch; should not change after a Session
    /// has been created.
    public static var logSubsystem: String =
        Bundle.main.bundleIdentifier ?? "Watcher"
}
```

### Categories

Three stable categories matching the actor + Core architecture:

- **`Session`** — actor-level events: init, stop, throttle flushes,
  thrown errors, scope-resource acquisition.
- **`Core.Folder`** — FSEventStream lifecycle (create, start, stop,
  invalidate) and raw callback batches.
- **`Core.File`** — DispatchSource lifecycle and raw events.

### Logger declaration rule

Every file-scope logger must be declared `nonisolated private let` to
avoid implicit `@MainActor` isolation in projects that use
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Otherwise the engine code
(running on Core's dispatch queue) cannot access the logger without
an isolation hop.

```swift
nonisolated private let logger = Logger(
    subsystem: Watcher.logSubsystem,
    category: "Core.Folder"
)
```

### Levels

- `debug` — per-raw-event detail (one line per FSEvent flag batch).
- `notice` — Session lifecycle (start, stop, root-invalidated,
  refresh-required).
- `error` — OS-level failures: `FSEventStreamCreate` returning nil,
  `FSEventStreamStart` returning false, DispatchSource errors.

### Path privacy

Paths come from the caller and may be user-named (sensitive). Default:
`privacy: .private` for all path interpolations. Developers needing
to see paths during debugging should run with private-data
unredaction enabled (via a configuration profile on macOS or
`log stream --info --debug` with the relevant entitlement).

FSEventStream / DispatchSource flag bitmasks, event IDs, and counts
are non-sensitive and log as `privacy: .public`.

---

## 11. Open Questions / Iteration Points

The architecture is settled enough to start writing code. The items
below are deferred until we can review real code rather than prose —
they are easier to evaluate against a working implementation than to
design in the abstract.

### Behavior to confirm during code review

1. **Symlinks within the watched tree.** FSEvents reports paths to
   symlinks themselves, not their targets. Current behavior: emit as
   normal `.fileAdded` / `.fileChanged` etc. with the symlink URL.
   The consumer resolves if they care. Confirm this default once we
   can test it.
2. **The `Watcher` namespace.** PRD references `Watcher.logSubsystem`
   and an internal `Watcher.realpath` shim. Whether `Watcher` is a
   caseless `public enum` namespace or some other shape is an
   implementation choice; pick one in code and revisit if it reads
   poorly.

### Invariants to verify with tests

3. **No-retain-cycle.** Open a Session in a scope, hold a `weak var`
   externally, exit scope, assert weak ref nils and the consumer's
   `for try await` exits. Required because the Core → Session weak
   reference is the load-bearing invariant.
4. **`FSEventStreamInvalidate` actually drains callbacks
   synchronously.** Apple's docs say it does; verify with a stress
   test (concurrent `stop()` + active event flow + assert no callback
   fires after `Invalidate` returns).
5. **`flush()` waits for kernel delivery.** Verify
   `FSEventStreamFlushSync` returns only after the events have been
   dispatched to our queue; verify our `flush()` then drains the
   throttle buffer before returning.
6. **Security scope behaves in a real sandboxed app.** The PRD model
   (Session acquires at init, releases at deinit) is correct in
   theory; needs a smoke test in an actual sandboxed host app.

### Performance to measure

7. **Per-batch actor hop cost.** Core hops to the actor once per
   FSEvents batch. Under heavy load (large unzip into the watched
   tree, ~10k events/sec) measure the actor backlog and the consumer
   latency. If hop cost dominates, consider batch coalescing inside
   Core before the hop.
8. **Throttle clamp range.** `[150 ms, 5 s]` is a guess. Real-app
   feedback may show 150 ms is too aggressive (drops out-of-order
   events) or too conservative (laggy UI). Adjust empirically.

### Deferred to v2

- **Replay across launches.** Persist the last
  `FSEventStreamEventId` so a new Session can resume from where the
  previous one stopped, replaying events that occurred while the
  process was dead. Non-trivial because the stored ID must be
  invalidated on root reformat / volume change.
- **iOS folder fallback.** Per-child DispatchSource swarm for shallow
  folder watch on iOS. Scoped out of v1; revisit if requested.
- **Multi-consumer broadcast.** Currently single-consumer per Session.
  If consumers ask for fan-out, evaluate `swift-async-algorithms`
  `AsyncChannel` or a hand-rolled multicaster.

---

## 12. Testing Strategy

- **Unit tests** with Swift Testing (`@Test`, `#expect`):
  - Create temp directory, open `Session`, perform mutations via
    `FileManager`, assert observed event sequence on `session.events`.
  - Verify throttle: rapid bursts → one batch per throttle window;
    sustained load → batches at most every `throttle` interval.
  - Verify dedup: 100 modifications to one file in a window → one
    `.fileChanged(url)` event.
  - Verify add/delete cancellation: create + delete same URL within a
    throttle window → zero events emitted.
  - Verify path canonicalization: pass a symlinked path to a temp
    directory; events come back rooted at the realpath form.
  - Verify root-invalidated: delete the watched folder →
    `for try await` throws `WatcherError.rootInvalidated(url)`.
  - Verify single-file delete: delete the watched file → emits
    `.fileDeleted(url)`, then sequence finishes cleanly (no throw).
  - Verify scope filtering: `.fileAddedOrDeleted` alone drops in-place
    modifications; `.fileChanged` alone drops add/delete; `.all`
    admits all three.
  - Verify depth filtering: events deeper than `Depth.levels(N)` are
    dropped; `Depth.immediate` reports only direct children.
  - Verify `flush()`: after a mutation, `await session.flush()`
    delivers events without waiting for the throttle window.
  - **Verify the no-retain-cycle invariant.** Open a `Session` in a
    scope, retain a `weak var` reference, exit scope, assert weak
    reference becomes nil and the consumer's `for try await` exits.
- **Concurrency tests:** run under TSan in CI. Verify no data races
  when consumers iterate while Core's queue emits and the actor
  yields.
- **Platform conditionals:** macOS-only tests gated on `#if os(macOS)`;
  cross-platform tests cover only single-file sessions.
- **iOS smoke test:** assert that `Session(path: folderURL)` on iOS
  throws `WatcherError.unsupportedPlatformFeature`.

---

## 13. Milestones

- **M1 — Skeleton & types.** `Package.swift` updated to declare all
  Apple platforms with the minimum versions below. `Session`,
  `Event`, `Options`, `WatcherError` declared with stub
  implementations. Compiles. Stub tests.
- **M2 — File engine.** DispatchSource-backed single-file `Session` on
  all Apple platforms. Termination on `.delete` and on session release
  verified by tests.
- **M3 — Folder engine (macOS).** FSEventStream-backed folder
  `Session` with debouncing, scope filtering, depth filtering, and
  root-changed teardown. Tests pass.
- **M4 — Hardening.** Strict concurrency clean. Logging finalized.
  TSan-clean tests. Documentation pass. README with the canonical
  `for await` snippet.
- **M5 — (stretch) iOS folder fallback** if §11.1 lands as Option B.

### `Package.swift` shape (target for M1)

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Watcher",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "Watcher", targets: ["Watcher"]),
    ],
    targets: [
        .target(name: "Watcher"),
        .testTarget(name: "WatcherTests", dependencies: ["Watcher"]),
    ],
    swiftLanguageModes: [.v6]
)
```

- Single target. `Session` and its nested `Core` class live in the
  same module.
- No external dependencies. Foundation, Dispatch, CoreServices (gated
  to macOS), `os.Logger`, and Darwin (for `realpath`) are all SDK.
- Swift 6 strict concurrency mode.

---

## 14. Risks

- **R1.** `FSEventStream` callback-to-Swift bridging via `Unmanaged` is
  the fragile core; mishandling reference counts crashes the host. The
  reference `FolderWatcher.swift` gets this right (`passUnretained` +
  matching `takeUnretainedValue`); we'll mirror that pattern verbatim.
- **R2.** The no-retain-cycle invariant depends on the engine *not*
  holding the Session. The FSEventStream context must reference the
  Engine (not the Session), and no engine callback may capture the
  Session. Enforced by code review and a unit test that asserts a
  weak reference to the Session is nilled after the consumer drops it.
- **R3.** Strict concurrency: FSEventStream callbacks fire on whatever
  queue we set; the captured `info` pointer must refer to a class with
  a stable lifetime. The Session retains the Engine, so the Engine
  outlives any in-flight callback as long as the Session is alive; the
  Session's `deinit` must drain pending callbacks (i.e. invalidate the
  stream synchronously) before releasing the Engine.
- **R4.** AsyncStream backpressure: if a consumer iterates slowly, the
  buffering policy matters. Default `bufferingPolicy: .bufferingNewest(N)`
  with N tunable.
- **R5.** Test flakiness on CI from filesystem timing. Mitigate with
  generous debounce in test fixtures and (if §11.8 lands) `flush()`.

---

## 15. Reference Implementation Notes

The PRD's correctness baseline is
`/Users/brennan/Developer/brennanMKE/Issues/Issues/Services/FolderWatcher.swift`.
Key patterns to preserve:

- `Unmanaged.passUnretained(self).toOpaque()` for context info.
- `FSEventStreamSetDispatchQueue` (not run loop scheduling).
- Flags: `FileEvents | NoDefer | WatchRoot | UseCFTypes`.
- Paths via `(cfArray as NSArray).compactMap { $0 as? String }`.
- Root-changed → invalidate → emit terminal error.
- Debounce via `DispatchWorkItem` on the engine's queue.

What the reference does that *Watcher* should **not** propagate:

- `@MainActor` callback contract — that's a UI choice.
- Fire-and-forget `Task { @MainActor in ... }` from inside the FSEvent
  callback — replace with continuation yields.
- `onChange` / `onInvalidated` closure pair — replace with a single
  `AsyncThrowingStream` event/error channel.
