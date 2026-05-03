import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Internal helpers for canonicalizing paths via `realpath(3)`.
enum PathCanonicalization {
    /// Resolve `url` through `realpath(3)`. Returns the canonical URL on
    /// success.
    ///
    /// Throws ``WatcherError/pathNotFound(_:)`` for `ENOENT`, otherwise
    /// ``WatcherError/notReadable(_:underlying:)`` carrying the underlying
    /// `POSIXError`.
    static func canonicalize(_ url: URL) throws -> URL {
        let path = url.path(percentEncoded: false)
        return try path.withCString { cpath -> URL in
            guard let resolved = realpath(cpath, nil) else {
                let err = errno
                if err == ENOENT {
                    throw WatcherError.pathNotFound(url)
                }
                let posix = POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
                throw WatcherError.notReadable(url, underlying: posix)
            }
            defer { free(resolved) }
            let resolvedString = String(cString: resolved)
            return URL(fileURLWithPath: resolvedString)
        }
    }

    /// Test whether `url` is a directory. Assumes the URL is already
    /// resolved through `realpath(3)`. Returns `false` for any path that
    /// cannot be `stat`'d (the caller's prior `realpath` call should have
    /// caught those cases).
    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        let path = url.path(percentEncoded: false)
        let result = path.withCString { stat($0, &info) }
        guard result == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }
}
