# WebSocket シグナリングでクライアント証明書を指定できるようにする

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-websocket-client-certificate
- Polished: 2026-06-06

## 目的

WebSocket シグナリング接続においてクライアント証明書（PKCS#12 形式）を指定できるようにする。クライアント認証が必要な環境（企業内 mTLS 環境など）での接続を可能にする。

## 優先度根拠

企業内システムとの連携で mTLS 認証が求められるケースが存在し、現状では SDK がクライアント証明書を扱う手段を提供していないため対応が必要。ただし一般的な用途では不要な機能であり、High とするほどの緊急性はないため Medium とする。

## 依存関係

- `0022-add-user-ca-certificate`：`Configuration` への公開 API 追加方針と `SoraError.configurationError` の追加は 0022 で行うため、0022 の完了後に本 issue に着手すること
- `0020-add-websocket-ca-certificate`：WebSocket の証明書検証処理を実装した 0020 と合わせて実装すること
- `0064-add-turn-tls-client-certificate`：本 issue で確定した型設計を TURN-TLS 側（0064）でも統一すること

## 現状

`URLSessionWebSocketChannel.swift` の `urlSession(_:task:didReceive:completionHandler:)` デリゲートメソッド（行 231–277）は `switch authMethod` で `NSURLAuthenticationMethodServerTrust` と `NSURLAuthenticationMethodHTTPBasic` の 2 ケースのみを処理し、`NSURLAuthenticationMethodClientCertificate` は `default:` に落ちて `performDefaultHandling` で無視される（行 269–275）。

`Configuration` には `clientP12Data` や `clientP12Password` に相当するプロパティが存在しない。

`URLSessionWebSocketChannel.init(url:proxy:)` は `url` と `proxy` の 2 引数のみを受け取り（行 25–28）、クライアント証明書を渡す経路がない。`SignalingChannel` の `setUpWebSocketChannel(url:proxy:)` も同様に 2 引数のみである（行 109）。

## 設計方針

### 型設計

`Configuration.swift` の `proxy` プロパティ（行 217）の直後に以下の 2 プロパティを追加する。

```swift
/// WebSocket シグナリングで使用するクライアント証明書の PKCS#12 データ。
/// nil を指定するとクライアント証明書認証を行わない。
public var clientP12Data: Data?

/// clientP12Data に対応する PKCS#12 パスワード。
/// nil を指定した場合は空文字列として扱う（パスワードなし PKCS#12 には nil を指定する）。
public var clientP12Password: String?
```

**PKCS#12 形式を採用する理由**: iOS で `NSURLAuthenticationMethodClientCertificate` チャレンジに応答するには `URLCredential(identity:certificates:persistence:)` が必要であり、このイニシャライザには `SecIdentity` 型が必須である。`SecIdentity` を得る最もシンプルな方法は `SecPKCS12Import` による PKCS#12 インポートであり、`SecCertificate + SecKey` のペアから直接 `SecIdentity` を生成するキーチェーン非依存の公開 API が iOS に存在しない。

### `Configuration` への変換メソッド追加

`Configuration.swift` に `internal func parsedClientIdentity() throws -> SecIdentity?` を追加する。`clientP12Data` が `nil` の場合は `nil` を返す（後方互換）。`clientP12Data` が非 `nil` の場合は `SecPKCS12Import` でインポートし、戻り値の配列から `kSecImportItemIdentity` キーで `SecIdentity` を取り出して返す。インポート失敗時または `SecIdentity` を取り出せなかった場合は `SoraError.configurationError(reason:)` を throw する。`clientP12Password` が `nil` の場合は空文字列をパスワードとして使う。

`internal` とするのは `SignalingChannel` から呼び出すためであり、0022 の `parsedCACertificates()` と同じスコープ設計に従う。

### `URLSessionWebSocketChannel` の変更

`URLSessionWebSocketChannel.swift`:

- `init(url:proxy:)` を `init(url:proxy:clientIdentity:)` に変更し、`clientIdentity: SecIdentity?` 引数を追加する
- インスタンスプロパティとして `let clientIdentity: SecIdentity?` を追加する

`SignalingChannel.swift`:

- `setUpWebSocketChannel(url:proxy:)` を `setUpWebSocketChannel(url:proxy:clientIdentity:)` に変更する（行 109）
- `connect` 内（行 214–221 の `for url in urlCandidates` ループ）では、ループの外（`let urlCandidates = unique(urls:)` の直後）で `parsedClientIdentity()` を 1 回だけ呼び出す。throw 時のエラー伝播は 0022 の設計方針（issue 0022 行 76–77）に従い `disconnect(error:reason: .signalingFailure)` 経由で行うこと。ただし接続コールバック（`onConnect?`）にエラーを返す必要があるため、`onConnect?(error)` を呼んだ後 `disconnect(error:reason: .signalingFailure)` を呼ぶこと（`disconnect` は `internalHandlers.onDisconnect` のみを呼ぶため、`onConnect?` を呼ばないと呼び出し元の `connect(handler:)` にエラーが伝わらない）
- `redirect` 内（行 242）では、`setUpWebSocketChannel` の呼び出し直前で `parsedClientIdentity()` を呼び出す。`try?` は使わず `do { ... } catch { disconnect(error: error, reason: .signalingFailure); return }` パターンで例外を処理すること（`try?` を使うと throw が `nil` に変換されてエラーが握り潰されるため）

### `NSURLAuthenticationMethodClientCertificate` チャレンジの処理

`switch authMethod` の `case NSURLAuthenticationMethodHTTPBasic:` の直後（行 267 と `default:` の間）に以下を追加する。

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

既存のガード節（`URLSessionWebSocketChannel.swift` 行 242–251）は `previousFailureCount != 0` の場合に一律キャンセルし、エラーメッセージが「Basic authentication failed」固定になっており、`switch` 前の共通ガードとして全認証方式に適用されている。

このガード節を `handleBasicAuthenticationChallenge` の冒頭に移動することで、`NSURLAuthenticationMethodHTTPBasic` のみに適用するよう変更する。`urlSession(_:task:didReceive:completionHandler:)` の共通ガード節は削除する。これにより `NSURLAuthenticationMethodServerTrust` には `previousFailureCount` チェックが適用されなくなるが、`ServerTrust` チャレンジで `previousFailureCount > 0` になるケースは実用上発生しないため問題ない。`NSURLAuthenticationMethodClientCertificate` チャレンジでは `handleClientCertificateChallenge` 内の独自チェックで処理する。

## テスト方針

モック・スタブは使用しない。`parsedClientIdentity()` は `SecPKCS12Import` に依存するため、不正な PKCS#12 データ（任意のバイト列）を渡した場合の `SoraError.configurationError` 返却はシミュレーターで検証可能であり、ユニットテストを追加してよい。

以下の動作確認を実機で行い、結果を `## 解決方法` に記載すること。

- クライアント証明書を要求する Sora サーバー（mTLS 設定）に接続できること。初期実装では `certificates: nil`（中間 CA チェーンなし）で接続できることをここで確認すること
- `clientP12Data` が `nil` の場合は従来どおり接続できること（後方互換）
- 不正な PKCS#12 データまたは間違ったパスワードを指定した場合に `connect()` コールバックに `SoraError.configurationError` が返ること
- `redirect` 後の再接続でもクライアント証明書が正しく引き渡されること

## 完了条件

- 依存 issue 0022 が完了し `SoraError.configurationError(reason: String)` が `SoraError.swift` に定義済みであること（未定義の場合はコンパイルエラーになる）
- `Configuration` に `public var clientP12Data: Data?` および `public var clientP12Password: String?` プロパティが追加されていること
- `Configuration` に `internal func parsedClientIdentity() throws -> SecIdentity?` が実装されていること
- `URLSessionWebSocketChannel.init` に `clientIdentity: SecIdentity?` 引数が追加され、`private func handleClientCertificateChallenge` が実装されていること
- `handleClientCertificateChallenge` 内で `previousFailureCount != 0` の場合に接続を切断していること
- `SignalingChannel.setUpWebSocketChannel` のシグネチャが更新され、`connect` 内（for ループ外で 1 回）と `redirect` 内（`do-catch` パターン）の 2 箇所が更新されていること
- `previousFailureCount` ガードが `handleBasicAuthenticationChallenge` 内に移動されていること
- `clientP12Data` が `nil` の場合は既存の動作が変わらないこと（後方互換）
- テスト方針に記載した動作確認がすべてパスしていること
- `CHANGES.md` の `## develop` セクションに以下を追記すること

```
- [ADD] WebSocket シグナリングでクライアント証明書（PKCS#12）を指定できるようにする
  - @voluntas
```

## 解決方法
