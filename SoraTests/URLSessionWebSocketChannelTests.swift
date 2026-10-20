import XCTest

@testable import Sora

/// URLSessionWebSocketChannel の終端処理のユニットテスト
///
/// 実 URLSession / URLSessionWebSocketTask と本番の delegate メソッド / 完了ハンドラを
/// そのまま使い、ネットワークに依存せずに次を検証する。
///
/// - `didCloseWith` と `didCompleteWithError` が両方届いても切断通知が 1 回であること
/// - 切断要求後に届いた受信 / 送信の完了でハンドラーを呼ばないこと
///
/// タスクは resume しないためネットワークは発生しない。
/// モックやスタブは使用しない。
final class URLSessionWebSocketChannelTests: XCTestCase {
  /// テスト用の URL を返す
  private func makeURL() -> URL {
    guard let url = URL(string: "ws://127.0.0.1:1") else {
      fatalError("テスト URL の生成に失敗しました")
    }
    return url
  }

  /// 実 URLSession / URLSessionWebSocketTask を注入した channel を返す
  ///
  /// タスクは resume しない。delegate メソッドをテストから直接呼ぶことで、
  /// ネットワークに依存せずに本番の終端処理だけを検証する。
  private func makeChannelWithTask() -> (
    channel: URLSessionWebSocketChannel, session: URLSession, task: URLSessionWebSocketTask
  ) {
    let url = makeURL()
    let channel = URLSessionWebSocketChannel(
      url: url, proxy: nil, caCertificates: nil, insecure: false)
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: url)
    channel.urlSession = session
    channel.webSocketTask = task
    return (channel, session, task)
  }

  /// タスクを注入しない channel を返す
  ///
  /// 受信 / 送信の完了ハンドラだけを直接呼ぶ検証で使う。
  /// タスクが nil のため、受信の再開は no-op になる。
  private func makeChannel() -> URLSessionWebSocketChannel {
    URLSessionWebSocketChannel(
      url: makeURL(), proxy: nil, caCertificates: nil, insecure: false)
  }

  /// NetworkConnectionLost 相当のエラーを返す
  ///
  /// didCompleteWithError / 送信完了に渡す実エラーとして使う。
  private func makeConnectionLostError() -> NSError {
    NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
  }

  // MARK: - 切断通知の 1 回保証

  /// didCloseWith と didCompleteWithError が両方届いても切断通知が 1 回であることを確認する
  ///
  /// サーバー起因の切断では両方の delegate が呼ばれ得る。
  /// 1 回保証は isClosing で行うため、2 回目の通知が発生しないことを検証する。
  func testDisconnectNotificationIsSentOnceForCloseCallbacks() {
    let (channel, session, task) = makeChannelWithTask()
    var notificationCount = 0
    channel.internalHandlers.onDisconnectWithError = { _, _ in
      notificationCount += 1
    }

    // 1 回目: didCloseWith で切断通知が 1 回発火する
    channel.urlSession(
      session, webSocketTask: task, didCloseWith: .normalClosure, reason: nil)
    XCTAssertEqual(notificationCount, 1, "didCloseWith で切断通知が 1 回発火すること")

    // 2 回目: didCompleteWithError が届いても通知されない
    // (通知ハンドラは 1 回目の通知で空になるため、2 回目でも検証できるよう再設定する)
    channel.internalHandlers.onDisconnectWithError = { _, _ in
      notificationCount += 1
    }
    channel.urlSession(session, task: task, didCompleteWithError: makeConnectionLostError())

    XCTAssertEqual(notificationCount, 1, "didCompleteWithError で切断通知が増えないこと")
    XCTAssertTrue(channel.isClosing, "切断済みとして記録されること")
  }

  /// 利用者切断の後に close callback が届いても切断通知が発火しないことを確認する
  ///
  /// disconnect(error: nil) は利用者からの切断であり通知を発火しない。
  /// その後に届く close callback でも通知されないことを検証する。
  func testDisconnectNotificationIsNotSentAfterUserDisconnect() {
    let (channel, session, task) = makeChannelWithTask()
    var notificationCount = 0

    channel.disconnect(error: nil)
    XCTAssertTrue(channel.isClosing, "切断済みとして記録されること")

    // 通知ハンドラは切断処理で空になるため、再設定して検証する
    channel.internalHandlers.onDisconnectWithError = { _, _ in
      notificationCount += 1
    }
    channel.urlSession(
      session, webSocketTask: task, didCloseWith: .normalClosure, reason: nil)
    channel.urlSession(session, task: task, didCompleteWithError: makeConnectionLostError())

    XCTAssertEqual(notificationCount, 0, "利用者切断後の close callback で通知されないこと")
  }

  // MARK: - 切断後の完了ハンドラ

  /// 切断後に届いた受信結果でハンドラーが呼ばれないことを確認する
  ///
  /// 利用者 handler (handlers.onReceive) と内部 handler (internalHandlers.onReceive) の
  /// 両方が対象である。disconnect は internalHandlers しか空にしないため、
  /// 利用者 handler のためにも isClosing の確認が必要になる。
  func testReceiveResultAfterDisconnectDoesNotCallHandlers() {
    let channel = makeChannel()
    var userReceiveCount = 0
    var internalReceiveCount = 0
    channel.handlers.onReceive = { _ in userReceiveCount += 1 }
    channel.internalHandlers.onReceive = { _ in internalReceiveCount += 1 }

    // 接続中は両方のハンドラーが呼ばれる
    channel.handleReceiveResult(.success(.string("connected")))
    XCTAssertEqual(userReceiveCount, 1, "接続中は利用者 handler が呼ばれること")
    XCTAssertEqual(internalReceiveCount, 1, "接続中は内部 handler が呼ばれること")

    // 切断後は呼ばれない
    channel.disconnect(error: nil)
    channel.handleReceiveResult(.success(.string("after disconnect")))
    XCTAssertEqual(userReceiveCount, 1, "切断後の受信で利用者 handler が呼ばれないこと")
    XCTAssertEqual(internalReceiveCount, 1, "切断後の受信で内部 handler が呼ばれないこと")
  }

  /// 切断後に届いた送信完了で切断通知が発火しないことを確認する
  func testSendCompletionAfterDisconnectDoesNotNotify() {
    let channel = makeChannel()
    var notificationCount = 0

    // 接続中の送信失敗では切断通知が 1 回発火する
    channel.internalHandlers.onDisconnectWithError = { _, _ in
      notificationCount += 1
    }
    channel.handleSendCompletion(makeConnectionLostError())
    XCTAssertEqual(notificationCount, 1, "接続中の送信失敗で切断通知が発火すること")
    XCTAssertTrue(channel.isClosing, "切断済みとして記録されること")

    // 通知ハンドラは切断処理で空になるため、再設定して検証する
    channel.internalHandlers.onDisconnectWithError = { _, _ in
      notificationCount += 1
    }
    channel.handleSendCompletion(makeConnectionLostError())
    XCTAssertEqual(notificationCount, 1, "切断後の送信完了で通知が増えないこと")
  }
}
