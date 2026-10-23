// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Saunter",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Saunter", path: "Sources/Saunter")
    ],
    swiftLanguageModes: [.v5]
)
