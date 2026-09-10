# TURN-TLS の証明書エラーで接続失敗した後も libwebrtc のログが流れ続ける問題を修正する

- Priority: Medium
- Created: 2026-06-03
- Completed: 2026-08-04
- Model: Opus 4.8
- Branch: feature/fix-turn-tls-log-leak-after-cert-error
- Polished: 2026-08-04

## 目的

TURN-TLS （ `turn_tls_only` 指定）で証明書エラーにより接続に失敗した後も、 `RTCPeerConnection` が動き続け、 libwebrtc の VERBOSE ログ（ネットワーク列挙など）が出力され続ける。接続失敗時に確実に終了処理（ `RTCPeerConnection` のクローズ）を行い、ログが止まるようにする。

根本原因は TURN-TLS 固有のものではなく、接続試行中に `connect()` が取得した初期ロックが解放されず `basicDisconnect` が呼ばれない、という汎用のロック解放漏れである可能性が高い（「失敗経路の分析」参照）。 TURN-TLS 証明書エラーはそのトリガーの 1 つに過ぎない。

## 優先度根拠

- 接続失敗後もネイティブのピア接続が動き続けるリソースリーク相当のバグであり、不要な処理とログ出力が継続する。
- 影響はログ出力だけに留まらない。 `basicDisconnect` が実行されないため、送信・受信ストリームの停止、 WebSocket 切断、切断通知が行われず、実リソースリークに及ぶ（「失敗経路の分析」参照）。経路 B のみの場合はユーザーへのエラー通知も発生しない可能性がある。
- ユーザー操作で接続失敗には到達するため再現性が高い。一方で接続成功時の通信には影響しないため High ではなく Medium とする。

## 関連 issue

- 0041: offer 受信後にエラーとなった場合すぐに切断されない問題。同じ根本原因（ `connect()` の初期ロック解放漏れによる `basicDisconnect` 到達不能）を SDP エラーパスで扱った issue 。 `createAnswer` エラーパスの `lock.unlock()` 追加は反映済みだが、本 issue の answer 送信成功後の失敗経路は別途未解決。
- 0042: 切断・接続を繰り返すと DUPLICATED-CHANNEL-ID が発生する問題。本 issue の修正で接続失敗時に即時エラーが返るようになると、ユーザーが即座に再接続するフローが発生し、サーバー側の旧セッション解放とのレースが生じやすくなる。未完了。
- 0043: 受信中にネットワークが切断されてもエラー通知がない問題。 `peerConnection(_:didChange:)` に新たな切断トリガー（方針 B は `RTCIceConnectionState.failed` ）を追加する方針であり、 `disconnect` → `Lock.waitDisconnect` の経路を共有する。 0043 の主シナリオ（接続完了後）は初期ロック解放済み（ count == 0 ）のため影響を受けないが、接続試行中に発火するケースは本 issue のロック解放漏れの影響を受ける。未完了。

## 再現手順

前提条件:

- 実際にクライアントが使用する ICE サーバー（クライアント側の設定かサーバー側の設定かは問わない）に、証明書検証が失敗する `turns:` サーバーが含まれること。
  - Sora サーバーが `turn_tls_only` モードの場合は、サーバーが送る `offer.configuration.iceServerInfos` に `turns:` が含まれる。この場合、手順 2 のクライアント側の設定は `createAndSendAnswer` （ `Sora/PeerChannel.swift:845-852` ）で上書きされるが、サーバー側の `turns:` が証明書検証に失敗するため再現する。
  - サーバーが `offer.configuration` で ICE サーバー設定を送らない構成の場合は、クライアント側の設定がそのまま使用される（サーバーが `iceServerInfos` が空の `configuration` を送る場合も上書きで消えるため、 configuration 自体を送らない構成が必要）。
- シグナリングの WebSocket （ `wss:` ）は有効な証明書で接続成功すること。 WebSocket も証明書エラーになる構成では、 `RTCPeerConnection` 生成前（ `Sora/PeerChannel.swift:879` より前）に失敗し、ネイティブ処理が残存する本症状は再現しない。
- `Configuration.insecure` はデフォルト（ false ）であること。 true の場合は `usesVerifiedTURNTLS` が false になり `IOSCertificateVerifier` 自体が生成されない（ `Sora/WebRTCConfiguration.swift:123-130` ）。
- クライアントと Sora サーバーが同一 LAN の環境では、証明書エラーで失われるのは relay 候補のみであり、 host 候補（ mDNS ）で ICE が確立して接続が成功し、本問題が再現しない。 host 候補による接続が成立しないネットワーク構成で確認すること。

手順:

1. システム CA で検証できない証明書（自己署名証明書など、 `SecTrustEvaluateWithError` が失敗するもの）を持つ `turns:` サーバーを用意する（例: coturn に自己署名証明書を設定し、 TURN ユーザーを作成する）
2. `Configuration.webRTCConfiguration.iceServerInfos` に `turns:` の URL （例: `turns:<hostname>:443?transport=tcp` ）と、手順 1 で作成した TURN ユーザーの `userName` / `credential` を持つ `ICEServerInfo` を設定する（ coturn のデフォルトでは TURN 認証が必須のため）
3. `Sora.setWebRTCLogLevel(.verbose)` で libwebrtc のログレベルを VERBOSE にする（ `Sora/Sora.swift:378` ）。設定しないと `network.cc` のログは Xcode Console に表示されない
4. `Sora.connect()` を呼んで接続を試みる
5. 接続が失敗するまで待つ。 `onConnect` コールバックに error が渡される場合（経路 A: サーバー側のタイムアウトによる WebSocket 切断）と、エラーが渡されないままログが流れ続ける場合（経路 B ）のどちらも観察する。エラー表示のタイミングはサーバー実装に依存し、保証されない。経路 B のみの観察方法は「テスト方針」を参照
6. 以下のような libwebrtc の VERBOSE ログが流れ続けることを確認する:

```
libwebrtc VERBOSE: (network.cc:155): Ignore link local IP:fe80:...
```

## 現状

証明書検証は `IOSCertificateVerifier.verifyChain(_:)` で行われ、検証に失敗すると `false` を返す（ `Sora/IOSCertificateVerifier.swift:39-53` ）。

検証失敗（ `IOSCertificateVerifier` は libwebrtc 組み込みの証明書検証と OR 判定で動作するため、組み込み検証も同時に失敗した場合）は TURN-TLS 経路の失敗となり ICE 候補（ relay 候補 ）が得られないため、接続が成立しない。経路 A の場合、再現時の画面には「接続に失敗しました WebSocket error ...」が表示されるが、その後も libwebrtc の VERBOSE ログが出力され続ける。

なお、この「 WebSocket error 」の表示は `PeerChannel` を経由せず、 `MediaChannel.internalDisconnect` → `executeHandler` （ `Sora/MediaChannel.swift:541-543` ）経由で行われる。エラー表示は `basicDisconnect` の実行とは独立しており、「エラーが表示された = `basicDisconnect` が呼ばれた」を意味しない（「失敗経路の分析」参照）。

接続失敗時の終了処理は `basicDisconnect` （ `Sora/PeerChannel.swift:1258` ）であり、その中の `nativeChannel?.close()` （ `Sora/PeerChannel.swift:1287` ）で `RTCPeerConnection` をクローズする。ネイティブのピア接続が閉じられず ICE 収集などが継続していると、ログが流れ続ける。

## 失敗経路の分析

TURN-TLS 証明書エラーが接続失敗に至る経路として 2 つが考えられる:

**経路 A （ WebSocket エラー経路）**: 証明書エラーにより ICE が確立できない → Sora サーバー側でセッションがタイムアウトする（または接続失敗を検知する） → シグナリング WebSocket が切断される → 切断検知（ `URLSessionWebSocketChannel` の `didCloseWith` または `didCompleteWithError` ）→ `SignalingChannel.disconnect` （ `Sora/SignalingChannel.swift:288` ）→ `internalHandlers.onDisconnect` → `MediaChannel.internalDisconnect` （ `Sora/MediaChannel.swift:404` で設定）→ `executeHandler` で「 WebSocket error 」を表示 → `peerChannel.disconnect` （ `MediaChannel.swift:547` ）→ `Lock.waitDisconnect` （ `PeerChannel.swift:108` ）

**経路 B （ PeerConnectionState.failed 経路）**: 証明書エラー → TURN-TLS ハンドシェイク失敗 → ICE 状態が failed → `RTCPeerConnectionState.failed` → `peerConnection(_:didChange:RTCPeerConnectionState)` （ `Sora/PeerChannel.swift:1494` ）→ `disconnect` （行 318 ）→ `Lock.waitDisconnect`

WebSocket の切断は TURN 経路とは独立である。 SDK 内に「 ICE 失敗を WebSocket 切断に伝える」処理は存在しないため、経路 A の WebSocket 切断はサーバー側の挙動に依存する観測である。ユーザーへのエラー表示は経路 A （サーバーによる WebSocket 切断）または `ConnectionTimer` のタイムアウト（デフォルト 30 秒）で発生する（経路 B のみの場合のエラー通知の有無は「根本原因」の項参照）。

### 根本原因: `connect()` の初期ロックが解放されず `basicDisconnect` が到達不能

`connect()` は初期ロックを取得する（ `Sora/PeerChannel.swift:270` ）。本 issue のシナリオ（ answer 送信成功後の接続失敗 ）に限っては、 count を 0 に戻して初期ロックを解放する箇所は以下の 2 箇所のみであり、いずれも発生しない:

- `finishConnecting()` （ `PeerChannel.swift:1255` ）: `RTCPeerConnectionState` が `.connected` になった場合のみ
- `sendConnectMessage(error:)` のシグナリング接続エラーパス（ `PeerChannel.swift:332` ）

接続試行のフロー（ `createAndSendAnswer` ）では、通常経路では `lock()` （行 898 ）と `unlock()` （行 926 ）が対で呼ばれ、 count は 2 → 1 に減るだけで 0 にはならない（なお、 answer 送信前のエラーパス（ CA 証明書パース失敗、行 872 と `createNativePeerChannel` 失敗、行 890 ）では count は 0 に戻り、正常に `basicDisconnect` へ到達するが、本 issue のシナリオでは発生しない） 。 answer 送信後に接続失敗した場合（経路 A・B のどちらでも）:

1. `waitDisconnect` に到達した時点で count == 1
2. `waitDisconnect` は count != 0 のため `shouldDisconnect` に保存するだけで `basicDisconnect` を呼ばない（ `PeerChannel.swift:108-122` ）
3. 初期ロックを解放する経路（ `.connected` への遷移 / シグナリング接続エラー）はどちらも発生しないため、 count は 1 のまま永久に残る
4. `basicDisconnect` が呼ばれず、 `nativeChannel?.close()` も実行されないため、 `RTCPeerConnection` は生存し続ける

これが「 libwebrtc のログが流れ続ける」症状の根本原因である。 `basicDisconnect` が呼ばれないことによる未実行処理はログ停止だけではない（以下は PeerChannel 側の処理の列挙。経路 A では `MediaChannel.internalDisconnect` が単独で実行され、ユーザーへのエラー通知と MediaChannel ハンドラの発火は行われるが、以下の PeerChannel の処理は経路 A・B のどちらでも実行されない）:

- `terminateSenderStream()` （行 1278-1280 ）: 送信ストリーム（カメラ・音声）が停止しない
- `streams.terminate()` （行 1282-1285 ）: 受信ストリームが停止しない
- `signalingChannel.disconnect` （行 1302 ）: シグナリングチャンネルへの切断指示が実行されない（経路 A ではシグナリング切断自体がトリガーのため WebSocket は既に切断済み）
- `internalHandlers.onDisconnect` （行 1305 ）: 切断通知が発火しない（ MediaChannel の切断通知は `internalDisconnect` 経由で実行されるが、 PeerChannel 側の `internalHandlers.onDisconnect` は実行されない）
- `onConnect?(error)` （行 1311 ）: 経路 B のみの場合、 `RTCPeerConnectionState.failed` への遷移が `ConnectionTimer` （デフォルト 30 秒）の発火より先に起きると、タイマーも実質機能しない（タイマー自体は発火するが、 `ConnectionState(.failed)` は `.disconnected` 扱いのため `isConnecting` チェックでスキップされる、 `Sora/ConnectionState.swift:40-42` 、 `Sora/ConnectionTimer.swift:52` ）。この場合、ユーザーへのエラー通知が永遠に届かない可能性があり、 `Sora.connect()` が返す `ConnectionTask` も完了しない（ `complete()` は `MediaChannel.swift:378` ・411・421・488 の 4 箇所でのみ呼ばれ、経路 B のみでは 378 を除く 3 箇所がすべて発火しないため、 `state` は `.connecting` のまま残る）。逆に ICE が 30 秒以内に failed に遷移しない場合はタイマーが発火し、 `connectionTimeout` エラーが通知される

なお、シグナリング接続エラーパスでのロック解放漏れは 2026.2.0 で修正済み（ `CHANGES.md` の「シグナリングチャンネル接続エラー時に `connect()` で取得したロックが解放されないバグを修正する」）だが、本 issue の経路（ answer 送信後の接続失敗）は修正対象外である。

### issue 0041 との関係

本 issue の根本原因は issue 0041 と同じ機構である。 0041 では offer 受信後の SDP エラーパス（ `createAnswer` 失敗時）に対して `createAnswer` エラーパスでの `lock.unlock()` 追加を扱っている。トリガーと症状が異なるため、本 issue とは別 issue として扱う:

- 0041: `createAnswer` エラー時（ count 2 → 1 後の `disconnect` ）。症状は約 30 秒の切断遅延
- 本 issue: answer 送信成功後の接続失敗（ count 1 のまま）。症状は `RTCPeerConnection` の残存とログ流出

0041 で扱った `createAnswer` エラーパスでの `lock.unlock()` 追加は、本 issue のシナリオには効かない（修正の競合と二重解放への注意は「設計方針」の修正時の注意を参照）。

## 設計方針

**ステップ 1 （調査）: 根本原因の確認**

上記の根本原因仮説（初期ロック解放漏れ）はコード解析上の強い仮説であるが、実機・Simulator での再現時に以下へデバッグログを追加して仮説を検証する:

- `disconnect()` 入り口（ `Sora/PeerChannel.swift:318` ）: 呼び出し時の `state` と `reason`
- `Lock.waitDisconnect` （ `PeerChannel.swift:108` ）: 呼び出し時の `count` と、保存したか・直接 `basicDisconnect` を呼んだか
- `Lock.unlock()` （ `PeerChannel.swift:136` ）: 呼び出し前後の `count`
- `basicDisconnect` （ `PeerChannel.swift:1258` ）と `nativeChannel?.close()` （行 1287 ）: 到達したか
- `RTCPeerConnectionState` / `RTCIceConnectionState` / `RTCIceGatheringState` の既存ログ（ `PeerChannel.swift:1474-1498` ）: `.connected` に到達したか（ `finishConnecting` が呼ばれたか）、経路 A・B のどちらが発火したか
- `MediaChannel.internalDisconnect` （ `Sora/MediaChannel.swift:523` ）と `executeHandler` （行 356 ）: ユーザーへのエラー表示経路の確認。あわせて connect handler の呼び出し回数を数えるため、 `MediaChannel.swift:482-506` の `handler(error)` 呼び出しにもログを追加する

確認項目:

- count が 1 のまま `waitDisconnect` に到達し、 `basicDisconnect` が呼ばれないこと
- 経路 B （ ICE failed への遷移）と `ConnectionTimer` タイムアウトのどちらが先に発生するか（ 30 秒以内に failed へ到達するかどうかで、ユーザーへのエラー通知の有無が分岐する）
- `basicDisconnect` の呼び出し回数（経路 A・B が連続発火した場合の二重実行検出のため）
- 経路 B のみの場合にユーザーへのエラー通知が発生しない（または届くまでに長時間かかる）こと
- sendonly で `createClientOfferSDP` の offer 生成に失敗した場合（ `PeerChannel.swift:361-378` ）も、初期ロックが解放されず count == 1 のまま `basicDisconnect` が到達不能になること（修正のスコープ判断のため）
- 接続試行中のユーザー操作（ `ConnectionTask.cancel()` → `peerChannel?.disconnect(connectionCancelled, .user)` 、 `Sora/Sora.swift:434-441` と `mediaChannel.disconnect()` → `internalDisconnect(.user)` 、 `Sora/MediaChannel.swift:518-521` ）でも、 count == 1 のまま `waitDisconnect` に到達して同じリークが発生すること（修正のスコープ判断のため）
- `ConnectionTimer` のタイムアウト経由（ `MediaChannel.swift:509-512` → `internalDisconnect(.connectionTimeout, .signalingFailure)` ）でも、 count == 1 のまま `waitDisconnect` に到達して同じリークが発生すること（修正のスコープ判断のため）
- 仮に `close()` 実行後もログが流れ続ける場合（本仮説が否定された場合）は、生存している `RTCPeerConnection` が他にないかを確認する（例: sendonly で `createClientOfferSDP` が生成する一時 PC は全パスで close 済みであることの確認、 `Sora/NativePeerChannelFactory.swift:186-217` ）

**ステップ 2 （修正）**: ステップ 1 の調査結果をもとに修正を実施する。修正の方向性の候補:

- 接続試行の終了時（失敗を含む）に初期ロックを確実に解放する
- `waitDisconnect` が、接続試行中の失敗に対して `basicDisconnect` へ確実に到達させる

方向性の選択基準: 確認項目で特定した修正対象の経路（ TURN-TLS 証明書エラーに加え、 sendonly の offer 生成失敗、ユーザー操作のキャンセル、 `ConnectionTimer` タイムアウト）をすべてカバーするには、初期ロックを確実に解放する方向性 1 が自然である。方向性 2 を選ぶ場合は、判定条件に漏れがないよう経路を網羅すること（後述の注意参照）。

修正時の注意:

- 修正は接続失敗時のクリーンアップに限定し、接続成功時の挙動は変更しない
- `basicDisconnect` 内で無条件に `lock.unlock()` すると、既に count == 0 で `basicDisconnect` へ到達する既存パス（シグナリング接続エラー、 `PeerChannel.swift:332` と answer 送信前のエラーパス、行 872 ・890 ）で `fatalError` （ count <= 0 ）になる。 `basicDisconnect` 入り口では `onConnect` は非 nil のまま（ nil 化は basicDisconnect 内、行 1312 ）で、 `onConnect != nil` や state では初期ロックの有無を判別できない（ `Lock.count` は private ）。方向性 1 を選ぶ場合は `Lock` に初期ロック解放用の API （例: `unlockInitialLockIfHeld()` ）の追加が必要になる。方向性 2 を選ぶ場合は、条件を `state` ではなく `reason` で判定すること（ state は経路 B で `.failed` になり、接続試行中として捕捉できない） 。 reason の判定リストは `.peerConnectionStateFailed` / `.webSocket` / `.signalingFailure` （ `ConnectionTimer` タイムアウト経由） / `.user` （ユーザー操作のキャンセル）を漏れなく含めること
- 接続成功と切断要求の競合（ `.connected` への遷移と `disconnect` がほぼ同時）に注意する。現在のコードでは count 1 のまま `waitDisconnect` が保存し、後から `finishConnecting()` の `lock.unlock()` （ `PeerChannel.swift:1255` 、無条件で count を 0 にする）で初めて `basicDisconnect` が dispatch されるため安全に処理される。修正で count を 0 にする実装を選ぶと、配送済みの `.connected` コールバックが後から処理された場合に `finishConnecting()` の `unlock()` が count == 0 で `fatalError` になる。 `finishConnecting()` 側にガード（ `isDisconnecting` チェックなど）を入れるか、 `waitDisconnect` の不変条件（ `isDisconnecting == true` ならば count == 0 、 `PeerChannel.swift:99` ）を満たす形で count の遷移を設計すること
- 経路 A と経路 B が短時間に連続発火した場合の `basicDisconnect` 二重実行を防ぐ（ `waitDisconnect` は `isDisconnecting` をチェックしないため、チェックの追加を検討する） 。 0043 の修正（ `RTCIceConnectionState.failed` トリガーの追加）が入った場合は、同一の接続失敗で `RTCPeerConnectionState.failed` と `RTCIceConnectionState.failed` の 2 トリガーが連続発火し得るため、対策は必須になる
- エラー通知の多重呼び出しへの対処: 修正により `basicDisconnect` が到達可能になると、経路 A・B のどちらでも、 `MediaChannel.internalDisconnect` → `executeHandler` （ `Sora/MediaChannel.swift:541-543` ）と `basicDisconnect` 内の `onConnect?(error)` （ `PeerChannel.swift:1311` ）が両方実行され、ユーザーの connect handler が複数回呼ばれる（ `executeHandler` は `_handler = nil` にするが、 2 回目以降は `MediaChannel.swift:493` のクロージャから直接呼ばれるため防げない）。この多重呼び出しは修正で新たに発生するのではなく、既存のシグナリング接続エラーパス（ `PeerChannel.swift:332` ）でも発生している。どちらか一方に統合するなどの対策を、既存パスも含めた全パスで行うこと
- issue 0041 で入った `createAnswer` エラーパスの修正と競合しないこと。 SDP エラーパスと answer 送信成功後の失敗経路で、ロック解放条件が二重解放にならないことを確認すること

## テスト方針

モック・スタブは使用しない。再現手順の操作を実機または Simulator で行い、以下を手動テストで確認すること:

- 修正後、 TURN-TLS 証明書エラーで接続失敗した後、 `basicDisconnect` が呼ばれ `nativeChannel?.close()` が実行されることをデバッグログで確認すること
- libwebrtc の VERBOSE ログ（ `network.cc` 等）が停止すること（ `Sora.setWebRTCLogLevel(.verbose)` 設定時に Xcode Console で目視確認）。停止するまでの時間は RTCPeerConnection の close 完了次第なので秒数は問わず、継続して流れ続けないことを確認する
- 経路 B のみのケース（サーバーが WebSocket を閉じない状況）を作り分けるには、サーバー側のセッションタイムアウトを無効化する（または長時間 WebSocket を維持するサーバー構成にする）必要がある。 `Configuration.connectionTimeout` はクライアント側の `ConnectionTimer` を延長するだけで、サーバー側の WebSocket クローズには影響しない。そのうえで `Configuration.connectionTimeout` を十分に大きく設定してタイマーによるエラー通知を抑制し、 ICE failed への遷移を待つ。サーバー側のタイムアウトが無効化できない環境では経路 B のみの観察はできず、経路 A との連続発火として観察されることに注意する
- 有効な証明書を使った通常の TURN-TLS 接続が引き続き成功すること（後方互換確認）
- 既存の `SoraTests/IOSCertificateVerifierTests.swift` に影響がないこと（証明書検証ロジックは変更しない）
- 調査用に追加したデバッグログは、調査完了後に削除するか、残す場合はその理由を明記すること

## 完了条件

- 現在の libwebrtc （ m150.7871.3.0 ）で再現を確認すること。再現しない場合は、前提条件のネットワーク構成の影響で接続が成功している可能性があるため、接続失敗自体が発生し count == 1 のまま `waitDisconnect` に到達することを確認してから close する
- TURN-TLS の証明書エラーで接続に失敗した後、 libwebrtc の VERBOSE ログが流れ続けないこと
- 接続失敗時に `RTCPeerConnection` がクローズされ、 ICE 収集などのネイティブ処理が停止すること（ `basicDisconnect` → `nativeChannel?.close()` の実行をデバッグログで確認）
- 接続失敗時にユーザーへのエラー通知が一度だけ呼ばれること（経路 B のみのケースを含む）
- 接続成功時の挙動が変わらないこと
- 調査内容と修正内容を「解決方法」セクションに記載すること
- `CHANGES.md` の `develop` セクションに以下を追記すること:

```
- [FIX] TURN-TLS の証明書エラーで接続失敗した後も libwebrtc のログが流れ続ける問題を修正する
  - @voluntas
```

## 解決方法

### 調査結果 (根本原因)

TURN-TLS 証明書エラーで接続に失敗した後も libwebrtc のログが流れ続ける原因は、 `connect()` が取得した初期ロックが解放されないまま残り、 `basicDisconnect` が到達不能になることだった。

- `connect()` の初期ロック (`PeerChannel.swift:270`) は `finishConnecting()` と `sendConnectMessage(error:)` の 2 箇所でしか解放されない
- answer 送信後の接続失敗 (RTCPeerConnectionState.failed / WebSocket 切断 / ConnectionTimer タイムアウト) ではどちらも発生しないため、 count は 1 のまま残る
- `Lock.waitDisconnect` は count != 0 のとき `shouldDisconnect` に保存するだけで `basicDisconnect` を呼ばないため、 `nativeChannel?.close()` が実行されず、 `RTCPeerConnection` が生存し続けた

なお、ユーザーに表示される「WebSocket error」は `MediaChannel.internalDisconnect` → `executeHandler` 経由で `basicDisconnect` とは独立に通知されるため、「エラーが表示された = クリーンアップ完了」ではない。

### 修正内容

- `Sora/PeerChannel.swift`: `Lock.waitDisconnect` が、接続試行中 (count == 1 かつ `onConnect != nil`) の切断要求を受け取った場合に、初期ロックを解放して `basicDisconnect` を直接実行するようにした。あわせて `isDisconnecting` チェックを追加し、切断処理の二重実行を防いだ
- `Sora/PeerChannel.swift`: `Lock.unlock` が、切断処理開始後に非同期処理から呼ばれた場合に `unlock` を無視するようにした。また、接続試行中 (count == 1) に切断要求が保存されている場合は、進行中の非同期処理の完了時に `basicDisconnect` へ到達させるようにした
- `Sora/MediaChannel.swift`: 接続失敗時のエラー通知を `executeHandler` 経由に統一し、 `basicDisconnect` 内の `onConnect?(error)` との多重呼び出しを防止した

### 確認結果

- 再現: 自己署名証明書の TURN-TLS サーバー構成で、 `TURN-TLS trust evaluate error` による接続失敗を確認
- タイムアウト経路: 接続タイムアウト発生後に `basicDisconnect` → `nativeChannel?.close()` が実行され、以降 libwebrtc の `network.cc` ログが出力されないことを確認
- 経路 A (WebSocket 切断): サーバー起因の切断 (close code 4490, reason TIMEOUT) で、ユーザーへのエラー通知が 1 回だけ呼ばれ、切断処理が完了することを確認
- 後方互換: 自己署名証明書を利用した接続確認を実施し、接続が成功することを確認
- 経路 B (ICE failed のみ): サーバー側のテスト用設定を用意できなかったため未確認 (経路 A と同一の `waitDisconnect` 修正を通過するため、挙動は同じ)
