// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [
        .macOS("14.2")
    ],
    dependencies: [
        .package(url: "https://github.com/makeusabrew/audiotee.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: [
                .product(name: "AudioTeeCore", package: "audiotee"),
            ],
            path: "Sources/MeetingRecorder"
        ),
    ]
)
