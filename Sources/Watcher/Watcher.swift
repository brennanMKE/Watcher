import Foundation

/// Namespace for package-wide configuration. Not instantiable.
public enum Watcher {
    /// Subsystem used by all file-scope loggers in the package.
    ///
    /// Defaults to the host app's bundle identifier so Watcher logs naturally
    /// sort under the consuming app in Console.app. Configurable at app launch;
    /// should not change after a ``Session`` has been created.
    ///
    /// Marked `nonisolated(unsafe)` because file-scope `Logger` instances
    /// read this once at initialization. The contract is "set once, before
    /// constructing any `Session`" — concurrent mutation is not supported.
    nonisolated(unsafe) public static var logSubsystem: String =
        Bundle.main.bundleIdentifier ?? "Watcher"
}
