import Foundation

/// Errors thrown by ``Session`` initialization or surfaced through the
/// `events` async sequence on OS-initiated teardown.
public enum WatcherError: Error, Sendable {
    /// The supplied path does not exist (resolved through `realpath(3)`).
    case pathNotFound(URL)
    /// The supplied path is not readable. The underlying POSIX error is
    /// attached when available.
    case notReadable(URL, underlying: Error?)
    /// `FSEventStreamCreate` returned `nil` or `open(O_EVTONLY)` failed.
    case streamCreationFailed(URL)
    /// `FSEventStreamStart` returned `false`.
    case streamStartFailed(URL)
    /// The requested feature is not available on this platform — for
    /// example, folder watching on iOS / tvOS / watchOS / visionOS.
    case unsupportedPlatformFeature(String)
    /// The watcher was torn down externally — folder root was deleted or
    /// renamed, or a single-file root was renamed. Thrown into `events`.
    case rootInvalidated(URL)
}
