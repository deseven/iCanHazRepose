// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "iCanHazRepose",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "iCanHazRepose",
            dependencies: [],
            path: "src"
        ),
    ]
)
