import Foundation
import XCTest

@testable import Sora

/// ログと文字列表現からシークレットが漏れないことを確認します。
///
/// 対象は TURN の認証情報 (`username` / `credential`)、シグナリング URL の userinfo、
/// signaling notify の `data` に含まれるマスク対象キーの値です。
/// JSON の値のマスクは `Logger` と `ICEServerInfo.description` が、ログへ出す前の URL の
/// userinfo の除去は `URLUserInfo` が担います。
final class SecretMaskingTests: XCTestCase {
  // MARK: - ICEServerInfo

  /// `ICEServerInfo.description` が認証情報の値を伏せることを確認します。
  ///
  /// `description` は利用者の `print` や `os_log` からも呼ばれるため、`Logger` を通さない
  /// 文字列化でも認証情報が平文で現れない必要があります。
  func testICEServerInfoDescriptionMasksCredentials() throws {
    let info = ICEServerInfo(
      urls: ["turns://example.com"],
      userName: "turn-user-7",
      credential: "turn-secret-9")

    let description = info.description
    XCTAssertFalse(
      description.contains("turn-user-7"),
      "description に username の値が平文で含まれないこと")
    XCTAssertFalse(
      description.contains("turn-secret-9"),
      "description に credential の値が平文で含まれないこと")

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(description.utf8)) as? [String: Any],
      "description が JSON object として読めること")
    XCTAssertEqual(object["username"] as? String, "***", "username が伏せられること")
    XCTAssertEqual(object["credential"] as? String, "***", "credential が伏せられること")
    XCTAssertEqual(
      object["urls"] as? [String], ["turns://example.com"], "urls は変わらないこと")
  }

  /// `ICEServerInfo` の `Codable` の出力が、認証情報を含む元の値のままであることを確認します。
  ///
  /// `description` のマスクは文字列表現だけを対象にし、JSON として保存する値は変えません。
  /// 同じインスタンスで `description` を呼んだ後も値が変わらないことを検証します。
  func testICEServerInfoCodableKeepsCredentialValues() throws {
    let info = ICEServerInfo(
      urls: ["turns://example.com"],
      userName: "turn-user-7",
      credential: "turn-secret-9")

    // `description` が自分自身の値を書き換えていないことを確認するため、先に呼びます。
    _ = info.description
    XCTAssertEqual(
      info.userName, "turn-user-7", "description の呼び出しで username が変わらないこと")
    XCTAssertEqual(
      info.credential, "turn-secret-9", "description の呼び出しで credential が変わらないこと")

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try JSONEncoder().encode(info)) as? [String: Any],
      "ICEServerInfo を JSON object として読めること")
    XCTAssertEqual(
      object["username"] as? String, "turn-user-7",
      "JSON の username は利用者が設定した値のままであること")
    XCTAssertEqual(
      object["credential"] as? String, "turn-secret-9",
      "JSON の credential は利用者が設定した値のままであること")
  }

  /// `ICEServerInfo.description` の JSON キー集合が `Codable` の出力と同じことを確認します。
  ///
  /// `description` はマスク用に値を差し替えた複製を作るため、フィールドを追加したときに
  /// 片方だけ更新されるとキーが欠けます。両者のキー集合と、認証情報が伏せられていることを
  /// 比較します。非 optional のフィールドを追加した場合はキー集合が一致するため、この
  /// テストでは検出できません。
  func testICEServerInfoDescriptionKeysMatchCodable() throws {
    let values: [(userName: String?, credential: String?)] = [
      ("turn-user-7", "turn-secret-9"),
      (nil, nil),
    ]
    for value in values {
      let info = ICEServerInfo(
        urls: ["turns://example.com"],
        userName: value.userName,
        credential: value.credential)
      let descriptionObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(info.description.utf8)) as? [String: Any],
        "description が JSON オブジェクトであること")
      let encodedObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any],
        "Codable の出力が JSON オブジェクトであること")
      XCTAssertEqual(
        Set(descriptionObject.keys), Set(encodedObject.keys),
        "description の JSON キー集合が Codable の出力と一致すること")
      XCTAssertEqual(
        descriptionObject["urls"] as? [String], ["turns://example.com"],
        "description の urls は設定値のままであること")
      if value.userName != nil {
        XCTAssertEqual(
          descriptionObject["username"] as? String, "***",
          "description の username は伏せられること")
        XCTAssertEqual(
          descriptionObject["credential"] as? String, "***",
          "description の credential は伏せられること")
      }
    }
  }

  /// 認証情報が nil の場合、`description` の JSON にキー自体が含まれないことを確認します。
  func testICEServerInfoDescriptionOmitsNilCredentials() throws {
    let info = ICEServerInfo(urls: ["stun:example.com"], userName: nil, credential: nil)

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(info.description.utf8)) as? [String: Any],
      "description が JSON object として読めること")
    XCTAssertEqual(
      Set(object.keys), ["urls"], "認証情報が nil の場合はキーが含まれないこと")
  }

  // MARK: - URL の userinfo

  /// `URL` から userinfo が除かれることを確認します。
  func testURLRemovingUserInfo() throws {
    let withUserInfo = try XCTUnwrap(URL(string: "wss://user:pass@example.com/signaling"))
    XCTAssertEqual(
      URLUserInfo.removed(from: withUserInfo).absoluteString,
      "wss://example.com/signaling",
      "URL の userinfo が除かれること")

    let withoutUserInfo = try XCTUnwrap(URL(string: "wss://example.com/signaling"))
    XCTAssertEqual(
      URLUserInfo.removed(from: withoutUserInfo).absoluteString,
      "wss://example.com/signaling",
      "userinfo を含まない URL は変わらないこと")

    let userOnly = try XCTUnwrap(URL(string: "wss://user@example.com/signaling"))
    XCTAssertEqual(
      URLUserInfo.removed(from: userOnly).absoluteString,
      "wss://example.com/signaling",
      "パスワードを持たない userinfo も除かれること")

    let emptyUser = try XCTUnwrap(URL(string: "wss://:pass@example.com/signaling"))
    XCTAssertEqual(
      URLUserInfo.removed(from: emptyUser).absoluteString,
      "wss://example.com/signaling",
      "ユーザー名が空の userinfo も除かれること")
  }

  /// 文字列から userinfo が除かれることを確認します。
  ///
  /// `URL` として解釈できない文字列も対象にするため、文字列ベースで除去します。
  func testStringRemovingUserInfo() {
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://user:pass@example.com/signaling"),
      "wss://example.com/signaling",
      "パスを含む location から userinfo が除かれること")
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://user:pass@example.com"),
      "wss://example.com",
      "パスを含まない location から userinfo が除かれること")
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://user:pass@[invalid"),
      "wss://[invalid",
      "URL として解釈できない location からも userinfo が除かれること")
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://user@example.com/signaling"),
      "wss://example.com/signaling",
      "パスワードを持たない userinfo も除かれること")
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://user:p%40ss@example.com/signaling"),
      "wss://example.com/signaling",
      "パーセントエンコードされた値を含む userinfo も除かれること")
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://a@b@example.com/signaling"),
      "wss://example.com/signaling",
      "複数の @ を含む不正な userinfo は最後の @ より前を除くこと")
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://example.com/signaling?redirect=a@b"),
      "wss://example.com/signaling?redirect=a@b",
      "query の @ は userinfo として扱わないこと")
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://example.com/signaling#a@b"),
      "wss://example.com/signaling#a@b",
      "fragment の @ は userinfo として扱わないこと")
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://example.com?next=a@b"),
      "wss://example.com?next=a@b",
      "パスを持たない location では query の @ を userinfo として扱わないこと")
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://example.com#a@b"),
      "wss://example.com#a@b",
      "パスを持たない location では fragment の @ を userinfo として扱わないこと")
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://user:pass@example.com?x=1"),
      "wss://example.com?x=1",
      "query を持つ location でも userinfo が除かれること")
    XCTAssertEqual(
      URLUserInfo.removed(from: " wss://user:pass@example.com/signaling"),
      " wss://example.com/signaling",
      "先頭に空白がある location でも userinfo が除かれること")
    XCTAssertEqual(
      URLUserInfo.removed(from: "user:pass@example.com/signaling"),
      "user:pass@example.com/signaling",
      "scheme を持たない文字列は userinfo として扱わないこと")
    XCTAssertEqual(
      URLUserInfo.removed(from: "//user:pass@example.com/signaling"),
      "//example.com/signaling",
      "scheme 相対の参照からも userinfo が除かれること")
    XCTAssertEqual(
      URLUserInfo.removed(from: "WSS://user:pass@example.com/signaling"),
      "WSS://example.com/signaling",
      "大文字の scheme でも userinfo が除かれること")
    XCTAssertEqual(
      URLUserInfo.removed(from: "ws+foo-1.2://user:pass@example.com/signaling"),
      "ws+foo-1.2://example.com/signaling",
      "scheme に使える記号を含む scheme でも userinfo が除かれること")
    XCTAssertEqual(
      URLUserInfo.removed(from: "/path://user:pass@example.com"),
      "/path://user:pass@example.com",
      "先頭が scheme でない文字列は書き換えないこと")
    XCTAssertEqual(
      URLUserInfo.removed(from: "wss://example.com/signaling"),
      "wss://example.com/signaling",
      "userinfo を含まない location は変わらないこと")
    XCTAssertEqual(
      URLUserInfo.removed(from: "invalid message"),
      "invalid message",
      "URL の形式でない文字列は変わらないこと")
  }

  // MARK: - SignalingChannel のログとエラー

  /// シグナリングのログに userinfo が残らないことを確認します。
  ///
  /// `127.0.0.1:1` は接続が即時失敗するため、モックを使わずに接続試行のログを実走できます。
  func testSignalingChannelLogsDoNotContainUserInfo() throws {
    let connectingLogged = expectation(description: "connecting to のログ")
    let capture = LoggerCapture { message in
      if message.hasPrefix("connecting to") {
        connectingLogged.fulfill()
      }
    }

    let config = Configuration(
      urlCandidates: [try XCTUnwrap(URL(string: "wss://user:pass@127.0.0.1:1/signaling"))],
      channelId: "test",
      role: .sendonly)
    let snapshot = try ConnectionConfigurationSnapshot(configuration: config)
    let channel = SignalingChannel(
      snapshot: snapshot,
      webSocketChannelHandlers: config.webSocketChannelHandlers)

    let connectFailed = expectation(description: "接続失敗による切断")
    // 接続失敗は `connect` のハンドラーではなく `internalHandlers.onDisconnect` で通知されます
    // (`connect` のハンドラーは接続成功と接続開始前の失敗でだけ呼ばれます)。
    channel.internalHandlers.onDisconnect = { _, _ in
      connectFailed.fulfill()
    }

    channel.connect { _ in }

    wait(for: [connectingLogged, connectFailed], timeout: 10)

    let messages = capture.messages
    XCTAssertTrue(
      messages.contains { $0 == "urlCandidates: [wss://127.0.0.1:1/signaling]" },
      "urlCandidates のログが userinfo を除いて出力されること: \(messages)")
    XCTAssertTrue(
      messages.contains { $0 == "connecting to wss://127.0.0.1:1/signaling" },
      "connecting to のログが userinfo を除いて出力されること: \(messages)")
    XCTAssertFalse(
      messages.contains { $0.contains("user:pass") },
      "シグナリングのログに userinfo が残らないこと: \(messages)")
  }

  /// userinfo を含む有効な location で redirect しても、ログに userinfo が残らないことを
  /// 確認します。
  ///
  /// `127.0.0.1:1` は接続が即時失敗するため、redirect 先の接続ログまで実走できます。
  func testSignalingChannelRedirectLogDoesNotContainUserInfo() throws {
    let redirectLogged = expectation(description: "try redirecting to のログ")
    let capture = LoggerCapture { message in
      if message.hasPrefix("try redirecting to") {
        redirectLogged.fulfill()
      }
    }

    let config = Configuration(
      urlCandidates: [try XCTUnwrap(URL(string: "wss://example.com/signaling"))],
      channelId: "test",
      role: .sendonly)
    let snapshot = try ConnectionConfigurationSnapshot(configuration: config)
    let channel = SignalingChannel(
      snapshot: snapshot,
      webSocketChannelHandlers: config.webSocketChannelHandlers)

    let connectFailed = expectation(description: "redirect 先への接続失敗による切断")
    channel.internalHandlers.onDisconnect = { _, _ in
      connectFailed.fulfill()
    }

    channel.redirect(location: "wss://user:pass@127.0.0.1:1/signaling")

    wait(for: [redirectLogged, connectFailed], timeout: 10)

    let messages = capture.messages
    XCTAssertTrue(
      messages.contains { $0 == "try redirecting to wss://127.0.0.1:1/signaling" },
      "try redirecting to のログが userinfo を除いて出力されること: \(messages)")
    XCTAssertFalse(
      messages.contains { $0.contains("user:pass") },
      "redirect のログに userinfo が残らないこと: \(messages)")
  }

  /// redirect の location に userinfo が含まれても、ログとエラーのメッセージに残らないことを
  /// 確認します。
  ///
  /// `invalid message` の文字列は `SoraError` の reason にも載り、`error.localizedDescription`
  /// として `SignalingChannel.disconnect(error:)` と `PeerChannel.basicDisconnect` の
  /// error ログにも再出力されます。ログの 1 箇所だけをマスクしても漏えいが残るため、
  /// 組み立て時点で userinfo を除いた文字列を使うことを確認します。
  func testSignalingChannelRedirectErrorDoesNotContainUserInfo() throws {
    let invalidMessageLogged = expectation(description: "invalid message のログ")
    let capture = LoggerCapture { message in
      if message.hasPrefix("invalid message:") {
        invalidMessageLogged.fulfill()
      }
    }

    let config = Configuration(
      urlCandidates: [try XCTUnwrap(URL(string: "wss://example.com/signaling"))],
      channelId: "test",
      role: .sendonly)
    let snapshot = try ConnectionConfigurationSnapshot(configuration: config)
    let channel = SignalingChannel(
      snapshot: snapshot,
      webSocketChannelHandlers: config.webSocketChannelHandlers)

    // 接続していない channel に redirect が届いた場合でも、切断時のエラーを onDisconnect で
    // 観測します。
    let disconnected = expectation(description: "redirect の失敗による切断")
    let reasonBox = ErrorReasonBox()
    channel.internalHandlers.onDisconnect = { error, _ in
      reasonBox.set(error?.localizedDescription)
      disconnected.fulfill()
    }

    // `URL(string:)` が nil を返すため、接続を開始せずにエラーの経路だけを実走できます。
    channel.redirect(location: "wss://user:pass@[invalid")

    wait(for: [invalidMessageLogged, disconnected], timeout: 10)

    let messages = capture.messages
    XCTAssertTrue(
      messages.contains { $0 == "try redirecting to wss://[invalid" },
      "try redirecting to のログが userinfo を除いて出力されること: \(messages)")
    XCTAssertTrue(
      messages.contains { $0 == "invalid message: wss://[invalid" },
      "invalid message のログが userinfo を除いて出力されること: \(messages)")
    XCTAssertFalse(
      messages.contains { $0.contains("user:pass") },
      "redirect のログに userinfo が残らないこと: \(messages)")

    let reason = try XCTUnwrap(reasonBox.value, "onDisconnect が呼ばれること")
    XCTAssertFalse(
      reason.contains("user:pass"),
      "エラーの reason に userinfo が残らないこと: \(reason)")
    XCTAssertTrue(
      reason.contains("invalid message: wss://[invalid"),
      "エラーの reason が userinfo を除いた location を使うこと: \(reason)")
  }

  // MARK: - LogType.signaling のログ

  /// notify の `data` の downcast に失敗したログが JSON 形式で出力され、マスク対象キーの
  /// 文字列値だけが伏せられることを確認します。
  ///
  /// `data` は `authn_metadata` / `authz_metadata` / `metadata` など利用者や認証ウェブフックが
  /// 設定した任意の値を含み得ます。ログは JSON に戻して出力するため、既存の
  /// `Logger.maskSecrets` の対象になります。
  func testSignalingDowncastFailureLogMasksSecrets() throws {
    // 既定値そのものを使い、既定設定で出力されることを確認します。
    let defaults = Logger()
    let capture = LoggerCapture(level: defaults.level, groups: defaults.groups)

    // `data` がオブジェクトの配列でない notify を作ります。要素に NSNull を混ぜると
    // `[[String: Any]]` への downcast が失敗し、`serializeData` のログが出ます。
    let data = try JSONSerialization.data(
      withJSONObject: [
        "type": "notify",
        "event_type": "connection.created",
        "data": [
          [
            "client_id": "dummy-client",
            "authn_metadata": [
              "access_token": "dummy-token",
              "username": "dummy-user",
            ],
          ],
          NSNull(),
        ],
      ])
    let signaling = try Signaling.decode(data).get()
    guard case .notify = signaling else {
      XCTFail("notify として decode されること")
      return
    }

    let logs = capture.logs.filter {
      $0.message.hasPrefix("downcast failed in serializeData")
    }
    XCTAssertEqual(logs.count, 1, "downcast 失敗のログが 1 件出力されること: \(capture.messages)")
    let log = try XCTUnwrap(logs.first, "downcast 失敗のログがあること")
    guard case .signaling = log.type else {
      XCTFail("ログの type が .signaling であること: \(log.type)")
      return
    }
    XCTAssertEqual(log.level, .info, "ログの level が .info であること")

    // `data: ` 以降を JSON として読み、データ本体は残したままマスク対象キーの値だけが
    // 伏せられていることを確認します。
    let prefix = "downcast failed in serializeData. data: "
    let jsonText = String(log.message.dropFirst(prefix.count))
    let entries = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(jsonText.utf8), options: [.fragmentsAllowed]) as? [Any],
      "ログの data が JSON として読めること: \(log.message)")
    XCTAssertEqual(entries.count, 2, "データ本体の要素が全て残ること")
    if entries.count == 2 {
      XCTAssertTrue(entries[1] is NSNull, "2 件目の null が残ること")
    }
    let metadata = try XCTUnwrap(entries.first as? [String: Any], "1 件目がオブジェクトであること")
    XCTAssertEqual(metadata["client_id"] as? String, "dummy-client", "データ本体の値が残ること")
    let authnMetadata = try XCTUnwrap(
      metadata["authn_metadata"] as? [String: Any], "authn_metadata がオブジェクトであること")
    XCTAssertEqual(authnMetadata["access_token"] as? String, "***", "access_token がマスクされること")
    XCTAssertEqual(authnMetadata["username"] as? String, "***", "username がマスクされること")
    XCTAssertFalse(log.message.contains("dummy-token"), "access_token の平文が残らないこと")
    XCTAssertFalse(log.message.contains("dummy-user"), "username の平文が残らないこと")
  }

  /// JSON の数値として表現できない値 (`-1e999` は `-inf` として解析されます) を含む notify でも、
  /// downcast 失敗ログがクラッシュせずに出力され、データ本体を出さないことを確認します。
  ///
  /// `JSONSerialization.data(withJSONObject:)` は非有限数を渡すと捕捉できない NSException を
  /// 送出してプロセスを終了させるため、ログのための直列化では事前に検証する必要があります。
  func testSignalingDowncastFailureLogDoesNotCrashOnNonJSONValue() throws {
    // このテストは直列化できない値の分岐だけを見るため `.channels` だけで足ります。
    let capture = LoggerCapture(level: .info, groups: [.channels])
    // `JSONSerialization.data(withJSONObject:)` ではこの JSON を組み立てられないため、
    // 文字列リテラルから Data を作ります。
    let raw =
      #"{"type":"notify","event_type":"connection.created","data":{"access_token":"dummy-token","x":-1e999}}"#
    let signaling = try Signaling.decode(Data(raw.utf8)).get()
    guard case .notify = signaling else {
      XCTFail("notify として decode されること")
      return
    }

    let logs = capture.logs.filter {
      $0.message.hasPrefix("downcast failed in serializeData")
    }
    XCTAssertEqual(logs.count, 1, "downcast 失敗のログが 1 件出力されること: \(capture.messages)")
    let message = try XCTUnwrap(logs.first?.message, "downcast 失敗のログがあること")
    XCTAssertTrue(
      message.contains("<not a JSON value>"),
      "JSON に戻せない値であることを出力すること: \(message)")
    XCTAssertFalse(message.contains("dummy-token"), "データ本体を出力しないこと: \(message)")
  }

  /// `data` が文字列の断片でも JSON として出力され、マスク対象キーの値が伏せられることを
  /// 確認します。`data` はオブジェクトの配列に限らないため `fragmentsAllowed` が必要です。
  func testSignalingDowncastFailureLogSerializesFragmentAsJSON() throws {
    let capture = LoggerCapture(level: .info, groups: [.channels])
    let raw =
      #"{"type":"notify","event_type":"connection.created","data":"{\"token\":\"dummy-token\"}"}"#
    _ = try Signaling.decode(Data(raw.utf8)).get()

    let logs = capture.logs.filter {
      $0.message.hasPrefix("downcast failed in serializeData")
    }
    XCTAssertEqual(logs.count, 1, "downcast 失敗のログが 1 件出力されること: \(capture.messages)")
    let log = try XCTUnwrap(logs.first, "downcast 失敗のログがあること")
    guard case .signaling = log.type else {
      XCTFail("ログの type が .signaling であること: \(log.type)")
      return
    }
    let message = log.message
    XCTAssertTrue(
      message.contains(#"\"token\": \"***\""#),
      "JSON 文字列の断片でもトークンがマスクされること: \(message)")
    XCTAssertFalse(message.contains("dummy-token"), "平文が残らないこと: \(message)")
  }

  /// `data` がオブジェクトでも JSON として出力され、マスク対象キーの文字列値だけが伏せられ、
  /// マスク対象外のキーと URL はそのまま残ることを確認します。
  func testSignalingDowncastFailureLogSerializesDictionary() throws {
    let capture = LoggerCapture(level: .info, groups: [.channels])
    let data = try JSONSerialization.data(
      withJSONObject: [
        "type": "notify",
        "event_type": "connection.created",
        "data": [
          "client_id": "dummy-client",
          "url": "wss://example.com/signaling",
          "authn_metadata": ["access_token": "dummy-token"],
        ],
      ])
    _ = try Signaling.decode(data).get()

    let logs = capture.logs.filter {
      $0.message.hasPrefix("downcast failed in serializeData")
    }
    XCTAssertEqual(logs.count, 1, "downcast 失敗のログが 1 件出力されること: \(capture.messages)")
    let message = try XCTUnwrap(logs.first?.message, "downcast 失敗のログがあること")
    XCTAssertFalse(message.contains("dummy-token"), "access_token の平文が残らないこと: \(message)")
    XCTAssertTrue(
      message.contains("\"client_id\":\"dummy-client\""),
      "マスク対象外のキーが残ること: \(message)")
    XCTAssertTrue(
      message.contains("\"url\":\"wss://example.com/signaling\""),
      "URL のスラッシュがエスケープされないこと: \(message)")
  }
}

/// 切断時のエラーの説明をテストから受け取るための箱です。
///
/// `onDisconnect` の呼び出し元スレッドは保証されないため、可変値を直接 capture せず
/// lock 付きの型に閉じ込めます。
private final class ErrorReasonBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String?

  func set(_ value: String?) {
    lock.lock()
    defer { lock.unlock() }
    stored = value
  }

  var value: String? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}
