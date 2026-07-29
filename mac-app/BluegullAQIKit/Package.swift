// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BluegullAQIKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BluegullAQIKit",
            targets: ["BluegullAQIKit"]
        ),
    ],
    targets: [
        .target(
            name: "BluegullAQIKit"
        ),
        .testTarget(
            name: "BluegullAQIKitTests",
            dependencies: ["BluegullAQIKit"]
        ),
    ]
)
