// swift-tools-version:5.3

import Foundation
import PackageDescription

let file = "WebRTC-102.5005.7.6/WebRTC.xcframework.zip"

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
            checksum: "5554e0bb76ee56584d2e3a317dd01a27804dc6411c7ae163cec525c668262a44"
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
