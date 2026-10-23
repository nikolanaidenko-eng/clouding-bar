// swift-tools-version:5.5
// For editors and `swift build`; the Makefile builds with swiftc directly.
import PackageDescription

let package = Package(
    name: "CloudingBar",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "CloudingBar", path: "Sources/CloudingBar"),
        .executableTarget(name: "CloudingBarHook", path: "Sources/CloudingBarHook"),
        .executableTarget(name: "CloudingBarTap", path: "Sources/CloudingBarTap"),
        .executableTarget(name: "CloudingBarKey", path: "Sources/CloudingBarKey"),
    ]
)
