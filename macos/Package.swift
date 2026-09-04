// swift-tools-version: 6.0
import PackageDescription

// The Quick Share transport lives in SwiftPM. The container app (App/) and the
// Finder extension (ShareExtension/) are Xcode targets — an .appex cannot be
// produced by SwiftPM. Both link this package.
//
// Keeping the transport in a package means the encrypted protocol layer stays
// buildable and checkable without launching either user interface.
//
// The assertions live in the `easyshare-selftest` executable so they run in
// the same environment as the package and do not require a UI test host.
let package = Package(
    name: "EasyShareKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EasyShareKit", targets: ["EasyShareKit"]),
        .executable(name: "easyshare-selftest", targets: ["SelfTest"]),
    ],
    dependencies: [
        // Quick Share's wire protocol is protobuf. Pin through SwiftPM rather
        // than checking generated runtime sources into this package.
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.2"),
    ],
    targets: [
        .target(
            name: "EasyShareKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/EasyShareKit",
            // The protobuf definitions are audit inputs; generated Swift lives
            // beside them in Wire/Generated and is compiled.
            exclude: ["Transports/QuickShare/Protos"],
            sources: ["IncomingFilename.swift", "Transports/QuickShare", "Transports/Companion"]
        ),
        .executableTarget(name: "SelfTest", dependencies: ["EasyShareKit"]),
    ],
    // Swift 5 language mode on purpose. The Network.framework callbacks use a
    // serial queue; changing them to strict-concurrency actors is a separate
    // design decision rather than a compiler-settings change.
    swiftLanguageModes: [.v5]
)
