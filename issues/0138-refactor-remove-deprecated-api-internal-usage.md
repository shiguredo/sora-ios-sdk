# 非推奨化した API を SDK 内部で使い続けないようにする

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/refactor-remove-deprecated-api-internal-usage
- Polished: 2026-09-30

## 目的

SDK が後方互換のために残している非推奨 API `TLSSecurityPolicy` / `ICEServerInfo.tlsSecurityPolicy` を SDK 内部で参照しないようにし、その参照に由来する deprecation 警告をなくす。`Configuration.spotlightEnabled` の内部参照は `0102` で解消済みであり、本 issue はその状態を崩さないことを確認するだけで、宣言も参照も変更しない。

## 現状

- `ICEServerInfo.tlsSecurityPolicy` は `@available(*, deprecated, message: "2027 年中に廃止予定です。Configuration.insecure を使用してください")` 付きの stored property で、既定値に `TLSSecurityPolicy.secure` を持つ。
- その内部参照は 2 か所だけである。`ICEServerSnapshot.init(_ info: ICEServerInfo)` が `info.tlsSecurityPolicy == .insecure` を読み、非推奨でないイニシャライザ `init(urls:userName:credential:)` が `self.tlsSecurityPolicy = .secure` を設定している。非推奨イニシャライザ `init(urls:userName:credential:tlsSecurityPolicy:)` の `self.tlsSecurityPolicy = tlsSecurityPolicy` は、非推奨宣言の内側のため警告にならない。
- `Configuration.spotlightEnabled` は `Configuration.isSpotlightEnabled` へ委譲する非推奨の computed property であり、`Sora/` からの内部参照は無い。`PeerChannel.makeSignalingConnect` は `ConnectionConfigurationSnapshot.isSpotlightEnabled` を読む。
- `ICEServerInfo.nativeValue(insecure:)` / `ICEServerInfo.usesVerifiedTURNTLS` と `TLSSecurityPolicy.nativeValue` / 対応表は `0102` で削除済みであり、`ICEServerSnapshot` 側にだけ判定がある。
- 2026-09-30 の実測 (Xcode 26.6 / Swift 6.3.3) で、`Sora/` を `-swift-version 6` で型検査したときの `DeprecatedDeclaration` は 17 件 / error 0 件である。うち本 issue が対象とするのは 4 件で、内訳は `ICEServerSnapshot.init(_:)` の `tlsSecurityPolicy` と `TLSSecurityPolicy.insecure`、`ICEServerInfo.init(urls:userName:credential:)` の `tlsSecurityPolicy` と `TLSSecurityPolicy.secure` である。残り 13 件は本 issue の対象外である (「スコープ外」)。
- `TestConsumers/Swift6Consumer/Sources/ConsumerLegacy/DeprecatedAPI.swift` が非推奨の `tlsSecurityPolicy` とイニシャライザを意図的に使い、`.github/workflows/consumer-test.yml` の `Check Deprecation Warning` がその deprecation 警告を symbol 名で要求している。非推奨 API を残す契約が CI で固定されている。

## 前提となる issue

完了済み:

- `0065`: `Configuration.insecure` を追加し、`TLSSecurityPolicy` / `ICEServerInfo.tlsSecurityPolicy` を非推奨にした。deprecated API は残し、`Configuration.insecure` を優先する契約を定めた。
- `0102` (完了 2026-09-16): `ICEServerInfo.nativeValue(insecure:)` / `usesVerifiedTURNTLS` を `ICEServerSnapshot` へ移設した。その「設計方針」は `ICEServerSnapshot.isTLSInsecure` を「`0138` の完了時に確定した識別子を使う」として本 issue に委ねており、本 issue はその引き取りである。
- `0108` (完了 2026-09-29): `Sora` target の warnings-as-errors gate を `Makefile` の `build` と `build.yml` に `-warnings-as-errors -Wwarning DeprecatedDeclaration` で入れた。非推奨警告は warning のまま残る契約であり、本 issue はこの gate と降格を変えない。
- `0171` (完了 2026-09-30): `SoraTests` target の warnings-as-errors gate。テストが意図的に参照する非推奨 API の警告は warning のまま残る契約であり、本 issue はこの契約を変えない。

open (着手順を決める相手):

- `0030` (open): `ICEServerInfo.userName` を `username` に改名し、`userName` を非推奨の computed property にする別スコープ。同じ `Sora/ICEServerInfo.swift` の同じ 2 つのイニシャライザを変更するため、`init(urls:userName:credential:)` と `init(urls:userName:credential:tlsSecurityPolicy:)` の本体で競合する。
  - 本 issue を先に実施する。`0030` は本 issue の完了後に develop から分岐し、`init(urls:username:credential:)` へ改名した本体で `self.isTLSInsecure = false` を維持する。逆順にする場合は、本 issue の変更対象を `init(urls:username:credential:)` の本体へ読み替える。
  - `0030` の「現状」と「設計方針」は `0102` の移設より前の記述 (`ICEServerInfo.nativeValue(insecure:)` を変更対象にしている) のままであり、`0030` 側の更新が別途必要である。本 issue は `0030` の記述を変更しない。
  - `0030` は `ICEServerInfo.userName` を非推奨にするため、`ICEServerSnapshot.init(_:)` の `info.userName` の読み取りを `info.username` へ変える作業は `0030` の側が持つ。本 issue はこの行の `userName` に触れず、同じ `self.init(...)` 呼び出しの `isTLSInsecure` 引数だけを変える。
  - `0030` と本 issue はどちらも公開 stored property を computed property に変えるため、それぞれが自分の変更で公開 API baseline を再生成する。同じ commit にまとめない。

## 設計方針

- `ICEServerInfo` に internal な真値 `var isTLSInsecure: Bool` を追加する。`ICEServerSnapshot.isTLSInsecure` と同じ意味と名前を持つ真値である。既定値は持たせず、2 つの designated イニシャライザが必ず設定する (`init(from:)` は `init(urls:userName:credential:)` を通る)。既定値を持たせないのは、新しいイニシャライザを追加したときに真値の設定漏れをコンパイルエラーにするためである。この真値に `@available(*, deprecated)` は付けない (付けると `ICEServerSnapshot` 側の読み取りが非推奨参照になる)。
- `ICEServerInfo.tlsSecurityPolicy` は stored property をやめ、`isTLSInsecure` へ委譲する非推奨の computed property にする。`get` は `isTLSInsecure ? .insecure : .secure`、`set` は `isTLSInsecure = (newValue == .insecure)` とする。`@available(*, deprecated, message:)` の文面と `public` は変えない。この property 自体が非推奨のため、get / set 内の `TLSSecurityPolicy.insecure` / `.secure` の参照は警告にならない。
- 非推奨でないイニシャライザ `init(urls:userName:credential:)` は `self.tlsSecurityPolicy = .secure` をやめ、`self.isTLSInsecure = false` を設定する (`.secure` と同じ意味)。
- 非推奨イニシャライザ `init(urls:userName:credential:tlsSecurityPolicy:)` は引数を `self.isTLSInsecure = (tlsSecurityPolicy == .insecure)` として写す。非推奨プロパティを経由せず真値を直接設定する。
- `ICEServerSnapshot.init(_ info: ICEServerInfo)` は `isTLSInsecure: info.isTLSInsecure` を copy し、`tlsSecurityPolicy` の読み取りをなくす。`ICEServerSnapshot.isTLSInsecure` の doc コメント (現在は真値を `ICEServerInfo.tlsSecurityPolicy` と説明している) と `init(_:)` のコメントを、真値が `ICEServerInfo.isTLSInsecure` にある記述へ更新する。
- 後方互換 (公開 API の読み書きの挙動を変えない)。利用者が `info.tlsSecurityPolicy = .insecure` を代入した場合は computed setter が `isTLSInsecure` を true にし、以後の読み出しも `.insecure` を返す。`ICEServerInfo(...tlsSecurityPolicy: .insecure)` で組み立てた場合も同じ真値になる。この真値を `ICEServerSnapshot` が copy するため、`ICEServerSnapshot.isTLSInsecure` / `usesVerifiedTURNTLS` / `nativeValue(insecure:)` の `tlsCertPolicy` は従来どおり追随する。
- `ICEServerSnapshot.nativeValue(insecure:)` の `tlsCertPolicy` (`insecure || isTLSInsecure` のとき `.insecureNoCheck`、それ以外 `.secure`) と `usesVerifiedTURNTLS` (`isTLSInsecure` なら false、それ以外は `turns:` で始まる URL の有無) の判定は変えない。`ICEServerSnapshot` は `Sendable` のまま `let isTLSInsecure` で持つ。
- `TLSSecurityPolicy` の enum、`ICEServerInfo.tlsSecurityPolicy`、非推奨イニシャライザ、`TestConsumers/Swift6Consumer/Sources/ConsumerLegacy/DeprecatedAPI.swift` と `.github/workflows/consumer-test.yml` の deprecation 検査は変更しない。computed property 化しても symbol 名と deprecation は変わらないため、検査の symbol 一覧はそのままで通る。
- `CHANGES.md` は `## develop` の `### misc` の末尾に次のエントリを追加する (「機能に直接影響しない変更は `### misc`」の規約と `0171` の位置・形式に合わせる。担当者行は実装者の名前にする)。issue 番号は書かない。
  ```
  - [UPDATE] SDK 内部で非推奨 API の `ICEServerInfo.tlsSecurityPolicy` を参照しないようにする
    - `tlsSecurityPolicy` を内部の真値へ委譲する computed property にし、公開 API のシグネチャと読み書きの挙動は変えない。ユーザー影響はない
    - 公開 API baseline を再生成する (ABI dump の宣言属性のみが変わる)
    - @t-miya
  ```
- 公開 API baseline の再生成を同じ変更に含める。`tlsSecurityPolicy` の stored property → computed property は ABI dump の表現を変えるため、`make api-check` の診断か fresh な dump の比較のいずれかで `make api-check-fresh` が失敗する (`make api-check` だけが成功しても baseline の再生成は必要である)。`0177` が `MediaChannel.state` で最小 module を実測したのと同じ制約である (`0180` が引き取った)。
  - 2026-09-30 に最小 module の probe で実測した変更前後の dump の差分は、`tlsSecurityPolicy` の `declAttributes` からの `HasInitialValue` / `HasStorage` の削除、`hasStorage` の削除、getter / setter の `implicit` と `Transparent` の削除だけである。`usr` / `mangledName` / `deprecated` / 型は変わらない。内部に追加する `isTLSInsecure` は dump に現れない。
  - `make api-baseline` の後に `git diff TestConsumers/Swift6Consumer/ApiBaseline/` を読み、差分が上記の `tlsSecurityPolicy` の宣言属性だけであり、他の symbol の追加・削除・変更が無いことを確認する。`iphoneos26.5.info.txt` は同じ内容で再生成されるため差分が出ない (出た場合は Xcode / SDK の不一致として中止する)。
- 公開 stored property を維持したまま baseline を変えずに内部の非推奨参照を消す方法は無いため、computed property 化と baseline 再生成を採用する。検討した別案は次のとおりで、いずれも採用しない。
  - stored property を真値として残すと `ICEServerSnapshot.init(_:)` の読み取りが残り、対象の警告が消えない。
  - stored property と内部 Bool の二重管理は、利用者の `info.tlsSecurityPolicy = .insecure` が内部 Bool へ伝わらず snapshot が古いポリシーを写すため後方互換が壊れる。
  - stored property に `didSet` で内部 Bool を追随させる方式も、`0177` / `0180` が最小 module で実測したとおり getter から `Transparent` が外れて baseline が変わるため、再生成を避けられないうえ真値が 2 つになる。
  - 非推奨宣言の内側では deprecation 警告が出ない性質を使い、internal な非推奨ヘルパー経由で読む方法は警告だけを消せる。非推奨 API を真値として使い続けるため「SDK 内部で非推奨 API を参照しない」という目的に反し、採用しない。

## 変更対象

- `Sora/ICEServerInfo.swift`: internal な `isTLSInsecure` の追加、`tlsSecurityPolicy` の computed property 化、2 つのイニシャライザの内部 Bool 設定への変更、`tlsSecurityPolicy` の doc コメントの更新
- `Sora/ConnectionConfigurationSnapshot.swift`: `ICEServerSnapshot.init(_ info: ICEServerInfo)` の copy 元を `info.isTLSInsecure` へ変更し、`ICEServerSnapshot.isTLSInsecure` と `init(_:)` の doc コメントを更新
- `SoraTests/ConnectionConfigurationSnapshotTests.swift`: `tlsSecurityPolicy` の get / set が内部 Bool と同期することの回帰テストを追加 (「テスト方針」)
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json`: `make api-baseline` による再生成 (同じ変更に含める)
- `CHANGES.md`: `## develop` の `### misc` への追記

## テスト方針

モックやスタブは使用しない。検証環境は Xcode 26.6 / `iphoneos26.5` (現在の `Makefile` の `API_XCODE` / `XCODE_SDK` と一致) とする。

- `Sora/` を `-swift-version 6` で型検査し、`DeprecatedDeclaration` が 17 件から 13 件へ減り、error が 0 件であることを確認する。
  ```
  swiftc -typecheck -swift-version 6 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
    -module-cache-path build/module-cache $(find Sora -name '*.swift') 2>&1 | tee build/0138-typecheck.log
  grep -cE '^Sora/[^ ]+:[0-9]+:[0-9]+: warning:' build/0138-typecheck.log
  ```
- `make build` (scheme `Sora` / iOS device / Release) が成功し、`0108` の `-Wwarning DeprecatedDeclaration` の降格のまま非推奨警告が 17 件から 13 件、error 0 件であることを確認する。`Makefile` / `build.yml` の `OTHER_SWIFT_FLAGS` は変更しない。
- `SoraTests/ConnectionConfigurationSnapshotTests` の既存 `testICEServerSnapshotCopiesPolicyFromICEServerInfo` が、非推奨でないイニシャライザ (`.secure` 相当) と非推奨イニシャライザ (`.insecure`) の写し取り、`usesVerifiedTURNTLS`、`nativeValue(insecure: false).tlsCertPolicy` を検証している。同じ test に次のケースを追加し、computed setter が内部 Bool を書くことと getter が内部 Bool を読むことを固定する。テストの意図は日本語コメントで書く。
  - 非推奨でないイニシャライザで作った `ICEServerInfo` へ `tlsSecurityPolicy = .insecure` を代入すると、`ICEServerSnapshot(info).isTLSInsecure` が true になり、`usesVerifiedTURNTLS` が false、`nativeValue(insecure: false).tlsCertPolicy` が `.insecureNoCheck` になる
  - `ICEServerInfo(...tlsSecurityPolicy: .insecure)` の `tlsSecurityPolicy` が `.insecure` を返す
  - 追加するテストは非推奨 API を意図的に参照するため `SoraTests` の deprecation 警告は増えるが、`0171` の gate はこれを warning のまま残すため build は失敗しない。増加件数は完了条件に含めない。
- `SoraTests` 全体を CI と同じ invocation (`.github/workflows/e2e-test.yml` の `build-for-testing` と `simctl spawn`) で実行し、失敗 0 件であること。
- `make api-baseline` を実行し、`git diff TestConsumers/Swift6Consumer/ApiBaseline/` の差分をレビューする (「設計方針」)。その後 `make api-check-fresh` が成功すること。
- `make consumer-build SCHEME=ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` が成功し、`ConsumerLegacy` の log に `tlsSecurityPolicy` / `TLSSecurityPolicy` / `secure` / `insecure` / `init(urls:userName:credential:tlsSecurityPolicy:)` の deprecation 警告が出続けること。`make consumer-check-negative` が成功すること。
- `make fmt-lint` と `swiftlint lint --strict` が成功すること。
- 退行検出: `ICEServerSnapshot.init(_:)` の copy 元を `info.tlsSecurityPolicy == .insecure` へ戻すと型検査の警告が 4 件増えて 17 件に戻ること、`tlsSecurityPolicy` の setter を `isTLSInsecure` へ書かない実装にすると追加したテストが失敗することを確認する。確認用の変更は commit しない。

## 完了条件

- `ICEServerInfo` に internal な `isTLSInsecure: Bool` があり、`tlsSecurityPolicy` が `isTLSInsecure` へ委譲する非推奨の computed property になっていること。`tlsSecurityPolicy` の `@available(*, deprecated, message:)` の文面、`public`、公開イニシャライザ 2 つのシグネチャが変わっていないこと。
- 非推奨でないイニシャライザが `isTLSInsecure = false` を設定し、非推奨イニシャライザが引数を `isTLSInsecure` へ写していること。
- `Sora/` の内部で非推奨 API を読み書きしている箇所が 0 件であること。`git grep -n 'tlsSecurityPolicy' -- Sora/` のヒットが `Sora/ICEServerInfo.swift` の非推奨宣言・非推奨イニシャライザの引数と doc コメントに限られ、`git grep -n 'spotlightEnabled' -- Sora/` のヒットが `Sora/Configuration.swift` の非推奨宣言と `Sora/Signaling.swift` の `SignalingConnect.spotlightEnabled` (非推奨ではない別プロパティ) に限られること。参照が無いことは次の `DeprecatedDeclaration` の減少で確認する。
- `Sora/` の `DeprecatedDeclaration` が 17 件から 13 件へ減り、error 0 件であること。残る 13 件が「スコープ外」の発生源 (`Configuration.multistreamEnabled` 4 件 / `Configuration.simulcastRid` 1 件 / `MediaChannelHandlers.onDisconnectLegacy` 3 件 / `onReceiveSignaling` 2 件 / iOS SDK 由来 3 件) だけであること。
- `ICEServerInfo.tlsSecurityPolicy` の読み書きと `ICEServerInfo(...tlsSecurityPolicy:)` が従来と同じ値になり、`ICEServerInfo` の JSON 表現 (キー `urls` / `username` / `credential`) が変わらず、`ICEServerSnapshot.nativeValue(insecure:)` の `tlsCertPolicy` と `ICEServerSnapshot` / `WebRTCConfigurationSnapshot` の `usesVerifiedTURNTLS` の判定が変わらないこと。
- 追加した回帰テストを含めて `SoraTests` 全体が失敗 0 件であること。
- `make api-baseline` で再生成した `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` の差分が `tlsSecurityPolicy` の ABI 表現 (`declAttributes` の `HasInitialValue` / `HasStorage`、`hasStorage`、getter / setter の `implicit` / `Transparent`) だけであり、`iphoneos26.5.info.txt` に差分が無く、他の symbol の追加・削除・変更が無いこと。その後に `make api-check-fresh` が成功すること。
- `make build` / `make consumer-build SCHEME=ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` / `make consumer-check-negative` / `make fmt-lint` / `swiftlint lint --strict` が成功すること。
- `CHANGES.md` の `## develop` の `### misc` の末尾に、ユーザー影響がない旨を含む `[UPDATE]` エントリが担当者行付きで追加されていること。

## スコープ外

- `Configuration.multistreamEnabled` (`Configuration.isMultistream` と `makeSignalingConnect`) 4 件、`Configuration.simulcastRid` (`makeSignalingConnect`) 1 件、`MediaChannelHandlers.onDisconnectLegacy` 3 件 / `onReceiveSignaling` 2 件の内部参照。後方互換のための参照または別目的の作業であり、それぞれ別 issue で扱う。本 issue の完了後もこれらの非推奨警告 10 件は残る。
- iOS SDK 由来の deprecation 3 件 (`Sora/Sora.swift` の `allowBluetooth`、`Sora/URLSessionWebSocketChannel.swift` の `kCFStreamPropertyHTTPSProxyHost` / `kCFStreamPropertyHTTPSProxyPort`)。
- `TLSSecurityPolicy` enum、`ICEServerInfo.tlsSecurityPolicy`、非推奨イニシャライザの削除。2027 年中の廃止まで後方互換のため残す。
- `Configuration.spotlightEnabled` の宣言 (非推奨の computed property) の変更。内部参照が無いことを確認するだけで、`Sora/Configuration.swift` は変更しない。
- `SoraTests` が意図的に参照する非推奨 API (`Utilities.Stopwatch` / `Configuration.spotlightEnabled` / `ICEServerInfo` の非推奨イニシャライザ / `Configuration.insecure`) の除去。`0171` の gate が warning のまま残す契約である。
- `0030` の `ICEServerInfo.userName` → `username` の改名と、それに伴う `ICEServerSnapshot.init(_:)` の `userName` 読み取りの変更。
- `0108` の `-Wwarning DeprecatedDeclaration` の削除と gate の強化。非推奨警告が残るため本 issue では行わない。
- `README.md` / `skills/sora-ios-sdk/SKILL.md` の非推奨 API の移行案内の変更。公開 API のシグネチャと deprecation の文面が変わらないため変更しない。

## 解決方法
