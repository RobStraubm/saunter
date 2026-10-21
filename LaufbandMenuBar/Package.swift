// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LaufbandMenuBar",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "LaufbandMenuBar", path: "Sources/LaufbandMenuBar")
    ],
    swiftLanguageModes: [.v5]
)
