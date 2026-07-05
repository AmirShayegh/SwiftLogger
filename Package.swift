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
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0")
    ],
    targets: [
        .target(
            name: "Logger",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "LoggerTests",
            dependencies: ["Logger"]
        )
    ]
)
