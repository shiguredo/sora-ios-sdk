# Logger の共有可変状態を同期する

- Created: 2026-08-27
- Completed: 2026-09-18
- Priority: Medium
- Branch: feature/refactor-logger-shared-state
- Polished: 2026-09-18

## 目的

`Logger.shared`、`level`、`groups`、`onOutputHandler` の読み書きを、設定を保持する storage と現在の instance を保持する storage の 2 つの lock で保護し、`Logger` の `@unchecked Sendable` と `nonisolated(unsafe)` な static storage への依存を除去して checked な `Sendable` に置き換える。

Logger 自身の lock を保持したまま利用者の出力 handler を呼ばない構造にし、handler 内から Logger の公開 API (設定の変更とログ出力) を呼んでも deadlock しないことを保証する。`Logger.shared` と `onOutputHandler` の doc に、差し替えと競合した場合の範囲、再入、再帰の危険、並行呼び出しの責任を明記する。

公開名・型・シグネチャは変えず、単一の executor から利用した場合の観測挙動も変えない。共有可変状態のデータ競合 (未定義動作) の除去が主目的であり、その帰結として 1 回の出力が単一の snapshot を使うことを保証する。あわせて、`0123` から委譲された `Log.description` の共有 `DateFormatter` の扱いを確定する。

## 現状

`Sora/Logger.swift` の `Logger` は class 全体が `@unchecked Sendable` で、現在の `Logger` instance を保持する `sharedStorage` は `nonisolated(unsafe) static var` である。次の mutable state に同期がない。

- `shared` の setter が書き換える `sharedStorage`
- `onOutputHandler`
- `groups`
- `level`

`Logger.output(log:)` は `groups` と `level` を読んで filtering し、`onOutputHandler?` を呼んでから `print` する。lock を持たないため、同時に設定を変更するとデータ競合になり、1 回の出力が異なる時点の設定を混ぜて観測し得る。

`Logger.fatal` / `error` / `warn` / `info` / `debug` / `trace` の各 static メソッドは `Logger.shared` を経由して `Logger.output(log:)` を呼ぶ。`Sora/` 内の呼び出しは 328 箇所 (`Logger.<レベル名>(` の出現数) あり、URLSession delegate、libwebrtc signaling thread、カメラの capture session queue (`Sora/CameraVideoCapturer.swift`)、MediaStream の owner queue (`Sora/StreamFrameOwner.swift`)、main queue など複数の executor から到達する。

`Log.description` は `private static let` の共有 `DateFormatter` を使う。`Log` は `Sendable` な公開値型であり、利用者が handler 経由で受け取った `Log` を任意の executor で `description` 化できる。

`Logger.shared` は public な setter を持つが、`Logger` に public な initializer が無いため、モジュール外の利用者は新しい `Logger` instance を生成できず、setter に渡せる値は `Logger.shared` 自身だけになる。リポジトリ内に `Logger.shared =` の代入は無い。

`skills/sora-ios-sdk/SKILL.md` は「スレッド安全でない共有状態」の節に `Logger.shared` / `Sora.logLevel` を、`@unchecked Sendable` の記載に `Logger` を挙げている。

## 関連 issue

- `0111`: `Sora` の共有状態と WebRTC callback logger。`Logger.shared` の同期は本 issue が扱い、SKILL.md の `@unchecked Sendable` の記載に残る `Sora` は `0111` が扱う。
- `0112`: `DeviceInfo.current` と、SKILL.md の「スレッド安全でない共有状態」の `DeviceInfo.current` の行・同節の見出し・導入文。
- `0123` (closed): 公開値型の `Sendable` 対応。`Log.description` が使う共有 `DateFormatter` の扱いを本 issue に割り当てている。
- `0107`: Swift 6 の consumer fixture と API baseline。本 issue の checked `Sendable` の検証は `requireSendable` と `git diff` で行い、外部 consumer からの検証は `0107` の範囲とする (本 issue では `0107` を変更しない)。
- `0156`: ログと文字列表現からのシークレット漏れの修正。`Sora/Logger.swift` / `Sora/ICEServerInfo.swift` / `Sora/SignalingChannel.swift` を変更し、`Logger.maskSecrets` の対象キーへ `username` を追加する。同じ `Sora/Logger.swift` の `maskSecrets` 周辺を変更するため、どちらかを先行させもう一方を rebase する (本 issue は対象キーの集合を変更しない)。
- `0119`: Thread Sanitizer を有効にした CI 基盤。本 issue の実行時検証は `0119` の基盤に従い、完了条件には含めない。
- `0165`: SDK 内部の lock 保持中に Logger を呼ぶ経路で deadlock する問題の修正。同じ `CHANGES.md` の `## develop` を更新するため、どちらかを先行させもう一方を rebase する。
- `0108`: `0100` から `0106` の対応状況を確認してから着手する (本 issue もその対象)。

## 設計方針

### 設定 storage

- `level` / `groups` / `onOutputHandler` を保持する internal な `LoggerStateStorage` と、現在の `Logger` instance を保持する internal な `LoggerSharedStorage` を導入する。どちらも final class (`@unchecked Sendable`) とし、それぞれを `NSLock` で保護する。actor や serial queue は採用しない。`level` / `groups` / `onOutputHandler` / `Logger.shared` は同期 getter / setter であり、同期 wait は再入で deadlock し得るためである。
- `Logger` は `LoggerStateStorage` を `let` で 1 つ持ち、`level` / `groups` / `onOutputHandler` は storage へ委譲する computed property にする。初期値は現行と同じ `level = .info`、`groups = [.channels, .user]`、`onOutputHandler = nil` とする。設定が instance 単位であることも現行と同じである。
- `Logger.output(log:)` は `level` / `groups` / `onOutputHandler` を 1 回の lock 区間で internal な struct `LoggerSettingsSnapshot` (`level` / `groups` / `onOutputHandler` を保持する) として取得する。`groups` は値コピー、handler は closure を 1 回 copy する。snapshot は `@Sendable` な境界へ渡さないため `Sendable` にしない。
- filtering、secret masking、文字列整形、handler 呼び出し、`print` は lock の外で行う。

### shared 参照

- `sharedStorage` の `nonisolated(unsafe) static var` を廃止し、`private static let sharedStorage = LoggerSharedStorage(Logger())` に置き換える。
- `static var shared` の get / set は今までどおり computed property とし、参照先を `LoggerSharedStorage` に変える。Swift 6 では stored な `nonisolated(unsafe)` なしの `static var` は error になるため、mutable な参照を `static let` の storage に閉じ込める。
- 差し替えの実行時挙動は現行と同一にする。`LoggerSharedStorage` が保持するのは現在の `Logger` instance だけで、`level` / `groups` / `onOutputHandler` は instance が持つ。`Logger.shared = X` の後は X の設定が使われ、X が既定値なら既定値に戻る (現行と同じ)。
- static メソッドは `Logger.shared` を 1 回読んでから、その instance の `Logger.output(log:)` を呼ぶ。
- `Logger.shared.level = X` は `LoggerSharedStorage` と instance の storage の 2 つの lock を跨ぐため、差し替えと競合すると `level` の更新が差し替え前の instance に適用されて観測されなくなり得る (差し替え自体は失われない)。`Sora.logLevel` の書き込みでも同じことが起きる。差し替えと出力が競合した場合は差し替え前の instance の設定で出力され得る。これらの範囲を `Logger.shared` の doc に書く。

### handler の再入

- handler を呼ぶ前に snapshot を確定して lock を解放する。Logger は handler の実行中にどの lock も保持しないため、handler 内から Logger の設定を読み書きし、ログを再出力しても deadlock しない。
- handler と `print` の順序は現行どおり handler → `print` とする。
- handler は呼び出し元 executor で呼ぶ現行契約を維持し、queue への hop を追加しない。
- handler が同じ `Log` を再出力した場合の無限再帰は利用者責任とし、thread-local cache や再入カウンタによる防御は追加しない。`onOutputHandler` の doc に、再入可能であること、再帰の危険があること、複数の executor から並行に呼ばれ得るため handler 側の排他は利用者の責任であることを書く。

### Sendable と formatter

- `Logger` の `@unchecked Sendable` を checked な `Sendable` に置き換え、stored property を `let` の `LoggerStateStorage` だけにする。テストから `Logger()` を生成できるよう、`Logger` の initializer (現行の暗黙の internal `init()`) を維持する。
- `Sora/Logger.swift` 内で `@unchecked Sendable` が付くのは `LoggerStateStorage` と `LoggerSharedStorage` の 2 型だけとし、型 doc に書く根拠を型ごとに限定する。
  - `LoggerStateStorage`: (1) `level` / `groups` / `onOutputHandler` への全アクセスが単一の `NSLock` 区間であること、(2) snapshot は lock 区間内で値コピーを作り lock の外ではそのコピーだけを使うこと、(3) 保持する `onOutputHandler` は利用者所有の closure であり、呼び出し元 executor 上で並行に呼ばれ得るため排他は利用者の責任であること。
  - `LoggerSharedStorage`: 保持する `Logger` instance への全アクセスが単一の `NSLock` 区間であること。あわせて、stored な `static var` は `nonisolated(unsafe)` を付けない限り Swift 6 で error になるため mutable な参照を `static let` の storage に閉じ込めている、という制約を書く。
- 既存の `@unchecked Sendable` の根拠コメントは、実装後の構造 (Logger は設定 storage への handle であること) に合わせて書き直す。
- storage の setter は旧値をローカルへ取り出し、`NSLock` を解放してから解放する (利用者の closure や `Logger` の deinit を lock 保持中に走らせない)。
- 共有 `DateFormatter` (`Log` の `formatter`) は初期化後に変更しない `static let` のままとし、別の formatter へ置き換えない。iOS SDK の `NSDateFormatter.h` が `NSDateFormatter` に `NS_SWIFT_SENDABLE` を付けており `DateFormatter` が `Sendable` として公開されていることを根拠として、コードコメントに日本語で書く。
- `Logger.maskSecrets` が使う `secretPatterns` (`private static let` の `[(key: String, regex: NSRegularExpression)]`) も、iOS SDK の `NSRegularExpression.h` の `NS_SWIFT_SENDABLE` により Sendable であり、lock を追加しない。この根拠もコードコメントに日本語で書く。
- `Sora/Sora.swift` の `Sora.logLevel` は `Logger.shared.level` への forwarding のままとし、変更しない。本 issue の完了後は Logger の lock で保護される。

## スコープ外

- SDK 内部の排他区間 (NSLock と serial queue の `sync`) を保持したまま Logger を呼ぶ call site の是正は本 issue の対象外とする。Logger は handler 実行中にどの lock も保持しないため、この問題は Logger の変更では解決しない。`0165` で扱う。
- `Logger.shared` の setter の非推奨化・削除は行わない。
- ログ API の廃止、ログ形式の変更、ログ group の追加・削除は行わない。
- secret masking の対象キーの集合の変更は行わない。
- handler の executor の変更と、ログ出力を別 executor へ hop させる変更は行わない。

## 変更対象

- `Sora/Logger.swift`: 設計方針のとおりの変更 (storage 2 型と `LoggerSettingsSnapshot` の導入、computed property 化、checked な `Sendable` への置き換え、doc とコードコメントの追加)
- `SoraTests/LoggerTests.swift` (新規): テスト方針の各項目
- `SoraTests/SendableConformanceTests.swift`: `requireSendable(Logger.self)` を追加する
- `skills/sora-ios-sdk/SKILL.md`: 「スレッド安全でない共有状態」から `Logger.shared` / `Sora.logLevel` の行を除去する (同節の見出し・導入文と `DeviceInfo.current` の行は `0112` が扱う)。`@unchecked Sendable` の記載から `Logger` を除去する。`Sora` がまだ残っている場合は `- \`@unchecked Sendable\`: \`Sora\`` とし、`0111` が先行して `Sora` が除去済みの場合は行ごと削除する。ログの `Sendable` の一覧 (`LogType` / `LogLevel` / `Log` / `Logger.Group` の行) に `Logger` を追加する。`### コールバックのスレッド` 節に `onOutputHandler` の契約を追記する
- `CHANGES.md`: `## develop` の主リストの `[UPDATE]` の並びの末尾 (FIX 群より前) へ `- [UPDATE] Logger の共有可変状態を同期する` を担当者行付きで追記する (担当者行は `shiguredo-changelog` の書式に従い、同批次の concurrency refactor と同じ `  - @t-miya` とする)。本文には「`Logger.shared` / `level` / `groups` / `onOutputHandler` の読み書きを lock で保護する」「並行に設定を変更した場合に、1 回の出力が異なる時点の設定を混ぜて観測しなくなる」「`Logger` の `@unchecked Sendable` を checked な `Sendable` へ置き換える」「公開名・型・シグネチャと、単一 executor からの利用時の挙動は変わらない」を含める。`### misc` ではなく主リストに置くのは、共有可変状態のデータ競合 (未定義動作) の除去と、スレッド安全でない共有状態という利用制約の解消を含む後方互換な変更であるためである (`0102` / `0103` / `0104` / `0105` も主リストに置かれている)

## テスト方針

モックやスタブは使用しない。実 `Logger` と実 handler を使い、記録は lock で保護した実 collector (`SoraTests/CameraStateOwnerTests.swift` の collector と同じ形) で行う。`Log` は `Equatable` ではないため、`Log` の識別には `Log.message` を使う。`XCTestExpectation` の timeout は 5 秒とする。`@testable import Sora` で `Log` の生成と `Logger.output(log:)` の呼び出しを行う。`Logger.shared` はプロセス全体の共有状態のため、これらのテストは直列実行を前提とする。

- `@testable import Sora` で instance ごとの `Logger` を生成して使う。`Logger.shared` を書き換えるテストは `setUp` で `Logger.shared` / `level` / `groups` / `onOutputHandler` を保存し、`tearDown` で復元して復元を検証する (`Logger.shared` はプロセス全体の共有状態であり、`SoraTests/E2ETestBase` も `Logger.shared.level` を書き換えるため、テストが設定した値を残さない)。復元は `Logger.shared` に対して行い、退行で停止し得る専用 queue の完了は待たない。
- 既定値: 新しい `Logger` instance の `level` が `.info`、`groups` が `[.channels, .user]`、`onOutputHandler` が `nil` であることを確認する。
- 固定設定での並行出力: 出力元はテストローカルの `Logger` instance とし、`Logger.shared` には設定しない。`level` と `groups` を「出力が通る値」に固定し、`concurrentPerform` で 100 件を出力して、handler の呼び出し回数が出力件数と一致し `Log.message` に重複と欠落がないことを確認する。
- 並行する設定変更: 出力が必ず通る `level` と `groups` へ複数スレッドから書き換えながら出力し、全件が handler に届くことを確認する (設定に依存する期待値を計算しない)。このテストは書き込む設定を全て「出力が通る値」に限定するため、1 回の出力が単一の snapshot を使うこと自体は検証できない。`Logger.output(log:)` が `level` と `groups` を別々に read する実装へ退行しても、`level` は `.debug` と `.fatal` のどちらでも `.fatal` のログを通り、`groups` はどちらも `.channels` を含むため、どの組み合わせを観測しても `.fatal` / `.sora` は出力されて全件が handler に届く。公開 API から interleaving を制御できず決定的な検出テストは書けず、確率的な検出テストは本方針の「設定に依存する期待値を計算しない」と衝突するため、この性質は完了条件の「コードで確認する」で担保し、このテストでは担保しない (この判断は `## 解決方法` にも記録する)。
- handler の再入: 出力元はテストローカルの `Logger` instance とし、`Logger.shared` には設定しない。出力元の instance は `onOutputHandler` を非 nil にし、`level` / `groups` を出力が通る値に設定する。handler 内から同じ instance の `level` / `groups` / `onOutputHandler` の読み書きと `Logger.output(log:)` の再呼び出しを行い、あわせて公開経路 (`Logger.shared` / `Logger.shared.level` / `Sora.logLevel` の読み書き、`Logger.info` の呼び出し) を行う。`Logger.info` の到達は `Logger.shared` の `level` / `groups` / `onOutputHandler` と `Logger.shared` 自体の参照で決まるため、`Logger.info` を呼ぶ直前にこれらを出力が通る値へ戻す (`level` は `.off` 以外、`groups` は `.channels` を含む (`LogType.sora` は `.channels` で通る)、`onOutputHandler` は非 nil、`Logger.shared` は元の instance)。`Logger.shared.onOutputHandler` に非 nil の handler を設定した場合は `Logger.info` がその handler を呼ぶため、再入は 1 段の範囲内で行い、`Logger.info` の再入が handler に届いたことを記録で確認する。再入は handler 側のフラグで 1 段に制限し、2 回目の出力は行わない。出力は専用 queue から行い、再入の完了後に expectation を fulfill する。lock を保持したまま handler を呼ぶ実装へ退行した場合はその queue が停止して expectation が timeout するためテストは失敗する。
- handler の lock 外実行 (snapshot の境界) の回帰: 出力元はテストローカルの `Logger` instance とし、`Logger.shared` には設定しない。出力は専用 queue から行う。1 回目の出力の handler は、呼ばれたことを記録し、同じスレッドで対象 instance の `level` を `.off` へ変更してから戻る (この setter は storage の lock を取るため、lock を保持したまま handler を呼ぶ実装ではここで停止する)。テストスレッドは handler 呼び出し完了の expectation を待つだけで、handler の実行中に Logger の lock を取得する操作を行わない。待機が timeout した場合は `XCTFail` して以降の手順 (2 回目の出力と完了待ち) を行わずにテストを終了する (停止した専用 queue を待たない)。成功した場合は 2 回目の出力を専用 queue へ投入し、その block の中で出力を呼んでから fulfill する完了 expectation を待つ (2 回目の出力は `level = .off` のため handler には到達せず、handler 側では fulfill しない)。その後に handler の呼び出し回数が 1 のままであることを確認する (`queue.sync {}` のような timeout の無い待機を使わない)。
- `Logger.shared` の差し替え: 別の `Logger` を設定し、以後の出力が新しい instance の `level` / `groups` / `onOutputHandler` を使うこと (現行挙動の維持) を確認する。
- `Logger.shared` の差し替えと `Logger.info` を複数スレッドで競合させ、`Logger.shared` の getter が常に設定済みの 2 つの instance のいずれかと同一であること、2 つの instance の handler の呼び出し回数の合計が出力回数と一致することを確認する (2 つの instance は出力が通る設定に固定し、開始前に一方を `Logger.shared` へ設定し、全スレッドの投入完了を待ってから合計を確認する)。
- filtering: groups と level の組み合わせが実装前と同じ結果になることを確認する (`level = .off` で handler が呼ばれないことを含める)。
- masking と出力形式: 対象の `LogType` を通す group と通過する level を設定して `Logger.output(log:)` を呼び、handler が受け取った `Log.message` の secret masking と `Log.description` の出力形式が、`0106` の変更前から存在する対象キーについて変わらないことを確認する。対象キーの集合は変更しないため、`0156` が先に完了していても本 issue の確認は成立する (`0156` が追加したキーの検証は行わない)。`Log.description` の期待値は、共有 `formatter` (`Log` の `formatter`) が `dateFormat` だけを設定して `locale` / `timeZone` を実行環境の既定値に任せているため、テストローカルの `DateFormatter` にも同じ `dateFormat` と `Locale.current` / `TimeZone.current` を明示して同じ実効値にそろえる (テスト内で `locale` / `timeZone` を変更しない)。
- `Log.description` の並行呼び出し: 複数のスレッドから同じ入力の `Log` を `description` 化し、結果が入力から一意に決まること (同じ timestamp なら同じ文字列) を確認する。
- `print` の出力内容と handler → `print` の順序はテストで検証しない。stdout の捕捉はプロセス全体に影響しテストが不安定になるため、`Sora/Logger.swift` を読んで lock の外にあることと順序を確認する。
- storage の setter が旧値を lock 解放後に解放すること (旧 closure の捕捉 object と旧 `Logger` の deinit を lock 保持中に走らせない) はテストで検証しない。解放の位置を観測するにはテスト用の仕掛けを実装本体へ持ち込むことになるため、`Sora/Logger.swift` を読んで確認する。
- テストには、handler を lock 外で呼ぶ理由と snapshot の境界を日本語コメントで明記し、テストのログメッセージも日本語にする。

### 実機で手動確認する (CI では未検証として区別する)

Simulator のユニットテストでは持続的な多スレッド競合と実データのペイロード形状を再現できないため、次を実機のアプリで確認し、結果を「解決方法」に記録する。

- 実接続を 5 分以上維持し、ログ出力が途中で止まらない・詰まらないこと。音声と映像を流した状態で行う (確認の目的は持続的な多スレッド競合の下でログ経路が停止しないことで、閾値の厳密さ自体に意味はない)。
- 接続中に `Sora.logLevel` と `Logger.shared.groups` を変更し、以後のログ出力がその設定に追随すること (変更時にログ経路が止まらないことも含む)。
- `access_token` を含む実際の metadata で接続し、`Sora.logLevel = .debug` のときにコンソールへ出る signaling ログでトークンの値が `***` にマスクされていること (平文で現れないこと)。
- 接続中に `Logger.shared.onOutputHandler` を設定・解除・差し替えしても、handler が呼ばれ続ける (解除後は呼ばれない) こと。差し替えは複数回行い、旧 handler の解放経路を踏むこと。
- handler から SDK の API を同期的に呼ぶと deadlock する (`0165` の既知の問題で本 issue では修正しない)。handler からは main queue へ hop して非同期に扱う前提で問題ないことを確認する。

## 完了条件

- `shared` / `level` / `groups` / `onOutputHandler` の全読み書きが `LoggerStateStorage` と `LoggerSharedStorage` の `NSLock` で保護され、`Logger.output(log:)` が 1 回の lock 区間で取得した 1 つの snapshot だけを使って filtering と handler 呼び出しを行い、filtering、masking、整形、handler 呼び出し、`print` を lock の外で実行すること (コードで確認する。テスト方針の「並行する設定変更」に書いたとおり、公開 API から interleaving を制御できず決定的なテストでは検出できないため、テストではなくコードで確認する)。
- `LoggerStateStorage.onOutputHandler` と `LoggerSharedStorage.current` の setter が、旧値をローカルへ取り出し、`NSLock` を解放してから解放すること (旧 closure の捕捉 object と旧 `Logger` の deinit を lock 保持中に走らせない。コードで確認する)。`level` / `groups` は単純な値型のため lock 内で解放してよい。
- handler 内から同じ instance の設定の読み書きとログの再出力を行っても deadlock しないこと。handler 内から `Logger.shared` / `Logger.shared.level` / `Logger.shared.onOutputHandler` / `Sora.logLevel` を呼んでも deadlock しないこと (テストで検証する)。
- `Logger.shared` の差し替え後に新しい instance の設定が使われること (テストで検証する)。
- `sharedStorage` の `nonisolated(unsafe)` が削除され、現在の `Logger` instance が `static let` の storage に入っていること。`Logger.shared` の get / set が今までどおり computed property で、`Logger` に `let` 以外の stored property が増えていないこと (`git diff` で確認する)。
- `Logger` が checked な `Sendable` に準拠し、`Sora/Logger.swift` 内で `@unchecked Sendable` が `LoggerStateStorage` と `LoggerSharedStorage` の 2 型だけに付き、各型の根拠が型ごとに限定した内容で型 doc に日本語で書かれていること。
- `Logger.shared` と `onOutputHandler` の doc に、設計方針で定めた契約が書かれていること。
- `Log.description` の出力形式と、`0106` の変更前から存在する対象キーの secret masking の結果が変わらないこと (テストで検証する。`0156` が追加したキーは検証対象にしない)。
- `Logger.maskSecrets` の対象キーの集合が `0106` の変更で変わっていないこと (`git diff` で `secretKeys` の宣言に差分が無いこと。`0156` が先行している場合は `username` が残っていること)。
- 共有 `DateFormatter` の扱いが設計方針のとおりで、`Log.description` の並行呼び出しが入力から一意な結果になること (テストで検証する)。
- `skills/sora-ios-sdk/SKILL.md` の「スレッド安全でない共有状態」から `Logger.shared` / `Sora.logLevel` の行が除去され、`@unchecked Sendable` の記載から `Logger` が外れ (行の形は `0111` の完了状況に合わせる)、ログの `Sendable` の一覧に `Logger` が入り、`### コールバックのスレッド` 節に `onOutputHandler` の契約が追記されていること。
- `CHANGES.md` の `## develop` の主リストの `[UPDATE]` の並びに、担当者行を含む `[UPDATE]` が追記されていること。
- `Logger.shared` を書き換えるテストが、保存した instance と設定を復元し、復元を検証していること。
- `SoraTests/SendableConformanceTests.swift` に `requireSendable(Logger.self)` が追加されていること。
- 追加したテストと既存テストが失敗 0 で終わること (環境変数が未設定の E2E テストは `XCTSkip` になる)。

### 検証手段

- `grep -nE "^[[:space:]]*(public |private |internal )?nonisolated\(unsafe\)" Sora/Logger.swift` が 0 件。
- `grep -nE "^[[:space:]]*(public |private |internal )?(final )?(class|struct|enum) .*: @unchecked Sendable" Sora/Logger.swift` が 2 件 (`LoggerStateStorage` / `LoggerSharedStorage` の宣言行)。
- `grep -nE "^[[:space:]]*(public |private |internal )?static var " Sora/Logger.swift` が `shared` の宣言 1 件だけで、`grep -n "static let sharedStorage" Sora/Logger.swift` が 1 件あること。
- `grep -rn "Logger\.shared" Sora/ | grep -vE ":[0-9]+:[[:space:]]*(//|/\*|\*)"` の結果に `Sora/Logger.swift` と `Sora/Sora.swift` 以外のファイルが現れないこと (本 issue が変更する公開面の範囲の確認)。
- `git diff -- Sora/Logger.swift` を読み、`let` 以外の stored property が増えていないことを確認する。
- `.github/workflows/ci.yml` の E2E job と同じ手順 (`rm -rf build` の後に `build-for-testing`、生成された `.xctestrun` を指定して `test-without-building`) でビルドが成功し、全テストが失敗 0 であること (`-sdk` と環境変数の注入は同 job の `XCODE_SDK` と手順に合わせる)。
- `make fmt-lint` と `make lint` が違反 0 であること。
- `git diff -- Sora/Sora.swift` に変更が無いこと。
- `git diff` を読み、`Logger` の公開面の変更が `@unchecked Sendable` の除去と `level` / `groups` / `onOutputHandler` の stored property から computed property への変更だけであること (公開名・型・シグネチャの変更が無いこと) を確認する。

## 解決方法

### 実装内容

- 設計方針のとおり実装した。`Logger` の stored property は `private let state` だけになり、`@unchecked Sendable` は `LoggerStateStorage` と `LoggerSharedStorage` の 2 型だけに付いている。
- `level` / `groups` / `onOutputHandler` は stored property から computed property になった (`shared` は元から computed property で、get / set の参照先を `LoggerSharedStorage` に変えた)。公開名・型・シグネチャと読み書きのソース互換性は変えていない。
- 共有 `DateFormatter` と `NSRegularExpression` は SDK ヘッダの `NS_SWIFT_SENDABLE` を根拠に lock を追加せず共有し、その理由を doc に書いた。`secretKeys` と `Sora/Sora.swift` は無変更。
- `skills/sora-ios-sdk/SKILL.md` の「スレッド安全でない共有状態」から `Logger.shared` / `Sora.logLevel` の行を除去し、`@unchecked Sendable` の記載を `Sora` だけにし、ログの `Sendable` の一覧に `Logger` を追加し、`### コールバックのスレッド` に `onOutputHandler` の契約 (呼び出し executor、排他と再入の責任、`@MainActor` のクラスから設定するときの隔離の注意) を追記した。`CHANGES.md` の `## develop` の `[UPDATE]` の末尾に担当者行を含むエントリを追記し、`SoraTests/SendableConformanceTests.swift` に `requireSendable(Logger.self)` を追加した。
- `issues/0112` が `0106` の SKILL.md への追記先を `### スレッド安全でない共有状態` 節と誤っていたため、`### コールバックのスレッド` 節であることを明記する形へ更新した。

### 検証

- `SoraTests/LoggerTests.swift` を新設し、既定値、固定設定での並行出力、並行する設定変更、handler の再入、handler の lock 外実行、`Logger.shared` の差し替え (`level` / `groups` / `onOutputHandler` の追随)、差し替えと出力の競合、filtering (`level = .off` と `groups` が空配列を含む)、masking と出力形式 (`secretKeys` の全キー)、`Log.description` の並行呼び出しを検証した。
- `LoggerTests` は 10/10 成功。全テストは 366 tests / 0 failures / 29 skipped (環境変数が未設定の E2E は `XCTSkip`)。
- `make fmt-lint` と `make lint` は違反 0。`xcodebuild build-for-testing` (scheme `Sora-Package`、`-sdk iphoneos26.5` とシミュレータの destination、`SWIFT_VERSION=6`) が成功し、生成した `.xctestrun` で `test-without-building` を実行した。E2E の環境変数は注入していないため、E2E テストは `XCTSkip` になる。
- 検証手段を全て実施した (`Sora/Logger.swift` 内で `nonisolated(unsafe)` 0 件、`@unchecked Sendable` は storage 2 型のみ、`static var` は `shared` のみで `static let sharedStorage` が 1 件、`Logger.shared` の参照は `Sora/Logger.swift` と `Sora/Sora.swift` のみ、`Logger` に `let` 以外の stored property なし、`Sora/Sora.swift` と `secretKeys` に差分なし、公開面の変更は `@unchecked Sendable` の除去と `level` / `groups` / `onOutputHandler` の computed property 化だけ)。

### テストで担保しない判断

- `Logger.output(log:)` が 1 回の出力で単一の `LoggerSettingsSnapshot` だけを使うこと (`level` と `groups` を別々に読む実装への退行) は、公開 API から interleaving を制御できず決定的なテストでは検出できない。テスト方針の「並行する設定変更」に書いたとおり、この性質はコードで確認する。
- `print` の出力内容と handler → `print` の順序は、stdout の捕捉がテスト全体を不安定にするためテストでは検証せず、`Sora/Logger.swift` を読んで確認する。
- storage の setter が旧値を lock 解放後に解放することは `withExtendedLifetime` が保証し、コードで確認できる。テストで担保しないのは、deinit の副作用を観測するためのテスト用の型を実装本体へ持ち込まないためである。

### 実機確認 (2026-09-18)

実機のアプリのログを 2 本分析した (1 本目: 11,364 行、14 分 27 秒、17:38:47-17:53:14。2 本目: 3,976 行、3 分 4 秒、18:45:00-18:48:04)。

- テスト方針の 1 番目 (5 分以上) は満たした。接続が維持されていたのは 9 分 35 秒 (`Sora` の `add media channel` から `remove media channel` まで。17:43:39-17:53:14) で、この区間のログの最大間隔は 2 秒、行数は 3,318 行、毎分 216-279 行で推移し、増加や停止の傾向は無かった。10 秒ごとの `notify` と、映像 (`quality_scaler` 254 件 / VP9 35 件 / H264 22 件)、音声 (`WebRtcVoiceEngine` 22 件 / `AudioDeviceBuffer` 4 件)、ICE / DTLS / SCTP のログが継続しており、音声と映像を流した持続的な多スレッド競合の下でログ経路が停止しないことを確認した。
- ログ全体の 14 分 27 秒には接続前の 4 分間 (17:39:40-17:43:39) が含まれるが、この区間は `add media channel` が無いアイドル状態であり、SDK のログが出ないのは正常である (ログの停止ではない)。接続と切断は 3 回行い (27 秒、5 秒、9 分 35 秒)、いずれも `remove media channel` まで到達した。
- テスト方針の 2 番目は満たした。サンプルアプリ (`sora-ios-sdk-samples`) に一時コードを入れ、接続から 30 秒後に `Logger.shared.groups = [.user]`、60 秒後に `[.channels, .user]` と `Sora.logLevel = .info`、90 秒後に `Sora.logLevel = .debug` へ戻す変更を main 以外のスレッドから行った。各区間の SDK のログ行数は 217 (30 秒間) → 0 (29 秒間) → 5 (30 秒間、DEBUG は 0) → 223 (94 秒間) で、`groups` と `level` の両方が接続中に反映された。`libwebrtc` の行は全区間で出続け (788 / 87 / 50 / 235 行)、`Sora.setWebRTCLogLevel` が別経路であることも確認できた。設定変更区間のログの最大間隔は 2 秒で、変更時にログ経路は停止しなかった。接続は 3 分 4 秒維持し、`remove media channel` まで正常に到達した。
- テスト方針の 3 番目は満たした。`access_token` / `token` / `authorization` / `secret` を `signalingConnectMetadata` に設定して接続し、送信する connect メッセージのログが `"metadata":{"access_token": "***","token": "***","authorization": "***","secret": "***"}` になる (4 キーとも `***` になる) ことを確認した。`credential` も別の接続で `PeerChannel` の `ICE server infos` が 3 件とも `***` になっていた。`secretKeys` の 5 キー全てが実データでマスクされることを確認した。
- 一方、`WebSocketChannel` の受信メッセージ (エスケープされた JSON) はマスクされないため、受信メッセージに認証情報が含まれる場合は平文で残る。詳細は「判明した別の問題」を参照する。
- テスト方針の 4 番目 (`Logger.shared.onOutputHandler` の設定・解除・差し替え) は未実施。
- テスト方針の 5 番目 (handler から SDK の API を同期的に呼ぶ経路) は `0165` の既知の問題であり、本 issue では確認対象外とする。

未確認として区別する項目:

- ログ全体にトークンの実文字列が現れないこと (受信メッセージのエスケープ形はマスクされないため、送信側の `***` の確認だけでは漏れの有無を判定できない)
- 接続中の `Logger.shared.onOutputHandler` の設定・解除・差し替え (4 番目)

### 判明した別の問題

- `LogType.signaling` はどの `Logger.Group` の受理リストにも含まれておらず、`.signaling` を指定したログ (`Sora/Signaling.swift` の `serializeData` / `updateMetadata` / `SignalingOffer.Encoding.init(from:)` の 3 箇所) は `level` / `groups` の設定に関係なく出力されない。本 issue の変更前から存在する挙動であり、本 issue のスコープ外。別 issue を起票して引き継ぐ (本 issue の完了時点では未起票)。
- `Logger.maskSecrets` は `"key"\s*:\s*"..."` の非エスケープ形だけをマスクするため、エスケープされた JSON では `secretKeys` の値がマスクされない。実機ログで、同じ TURN の `credential` が `PeerChannel` の `ICE server infos` では `***` にマスクされ、`WebSocketChannel` が `Logger.debug` に渡す受信メッセージ (`[host] receive message => string("{\"iceServers\":[{\"username\":\"...\",\"credential\":\"...\"}]}")`) では平文で出ることを確認した (`username` も平文)。本 issue の変更前から存在する挙動であり、`maskSecrets` と対象キーを扱う `0156` の範囲に含めるか、別 issue とするかを決める必要がある。実機ログを共有する場合は、TURN の認証情報が平文で含まれることに注意する。
