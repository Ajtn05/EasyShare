// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyShareKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EasyShareKit", targets: ["EasyShareKit"]),
        .executable(name: "easyshare-selftest", targets: ["SelfTest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.2"),
    ],
    targets: [
        .target(
            name: "EasyShareKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/EasyShareKit",
            exclude: ["Transports/QuickShare/Protos"],
            sources: ["IncomingFilename.swift", "Transports/QuickShare", "Transports/Companion"]
        ),
        .executableTarget(name: "SelfTest", dependencies: ["EasyShareKit"]),
    ],
    swiftLanguageModes: [.v5]
)
