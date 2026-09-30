// swift-tools-version:6.3

import Foundation
import PackageDescription

let libwebrtcVersion = "m154.8037.1.2"

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
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.0")
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/shiguredo-webrtc-build/webrtc-build/releases/download/\(libwebrtcVersion)/WebRTC.xcframework.zip",
            checksum: "2bf03aebd16a4f1fe01c662e21b2e6299c3fdd2f271a1fbc9c9ca20ad7f88acf"
        ),
        .target(
            name: "Sora",
            dependencies: ["WebRTC"],
            path: "Sora",
            exclude: ["Info.plist"],
            resources: [.process("VideoView.xib")]
        ),
        .testTarget(
            name: "SoraTests",
            dependencies: ["Sora"],
            path: "SoraTests"
        ),
    ],
    // SDK を Swift 6 言語モードで compile する。SwiftPM で取り込む consumer にも適用される。
    // warnings-as-errors の gate は consumer の compile 条件と衝突するため manifest には置かず、
    // repo の build 経路 (Makefile の build と .github/workflows/build.yml) に置く
    swiftLanguageModes: [.v6]
)
