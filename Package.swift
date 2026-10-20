// swift-tools-version:6.3

import Foundation
import PackageDescription

let libwebrtcVersion = "m155.8059.4.1"

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
            checksum: "dd76daf2045629e8c56d029ab42cb8041578f0b07d255a7b65a7180239ed5869"
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
            path: "SoraTests",
            swiftSettings: [
                // .treatAllWarnings を先、.treatWarning を後に書く。SwiftPM は宣言順に
                // -warnings-as-errors と -Wwarning を並べるため、逆順にすると後方互換検証の
                // ために参照している非推奨 API の警告 (DeprecatedDeclaration) が error になる
                .treatAllWarnings(as: .error),
                .treatWarning("DeprecatedDeclaration", as: .warning),
            ]
        ),
    ],
    // SDK を Swift 6 言語モードで compile する。SwiftPM で取り込む consumer にも適用される。
    // warnings-as-errors の gate は consumer の compile 条件と衝突するため manifest には置かず、
    // repo の build 経路 (Makefile の build と .github/workflows/build.yml) に置く
    swiftLanguageModes: [.v6]
)
