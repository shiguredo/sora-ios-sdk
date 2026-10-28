# ログと文字列表現からシークレットが漏れないようにする

- Created: 2026-09-15
- Completed: 2026-10-28
- Priority: Medium
- Branch: feature/fix-secret-masking
- Polished: 2026-10-27

## 目的

利用者が設定した TURN の認証情報 (`username` と `credential`) が、ログ出力と文字列表現から平文で漏れないようにする。

ログはサポートや障害調査のために共有されることがあり、認証情報が含まれると TURN サーバーの不正利用につながる。

## 現状

### マスク処理

`Sora/Logger.swift` の `secretKeys` は `access_token` / `token` / `secret` / `authorization` / `credential` の 5 キーを対象に、`"key"\s*:\s*"[^"]*"` を `"key": "***"` へ置換する (`secretPatterns` / `maskSecrets`)。`credential` は覆われているが `username` は対象外である。

正規表現はエスケープされていない JSON の `"key":"value"` (キーと値の間の空白の有無は問わない) にのみ一致する。`\"key\":\"value\"` のようにバックスラッシュでエスケープされたキーには一致しない。

`maskSecrets` は `private static` のため、直接呼ぶ単体テストは追加できない。マスクは `Logger.output(log:)` の出力経路で 1 回だけ適用され、`onOutputHandler` へ渡す `Log` と `print` する文字列の両方がマスク済みになる。

### 漏えい経路

1. `Sora/ICEServerInfo.swift` の `description` は `JSONEncoder` の出力をそのまま返す `CustomStringConvertible` の公開実装で、`username` と `credential` を含む。`Logger` を通さない文字列化 (利用者の `print`、`os_log`、クラッシュレポート、独自ログ基盤) では平文になる。`CustomStringConvertible` への準拠は公開 API baseline (`TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json`) に記録されている。
2. `Sora/PeerChannel.swift` の `createAndSendAnswer(offer:)` は offer 受信時に `config.iceServerInfos` を debug ログへ `"ICE server infos => \(config.iceServerInfos)"` として出力する。`[ICEServerInfo]` の文字列表現は各要素の `description` を使うため、`Logger` 経由のマスクでは `credential` はマスクされるが `username` は残る。
3. `Sora/URLSessionWebSocketChannel.swift` の `handleReceiveResult(_:)` は受信した `URLSessionWebSocketTask.Message` を `Logger.debug` へ `"[\(host)] receive message => \(message)"` の形で出力する。`message` の文字列表現は `.string` の場合 `string("{\"iceServers\":[{\"username\":\"...\",\"credential\":\"...\"}]}")` となり、JSON がエスケープされて文字列リテラルへ埋め込まれる。`maskSecrets` の正規表現はエスケープされたキーに一致しないため、この経路では `credential` も `username` もマスクされない。経路 2 と経路 3 で扱いが変わることは、現行の `maskSecrets` と同じ正規表現を同じ入力に適用した実行でも確認済みである。起票時には実機のログでも、同じ TURN の `credential` が経路 2 では `***` にマスクされ、この経路では平文で出力されることを確認している (`username` も平文)。
4. `Sora/SignalingChannel.swift` の `connect(handler:)` は `urlCandidates` を `Logger.info` へ出力し、続けて各候補について `connecting to \(String(describing: ws.url))` も `Logger.info` へ出力する。`redirect(location:)` は `try redirecting to \(location)` を debug ログへ、`URL(string:)` に失敗した場合は `invalid message: \(location)` を error ログへ出力する。URL に userinfo (`wss://user:pass@host` 形式) が含まれる場合、マスクの正規表現に一致しないため平文で残る。既定設定 (`level = .info`、`groups = [.channels, .user]`) でも `urlCandidates` と `connecting to` は出力される。

### テストの現状

`SoraTests/LoggerTests.swift` の `testMaskingAndOutputFormatUnchanged` が、`secretKeys` の 5 キーのマスクと `Log.description` の出力形式を検証している。同テストは「キーを追加した場合は、このテストの対象へ含めるかをそのとき判断します」とコメントしており、`username` 追加時の判断をここで行うことになっている。`username` を追加しても入力に `username` が無いため、このテストは更新しなくても成功する。

次の挙動を検証するテストは存在しない。

- `username` のマスク
- エスケープされた JSON に対するマスク
- JSON 以外の形式に対するマスク
- `ICEServerInfo.description` のマスク
- URL の userinfo の除去

## 設計方針

### マスク処理

- `Logger` の `secretKeys` に対象キー `username` を追加する。
- エスケープされた JSON でもマスクが効くようにする。マスクは `Logger.maskSecrets` に集約したまま、対象パターンに非エスケープ形 (`"key":"value"`) とエスケープ形 (`\"key\":\"value\"`) の 2 種類を持たせる。
- ログの組み立て側 (`URLSessionWebSocketChannel` の受信メッセージの出力など) でマスク済みの文字列を作る方式は採らない。ログの経路が増えるたびに適用漏れが起き、マスクの正しさを 1 箇所で保証できなくなるためである。
- エスケープ形のマスクは、メッセージのエスケープを解いたり組み直したりせず、エスケープされたままの表記で対象キーの値だけを `***` に置き換える。ログの他の部分の表記を変えないためである。
- `maskSecrets` の可視性は変えない (`private static` のまま)。検証は既存テストと同じく `Logger.output(log:)` 経由で行う。
- `username` は TURN 以外の用途のログでもキー名が一致すればマスクされる。キー名に基づくマスクとして意図どおりであり、対象を狭めない。

### `ICEServerInfo.description`

- `CustomStringConvertible` への準拠と `description` のシグネチャは維持し、返す文字列の `username` と `credential` の値だけをマスクする。
- `description` の提供をやめる案 (準拠の削除) は採らない。Swift では protocol conformance を非推奨化できず、移行期間を設けられない (`0113` と同じ判断)。`description` を残したまま平文を返すと目的を満たさないため、値をマスクする以外に両立する方法が無い。
- `@available(*, deprecated)` は付けない。公開 API の形が変わらないため、公開 API baseline の再生成は不要である。`make api-check-fresh` が成功することを確認する。
- `Codable` の `encode(to:)` と `CodingKeys` は変更しない。JSON のキー (`urls` / `username` / `credential`) と値は利用者が設定した値のままである必要があり、`0030` も JSON キー `username` の維持を完了条件にしている。`SoraTests/ConnectionConfigurationSnapshotTests.swift` の `testICEServerInfoJSONKeysAreUnchanged` が JSON のキー集合を固定しており、キーを変えると失敗する。値の不変はこのテストでは検証されないため、本 issue で追加するテストで検証する。
- マスクした文字列を組み立てる処理は `ICEServerInfo.description` の中で完結させ、`Codable` の経路とコードを共有しない。

### URL の userinfo

- URL から userinfo を除いた文字列を作る内部ヘルパーを 1 つ用意し、`urlCandidates` / `connecting to` / `try redirecting to` のログに適用する。`urlCandidates` だけを直すと、同じ `connect(handler:)` 内の `connecting to` が userinfo を出力し続けるため、適用範囲は URL を出力するログ全体とする。`invalid message` は次の項のとおり組み立て時に処理する。
- `redirect(location:)` の `location` は `PeerChannel` の redirect 処理から渡る `String` であるため、ヘルパーは `URL` と `String` の両方を受けられる形にする。`URL(string:)` に失敗した経路 (`invalid message`) では URL として解釈できないため、`<scheme>://` の直後から最初の `/` (無ければ文字列の末尾) までの間に `@` がある場合に `@` より前を除去する文字列ベースの処理で userinfo を除く。`URL(string:)` に失敗したら元の文字列をそのまま返す実装にすると漏えいが残るため、この経路でも文字列ベースの除去を行う。
- `invalid message` は組み立て時点で userinfo を除いた location を使い、その文字列をログと `SoraError.signalingChannelError` の reason の両方に使う。reason は `SoraEventError.message` として利用者にも届き、`error.localizedDescription` は `Sora/SignalingChannel.swift` の `disconnect(error:)` と `Sora/PeerChannel.swift` の `basicDisconnect` の error ログでも再出力されるため、ログの 1 箇所だけをマスクしても漏えいが残る。認証情報を含めないことを優先し、invalid redirect のエラーメッセージの文字列が変わることを許容する (`CHANGES.md` に記載する)。
- ヘルパーは `Logger` と同じモジュール内の internal な関数として置く。JSON の値のマスク (`secretKeys` / `maskSecrets`) と URL の userinfo の除去は別の処理であり、対象キーの一覧に混ぜない。

### `ICEServerSnapshot`

- `0102` が追加した `ICEServerSnapshot` は internal で `CustomStringConvertible` を持たず、ログにも出ない。`credential` / `username` を含む新しい文字列表現を追加しない (`0102` の設計を維持する)。

### 対象外

- `Logger.maskSecrets` の対象キーの一般化 (メタデータなどに含まれる任意の認証情報の検出)。
- JSON 以外の形式に対するマスク挙動の固定 (現行のマスクは JSON のキーと値を対象にする)。
- `Sora/SignalingChannel.swift` の責務分離 (`0141` の範囲)。

## 前提となる issue

- `0102` (完了済み): 接続設定の snapshot 化。本 issue は `ICEServerInfo.description` と URL のログのマスクを扱うため、`0102` の完了後に着手する。
- `0106` (develop にマージ済み): Logger の共有可変状態の同期。同じ `Sora/Logger.swift` の `maskSecrets` 周辺を変更するため、`0106` の完了後に着手する。`maskSecrets` と対象キーのロジックは `0106` で変更していない。なお `0106` は `testMaskingAndOutputFormatUnchanged` を追加しており、本 issue はそのテストを更新する。

## 関連 issue

- `0141` (open): `SignalingChannel` を WebSocket 接続管理に純化する。`0141` は `Sora/SignalingChannel.swift` の変更対象に本 issue を含めており、本 issue の完了後に着手する。`0141` が先に完了した場合は、本 issue の「現状」と「変更対象」を現行コードへ同期してから着手する。
- `0030` (open): `ICEServerInfo` の `userName` を `username` に変更する。同じ `Sora/ICEServerInfo.swift` を変更するが、`0030` はプロパティ名と `Codable` の定義、本 issue は `description` の出力であり変更箇所は重ならない。`0030` が先に完了した場合は `ICEServerInfo.userName` が `username` に変わるため、本 issue の記述を読み替える。`0030` は公開 API baseline を再生成するが、本 issue は再生成しない。
- `0166` (open): `LogType.signaling` の filtering を修正する。同じ `Sora/Logger.swift` と `SoraTests/LoggerTests.swift` を変更するが、`0166` は `Logger.output(log:)` の group 別受理リスト、本 issue は `secretKeys` / `secretPatterns` / `maskSecrets` であり変更箇所は重ならない。

## 変更対象

- `Sora/Logger.swift`: `secretKeys` への `username` の追加、`secretPatterns` / `maskSecrets` のエスケープ形対応
- `Sora/ICEServerInfo.swift`: `description` が返す文字列から `username` と `credential` の値をマスクする
- `Sora/SignalingChannel.swift`: `urlCandidates` / `connecting to` / `try redirecting to` のログと、`invalid message` の文字列 (ログと `SoraError` の reason の両方に使う) で userinfo を除く
- URL と文字列から userinfo を除く内部ヘルパー: `Sora/` 配下の既存の配置 (例: `Sora/Extensions/`) に合わせて追加する
- `SoraTests/LoggerTests.swift`: `testMaskingAndOutputFormatUnchanged` を `username` を含む 6 キーへ更新し、エスケープされた JSON のケースを追加する (実装時に `testMaskingAndLogDescriptionFormat` へ改名した)
- `SoraTests/`: `ICEServerInfo.description` のマスク、`Codable` の `encode(to:)` が出力する値の不変、URL の userinfo の除去を検証するテスト
- `CHANGES.md`: `## develop` の `[FIX]` にエントリを追記する

## 完了条件

- `username` を含む JSON 形式のログで、`username` の値がマスクされること。
- エスケープされた JSON を含むログ (`\"credential\":\"...\"` の形) でも、対象キーの値がマスクされること。
- エスケープされていない JSON とエスケープされた JSON のどちらでも、マスクの対象外のキーと値がそのまま残ること。
- `ICEServerInfo.description` から `credential` と `username` の平文が得られないこと。`Codable` の `encode(to:)` が出力する JSON のキー集合と値は変わらないこと (キー集合は `testICEServerInfoJSONKeysAreUnchanged` が成功することで確認し、値は本 issue で追加するテストで確認すること)。
- userinfo を含む URL を `urlCandidates` に指定した場合、userinfo を含む有効な location で redirect した場合、`URL(string:)` に失敗する userinfo を含む location で redirect した場合のそれぞれで、`urlCandidates` / `connecting to` / `try redirecting to` / `invalid message` のどのログにも userinfo が出力されないこと。
- invalid redirect の `invalid message` から作られる `SoraError` の reason、およびその reason が `error.localizedDescription` として再出力される `SignalingChannel.disconnect(error:)` と `PeerChannel.basicDisconnect` の error ログにも userinfo が出力されないこと。
- `SoraTests/LoggerTests.swift` の `testMaskingAndLogDescriptionFormat` が `username` とエスケープされた JSON のケースを検証し、成功すること。
- `ICEServerInfo.description` のマスク、`Codable` の `encode(to:)` が出力する値の不変、URL の userinfo の除去を検証するテストが存在し、成功すること。
- 公開 API baseline が変わらないこと (`make api-check-fresh` が成功すること。Xcode 26.6 と `iphoneos26.5` が必要なため、手元に無い場合は CI の `swift6-consumer` job で確認すること)。
- 追加したテストと既存テストがすべて成功すること。
- `CHANGES.md` の `## develop` の `[FIX]` の末尾に、担当者行 (`- @ユーザー名`) を付けてエントリを追記すること。invalid redirect のエラーメッセージが変わる (認証情報を含めない表記になる) ことも記載すること。

## 解決方法

- `Sora/Logger.swift`
  - `secretKeys` に `username` を追加した。`ICEServerInfo` は `username` を JSON のキーに使うため、offer の ICE server infos のログでもユーザー名がマスクされる。
  - `secretPatterns` を `(key, regex)` から `(regex, template)` に変え、全キーを 1 本の alternation にまとめた非エスケープ形・エスケープ形の 2 つの正規表現にした。キーごとに持つと走査がキー数に比例して増えるためである。キー名は置換テンプレートの `$1` で保持し、エスケープを保ったまま値を `***` に置換する。
  - 非エスケープ形の値は JSON 文字列として解釈し、値にエスケープされた引用符が含まれても途中で切れないようにした。エスケープ形は値の終端も値の中の引用符も `\"` として現れるため、区切り (`,` / `}`) または外側の文字列の閉じ引用符が続く `\"` を終端とみなす (文字列の末尾は終端にしない)。整形済み JSON のエスケープされた空白 (`\n` / `\r` / `\t`) はコロン前後と終端の両方で許容する。非エスケープ形は値の後ろに区切り (`,` / `}` / `]`) か文字列の末尾 (空白を挟んでもよい) を要求し、値が別のキー名そのものである不正な JSON でもそのキーを値として消費しない。
  - `maskSecrets` は `"` を含まないログを走査しない (JSON のキーは必ず `"` を伴う)。`"` を含む場合も 2 パターンを 1 回ずつ適用するだけで、繰り返しはしない。非エスケープ形に値の終端条件を入れてあるため、値が別のキー名そのものである不正な JSON でもそのキーを値として消費せず、1 回の走査で残りのキーをマスクできる。
  - エスケープ形の値の長さには上限 (4096 文字) を設けた。終端が現れない入力では出現位置ごとに末尾まで走査する二次関数的な時間がかかり、debug ログを有効にした利用者のシグナリングの直列 queue を長時間占有し得るためである。上限を超える値はマスクしない。TURN の credential はこの長さに達しない。
  - 既知の制約: 値の中の引用符の直後に区切りが続く場合 (例: 値が `ab",cd`) は値の残りが平文で残る。非エスケープ形で値が `\` で終わる不正な JSON (例: `{"credential":"secret\"}`) は、`\"` をエスケープされた引用符として扱うため閉じ引用符が無く、マスクしない。値の直後が区切りでも末尾でもない不正な JSON (例: `{"token":"s3cr3t""x":1}`) もマスクしない。エスケープ形で文字列の末尾まで途切れたログはマスクしない。二重にエスケープされた JSON は対象外。
- `Sora/ICEServerInfo.swift`
  - `description` は `username` / `credential` の値を `***` に置き換えた JSON を返す。値が nil の場合はキー自体を出さない従来の形を保つ。
  - `Codable` の `encode(to:)` と `CodingKeys` は変更していない。JSON のキーと値は利用者が設定した値のままである。
- `Sora/Extensions/URLUserInfo.swift` (新規)
  - `URLUserInfo.removed(from: URL)` と `URLUserInfo.removed(from: String)` を追加した。文字列版は `URL` として解釈できない location も扱えるよう、authority の開始位置 (`<scheme>://` の後ろ、または `//` の後ろ) から終端 (`/` `?` `#`、無ければ末尾) までの `@` より前を除去する。
  - WebSocket の URI (RFC 6455) は userinfo を持たないため、通常の仕様どおりの URL ではこの除去は何も変えない。仕様外の URL が設定されたり、redirect の location に userinfo が含まれたりした場合に備えた防御的な実装である。
- `Sora/SignalingChannel.swift`
  - `urlCandidates` / `connecting to` / `try redirecting to` のログで userinfo を除いた値を出力する。
  - `invalid message` は組み立て時点で userinfo を除いた location を使い、ログと `SoraError` の reason の両方に使う。reason は `error.localizedDescription` として `SignalingChannel.disconnect(error:)` と `PeerChannel.basicDisconnect` の error ログにも再出力されるため、reason 側を直す必要があった。
- `Sora/URLSessionWebSocketChannel.swift`
  - 受信失敗のログで `\(error)` を出していた。`NSError` の userInfo に接続先 URL が入り、その URL の userinfo がログへ残るため、domain / code / description だけを出す形に変えた。
- テスト
  - `SoraTests/LoggerTests.swift` の `testMaskingAndLogDescriptionFormat` を 6 キーへ更新し、エスケープされた JSON、非対象キーの文字列値、値の長さの上限、エスケープされた引用符を含む値、整形済み JSON、コロン前後のエスケープされた空白、外側の文字列に埋め込まれた escaped JSON、値を引用符で終わる場合、値が文字列の末尾で終わる場合、隣接する不正な JSON のケースを追加した。テスト名は実装に合わせて `testMaskingAndOutputFormatUnchanged` から改名した。
  - `SoraTests/SecretMaskingTests.swift` を追加した。`ICEServerInfo.description` のマスクと JSON キー集合の一致、`Codable` の値の不変、`URLUserInfo` の `URL` / 文字列の両形式、`SignalingChannel` のログと redirect のエラー reason を検証する。
  - `SoraTests/URLSessionWebSocketChannelTests.swift` に、受信した JSON のログのマスクと、受信失敗ログに userinfo が残らないことのテストを追加した。
  - `SoraTests/LoggerCapture.swift` を追加し、`Logger.shared` の設定変更と復元、ログ収集をテスト間で共通化した。
- 確認結果
  - 全テスト 538 件中 499 件成功 (39 件の内訳は E2E の環境変数未設定によるスキップ 33 件、シミュレータに実カメラが無いことによるスキップ 6 件)。
  - `make fmt-lint` と `make lint` (SwiftLint strict) が成功。
  - `make api-check-fresh` はローカルの Xcode が 26.6 でないため未実行。公開 API の宣言は変わらないため CI で確認する。
