import Foundation
import Testing
@testable import Watcher

/// Helpers shared by file-engine tests.
enum WatchTestSupport {
    /// Create a fresh empty temp directory and return its URL. Caller is
    /// responsible for cleaning up.
    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("WatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    /// Create an empty regular file at `url`.
    static func touch(_ url: URL) throws {
        try Data().write(to: url)
    }

    /// Drain `events` for up to `deadline` and return everything observed.
    /// Returns early if the stream finishes or throws.
    static func collectEvents(
        from session: Watcher.Session,
        deadline: Duration
    ) async -> (events: [Watcher.Event], thrown: Error?, finished: Bool) {
        var collected: [Watcher.Event] = []
        let task = Task<([Watcher.Event], Error?, Bool), Never> {
            var thrown: Error?
            var finished = false
            do {
                for try await event in session.events {
                    collected.append(event)
                }
                finished = true
            } catch {
                thrown = error
            }
            return (collected, thrown, finished)
        }
        try? await Task.sleep(for: deadline)
        await session.stop()
        return await task.value
    }
}

@Test func fileWatchObservesWrite() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("watched.txt")
    try WatchTestSupport.touch(file)

    var options = Watcher.Options()
    options.throttle = .milliseconds(150)
    let session = try await Watcher.Session(path: file, options: options)

    let collector = Task<[Watcher.Event], Error> {
        var collected: [Watcher.Event] = []
        for try await event in session.events {
            collected.append(event)
            if collected.count >= 1 { break }
        }
        return collected
    }

    // Give the source a moment to be fully resumed before mutating.
    try await Task.sleep(for: .milliseconds(50))
    try "hello".data(using: .utf8)!.write(to: file)
    await session.flush()

    // Wait for at least one event or a small deadline.
    let result = try await withThrowingTaskGroup(of: [Watcher.Event].self) { group in
        group.addTask { try await collector.value }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            return []
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }

    await session.stop()
    #expect(result.contains(where: {
        if case .fileChanged = $0 { return true } else { return false }
    }))
}

@Test func fileWatchEmitsDeletionThenFinishes() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("doomed.txt")
    try WatchTestSupport.touch(file)

    var options = Watcher.Options()
    options.throttle = .milliseconds(150)
    let session = try await Watcher.Session(path: file, options: options)

    // Give the source a moment to start.
    try await Task.sleep(for: .milliseconds(50))

    let consumer = Task<([Watcher.Event], Bool), Error> {
        var collected: [Watcher.Event] = []
        var finished = false
        do {
            for try await event in session.events {
                collected.append(event)
            }
            finished = true
        } catch {
            // Should not throw on a clean delete-then-finish.
            throw error
        }
        return (collected, finished)
    }

    try FileManager.default.removeItem(at: file)
    await session.flush()

    // Wait for the consumer to drain.
    let (events, finished) = try await withThrowingTaskGroup(of: ([Watcher.Event], Bool).self) { group in
        group.addTask { try await consumer.value }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            return ([], false)
        }
        let v = try await group.next()!
        group.cancelAll()
        return v
    }
    #expect(finished, "stream should finish cleanly after a delete")
    #expect(events.contains(where: {
        if case .fileDeleted = $0 { return true } else { return false }
    }))
}

@Test func fileWatchInitFailsForMissingPath() async throws {
    let missing = URL(fileURLWithPath: "/nonexistent/path/that/does/not/exist-\(UUID().uuidString)")
    do {
        _ = try await Watcher.Session(path: missing)
        Issue.record("expected init to throw")
    } catch let error as WatcherError {
        if case .pathNotFound = error {
            // expected
        } else {
            Issue.record("unexpected WatcherError: \(error)")
        }
    }
}

@Test func sessionReleaseFinishesStreamCleanly() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("file.txt")
    try WatchTestSupport.touch(file)

    var session: Watcher.Session? = try await Watcher.Session(path: file)
    let stream = session!.events

    let task = Task<Bool, Error> {
        for try await _ in stream {}
        return true
    }

    try await Task.sleep(for: .milliseconds(50))
    await session?.stop()
    session = nil

    let finished = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask { try await task.value }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            return false
        }
        let v = try await group.next()!
        group.cancelAll()
        return v
    }
    #expect(finished, "consumer should observe a clean finish")
}
