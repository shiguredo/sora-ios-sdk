// swift-tools-version:5.3

import Foundation
import PackageDescription

let file = "WebRTC-123.6312.3.0/WebRTC.xcframework.zip"

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
            checksum: "cb7b9631bac05f2ab9b15772a63bc88529a05192b0f92c3fcb4f28678ea57fe9"
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
