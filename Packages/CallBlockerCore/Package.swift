// swift-tools-version:5.7
import PackageDescription

// Pure-Swift core (no UIKit / CallKit / SQLite) so it can be unit-tested with
// `swift test` on macOS or Linux, and linked into both the app and the extension.
let package = Package(
    name: "CallBlockerCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "CallBlockerCore", targets: ["CallBlockerCore"]),
    ],
    targets: [
        .target(name: "CallBlockerCore"),
        .testTarget(name: "CallBlockerCoreTests", dependencies: ["CallBlockerCore"]),
    ]
)
