# ユーザーが CA 証明書を指定するための公開 API を追加する

- Priority: High
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-user-ca-certificate
- Polished: 2026-06-05

## 目的

企業内で自前のプライベート CA を利用している環境向けに、サーバー証明書検証用の CA 証明書をユーザーが指定できる公開 API を `Configuration` に追加する。指定された CA 証明書は WebSocket シグナリング経路（ 0020 ）と TURN-TLS 経路（ 0021 ）の両方の証明書検証で共通利用する。

本 issue は CA 証明書を受け取る公開 API の設計・追加と PEM → `SecCertificate` 変換の実装に限定し、実際の検証処理は 0020 / 0021 で行う。

## 優先度根拠

- 本 issue で追加する公開 API は、 0020 （ WebSocket シグナリング証明書検証）と 0021 （ TURN-TLS 証明書検証）の両方が依存する唯一の入口である。本 issue が完成しないと両者の機能をユーザーが一切利用できないため最優先（ High ）とする。

## 現状

`Configuration` には接続に必要な各種設定が公開プロパティとして定義されているが、 CA 証明書を指定するプロパティは存在しない（ `Sora/Configuration.swift:216-225` 付近を参照）。

証明書検証は経路ごとに独立しており、いずれもシステム CA による検証のみで、ユーザー指定 CA を受け取る入口が無い。詳細は以下を参照すること:

- WebSocket シグナリング経路の現状: `0020-add-websocket-ca-certificate`
- TURN-TLS 経路の現状: `0021-add-turn-tls-ca-certificate`

## 設計方針

**プロパティ定義**:

- プロパティ名は `caCertificate` とし、型は `String?` とする。 PEM 形式（ `-----BEGIN CERTIFICATE-----` / `-----END CERTIFICATE-----` ブロック）の文字列を受け取る。複数の CA 証明書（中間 CA を含む構成）が必要な場合は、複数の PEM ブロックを連結した文字列を渡す。デフォルトは `nil` で後方互換性を維持する。
- `Sora/Configuration.swift` の `proxy` プロパティ（行 217 ）の直後に追加する:

  ```swift
  /// サーバー証明書検証に使用する CA 証明書の PEM 文字列。
  /// nil を指定するとシステム CA による既定の検証を行う。
  public var caCertificate: String?
  ```

**`SoraError` の拡張**:

- `Sora/SoraError.swift` の `enum SoraError` に `case configurationError(reason: String)` を追加する（現在このケースは存在しない）。
- `LocalizedError` extension の `errorDescription` の `switch` 文に `case .configurationError(let reason): return "Configuration error (\(reason))"` を追加する。

**PEM → `[SecCertificate]` 変換**:

- `Sora/Configuration.swift` に以下の `internal` メソッドを追加する。 `private` ではなく `internal` とすることで `SignalingChannel` と `PeerChannel` から呼び出せるようにする:

  ```swift
  // internal: SignalingChannel および PeerChannel から呼び出す
  func parsedCACertificates() throws -> [SecCertificate]? {
    guard let pem = caCertificate else { return nil }
    let certs = Configuration.parsePEMCertificates(pem)
    if certs.isEmpty {
      throw SoraError.configurationError(reason: "caCertificate contains no valid PEM certificates")
    }
    return certs
  }
  ```

- 変換の実装は `private static func parsePEMCertificates(_ pem: String) -> [SecCertificate]` として `Configuration.swift` に追加する。アルゴリズムは以下:
  1. PEM 文字列から `-----BEGIN CERTIFICATE-----` から `-----END CERTIFICATE-----` までの各ブロックを正規表現等で抽出する。
  2. 各ブロックからヘッダー・フッターを除去し、改行を除去して Base64 デコードし DER バイト列を得る。
  3. `SecCertificateCreateWithData(nil, derData as CFData)` を呼んで `SecCertificate` を生成する。生成できなかった（ `nil` が返った）ブロックはスキップする。
  4. 生成できた `SecCertificate` の配列を返す。

**変換失敗時の挙動**:

- `caCertificate` が `nil` の場合は `nil` を返し（後方互換、エラーなし）、システム CA による検証を行う。
- `caCertificate` が非 `nil` だが有効な証明書を 1 つも含まない（不正な PEM 形式・空文字列等）の場合は `SoraError.configurationError` を throw する。この throw は接続時（ `connect()` の処理中）に発生し、 connect のコールバック（ `handler: (MediaChannel?, Error?) -> Void` ）にエラーとして伝播される。

**配線（両経路への伝播）**:

- WebSocket 経路（ 0020 の担当範囲）: `SignalingChannel.setUpWebSocketChannel` の呼び出し元（ `connect` / `redirect` ）で `try configuration.parsedCACertificates()` を呼び出し、結果を `setUpWebSocketChannel` の引数として渡す。 throw 時はエラーを `disconnect(error:reason:)` 経由で接続コールバックに伝播させること。
- TURN-TLS 経路（ 0021 の担当範囲）: `PeerChannel.swift` 行 822 の `createNativePeerChannel` 呼び出し前に `try configuration.parsedCACertificates()` を呼び出し、結果の `[SecCertificate]?` を `caCertificates:` 引数として渡す。 throw 時は同様に接続コールバックに伝播させること。
- 本 issue のスコープはプロパティ追加・変換関数の実装・ `SoraError.configurationError` 追加のみとし、各経路への引数追加と throw 伝播の実装は 0020 / 0021 で行う。

## テスト方針

モック・スタブは使用しない。 `parsedCACertificates()` と `parsePEMCertificates(_:)` は純粋な文字列処理と `SecCertificate` 生成のみであるため、実際のネットワーク接続なしでユニットテストを書ける。

以下をテストすること。テストの追加先は `SoraTests/ConfigurationTests.swift` を新規作成すること:

- `caCertificate` が `nil` の場合、 `parsedCACertificates()` が `nil` を返すこと（エラーなし）。
- 有効な自己署名証明書の PEM 文字列を渡すと `[SecCertificate]` が 1 件返ること。
- 複数の PEM ブロックを連結した文字列を渡すと `[SecCertificate]` が 2 件以上返ること。
- 不正な PEM 文字列（ヘッダー・フッターなし、 Base64 として無効な文字列等）を渡すと `SoraError.configurationError` が throw されること。

テスト用の PEM 文字列はテストコード内のリテラルとして埋め込むこと。 `openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -out /dev/stdout -days 3650 -subj "/CN=test"` 等で生成した自己署名証明書の PEM テキストを直接記述する（固定のテスト専用 PEM であり機密情報ではない）。 `SoraTests/Fixtures/` にファイルとして配置する場合は `Package.swift` の `testTarget` に `resources: [.process("Fixtures")]` の追加が必要になるため、リテラル埋め込みを推奨する。

## 完了条件

- `Configuration` に `public var caCertificate: String?` プロパティが追加されていること。
- `internal func parsedCACertificates() throws -> [SecCertificate]?` が実装されていること。
- `private static func parsePEMCertificates(_ pem: String) -> [SecCertificate]` が実装されていること。
- `SoraError` に `case configurationError(reason: String)` が追加され、 `LocalizedError.errorDescription` にも対応する `case` が追加されていること。
- `caCertificate` が `nil` の場合は既存の動作が変わらないこと（後方互換）。
- `caCertificate` が不正な PEM の場合は `connect()` コールバックに `SoraError.configurationError` が渡されること（ 0020 / 0021 で配線が完了した後に確認可能）。
- テスト方針に記載したテストがすべて通ること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] Configuration にサーバー証明書検証用の CA 証明書を指定する公開プロパティを追加する
    - @voluntas
  ```

## 解決方法
