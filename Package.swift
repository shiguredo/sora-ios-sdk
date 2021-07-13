// swift-tools-version:5.3

import PackageDescription

let file = "WebRTC-91.4472.9.1/WebRTC.xcframework.zip"

let package = Package(
    name: "Sora",
    platforms: [.iOS(.v10)],
    products: [
        .library(name: "Sora", targets: ["Sora"]),
        .library(name: "WebRTC", targets: ["WebRTC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", .exact( "3.1.1")),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/shiguredo/sora-ios-sdk-specs/releases/download/\(file)",
            checksum: "1951c3e83259a28f594b0447565c6284cd6a281639492179799428e17e1da325"),
        .target(
            name: "Sora",
            dependencies: ["WebRTC", "CoreGraphics", "Starscream"],
            path: "Sora"),
    ]
)
