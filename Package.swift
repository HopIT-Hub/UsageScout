// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "UsageScout",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "UsageScout", targets: ["UsageScout"])
    ],
    targets: [
        .executableTarget(
            name: "UsageScout",
            path: "Sources"
        )
    ]
)
