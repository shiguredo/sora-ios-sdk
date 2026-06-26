# ユーザーが CA 証明書を指定するための公開 API を追加する

- Priority: High
- Created: 2026-06-03
- Completed: 2026-06-26
- Model: Opus 4.8
- Branch: feature/add-user-ca-certificate
- Polished: 2026-06-05

## 目的

企業内で自前のプライベート CA を利用している環境向けに、サーバー証明書検証用の CA 証明書をユーザーが指定できる公開 API を `Configuration` に追加する。本 issue は API の追加と PEM → `SecCertificate` 変換の実装に限定し、実際の検証処理への配線は 0020 / 0021 で行う。

## 実装内容

### Configuration.swift

- `public var caCertificate: String?` を追加（`proxy` 直後、デフォルト `nil` で後方互換維持）
- `import Security` を追加
- `parsedCACertificates() throws -> [SecCertificate]?` 追加（internal、nil 時はシステム CA 検証にフォールバック）
- `parsePEMCertificates(_:) throws -> [SecCertificate]` 追加（private static）
  - PEM ブロックは `[\s\S]*?` の非貪欲マッチで抽出（複数証明書連結・URL-safe Base64 対応）
  - 1 ブロックでも抽出・Base64 デコード・`SecCertificate` 生成に失敗したら `configurationError` を throw（部分成功不可）

### SoraError.swift

- `case configurationError(reason: String)` を追加、`LocalizedError.errorDescription` に対応

### ConfigurationTests.swift（新規）

- 6 ケース: nil 返却 / 単一 PEM / 複数 PEM / 混在エラー / 空文字エラー / Base64 不正エラー
- エラー系は `guard case SoraError.configurationError = error` で型検証

### CHANGES.md

```
- [ADD] Configuration にサーバー証明書検証用の CA 証明書を指定する公開プロパティを追加する
  - @t-miya
```

## 変更ファイル一覧

- `Sora/Configuration.swift` — `caCertificate` プロパティ、`parsedCACertificates()`、`parsePEMCertificates()` 追加
- `Sora/SoraError.swift` — `configurationError` 追加
- `SoraTests/ConfigurationTests.swift` — 新規
- `CHANGES.md` — ADD エントリ追加
