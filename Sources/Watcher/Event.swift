import Foundation

/// A file-system event surfaced by a ``Session``.
///
/// Events are the public, normalized representation of native FSEvent /
/// DispatchSource signals. The `URL`s carried by each case are rooted at
/// the session's ``Session/canonicalRoot`` (i.e., already resolved through
/// `realpath(3)`).
public enum Event: Sendable, Hashable {
    /// A file or directory appeared inside the watched scope.
    case fileAdded(URL)
    /// A file or directory was removed from the watched scope.
    case fileDeleted(URL)
    /// An existing file's contents were modified in place.
    case fileChanged(URL)
    /// The kernel signaled it dropped events under this scope — the consumer
    /// should rescan to reconcile. Edge case under heavy load (e.g. unzipping
    /// a large archive into the watched tree); in normal use this case never
    /// fires.
    case refreshRequired(scope: URL)
}
