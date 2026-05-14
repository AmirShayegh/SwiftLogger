// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Logger",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Logger",
            targets: ["Logger"]
        )
    ],
    targets: [
        .target(
            name: "Logger"
        ),
        .testTarget(
            name: "LoggerTests",
            dependencies: ["Logger"]
        )
    ]
)
