// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ds4toolbar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ds4toolbar",
            dependencies: [],
            resources: []
        )
    ]
)
