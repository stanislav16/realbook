// swift-tools-version: 5.10
import PackageDescription

// The native Mac app. It runs RealBook's Python server without a window (realbook/engine.py) and shows
// everything itself. Build with packaging/build_app.sh.
let package = Package(
    name: "RealBook",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "RealBook", path: "Sources/RealBook")]
)
