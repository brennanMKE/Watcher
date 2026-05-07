import Foundation

extension Watcher {
    /// Tunables for a ``Session``.
    ///
    /// Cross-platform consumers reference only ``throttle``. Folder-specific
    /// configuration (``scope``, ``depth``, ``latency``) is macOS-only and must
    /// be wrapped in `#if os(macOS)` at the call site.
    public struct Options: Sendable {
        /// Throttle window. Events accumulate during this window; on expiry the
        /// deduplicated batch is yielded to `events`. A new window opens on the
        /// next incoming event (trailing throttle — not debounce — so sustained
        /// load cannot starve the consumer). Clamped internally to
        /// `[150 ms, 5 s]`. Available on all Apple platforms.
        public var throttle: Duration = .milliseconds(150)

        #if os(macOS)
        /// What kinds of changes are reported. Combine ``Scope/fileAddedOrDeleted``
        /// and ``Scope/fileChanged``, or pick one. Default is both.
        /// **macOS-only** — folder watching is unavailable on iOS, tvOS, watchOS,
        /// and visionOS, so this option is compiled out there.
        public var scope: Scope = .all

        /// How deep into the subtree we surface events. Only meaningful when
        /// `path` is a directory; ignored for single-file sessions. **macOS-only.**
        public var depth: Depth = .infinite

        /// Latency hint forwarded to FSEventStream. **macOS-only.**
        public var latency: Duration = .milliseconds(200)
        #endif

        public init() {}

        #if os(macOS)
        public struct Scope: OptionSet, Sendable, Hashable {
            public let rawValue: Int
            public init(rawValue: Int) { self.rawValue = rawValue }

            /// Files added or deleted within the watched tree. (Renames decompose
            /// into a delete + an add and are admitted by this option.)
            public static let fileAddedOrDeleted = Scope(rawValue: 1 << 0)
            /// In-place modifications to existing files within the tree.
            public static let fileChanged        = Scope(rawValue: 1 << 1)

            /// Both kinds. The default; expected to be the common case.
            public static let all: Scope = [.fileAddedOrDeleted, .fileChanged]
        }

        public enum Depth: Sendable, Hashable {
            /// Direct children of the watched path only (depth 0 below root).
            case immediate
            /// Up to N path components below the watched root. ``levels(_:)``
            /// with `0` is equivalent to ``immediate``.
            case levels(Int)
            /// No depth limit — full subtree. (Default.)
            case infinite
        }
        #endif
    }
}
