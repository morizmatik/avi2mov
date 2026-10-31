// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "avi2mov",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AVIConvert", targets: ["AVIConvert"]),
        .executable(name: "avi2mov", targets: ["avi2mov"]),
    ],
    targets: [
        .target(name: "AVIConvert"),
        .executableTarget(name: "avi2mov", dependencies: ["AVIConvert"]),
    ]
)
