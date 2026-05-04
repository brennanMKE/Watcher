import Foundation

/// One-shot holder for a security-scoped resource. Calls
/// `startAccessingSecurityScopedResource()` at init when requested and
/// guarantees a single matching `stopAccessingSecurityScopedResource()`
/// call regardless of how many times ``release()`` is invoked.
///
/// Marked `@unchecked Sendable` because the only mutable state is an
/// `os_unfair_lock`-protected `Bool`.
final class SecurityScope: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var released: Bool

    /// Try to acquire the scope. If `url.startAccessingSecurityScopedResource()`
    /// returns `false`, this holder no-ops on release.
    init(acquiring url: URL) {
        if url.startAccessingSecurityScopedResource() {
            self.url = url
            self.released = false
        } else {
            self.url = nil
            self.released = true
        }
    }

    /// Idempotent. Calls `stopAccessingSecurityScopedResource()` exactly
    /// once if the scope was actually acquired.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        url?.stopAccessingSecurityScopedResource()
    }

    deinit {
        // Final safety net for code paths that bypass release().
        release()
    }
}
