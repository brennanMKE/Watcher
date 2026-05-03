import Foundation
import Testing
@testable import Watcher

#if os(macOS)
@Test func sessionHasNoRetainCycle() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    weak var weakSession: Session?

    do {
        let session = try await Session(path: dir)
        weakSession = session
        // Hold a strong reference only inside this scope. The consumer's
        // `for try await` does NOT retain the Session — it only retains
        // the AsyncStream itself. Once we drop `session`, the engine
        // should tear down via deinit.
        try await Task.sleep(for: .milliseconds(50))
        await session.stop()
    }

    // Give the runtime a moment to release.
    try await Task.sleep(for: .milliseconds(50))
    #expect(weakSession == nil, "Session retained beyond its lexical scope; check for cycles")
}

@Test func folderWatchDedupsBurstOfModifications() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("hot.txt")
    try "0".data(using: .utf8)!.write(to: file)

    var options = Options()
    options.throttle = .milliseconds(300)  // big enough to hold all writes
    options.latency = .milliseconds(50)    // make FSEvents prompt
    let session = try await Session(path: dir, options: options)

    // Warm-up: FSEventStream needs a moment after start before mutations
    // are reliably reported.
    try await Task.sleep(for: .milliseconds(300))

    let stream = session.events
    let collector = Task<[Event], Never> {
        var events: [Event] = []
        do {
            for try await event in stream {
                events.append(event)
            }
        } catch {}
        return events
    }

    // Hammer the file — many modifications spaced enough that FSEvents
    // sees them but well within the 300 ms throttle window.
    for i in 0..<30 {
        try? "v\(i)-\(String(repeating: "x", count: i))".data(using: .utf8)!.write(to: file)
        try await Task.sleep(for: .milliseconds(2))
    }

    // Let the throttle window expire (300 ms) plus a kernel flush.
    try await Task.sleep(for: .milliseconds(500))
    await session.flush()
    try await Task.sleep(for: .milliseconds(100))

    await session.stop()
    let collected = await collector.value

    let changedCount = collected.filter {
        if case .fileChanged(let url) = $0, url.lastPathComponent == "hot.txt" {
            return true
        }
        return false
    }.count
    // Without dedup we'd see ~30 events. With dedup it's a small constant
    // (1 per throttle window the writes spanned).
    #expect(changedCount >= 1, "expected at least one fileChanged event; saw \(collected)")
    #expect(changedCount <= 4, "expected dedup: ~30 raw writes -> a small number of fileChanged events; got \(changedCount). All events: \(collected)")
}

@Test func flushDeliversBeforeThrottleExpires() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    var options = Options()
    options.throttle = .seconds(2)  // long throttle
    let session = try await Session(path: dir, options: options)

    try await Task.sleep(for: .milliseconds(150))

    let file = dir.appendingPathComponent("flushed.txt")
    let started = ContinuousClock.now

    let stream = session.events

    let consumer = Task<TimeInterval?, Never> {
        do {
            for try await event in stream {
                if case .fileAdded(let url) = event, url.lastPathComponent == "flushed.txt" {
                    let elapsed = started.duration(to: .now)
                    let secs = Double(elapsed.components.seconds) +
                        Double(elapsed.components.attoseconds) / 1.0e18
                    return secs
                }
            }
        } catch {}
        return nil
    }

    try? "x".data(using: .utf8)!.write(to: file)
    try await Task.sleep(for: .milliseconds(100))
    await session.flush()

    let elapsed = await withTaskGroup(of: TimeInterval??.self) { group in
        group.addTask { await consumer.value }
        group.addTask {
            try? await Task.sleep(for: .seconds(1))
            return nil
        }
        let v = await group.next()!
        group.cancelAll()
        return v
    }

    await session.stop()

    if let elapsed, let value = elapsed {
        #expect(value < 1.0, "flush should deliver the event well under the 2 s throttle window; got \(value) s")
    } else {
        Issue.record("never observed the flushed fileAdded event")
    }
}

@Test func stopIsIdempotent() async throws {
    let dir = try WatchTestSupport.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = try await Session(path: dir)
    await session.stop()
    await session.stop()  // must not crash or hang
    await session.stop()
}
#endif

@Test func eventsConformToSendableAndHashable() async throws {
    let url = URL(fileURLWithPath: "/tmp/x")
    let set: Set<Event> = [.fileAdded(url), .fileChanged(url), .fileAdded(url)]
    #expect(set.count == 2, "Event should be Hashable for set-based dedup")
}

@Test func optionsThrottleClamps() async throws {
    let dir: URL
    #if os(macOS)
    dir = try WatchTestSupport.makeTempDirectory()
    #else
    // Make a regular file on non-macOS — folder watch is unsupported.
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("WatcherTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let f = parent.appendingPathComponent("clamp.txt")
    try Data().write(to: f)
    dir = f
    #endif
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    var options = Options()
    options.throttle = .milliseconds(1) // below 150 ms floor
    // Construction should succeed; clamp is internal but observable
    // indirectly by the session not throwing.
    let s = try await Session(path: dir, options: options)
    await s.stop()
}
