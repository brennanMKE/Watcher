#if os(macOS)
import Foundation
import CoreServices
import Dispatch
import os

nonisolated private let folderLog = Logger(
    subsystem: Watcher.logSubsystem,
    category: "Core.Folder"
)

/// FSEventStream-backed folder watcher. **Stubbed in M2** — the real
/// implementation lands in M3.
///
/// This stub exists so Session compiles on macOS while the file engine is
/// being verified. It throws ``WatcherError/streamCreationFailed(_:)`` from
/// ``start(owner:)`` to keep folder sessions from being silently broken.
final class FolderEngine: Engine, @unchecked Sendable {
    private let url: URL
    private let latency: CFTimeInterval
    private let scope: Options.Scope
    private let depth: Options.Depth

    init(
        url: URL,
        latency: CFTimeInterval,
        scope: Options.Scope,
        depth: Options.Depth
    ) {
        self.url = url
        self.latency = latency
        self.scope = scope
        self.depth = depth
    }

    func start(owner: EngineOwner) throws {
        folderLog.error("FolderEngine is stubbed in M2 — folder watching arrives in M3")
        throw WatcherError.streamCreationFailed(url)
    }

    func stop() {}

    func flushKernel() {}
}
#endif
