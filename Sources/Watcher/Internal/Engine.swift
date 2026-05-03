import Foundation

/// A raw event produced by an engine before throttling / dedup / scope
/// filtering is applied. The Session actor receives batches of these and
/// translates them into public ``Event`` values.
enum RawEvent: Sendable, Hashable {
    case added(URL)
    case deleted(URL)
    case changed(URL)
    case refreshRequired(scope: URL)
}

/// Reasons an engine may signal a teardown to its owning Session.
enum EngineTeardown: Sendable {
    /// Clean termination — `events` should `finish()` without throwing.
    case clean
    /// External invalidation (folder root deleted/renamed, single-file root
    /// renamed). Surfaced as ``WatcherError/rootInvalidated(_:)``.
    case rootInvalidated(URL)
}

/// Receiver protocol implemented by ``Session`` so engines can hand work
/// back to the actor without statically referencing it.
protocol EngineOwner: AnyObject, Sendable {
    func didObserve(_ batch: [RawEvent]) async
    func engineDidTearDown(_ reason: EngineTeardown) async
}

/// Common interface for the file and folder engines. Engines own the C
/// resources (FSEventStream / DispatchSource) and a private serial queue;
/// they're instantiated by Session and torn down via ``stop()``.
///
/// Engines must be `@unchecked Sendable`: they expose a `nonisolated`
/// ``stop()`` that's safe to call from any context (including
/// `Session.deinit`), with internal mutable state confined to their own
/// serial dispatch queue.
protocol Engine: AnyObject, Sendable {
    /// Start the underlying watcher. `owner` is captured weakly; engines
    /// must not retain it. Throws on OS-level start failure.
    func start(owner: EngineOwner) throws

    /// Synchronously tear down the underlying watcher. Idempotent; safe
    /// from any context. After return, no callback can fire again.
    func stop()

    /// Force any kernel-buffered events to be dispatched to the engine's
    /// queue. Returns once the dispatch has completed. No-op for engines
    /// without a kernel-level flush.
    func flushKernel()
}
