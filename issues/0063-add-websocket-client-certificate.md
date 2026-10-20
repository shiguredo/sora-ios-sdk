# WebSocket シグナリングでクライアント証明書を指定できるようにする

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-websocket-client-certificate
- Polished: 2026-09-24

## 目的

WebSocket シグナリング接続においてクライアント証明書 (PKCS#12 形式) を指定できるようにする。クライアント認証が必要な環境（企業内 mTLS 環境など）での接続を可能にする。

## 優先度根拠

企業内システムとの連携で mTLS 認証が求められるケースが存在し、現状では SDK がクライアント証明書を扱う手段を提供していないため対応が必要。ただし一般的な用途では不要な機能であり、High とするほどの緊急性はないため Medium とする。

## 依存関係

- `0022-add-user-ca-certificate`：完了済み (2026-06-26)。`Configuration` への公開 API 追加方針と `SoraError.configurationError` の追加は 0022 で行われた。本 issue はこれに倣う
- `0020-add-websocket-ca-certificate`：完了済み (2026-07-07)。WebSocket の証明書検証処理（server trust challenge）は 0020 で実装済みであり、本 issue は同じ `urlSession(_:task:didReceive:completionHandler:)` デリゲートメソッドへクライアント証明書チャレンジの処理を追加する
- `0064-add-turn-tls-client-certificate`：pending。本 issue で確定した型設計 (`clientP12Data` / `clientP12Password`) を TURN-TLS 側 (0064) でも統一すること

## 現状

`URLSessionWebSocketChannel.swift` の `urlSession(_:task:didReceive:completionHandler:)` デリゲートメソッド内の `switch authMethod` は `NSURLAuthenticationMethodServerTrust` と `NSURLAuthenticationMethodHTTPBasic` の 2 ケースのみを処理し、`NSURLAuthenticationMethodClientCertificate` は `default:` に落ちて `performDefaultHandling` で無視される。

`Configuration` には `clientP12Data` や `clientP12Password` に相当するプロパティが存在しない。

接続開始時に `Configuration` から写し取られる `ConnectionConfigurationSnapshot` にもクライアント証明書に関する値はなく、`SignalingChannel` から `URLSessionWebSocketChannel` へクライアント証明書を渡す経路がない。`SignalingChannel.setUpWebSocketChannel(url:proxy:caCertificates:)` は `url`・`proxy`・`caCertificates` の 3 引数を受け取り、`URLSessionWebSocketChannel.init(url:proxy:caCertificates:insecure:)` も同様にクライアント証明書を受け取れない。

## 設計方針

### 型設計

`Configuration.swift` の `insecure` プロパティの直後（`caCertificate` と並ぶ証明書関連設定のグループ内）に以下の 2 プロパティを追加する。

```swift
/// WebSocket シグナリングで使用するクライアント証明書の PKCS#12 データ。
/// nil を指定するとクライアント証明書認証を行わない。
public var clientP12Data: Data?

/// clientP12Data に対応する PKCS#12 パスワード。
/// nil を指定した場合は空文字列として扱う (パスワードなし PKCS#12 には nil を指定する)。
public var clientP12Password: String?
```

`ConnectionConfigurationSnapshot.swift` の `caCertificate` プロパティの直後にも、型を同じくする `let clientP12Data: Data?` と `let clientP12Password: String?` を追加し、`init(configuration:)` で `Configuration` の値へ写し取る。`SignalingChannel` は `Configuration` を保持せず `ConnectionConfigurationSnapshot` のみを持つため、この写し取りを省略すると接続経路へ値が届かない。

**PKCS#12 形式を採用する理由**: iOS で `NSURLAuthenticationMethodClientCertificate` チャレンジに応答するには `URLCredential(identity:certificates:persistence:)` が必要であり、このイニシャライザには `SecIdentity` 型が必須である。`SecIdentity` を得る最もシンプルな方法は `SecPKCS12Import` による PKCS#12 インポートであり、`SecCertificate + SecKey` のペアから直接 `SecIdentity` を生成するキーチェーン非依存の公開 API が iOS に存在しない。

### クライアント証明書の解析メソッド追加

0022 の `parsePEMCertificates` / `parsedCACertificates` と同じ構成で、以下を追加する。

- `Configuration.parsePKCS12Identity(data:password:) throws -> SecIdentity` (static, internal)
  - `SecPKCS12Import` でインポートし、戻り値の配列から `kSecImportItemIdentity` キーで `SecIdentity` を取り出して返す
  - インポート失敗時または `SecIdentity` を取り出せなかった場合は `SoraError.configurationError(reason:)` を throw する
  - 解析のコアを `Configuration` の static メソッドに置くことで、既存の `ConfigurationTests` と同様にユニットテストから直接検証できるようにする
- `ConnectionConfigurationSnapshot.parsedClientIdentity() throws -> SecIdentity?` (internal)
  - `clientP12Data` が `nil` の場合は `nil` を返す（後方互換）
  - 非 `nil` の場合は `Configuration.parsePKCS12Identity(data:password:)` を呼ぶ。`clientP12Password` が `nil` の場合は空文字列をパスワードとして使う

`internal` とするのは `SignalingChannel` から `self.snapshot.parsedClientIdentity()` として呼び出すためであり、0022 の `parsedCACertificates()` と同じスコープ設計に従う。

### `URLSessionWebSocketChannel` の変更

`URLSessionWebSocketChannel.swift`:

- `init(url:proxy:caCertificates:insecure:)` に `clientIdentity: SecIdentity?` 引数を追加し、`init(url:proxy:caCertificates:insecure:clientIdentity:)` にする
- インスタンスプロパティとして `let clientIdentity: SecIdentity?` を追加する
- `SoraTests/URLSessionWebSocketChannelTests.swift` の `URLSessionWebSocketChannel(...)` 呼び出し 2 箇所 (`makeChannelWithTask` / `makeChannel`) へ `clientIdentity: nil` を追加する

`SignalingChannel.swift`:

- `setUpWebSocketChannel(url:proxy:caCertificates:)` に `clientIdentity: SecIdentity?` 引数を追加し、`URLSessionWebSocketChannel` のイニシャライザへ渡す
- `connect(handler:)` では、`ConnectionConfigurationSnapshot.parsedClientIdentity()` を CA 証明書のパース（`urlCandidates` の生成前）と同じ場所で 1 回だけ呼び出す。throw 時は CA 証明書のパース失敗と同じ経路で終端する: `owner.handle(.connectionFailed)` で state を `.disconnected` へ遷移させ、`owner.takeOnConnect()` を取り出して `onConnect(error)` を呼ぶ（`SoraError.configurationError` が利用者へ届く）。**`disconnect(error:reason:)` は呼ばない**。0022 の設計方針（接続開始前の設定エラーは `onConnect(error)` で即時に返し、`disconnect(error:reason:)` は呼ばない）に従う。`disconnect` は `internalHandlers.onDisconnect` を呼ぶため、ここで呼ぶと接続前の設定エラーで `onDisconnect` と `onConnect` の両方が発火し、二重のエラー通知になる
- `redirect(location:)` では、`setUpWebSocketChannel` の呼び出し直前で `parsedClientIdentity()` を呼び出す。`try?` は使わず `do { ... } catch { disconnect(error: error, reason: .signalingFailure); return }` パターンで例外を処理すること（`try?` を使うと throw が `nil` に変換されてエラーが握り潰されるため）。これは現行の CA 証明書パース失敗（`SignalingChannel.swift` の redirect 内の `parsedCACertificates()` 呼び出し）と同じ取り扱いにする

### `NSURLAuthenticationMethodClientCertificate` チャレンジの処理

`switch authMethod` の `case NSURLAuthenticationMethodHTTPBasic:` の直後と `default:` の間に以下を追加する。

```swift
case NSURLAuthenticationMethodClientCertificate:
  handleClientCertificateChallenge(challenge, completionHandler: completionHandler)
```

以下のプライベートメソッドを追加する。

```swift
private func handleClientCertificateChallenge(
  _ challenge: URLAuthenticationChallenge,
  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
)
```

実装内容:
- `challenge.previousFailureCount != 0` の場合は `cancelAuthenticationChallenge` を呼び、`SoraError.signalingChannelError(reason:)` でエラーメッセージを作成して `disconnect(error:)` を呼ぶ（サーバーがクライアント証明書を拒否して再チャレンジを送ってきた場合の処理）
- `clientIdentity` が `nil` の場合は `.performDefaultHandling` を返す（クライアント証明書未設定の場合はサーバー側の判断に任せる）
- `clientIdentity` が非 `nil` の場合は `URLCredential(identity: identity, certificates: nil, persistence: .forSession)` を生成して `.useCredential` で返す。`certificates: nil`（中間 CA チェーンなし）は初期実装の制約であり、PKCS#12 に中間 CA が含まれる場合でも `SecPKCS12Import` の `kSecImportItemCertChain` は使わない。これにより一部の mTLS 環境（クライアントが中間 CA を提示することをサーバーが要求する構成）では接続が失敗する可能性がある

### `previousFailureCount` ガードの修正

既存のガード節（`urlSession(_:task:didReceive:completionHandler:)` の冒頭、`switch` より前の共通ガード）は `previousFailureCount != 0` の場合に一律キャンセルし、エラーメッセージが「Basic authentication failed」固定になっており、全認証方式に適用されている。

このガード節を `handleBasicAuthenticationChallenge` の冒頭に移動することで、`NSURLAuthenticationMethodHTTPBasic` のみに適用するよう変更する。`urlSession(_:task:didReceive:completionHandler:)` の共通ガード節は削除する。これにより `NSURLAuthenticationMethodServerTrust` には `previousFailureCount` チェックが適用されなくなるが、`ServerTrust` チャレンジで `previousFailureCount > 0` になるケースは実用上発生しないため問題ない。`NSURLAuthenticationMethodClientCertificate` チャレンジでは `handleClientCertificateChallenge` 内の独自チェックで処理する。

## テスト方針

モック・スタブは使用しない。PKCS#12 の解析は `SecPKCS12Import` に依存するため、不正な PKCS#12 データ（任意のバイト列）を渡した場合の `SoraError.configurationError` 返却はシミュレーターで検証可能であり、`ConfigurationTests.swift` に `Configuration.parsePKCS12Identity(data:password:)` のユニットテストを追加してよい。

以下の動作確認を実機で行い、結果を `## 解決方法` に記載すること。

- クライアント証明書を要求する Sora サーバー（mTLS 設定）に接続できること。初期実装では `certificates: nil`（中間 CA チェーンなし）で接続できることをここで確認すること
- `clientP12Data` が `nil` の場合は従来どおり接続できること（後方互換）
- 不正な PKCS#12 データまたは間違ったパスワードを指定した場合に `connect()` コールバックに `SoraError.configurationError` が返ること
- `redirect` 後の再接続でもクライアント証明書が正しく引き渡されること

## 完了条件

- `Configuration` に `public var clientP12Data: Data?` および `public var clientP12Password: String?` プロパティが追加されていること
- `ConnectionConfigurationSnapshot` に `clientP12Data` / `clientP12Password` が追加され、`init(configuration:)` で写し取られていること
- `Configuration.parsePKCS12Identity(data:password:)` と `ConnectionConfigurationSnapshot.parsedClientIdentity()` が実装されていること
- `URLSessionWebSocketChannel.init` に `clientIdentity: SecIdentity?` 引数が追加され、`private func handleClientCertificateChallenge` が実装されていること
- `handleClientCertificateChallenge` 内で `previousFailureCount != 0` の場合に接続を切断していること
- `SignalingChannel.setUpWebSocketChannel` のシグネチャが更新され、`connect` 内（for ループ外で 1 回）と `redirect` 内（`do-catch` パターン）の 2 箇所が更新されていること
- `connect` 内の `parsedClientIdentity()` 失敗時に `disconnect(error:reason:)` を呼ばず、現行の CA 証明書パース失敗と同じ経路（`connectionFailed` + `onConnect(error)`）で終端していること
- `previousFailureCount` ガードが `handleBasicAuthenticationChallenge` 内に移動されていること
- `clientP12Data` が `nil` の場合は既存の動作が変わらないこと（後方互換）
- `URLSessionWebSocketChannelTests.swift` のイニシャライザ呼び出し 2 箇所が更新されていること
- テスト方針に記載した動作確認がすべてパスしていること
- `CHANGES.md` の `## develop` セクションに以下を追記すること

```
- [ADD] WebSocket シグナリングでクライアント証明書 (PKCS#12) を指定できるようにする
  - @voluntas
```

## 解決方法
