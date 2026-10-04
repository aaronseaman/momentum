// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MomentumKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MomentumKit", targets: ["MomentumKit"])
    ],
    targets: [
        .target(name: "MomentumKit"),
        .testTarget(name: "MomentumKitTests", dependencies: ["MomentumKit"])
    ]
)
