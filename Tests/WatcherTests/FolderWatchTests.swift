#if os(macOS)
import Foundation
import Testing
@testable import Watcher

/// Wait for the consumer task to surface at least one event matching
/// `predicate`, or time out. Returns all events seen up to that point.
private func waitForEvents(
    on session: Session,
    matching predicate: @escaping @Sendable (Event) -> Bool,
    timeout: Duration = .seconds(3)
) async -> [Event] {
    let stream = session.events
    return await withTaskGroup(of: [Event]?.self) { group in
        group.addTask {
            var collected: [Event] = []
            do {
                for try await event in stream {
                    collected.append(event)
                    if predicate(event) { return collected }
                }
                return collected
            } catch {
                return collected
            }
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next()!
        group.cancelAll()
        return first ?? []
    }
}

@Test func folderWatchObservesFileCreation() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    var options = Options()
    options.throttle = .milliseconds(150)
    let session = try await Session(path: dir, options: options)

    // Let FSEventStream warm up before mutating.
    try await Task.sleep(for: .milliseconds(150))

    let file = dir.appendingPathComponent("created.txt")
    Task {
        try? "hello".data(using: .utf8)!.write(to: file)
        await session.flush()
    }

    let events = await waitForEvents(on: session, matching: { event in
        if case .fileAdded = event { return true } else { return false }
    })
    await session.stop()
    #expect(events.contains(where: {
        if case .fileAdded = $0 { return true } else { return false }
    }), "expected a fileAdded event; saw \(events)")
}

@Test func folderWatchObservesInPlaceModification() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("existing.txt")
    try "v1".data(using: .utf8)!.write(to: file)

    var options = Options()
    options.throttle = .milliseconds(150)
    let session = try await Session(path: dir, options: options)

    try await Task.sleep(for: .milliseconds(200))

    Task {
        try? await Task.sleep(for: .milliseconds(50))
        try? "v2-now-longer".data(using: .utf8)!.write(to: file)
        await session.flush()
    }

    let events = await waitForEvents(on: session, matching: { event in
        if case .fileChanged = event { return true } else { return false }
    })
    await session.stop()
    #expect(events.contains(where: {
        if case .fileChanged = $0 { return true } else { return false }
    }), "expected a fileChanged event; saw \(events)")
}

@Test func folderWatchScopeFilterDropsModifications() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("existing.txt")
    try "v1".data(using: .utf8)!.write(to: file)

    var options = Options()
    options.throttle = .milliseconds(150)
    options.scope = .fileAddedOrDeleted   // exclude .fileChanged
    let session = try await Session(path: dir, options: options)

    try await Task.sleep(for: .milliseconds(200))

    Task {
        // In-place modification — should be filtered out by scope.
        try? "v2-modified".data(using: .utf8)!.write(to: file)
        try? await Task.sleep(for: .milliseconds(150))
        // New file — should pass.
        try? "x".data(using: .utf8)!.write(to: dir.appendingPathComponent("new.txt"))
        await session.flush()
    }

    let events = await waitForEvents(on: session, matching: { event in
        if case .fileAdded = event { return true } else { return false }
    })
    await session.stop()
    #expect(events.contains(where: {
        if case .fileAdded = $0 { return true } else { return false }
    }), "expected fileAdded; saw \(events)")
    #expect(!events.contains(where: {
        if case .fileChanged = $0 { return true } else { return false }
    }), "scope filter should have suppressed fileChanged; saw \(events)")
}

@Test func folderWatchDepthImmediateExcludesNestedEvents() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let nestedDir = dir.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)

    var options = Options()
    options.throttle = .milliseconds(150)
    options.depth = .immediate
    let session = try await Session(path: dir, options: options)

    try await Task.sleep(for: .milliseconds(200))

    Task {
        // Nested file — should be filtered out by depth.
        try? "nested".data(using: .utf8)!.write(to: nestedDir.appendingPathComponent("buried.txt"))
        try? await Task.sleep(for: .milliseconds(150))
        // Top-level file — should pass.
        try? "top".data(using: .utf8)!.write(to: dir.appendingPathComponent("top.txt"))
        await session.flush()
    }

    let events = await waitForEvents(on: session, matching: { event in
        if case .fileAdded(let url) = event,
           url.lastPathComponent == "top.txt" { return true }
        return false
    })
    await session.stop()
    #expect(events.contains(where: {
        if case .fileAdded(let url) = $0,
           url.lastPathComponent == "top.txt" { return true }
        return false
    }), "expected top-level fileAdded for top.txt; saw \(events)")
    #expect(!events.contains(where: {
        if case .fileAdded(let url) = $0,
           url.lastPathComponent == "buried.txt" { return true }
        return false
    }), "depth filter should have suppressed buried.txt; saw \(events)")
}

@Test func folderWatchInvalidatesOnRootDeletion() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    // We'll delete `dir` ourselves; defer-cleanup is best-effort.
    var options = Options()
    options.throttle = .milliseconds(150)
    let session = try await Session(path: dir, options: options)

    let consumer = Task<Error?, Never> {
        do {
            for try await _ in session.events {}
            return nil
        } catch {
            return error
        }
    }

    try await Task.sleep(for: .milliseconds(200))
    try? FileManager.default.removeItem(at: dir)

    let result = await withTaskGroup(of: Error??.self) { group in
        group.addTask { await consumer.value }
        group.addTask {
            try? await Task.sleep(for: .seconds(5))
            return nil
        }
        let v = await group.next()!
        group.cancelAll()
        return v
    }

    if let error = result as? WatcherError {
        if case .rootInvalidated = error {
            // expected
        } else {
            Issue.record("unexpected WatcherError: \(error)")
        }
    } else if result == nil {
        Issue.record("expected rootInvalidated; consumer never threw")
    }
}

@Test func folderWatchInitFailsForMissingPath() async throws {
    let missing = URL(fileURLWithPath: "/var/empty/no-such-dir-\(UUID().uuidString)")
    do {
        _ = try await Session(path: missing)
        Issue.record("expected init to throw")
    } catch let error as WatcherError {
        if case .pathNotFound = error {
            // expected
        } else {
            Issue.record("unexpected WatcherError: \(error)")
        }
    }
}

@Test func sessionCanonicalizesSymlinkRoot() async throws {
    let realDir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: realDir) }
    let linkDir = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("WatcherSymlink-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
    defer { try? FileManager.default.removeItem(at: linkDir) }

    let session = try await Session(path: linkDir)
    let canonical = session.canonicalRoot
    await session.stop()
    let realCanonical = try PathCanonicalization.canonicalize(realDir)
    #expect(canonical.path == realCanonical.path)
}
#endif
