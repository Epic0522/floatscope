// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FloatScope",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "FloatScope", targets: ["FloatScope"])
    ],
    targets: [
        .executableTarget(
            name: "FloatScope",
            path: "Sources/FloatScope"
        )
    ]
)
