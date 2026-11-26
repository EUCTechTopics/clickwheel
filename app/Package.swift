// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clickwheel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Clickwheel", path: "Sources/Clickwheel")
    ]
)
