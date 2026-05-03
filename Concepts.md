# Concepts

Background you need to hold in your head to read, write, or maintain the
Watcher package. Most of this is unavoidable Apple-platform plumbing.
The PRD describes *what* we're building; this document describes *why
the building blocks behave the way they do*.

---

## 1. Two Filesystem-Monitoring APIs on Apple Platforms

Apple offers two primitives, with non-overlapping strengths:

### 1.1 FSEventStream (CoreServices, macOS only)

- **What it watches:** a *path*, treated as the root of a subtree.
- **What it sees:** changes anywhere in the subtree, batched and
  delivered to a callback you provide.
- **Not available on iOS/tvOS/watchOS/visionOS.** macOS-only API.
- Key entry points:
  - `FSEventStreamCreate(...) -> FSEventStreamRef?`
  - `FSEventStreamSetDispatchQueue(stream, queue)`
  - `FSEventStreamStart(stream) -> Bool`
  - `FSEventStreamStop(stream)`
  - `FSEventStreamInvalidate(stream)`
  - `FSEventStreamRelease(stream)`
- Configured by a bitmask of `kFSEventStreamCreateFlag*` flags.
- Reports per-event a path string, an event ID (`FSEventStreamEventId`,
  a monotonic 64-bit counter), and a flags bitmask.

### 1.2 DispatchSource file system object source (Dispatch, all Apple OSes)

- **What it watches:** a single open file descriptor.
- **What it sees:** inode-level events on that descriptor.
- Available everywhere Dispatch is — iOS, macOS, tvOS, watchOS, visionOS.
- Key entry points:
  - `open(path, O_EVTONLY)` to get the FD.
  - `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:queue:)`
  - `source.setEventHandler { ... }`
  - `source.setCancelHandler { close(fd) }`
  - `source.resume()`
- Event mask members: `.write`, `.delete`, `.rename`, `.attrib`,
  `.link`, `.extend`, `.revoke`, `.funlock`.

### 1.3 Why both? The directory-FD trap

You might think a `DispatchSource` opened on a directory FD is enough to
watch a folder. It isn't. A directory's inode changes only when the
directory's own contents list changes (entry added/removed/renamed).
**An in-place modification to an existing file inside the directory does
not change the directory's inode**, so the directory-FD source doesn't
fire.

That's why folder watching needs `FSEventStream` with
`kFSEventStreamCreateFlagFileEvents`: it reports per-file events for
the entire subtree, including in-place edits to existing files.

---

## 2. FSEventStream Mental Model

### 2.1 Latency vs. NoDefer

`FSEventStreamCreate` takes a `latency: CFTimeInterval`. The stream
*coalesces* events within a `latency` window before calling your
callback. Setting `kFSEventStreamCreateFlagNoDefer` flips the
coalescing policy:

- **Without NoDefer:** every batch waits at least `latency` seconds.
  Good when bursts are common and you don't care about the first few ms.
- **With NoDefer:** the first event in a quiet period fires immediately,
  then subsequent events within `latency` are coalesced. Good for
  responsive UIs.

We always set `NoDefer` and add our own debounce on top.

### 2.2 The flag bitmask

`FSEventStreamEventFlags` is a `UInt32` bitmask. A single event can
carry many bits (e.g. `ItemIsFile | ItemModified | ItemInodeMetaMod`).
You read individual bits with bitwise AND:

```swift
flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0
```

### 2.3 The dangerous flags

Two flags require defensive handling:

- `kFSEventStreamEventFlagMustScanSubDirs` — the kernel dropped events
  and the consumer should rescan. Watcher should surface this as a
  hint to the caller.
- `kFSEventStreamEventFlagRootChanged` — the watched root was moved or
  deleted. The stream is now watching a stale path; we must terminate
  and surface `WatcherError.rootInvalidated`.

`UserDropped` and `KernelDropped` are weaker forms of "we lost
events" — same response: tell the caller to rescan.

### 2.4 The C callback bridge

`FSEventStreamCreate` takes a C function pointer:

```swift
typealias FSEventStreamCallback =
    @convention(c) (
        ConstFSEventStreamRef,
        UnsafeMutableRawPointer?,
        Int,
        UnsafeMutableRawPointer,
        UnsafePointer<FSEventStreamEventFlags>,
        UnsafePointer<FSEventStreamEventId>
    ) -> Void
```

`@convention(c)` closures cannot capture context. To get back to a
Swift instance, you stuff a pointer into the `FSEventStreamContext.info`
field, then unwrap it inside the callback:

```swift
var context = FSEventStreamContext(
    version: 0,
    info: Unmanaged.passUnretained(self).toOpaque(),
    retain: nil,
    release: nil,
    copyDescription: nil
)

let callback: FSEventStreamCallback = { _, info, n, eventPaths, flags, _ in
    guard let info else { return }
    let me = Unmanaged<MyEngine>.fromOpaque(info).takeUnretainedValue()
    me.handle(...)
}
```

Rules of survival:

- `passUnretained` + `takeUnretainedValue` must be paired. If you
  `passRetained` on the way in, you must `takeRetainedValue` somewhere
  to balance it, or you leak.
- The Swift instance referenced by `info` must outlive the stream. Our
  engine class is retained by the AsyncStream's onTermination closure
  precisely to guarantee this.
- Do not allocate Swift objects with intricate lifetimes inside the
  callback unless you understand exactly which thread you're on.

### 2.5 `UseCFTypes` and path bridging

With `kFSEventStreamCreateFlagUseCFTypes` set, the `eventPaths`
parameter is a `CFArrayRef` of `CFStringRef`. Without it, it's a C
array of C strings. We always set `UseCFTypes` and bridge:

```swift
let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
let paths = (cfArray as NSArray).compactMap { $0 as? String }
```

This is allocation-cheap and avoids manual UTF-8 decoding.

### 2.6 Run loop vs. dispatch queue

Older sample code uses `FSEventStreamScheduleWithRunLoop`. Modern code
uses `FSEventStreamSetDispatchQueue` so the callback is invoked on a
dispatch queue you own. We always use the dispatch-queue path — it
plays well with structured concurrency and doesn't require a live run
loop on the calling thread.

### 2.7 Event IDs and replay

Each event carries a `FSEventStreamEventId`, a 64-bit counter that's
monotonic per device. You can pass a stored ID to `FSEventStreamCreate`
instead of `kFSEventStreamEventIdSinceNow` to replay events that
happened while your process was dead. Watcher v1 doesn't expose this;
it's a candidate for v2.

---

## 3. DispatchSource Mental Model

### 3.1 `O_EVTONLY`

When you `open()` a file purely to watch it, use the `O_EVTONLY` flag.
This opens the file in a way that doesn't prevent unmounting the
volume — important for external drives and network shares.

```swift
let fd = open(path, O_EVTONLY)
```

### 3.2 The cancel handler closes the FD

The DispatchSource takes ownership of nothing. You must close the FD
when you're done, and the only safe place to do it is the source's
cancel handler:

```swift
source.setCancelHandler { close(fd) }
```

If you `close(fd)` before the source is cancelled, the source can fire
on a recycled FD. If you cancel without a handler, you leak the FD.

### 3.3 Rename / delete and "follow path" vs "follow inode"

DispatchSource watches the *inode*, not the path. If the user renames
the file:

- Follow-inode: keep emitting events; the path you tell the caller is
  stale, but the bytes are real.
- Follow-path: cancel and re-open by path; emit a `.renamed` to signal
  the discontinuity.

Watcher should default to follow-inode (matches `DispatchSource`'s
native behavior) and document the caveat. A future option can switch
modes.

### 3.4 Event coalescing

DispatchSource coalesces events of the same type within the same
delivery cycle — multiple writes between two callback invocations
arrive as a single `.write`. This is a feature, not a bug; it matches
the granularity most consumers want.

---

## 4. Coalescing and Debouncing

Two layers of coalescing exist:

1. **Kernel/system layer** — both APIs already coalesce within their
   delivery semantics. FSEventStream uses `latency`; DispatchSource
   uses event-mask deduplication.
2. **Application layer** — Watcher adds a debounce on top so that
   bursts spanning multiple system deliveries collapse into one
   user-visible event.

The reference implementation uses 150 ms; that's our default. Caller
can tune via `Options.debounce`.

Why two layers? Because the kernel cares about delivery efficiency
(don't wake userspace too often) and the app cares about UX (don't
re-render the file list 40 times per second when a save is happening).

---

## 5. Memory Management Across the C Boundary

A short list of the things that bite:

| Symptom                              | Cause                                  | Fix                                                              |
| ------------------------------------ | -------------------------------------- | ---------------------------------------------------------------- |
| Crash inside callback                | `info` points to deallocated instance  | Retain the instance for the lifetime of the stream               |
| Mysterious leak                      | `passRetained` without `takeRetained`  | Match retain/release; prefer `passUnretained` + manual retention |
| `FSEventStreamRelease` double-free   | Released twice on stop and dealloc     | Set `stream = nil` after first release; guard subsequent calls   |
| Wrong type after `fromOpaque`        | `info` cast to wrong Swift class       | Make the engine `final class` and use a unique opaque-cast site  |
| `Unmanaged` warnings under Swift 6   | Strict-concurrency complains on raw ptr | Wrap the bridge in a `nonisolated(unsafe)` helper, document why  |

---

## 6. Concurrency Model

### 6.1 What runs where

- **FSEventStream callback:** runs on the dispatch queue you supplied
  to `FSEventStreamSetDispatchQueue`. We use a serial utility-QoS
  queue per engine.
- **DispatchSource event handler:** runs on the queue passed at
  source creation. Same convention.
- **AsyncStream continuation:** we yield from the engine's queue.
  The continuation is `Sendable` and safe to call from any context.
- **Consumer:** iterates `for try await event in stream` from
  whatever Task / actor they like.

### 6.2 No `@MainActor` in the public API

The reference `FolderWatcher.swift` uses `@MainActor` callbacks because
its consumer is a SwiftUI view. That's a UI concern. Watcher delivers
events on a generic AsyncStream and lets consumers hop to MainActor
themselves:

```swift
for try await event in watcher.folder(at: url) {
    await MainActor.run { viewModel.apply(event) }
}
```

### 6.3 Sendable boundaries

- `WatchEvent`, `WatchEvent.Kind`, `WatchEvent.Attributes`,
  `*.Options` — all value types, `Sendable`.
- Engine class — `final class`, confined to its serial queue, marked
  `@unchecked Sendable` with a comment justifying it (state is only
  touched from the engine queue).
- `Unmanaged` bridge — `nonisolated(unsafe)`, with a comment.

### 6.4 Cancellation propagation

```swift
let stream = AsyncThrowingStream<WatchEvent, Error> { continuation in
    let engine = Engine(...)
    engine.start(yield: continuation.yield)
    continuation.onTermination = { @Sendable _ in
        engine.stop()
    }
}
```

`onTermination` runs whether the consumer cancels their task, breaks
out of the loop, or the stream finishes naturally. The engine is held
alive by the closure and released when the stream tears down.

---

## 7. Sandbox and Security-Scoped Bookmarks

On iOS and on sandboxed macOS apps, a folder URL obtained via
`NSOpenPanel` or `UIDocumentPickerViewController` only grants access
within a balanced `startAccessingSecurityScopedResource()` /
`stopAccessingSecurityScopedResource()` pair. If the caller forgets
this, the underlying open/`FSEventStreamCreate` call may fail with
EPERM-style errors.

Watcher does **not** manage security scope — that lifecycle belongs
to the caller, who knows where the URL came from. Watcher does
surface the underlying error verbatim so the caller can diagnose.

---

## 8. Why Not Just Poll?

You can `FileManager.contentsOfDirectory` every N seconds and diff.
It works. Why don't we?

- Wastes CPU and wakes the device when nothing has changed.
- Misses brief events (file written and deleted between polls).
- Can't distinguish in-place modification from atomic-replace without
  reading file contents or inodes.
- Latency is bounded by the poll interval, which is awful for UX.

The kernel-backed APIs are strictly better when they're available.
Polling is only a fallback for unsupported platforms or filesystems
(SMB on iOS, for instance) — and we're not adding it in v1.

---

## 9. Glossary

- **Inode** — the kernel's identity for a file; survives renames,
  changes when the file is replaced atomically (e.g., `mv tmp orig`).
- **In-place modification** — opening an existing file and writing to
  it without changing its inode (e.g., a text editor "overwriting in
  place"). Detected by FSEventStream + FileEvents, not by directory-FD
  DispatchSource.
- **Atomic replace** — writing to a temp file and `rename()`-ing it
  over the original. The directory entry now points to a different
  inode; consumers watching the inode lose their target.
- **Debounce** — wait for a quiet period before firing one event.
- **Coalesce** — merge multiple events into one based on type or
  proximity in time.
- **CFArray / CFString** — Core Foundation reference types that bridge
  losslessly to `NSArray` / `NSString` and onward to Swift `Array` /
  `String`. Cheap; preferred over manual C-string handling.
- **FSEventStreamEventId** — a monotonic 64-bit per-device counter
  for FSEvent records. Survives reboots; can be persisted for replay.
