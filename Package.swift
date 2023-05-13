// swift-tools-version:5.8

import PackageDescription

let package = Package(
    name: "tca-test-recording",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(
            name: "TestRecording",
            targets: ["TestRecording"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "0.53.0"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/JackYoustra/lumos", branch: "master"),
        .package(url: "https://github.com/philipturner/swift-reflection-mirror", branch: "main"),
        .package(url: "https://github.com/apple/swift-async-algorithms", branch: "main"),
    ],
    targets: [
        .target(
            name: "TestRecording",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "ReflectionMirror", package: "swift-reflection-mirror"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ]
        ),
        .testTarget(
            name: "TestRecordingTests",
            dependencies: [
                "TestRecording",
                .product(name: "Lumos", package: "lumos"),
            ]
        ),
    ]
)
