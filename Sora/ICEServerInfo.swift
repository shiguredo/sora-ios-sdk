import Foundation

/// ICE サーバーの情報を表します。
public final class ICEServerInfo {
  // MARK: プロパティ

  /// URL のリスト
  ///
  /// TURN URI はそのまま文字列として処理する
  public var urls: [String] = []

  /// ユーザー名
  public var userName: String?

  /// クレデンシャル
  public var credential: String?

  /// TURN-TLS のポリシーが insecure かどうかの真値
  ///
  /// 既定値を持たせず、designated イニシャライザが必ず設定するため、
  /// イニシャライザを追加したときに設定漏れがコンパイルエラーになります。
  var isTLSInsecure: Bool

  /// TLS のセキュリティポリシー
  /// このプロパティは非推奨です。代わりに `Configuration.insecure` を使用してください。
  @available(*, deprecated, message: "2027 年中に廃止予定です。Configuration.insecure を使用してください")
  public var tlsSecurityPolicy: TLSSecurityPolicy {
    get { isTLSInsecure ? .insecure : .secure }
    set { isTLSInsecure = (newValue == .insecure) }
  }

  /// 初期化します。
  public init(
    urls: [String],
    userName: String?,
    credential: String?
  ) {
    self.urls = urls
    self.userName = userName
    self.credential = credential
    self.isTLSInsecure = false
  }

  /// 初期化します。
  @available(
    *, deprecated,
    message: "2027 年中に廃止予定です。tlsSecurityPolicy は非推奨です。Configuration.insecure を使用してください"
  )
  public init(
    urls: [String],
    userName: String?,
    credential: String?,
    tlsSecurityPolicy: TLSSecurityPolicy
  ) {
    self.urls = urls
    self.userName = userName
    self.credential = credential
    self.isTLSInsecure = (tlsSecurityPolicy == .insecure)
  }
}

/// :nodoc:
extension ICEServerInfo: CustomStringConvertible {
  /// 認証情報を伏せた JSON 文字列を返します。
  ///
  /// `urls` / `username` / `credential` のキー構成は `Codable` の出力と同じに保ちます。
  /// `username` と `credential` は利用者が設定した値そのままのため、文字列表現では
  /// 値を `***` に置き換えます。`Codable` の `encode(to:)` は変更しないため、
  /// JSON として保存するときの値は変わりません。
  public var description: String {
    // 値を伏せた複製を encode することで、`Codable` の `encode(to:)` を変更せずに
    // 文字列表現だけをマスクします。`CodingKeys` にフィールドを追加した場合は、
    // 複製にもそのフィールドを写し取る必要があります。
    let masked = ICEServerInfo(
      urls: urls,
      userName: userName == nil ? nil : "***",
      credential: credential == nil ? nil : "***")
    let encoder = JSONEncoder()
    let data = try! encoder.encode(masked)
    return String(data: data, encoding: .utf8) ?? "-"
  }
}

/// :nodoc:
extension ICEServerInfo: Codable {
  enum CodingKeys: String, CodingKey {
    case urls
    case userName = "username"
    case credential
  }

  public convenience init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let urls = try container.decode([String].self, forKey: .urls)
    let userName = try container.decodeIfPresent(String.self, forKey: .userName)
    let credential = try container.decodeIfPresent(String.self, forKey: .credential)
    self.init(
      urls: urls,
      userName: userName,
      credential: credential)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(urls, forKey: .urls)
    if let userName {
      try container.encode(userName, forKey: .userName)
    }
    if let credential {
      try container.encode(credential, forKey: .credential)
    }
  }
}
