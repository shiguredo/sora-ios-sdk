// swift-tools-version:6.2

import PackageDescription

// Sora を外部の iOS アプリと同じ形 (通常の SwiftPM package 依存) で import し、
// Swift 6 language mode と warnings-as-errors で compile できるかを検証する consumer package。
// root package の target にはしない (root の scheme 一覧や plugin の対象に影響させないため)。
let package = Package(
  name: "Swift6Consumer",
  platforms: [.iOS(.v14)],
  products: [
    // product を宣言しないと xcodebuild が生成する scheme が package 名だけになり、
    // -scheme ConsumerCore のような指定ができない
    .library(name: "ConsumerCore", targets: ["ConsumerCore"]),
    .library(name: "ConsumerUI", targets: ["ConsumerUI"]),
    .library(name: "ConsumerLegacy", targets: ["ConsumerLegacy"]),
  ],
  dependencies: [
    // name を明示しないと package identity が checkout ディレクトリ名になり、
    // .product(name: "Sora", package: "Sora") の解決に失敗する
    .package(name: "Sora", path: "../..")
  ],
  targets: [
    // nonisolated な文脈の scenario
    .target(
      name: "ConsumerCore",
      dependencies: [
        .product(name: "Sora", package: "Sora"),
        // WebRTC product を consumer が import できることの検証に使う (HandlerCompatibility.swift)
        .product(name: "WebRTC", package: "Sora"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        // nil は「既定 (nonisolated) を使う」の意。nonisolated を明示する API は無い
        .defaultIsolation(nil),
        .treatAllWarnings(as: .error),
      ]
    ),
    // MainActor を既定隔離にした文脈の scenario
    .target(
      name: "ConsumerUI",
      dependencies: [
        .product(name: "Sora", package: "Sora")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .defaultIsolation(MainActor.self),
        .treatAllWarnings(as: .error),
      ]
    ),
    // 非推奨 API を利用しても build できることを検証する scenario
    .target(
      name: "ConsumerLegacy",
      dependencies: [
        .product(name: "Sora", package: "Sora")
      ],
      swiftSettings: [
        // .treatAllWarnings を先、.treatWarning を後に書く。
        // SwiftPM は宣言順に -warnings-as-errors と -Wwarning を並べるため、
        // 逆順にすると deprecation が error になり build できない
        .swiftLanguageMode(.v6),
        .defaultIsolation(nil),
        .treatAllWarnings(as: .error),
        .treatWarning("DeprecatedDeclaration", as: .warning),
      ]
    ),
  ]
)
