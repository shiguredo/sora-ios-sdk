# プライバシーマニフェストを同梱して Required Reason API の利用理由を申告する

- Created: 2026-11-02
- Completed: {YYYY-MM-DD}
- Branch: feature/add-privacy-manifest
- Polished: 2026-11-02
- Priority: Medium

## 目的

Sora iOS SDK は SwiftPM のソースパッケージとして配布され、`Sora` ターゲットの Swift ソースは利用アプリの実行ファイルに静的リンクされる。このため SDK が Required Reason API を利用していると、その利用理由をアプリの `PrivacyInfo.xcprivacy` に申告する責任が利用者に残る。申告が漏れると、2024-05-01 以降は App Store Connect がアプリのアップロードを受け付けない。SDK がプライバシーマニフェストを同梱すれば、利用者がアプリ側で同じカテゴリを申告し忘れる余地を減らせる。

## 現状

`Sora` ターゲットは Required Reason API の「システム起動時刻 API」を 2 種類利用している。

- `Sora/DummyAudioDevice.swift` の `consumePlayoutData(generation:)` と `deliverPCMData(generation:)` が、`AudioTimeStamp.mHostTime` に `mach_absolute_time()` を設定している
- `Sora/ScreenCapture.swift` の `shouldSendVideoFrameWithUptime()` と `markVideoFrameSent(presentationTimestamp:)` が `ProcessInfo.processInfo.systemUptime` でフレーム間隔を測っている

Apple の Required Reason API の一覧では、`ProcessInfo.systemUptime` と `mach_absolute_time()` は `NSPrivacyAccessedAPICategorySystemBootTime` に分類されている。

- `Package.swift` の `Sora` ターゲットの `resources` は `VideoView.xib` のみで、`PrivacyInfo.xcprivacy` を同梱していない
- `WebRTC.xcframework` は同梱の `PrivacyInfo.xcprivacy` で `NSPrivacyAccessedAPICategorySystemBootTime` (`35F9.1` / `8FFB.1`) と `NSPrivacyAccessedAPICategoryFileTimestamp` (`C617.1`) を申告済み。ただしこれは WebRTC フレームワーク自身の利用分で、`Sora` ターゲットの Swift ソースの利用はカバーしない
- `Sora` のソースに他の Required Reason API カテゴリ (UserDefaults / ファイル時刻 / ディスク容量 / キーボード) の利用はない
- `SoraTests` の `systemUptime` 利用は配布物に含まれないため対象外
- Sora iOS SDK は Apple の「プライバシーマニフェストと署名が必要な SDK」の一覧には含まれない。ただし Apple は Required Reason API を利用する SDK にはマニフェストの同梱を求めている

## 設計方針

- `Sora/PrivacyInfo.xcprivacy` を追加し、`NSPrivacyAccessedAPIType` に `NSPrivacyAccessedAPICategorySystemBootTime`、`NSPrivacyAccessedAPITypeReasons` に `35F9.1` と `8FFB.1` を宣言する
  - `35F9.1`: `ScreenCapture` がアプリ内イベント間の経過時間からフレーム間隔を判定する用途
  - `8FFB.1`: `DummyAudioDevice` が AVFAudio 系のコールバックに渡す絶対タイムスタンプを計算する用途
  - 理由コードは実際の用途と一致させる。利用をやめた場合は理由コードも見直す
- `Package.swift` の `Sora` ターゲットの `resources` に `.process("PrivacyInfo.xcprivacy")` を追加する。Apple が Swift パッケージで示している配置方法に従う
- `NSPrivacyTracking` は `false`、`NSPrivacyTrackingDomains` と `NSPrivacyCollectedDataTypes` は空配列にして `WebRTC.xcframework` のマニフェストと揃える。SDK が収集するデータの申告は本 issue の対象外とし、必要なら別 issue で扱う
- 公開 API と挙動は変更しない
- `CHANGES.md` の `## develop` に `[ADD]` として追記する

## 変更対象

- `Sora/PrivacyInfo.xcprivacy` (新規)
- `Package.swift`
- `CHANGES.md`

## 完了条件

- `Sora/PrivacyInfo.xcprivacy` が追加され、`plutil -lint` が成功する
- `Package.swift` の `Sora` ターゲットの `resources` に `PrivacyInfo.xcprivacy` が含まれている
- `make consumer-build SCHEME=ConsumerCore` でビルドした `Sora_Sora.bundle` に `PrivacyInfo.xcprivacy` が含まれ、SystemBootTime の理由が `35F9.1` と `8FFB.1` になっている
- `make fmt-lint` と `make lint` が成功する
- 公開 API が変わらないため `make api-check-fresh` が成功する
- `CHANGES.md` の `## develop` に追記されている

## 解決方法

- `Sora/PrivacyInfo.xcprivacy` を次の内容で追加する

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategorySystemBootTime</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>35F9.1</string>
				<string>8FFB.1</string>
			</array>
		</dict>
	</array>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
</dict>
</plist>
```

- `Package.swift` の `Sora` ターゲットの `resources` を `[.process("VideoView.xib"), .process("PrivacyInfo.xcprivacy")]` にする
- `make consumer-build SCHEME=ConsumerCore` を実行し、生成された `Sora_Sora.bundle` に `PrivacyInfo.xcprivacy` が含まれることを確認する
- `CHANGES.md` の `## develop` に `[ADD]` のエントリを追加する

## 参考

- [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [NSPrivacyAccessedAPIType](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [Adding a privacy manifest to your app or third-party SDK](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [Upcoming third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
