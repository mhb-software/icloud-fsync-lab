// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LabKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "LabKit", targets: ["LabKit"])],
    dependencies: [
        // The same zip library and version Mix writes `.mix` files with.
        .package(url: "https://github.com/weichsel/ZIPFoundation", exact: "0.9.20")
    ],
    targets: [
        .target(name: "LabKit", dependencies: ["ZIPFoundation"]),
        .testTarget(name: "LabKitTests", dependencies: ["LabKit", "ZIPFoundation"]),
    ]
)
