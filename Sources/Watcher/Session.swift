import Foundation
import os

nonisolated private let log = Logger(
    subsystem: Watcher.logSubsystem,
    category: "Session"
)

/// A live filesystem watcher. Construction starts watching; release (or
/// `stop()`) tears it down.
///
/// Each session exposes its events through ``events``, an async throwing
/// sequence. The session reference is the lifetime token: dropping it
/// terminates the sequence.
public actor Session {
    /// Async sequence of file-system events.
    ///
    /// - **Finishes cleanly** when the user releases the session or calls
    ///   ``stop()``, and when a single-file session's file is deleted (the
    ///   deletion is emitted as ``Event/fileDeleted(_:)`` first).
    /// - **Throws ``WatcherError/rootInvalidated(_:)``** when the OS tears
    ///   down the watcher externally — folder root deleted or renamed, or
    ///   a single-file root renamed to a new path.
    ///
    /// **Single-consumer.** `AsyncThrowingStream` is a single-iterator
    /// sequence; concurrent iteration from two tasks splits events between
    /// them rather than broadcasting.
    nonisolated public let events: AsyncThrowingStream<Event, Error>

    /// The canonical, symlink-resolved URL the session is watching. Computed
    /// at init via `realpath(3)`; all emitted event URLs are rooted at this
    /// path.
    nonisolated public let canonicalRoot: URL

    /// Construct a session. **Stubbed in M1** — does no I/O; will be filled
    /// in by M2 (file engine) and M3 (folder engine).
    public init(path: URL, options: Options = .init()) async throws {
        self.canonicalRoot = path
        self.events = AsyncThrowingStream<Event, Error> { _ in }
        log.notice("session init (stub) for \(path.path, privacy: .private)")
    }

    /// Stop watching and finish the `events` sequence. **Stubbed in M1.**
    public func stop() async {
        log.notice("session stop (stub)")
    }

    /// Force any pending events to be delivered before this call returns.
    /// **Stubbed in M1.**
    public func flush() async {
        log.notice("session flush (stub)")
    }
}
