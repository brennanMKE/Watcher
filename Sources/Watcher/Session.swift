import Foundation
import os

nonisolated private let log = Logger(
    subsystem: Watcher.logSubsystem,
    category: "Session"
)

extension Watcher {

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

    /// One-shot holder for the security-scoped resource. Acquires at init,
    /// releases exactly once via ``SecurityScope/release()`` regardless of
    /// whether ``stop()`` or ``deinit`` runs first.
    private let securityScope: SecurityScope

    /// The throttle window, after clamping to `[150 ms, 5 s]`.
    private let throttle: Duration

    private let engine: any Engine
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation

    /// Buffer of deduplicated events accumulated during the current
    /// throttle window. Set-typed for O(1) dedup; ordered emission is
    /// deferred to a deterministic sort at flush time.
    private var buffer: Set<Event> = []
    /// Insertion-order tracker, parallel to ``buffer``. Maintained so
    /// emission order is stable even though we dedup with a Set.
    private var bufferOrder: [Event] = []
    private var throttleTask: Task<Void, Never>?
    private var didStop = false

    #if os(macOS)
    private let scope: Options.Scope
    private let depth: Options.Depth
    #endif

    /// Watch a folder or a single file.
    ///
    /// **Async.** Init does file I/O (`realpath(3)`, security-scope
    /// negotiation, FSEventStreamCreate/Start) and is `async` so it won't
    /// block the calling thread on slow volumes or extension proxies.
    ///
    /// The supplied `path` is canonicalized via `realpath(3)` at
    /// construction. Throws:
    /// - ``WatcherError/pathNotFound(_:)`` if the path does not exist.
    /// - ``WatcherError/notReadable(_:underlying:)`` for any other
    ///   `realpath` failure (e.g. `EACCES`); the underlying `POSIXError`
    ///   is attached.
    /// - ``WatcherError/streamCreationFailed(_:)`` /
    ///   ``WatcherError/streamStartFailed(_:)`` if the OS rejects the
    ///   watcher.
    /// - ``WatcherError/unsupportedPlatformFeature(_:)`` if the resolved
    ///   path is a directory on a non-macOS platform.
    public init(path: URL, options: Options = .init()) async throws {
        // 1. Acquire security scope first — needed for realpath /
        //    FSEventStreamCreate to succeed in sandboxed apps.
        let scope = SecurityScope(acquiring: path)

        do {
            // 2. Canonicalize.
            let canonical = try PathCanonicalization.canonicalize(path)

            // 3. Probe directory vs file.
            let isDirectory = PathCanonicalization.isDirectory(canonical)

            // 4. Pick engine.
            let engine: any Engine
            if isDirectory {
                #if os(macOS)
                engine = FolderEngine(
                    url: canonical,
                    latency: Self.latencySeconds(options),
                    scope: options.scope,
                    depth: options.depth
                )
                #else
                throw WatcherError.unsupportedPlatformFeature("folder watching")
                #endif
            } else {
                engine = FileEngine(url: canonical)
            }

            // 5. Allocate the AsyncThrowingStream + continuation.
            var continuation: AsyncThrowingStream<Event, Error>.Continuation!
            let stream = AsyncThrowingStream<Event, Error>(
                bufferingPolicy: .unbounded
            ) { c in
                continuation = c
            }

            self.canonicalRoot = canonical
            self.events = stream
            self.continuation = continuation
            self.securityScope = scope
            self.throttle = Self.clampedThrottle(options.throttle)
            self.engine = engine
            #if os(macOS)
            self.scope = options.scope
            self.depth = options.depth
            #endif

            // 6. Start the engine. Engine retains owner weakly via
            //    EngineOwner; passing self does not retain self.
            do {
                try engine.start(owner: self)
            } catch {
                engine.stop()
                continuation.finish()
                scope.release()
                throw error
            }

            log.notice("session started for \(canonical.path, privacy: .private)")
        } catch {
            scope.release()
            throw error
        }
    }

    /// Stop watching and finish the `events` sequence. Idempotent and safe
    /// to call from multiple tasks.
    ///
    /// - Flushes any buffered throttle events to `events` before finishing
    ///   the stream — no events are silently dropped.
    /// - Tears down the FSEventStream / DispatchSource synchronously; after
    ///   this returns, no callback can fire.
    /// - Releases the security-scoped resource if Session acquired it.
    /// - A second call is a no-op.
    public func stop() async {
        guard !didStop else { return }
        didStop = true
        engine.stop()
        throttleTask?.cancel()
        throttleTask = nil
        flushBufferLocked()
        continuation.finish()
        securityScope.release()
        log.notice("session stopped")
    }

    /// Force any pending events to be delivered through ``events`` before
    /// this call returns. Two layers are flushed:
    /// 1. **Kernel.** For folder sessions, calls `FSEventStreamFlushSync`
    ///    so the OS dispatches any events it's batching.
    /// 2. **Throttle buffer.** Yields the deduplicated buffer immediately,
    ///    skipping the remaining throttle wait.
    public func flush() async {
        // 1. Drain the kernel into our queue.
        engine.flushKernel()
        // 2. Give the engine's queue a moment to dispatch the resulting
        //    callback into the actor. Engine→actor is async-Task-based,
        //    so a 0-duration yield is not enough; sleep briefly.
        try? await Task.sleep(for: .milliseconds(20))
        // 3. Flush our own throttle buffer.
        throttleTask?.cancel()
        throttleTask = nil
        flushBufferLocked()
    }

    // MARK: - Engine callback surface (EngineOwner)

    /// Receive a raw batch from the engine. Filters by scope/depth, dedups
    /// against the throttle buffer, schedules a window if none is open.
    func didObserve(_ batch: [RawEvent]) async {
        guard !didStop else { return }
        for raw in batch {
            guard let event = mapToEvent(raw) else { continue }

            switch event {
            case .refreshRequired:
                // Refresh signals bypass throttle and dedup per PRD §8.
                continuation.yield(event)
                continue
            default:
                break
            }

            // Add/Delete cancellation: an incoming `.fileDeleted(url)` whose
            // matching `.fileAdded(url)` is already buffered removes both.
            if case .fileDeleted(let url) = event,
               buffer.contains(.fileAdded(url)) {
                buffer.remove(.fileAdded(url))
                bufferOrder.removeAll { $0 == .fileAdded(url) }
                continue
            }
            if case .fileAdded(let url) = event,
               buffer.contains(.fileDeleted(url)) {
                buffer.remove(.fileDeleted(url))
                bufferOrder.removeAll { $0 == .fileDeleted(url) }
                continue
            }

            if buffer.insert(event).inserted {
                bufferOrder.append(event)
            }
        }

        if !buffer.isEmpty && throttleTask == nil {
            scheduleThrottleWindow()
        }
    }

    /// Engine signaled a teardown. Flush any buffered events, then finish
    /// the stream cleanly or with `.rootInvalidated(_:)`.
    func engineDidTearDown(_ reason: EngineTeardown) async {
        guard !didStop else { return }
        didStop = true
        throttleTask?.cancel()
        throttleTask = nil
        flushBufferLocked()
        switch reason {
        case .clean:
            continuation.finish()
        case .rootInvalidated(let url):
            continuation.finish(throwing: WatcherError.rootInvalidated(url))
        }
        securityScope.release()
        log.notice("session torn down by engine")
    }

    // MARK: - Throttle / mapping (actor-confined)

    private func scheduleThrottleWindow() {
        let throttle = self.throttle
        throttleTask = Task { [weak self] in
            try? await Task.sleep(for: throttle)
            guard let self else { return }
            await self.expireThrottleWindow()
        }
    }

    private func expireThrottleWindow() {
        guard !didStop else { return }
        throttleTask = nil
        flushBufferLocked()
    }

    /// Drain ``buffer`` to the continuation. Caller is responsible for
    /// guarding against re-entry.
    private func flushBufferLocked() {
        guard !bufferOrder.isEmpty else { return }
        for event in bufferOrder {
            continuation.yield(event)
        }
        buffer.removeAll(keepingCapacity: true)
        bufferOrder.removeAll(keepingCapacity: true)
    }

    /// Map a raw engine event to the public ``Event``, applying scope and
    /// depth filtering. Returns nil if the event should be dropped.
    private func mapToEvent(_ raw: RawEvent) -> Event? {
        let event: Event
        switch raw {
        case .added(let url):           event = .fileAdded(url)
        case .deleted(let url):         event = .fileDeleted(url)
        case .changed(let url):         event = .fileChanged(url)
        case .refreshRequired(let url): return .refreshRequired(scope: url)
        }

        #if os(macOS)
        if engine is FolderEngine {
            // Scope filter.
            switch event {
            case .fileAdded, .fileDeleted:
                guard scope.contains(.fileAddedOrDeleted) else { return nil }
            case .fileChanged:
                guard scope.contains(.fileChanged) else { return nil }
            case .refreshRequired:
                break
            }
            // Depth filter.
            if !passesDepthFilter(event) { return nil }
        }
        #endif

        return event
    }

    #if os(macOS)
    private func passesDepthFilter(_ event: Event) -> Bool {
        let url: URL
        switch event {
        case .fileAdded(let u), .fileDeleted(let u), .fileChanged(let u):
            url = u
        case .refreshRequired:
            return true
        }
        let rootComponents = canonicalRoot.pathComponents.count
        let eventComponents = url.pathComponents.count
        let relativeDepth = eventComponents - rootComponents - 1
        switch depth {
        case .infinite:
            return true
        case .immediate:
            return relativeDepth == 0
        case .levels(let n):
            return relativeDepth >= 0 && relativeDepth <= n
        }
    }
    #endif

    // MARK: - Helpers

    private static func clampedThrottle(_ requested: Duration) -> Duration {
        let lo: Duration = .milliseconds(150)
        let hi: Duration = .seconds(5)
        if requested < lo { return lo }
        if requested > hi { return hi }
        return requested
    }

    #if os(macOS)
    private static func latencySeconds(_ options: Options) -> CFTimeInterval {
        let comps = options.latency.components
        return CFTimeInterval(comps.seconds) +
            CFTimeInterval(comps.attoseconds) / 1.0e18
    }
    #endif

    nonisolated deinit {
        // Synchronous teardown — actor's stop() may not have run.
        engine.stop()
        continuation.finish()
        securityScope.release()
    }
}

}  // extension Watcher

// MARK: - EngineOwner conformance

extension Watcher.Session: EngineOwner {}
