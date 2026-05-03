import Foundation
import Dispatch
import os
#if canImport(Darwin)
import Darwin
#endif

nonisolated private let fileLog = Logger(
    subsystem: Watcher.logSubsystem,
    category: "Core.File"
)

/// DispatchSource-backed single-file watcher. Watches one inode for write,
/// delete, rename, and attribute changes.
///
/// State is confined to ``queue`` — a private serial dispatch queue. Public
/// methods (``start(owner:)``, ``stop()``, ``flushKernel()``) hop onto the
/// queue synchronously where needed. Marked `@unchecked Sendable` with
/// queue-confinement as the invariant.
final class FileEngine: Engine, @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var stopped = false
    private weak var owner: EngineOwner?

    init(url: URL) {
        self.url = url
        self.queue = DispatchQueue(
            label: "co.sstools.Watcher.FileEngine",
            qos: .utility
        )
    }

    func start(owner: EngineOwner) throws {
        let path = url.path(percentEncoded: false)
        let fd = path.withCString { open($0, O_EVTONLY) }
        guard fd >= 0 else {
            fileLog.error("open(O_EVTONLY) failed for \(path, privacy: .private)")
            throw WatcherError.streamCreationFailed(url)
        }

        let mask: DispatchSource.FileSystemEvent = [
            .write, .delete, .rename, .attrib, .extend, .revoke
        ]
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: mask,
            queue: queue
        )

        // Sync-set state on our queue so callbacks see consistent values.
        queue.sync {
            self.fileDescriptor = fd
            self.source = source
            self.owner = owner
        }

        source.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        fileLog.notice("file watch started for \(path, privacy: .private)")
    }

    /// Nonisolated, synchronous, idempotent. Safe from any context.
    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            owner = nil
            if let source {
                source.cancel()
            }
            source = nil
            // FD is closed in the cancel handler; do not close it here.
            fileLog.notice("file watch stopped")
        }
    }

    /// DispatchSource has no kernel-level flush analogous to
    /// `FSEventStreamFlushSync`; this is a no-op.
    func flushKernel() {}

    // MARK: - Event handling (runs on `queue`)

    private func handleEvent() {
        guard let source else { return }
        guard !stopped else { return }
        let data = source.data
        let canonical = url
        var batch: [RawEvent] = []
        var rootInvalidated = false
        var fileDeleted = false

        if data.contains(.delete) {
            batch.append(.deleted(canonical))
            fileDeleted = true
        }
        if data.contains(.rename) {
            // Rename of the watched file means the path we hold no longer
            // points at this inode. Signal external invalidation; the
            // session decides how to surface it.
            rootInvalidated = true
        }
        if data.contains(.write) || data.contains(.extend) {
            batch.append(.changed(canonical))
        }
        if data.contains(.attrib) {
            // Metadata-only changes are dropped per PRD §8 mapping.
        }
        if data.contains(.revoke) {
            rootInvalidated = true
        }

        let owner = self.owner
        if !batch.isEmpty {
            Task { [batch] in
                await owner?.didObserve(batch)
            }
        }

        if rootInvalidated {
            // Tear down our side first so no further events fire after the
            // owner sees the teardown signal.
            let url = self.url
            stopInternal()
            Task {
                await owner?.engineDidTearDown(.rootInvalidated(url))
            }
            return
        }

        if fileDeleted {
            // Per PRD §9: single-file delete emits .fileDeleted then
            // finishes the stream cleanly (no throw).
            stopInternal()
            Task {
                await owner?.engineDidTearDown(.clean)
            }
        }
    }

    /// Queue-internal stop. Caller must already be on `queue`.
    private func stopInternal() {
        guard !stopped else { return }
        stopped = true
        owner = nil
        if let source {
            source.cancel()
        }
        source = nil
    }
}
