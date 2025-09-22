// swift-tools-version:5.3

import Foundation
import PackageDescription

let libwebrtcVersion = "m140.7339.2.2"

let package = Package(
    name: "Sora",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "Sora", targets: ["Sora"]),
        .library(name: "WebRTC", targets: ["WebRTC"]),
    ],
    dependencies: [
        // 開発用依存関係
        // SwfitLint 公式で推奨されている SwfitLintPlugins を利用する
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.58.2")
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/shiguredo-webrtc-build/webrtc-build/releases/download/\(libwebrtcVersion)/WebRTC.xcframework.zip",
            checksum: "72cae5fa2bfecd66ab8d5e7f4234fffb7b50eee869a92cb5671d898025bc41f2"
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
