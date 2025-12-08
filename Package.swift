// swift-tools-version:5.3

import Foundation
import PackageDescription

let libwebrtcVersion = "m143.7499.1.0"

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
            path: "WebRTC.xcframework.zip"
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
