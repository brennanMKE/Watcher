// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Watcher",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "Watcher",
            targets: ["Watcher"]
        ),
    ],
    targets: [
        .target(
            name: "Watcher"
        ),
        .testTarget(
            name: "WatcherTests",
            dependencies: ["Watcher"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
