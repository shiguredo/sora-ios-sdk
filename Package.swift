// swift-tools-version:5.3

import Foundation
import PackageDescription

let file = "WebRTC-98.4758.0.0/WebRTC.xcframework.zip"

let package = Package(
    name: "Sora",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "Sora", targets: ["Sora"]),
        .library(name: "WebRTC", targets: ["WebRTC"]),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/shiguredo/sora-ios-sdk-specs/releases/download/\(file)",
            checksum: "70d629675279887f3833d08f414d73a156183dd41751519557961512f7eae2e0"
        ),
        .target(
            name: "Sora",
            dependencies: ["WebRTC"],
            path: "Sora",
            exclude: ["Info.plist"],
            resources: [.process("VideoView.xib")]
        ),
    ]
)
