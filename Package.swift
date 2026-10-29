// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FocusTrace",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FocusTrace", targets: ["FocusTrace"])],
    targets: [
        .target(name: "TrackingCore"),
        .executableTarget(name: "FocusTrace", dependencies: ["TrackingCore"]),
        .testTarget(name: "TrackingCoreTests", dependencies: ["TrackingCore"]),
        .testTarget(name: "FocusTraceTests", dependencies: ["FocusTrace"])
    ]
)
