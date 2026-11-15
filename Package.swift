// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VisionScreenRecallKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VisionScreenRecallKit",
            targets: ["VisionScreenRecallKit"]
        )
    ],
    targets: [
        .target(
            name: "VisionScreenRecallKit",
            path: "Sources/VisionScreenRecallKit",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "VisionScreenRecallKitTests",
            dependencies: ["VisionScreenRecallKit"],
            path: "Tests/VisionScreenRecallKitTests"
        )
    ]
)
