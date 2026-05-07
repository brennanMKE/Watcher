#if os(macOS)
import Foundation
import CoreServices
import Dispatch
import os

nonisolated private let folderLog = Logger(
    subsystem: Watcher.logSubsystem,
    category: "Core.Folder"
)

/// FSEventStream-backed folder watcher.
///
/// State is confined to ``queue`` — a private serial dispatch queue. Public
/// methods (``start(owner:)``, ``stop()``, ``flushKernel()``) hop onto the
/// queue synchronously where needed. Marked `@unchecked Sendable` with
/// queue-confinement as the invariant.
///
/// The C callback uses `Unmanaged.passUnretained(self)` to bridge back into
/// Swift. This is safe because ``Session`` retains the engine, and
/// ``stop()`` synchronously drains in-flight callbacks via
/// `FSEventStreamInvalidate` before releasing the stream.
final class FolderEngine: Engine, @unchecked Sendable {
    private let url: URL
    private let latency: CFTimeInterval
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private var stopped = false
    private weak var owner: EngineOwner?

    init(
        url: URL,
        latency: CFTimeInterval,
        scope: Watcher.Options.Scope,
        depth: Watcher.Options.Depth
    ) {
        self.url = url
        self.latency = max(latency, 0)
        // scope and depth are honored by Session as a post-filter; we keep
        // them in the signature for clarity but don't store them here —
        // FSEventStream itself takes neither.
        _ = scope
        _ = depth
        self.queue = DispatchQueue(
            label: "co.sstools.Watcher.FolderEngine",
            qos: .utility
        )
    }

    func start(owner: EngineOwner) throws {
        let path = url.path(percentEncoded: false)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagUseCFTypes
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info else { return }
            let engine = Unmanaged<FolderEngine>.fromOpaque(info).takeUnretainedValue()
            // UseCFTypes is set, so eventPaths is a CFArrayRef of CFStringRef.
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let paths = (cfArray as NSArray).compactMap { $0 as? String }
            engine.handle(count: numEvents, paths: paths, flags: eventFlags)
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            folderLog.error("FSEventStreamCreate returned nil for \(path, privacy: .private)")
            throw WatcherError.streamCreationFailed(url)
        }

        FSEventStreamSetDispatchQueue(s, queue)

        // Sync-set state on our queue so the C callback sees consistent
        // values when it fires.
        queue.sync {
            self.owner = owner
            self.stream = s
        }

        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            queue.sync {
                self.owner = nil
                self.stream = nil
            }
            folderLog.error("FSEventStreamStart returned false for \(path, privacy: .private)")
            throw WatcherError.streamStartFailed(url)
        }

        folderLog.notice("watching \(path, privacy: .private) (latency=\(self.latency, privacy: .public))")
    }

    /// Nonisolated, synchronous, idempotent. Safe from any context.
    /// Sequence: `Stop → Invalidate → Release`. `Invalidate` synchronously
    /// drains in-flight callbacks before returning.
    func stop() {
        queue.sync {
            stopInternal()
        }
    }

    func flushKernel() {
        // Capture stream on the queue for safety, then call FlushSync
        // outside the sync block — FlushSync itself dispatches into our
        // queue and would deadlock if we held it.
        let s: FSEventStreamRef? = queue.sync { stream }
        guard let s else { return }
        FSEventStreamFlushSync(s)
    }

    // MARK: - Event handling (runs on `queue`)

    private func handle(
        count: Int,
        paths: [String],
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        guard !stopped else { return }

        var rootChanged = false
        var refreshScopes: [URL] = []
        var batch: [RawEvent] = []

        for i in 0..<count {
            let flag = flags[i]
            let path = paths.indices.contains(i) ? paths[i] : ""

            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                rootChanged = true
                continue
            }

            // Drop signals — surface as refreshRequired with the watched
            // root as scope. (The kernel doesn't tell us a sub-scope for
            // UserDropped/KernelDropped; for MustScanSubDirs the path
            // *is* the subtree, but we keep one channel.)
            let mustScan = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            let userDrop = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
            let kernelDrop = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
            if mustScan || userDrop || kernelDrop {
                let scope: URL
                if mustScan, !path.isEmpty {
                    scope = URL(fileURLWithPath: path)
                } else {
                    scope = url
                }
                refreshScopes.append(scope)
                continue
            }

            // Skip metadata-only events.
            let dataChange =
                flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0
            guard dataChange else { continue }
            guard !path.isEmpty else { continue }

            let pathURL = URL(fileURLWithPath: path)

            // Renamed: emit as delete + add. Without the cookie pairing
            // we can't tell which side of the rename this path is, but
            // the public contract says rename decomposes into delete+add
            // — emitting both for the same URL is a no-op net (they
            // cancel in the throttle buffer if from the same window).
            // In practice FSEvents fires Renamed twice (once on each
            // side) so each side appears as one .deleted + one .added.
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
                if FileManager.default.fileExists(atPath: path) {
                    batch.append(.added(pathURL))
                } else {
                    batch.append(.deleted(pathURL))
                }
                continue
            }

            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
                batch.append(.added(pathURL))
            }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
                batch.append(.deleted(pathURL))
            }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 {
                // Modified-only on a still-existing file = .changed.
                // If Created and Modified both fired (atomic save), the
                // .added above is already in batch; the .changed here
                // dedupes against it via Set semantics in the actor.
                batch.append(.changed(pathURL))
            }
        }

        let owner = self.owner

        if rootChanged {
            // Tear down our side first so no further events fire.
            let url = self.url
            stopInternal()
            Task {
                await owner?.engineDidTearDown(.rootInvalidated(url))
            }
            return
        }

        // Refresh signals bypass throttle/dedup at the actor — but we do
        // ship them in their own batch so the actor's didObserve can spot
        // them without being interleaved with normal events.
        if !refreshScopes.isEmpty {
            let refreshBatch = refreshScopes.map { RawEvent.refreshRequired(scope: $0) }
            Task { [refreshBatch] in
                await owner?.didObserve(refreshBatch)
            }
        }

        if !batch.isEmpty {
            Task { [batch] in
                await owner?.didObserve(batch)
            }
        }
    }

    /// Queue-internal stop. Caller must already be on `queue`.
    private func stopInternal() {
        guard !stopped else { return }
        stopped = true
        owner = nil
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        folderLog.notice("folder watch stopped")
    }
}
#endif
