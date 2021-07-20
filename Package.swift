// swift-tools-version:5.3

import PackageDescription
import Foundation

let file = "WebRTC-91.4472.9.1/WebRTC.xcframework.zip"

// info.sh を実行する
let buildInfo = Process()
buildInfo.arguments = ["sh", "Sora/info.sh"]
buildInfo.waitUntilExit()

let package = Package(
    name: "Sora",
    platforms: [.iOS(.v12)],
    products: [
        .library(name: "Sora", targets: ["Sora"]),
        .library(name: "WebRTC", targets: ["WebRTC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", .exact( "4.0.4")),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/shiguredo/sora-ios-sdk-specs/releases/download/\(file)",
            checksum: "9cd8261c3c32934e8fd589ab2c2395076ca0b84df56e0cbdcd6982012910ecfb"),
        .target(
            name: "Sora",
            dependencies: ["WebRTC", "Starscream"],
            path: "Sora",
            exclude: ["Info.plist", "info.sh"],
            resources: [.process("info.json"), .process("Sora/VideoView.xib")])
    ]
)
