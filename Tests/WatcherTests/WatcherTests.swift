import Foundation
import Testing
@testable import Watcher

@Test func publicAPISmoke() async throws {
    // Public types are visible and constructible.
    var options = Options()
    options.throttle = .milliseconds(200)

    // Event is Hashable + Sendable + has the documented cases.
    let url = URL(fileURLWithPath: "/tmp")
    let added: Event = .fileAdded(url)
    let deleted: Event = .fileDeleted(url)
    let changed: Event = .fileChanged(url)
    let refresh: Event = .refreshRequired(scope: url)
    #expect(added != deleted)
    #expect(changed != refresh)

    // Errors compile.
    let _: WatcherError = .pathNotFound(url)

    // Watcher namespace.
    #expect(!Watcher.logSubsystem.isEmpty)
}
