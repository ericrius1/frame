// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Frame",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "Frame", targets: ["Frame"])],
    targets: [
        .executableTarget(name: "Frame"),
        .testTarget(name: "FrameTests", dependencies: ["Frame"])
    ]
)
