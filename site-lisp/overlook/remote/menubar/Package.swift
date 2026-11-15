// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "overlook-menubar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MenubarCore"),
        .executableTarget(name: "overlook-menubar", dependencies: ["MenubarCore"]),
        .testTarget(name: "MenubarCoreTests", dependencies: ["MenubarCore"]),
    ],
    swiftLanguageModes: [.v6]
)
