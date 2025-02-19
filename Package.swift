// swift-tools-version:5.3

import Foundation
import PackageDescription

let file = "WebRTC-132.6834.5.7/WebRTC.xcframework.zip"

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
            url: "https://github.com/zztkm/webrtc-build/releases/download/m133.6943.zztkm.test.2/WebRTC.xcframework.zip",
            checksum: "34f400349619dbeb7f4221810e06c6f729b3603907631a170fab459d0015fce4"
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
