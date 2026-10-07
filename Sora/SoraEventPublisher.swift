import Foundation

/// 購読者ごとに独立した `AsyncStream` を管理する内部 storage です。
///
/// 1 つの `AsyncStream` を複数の `Iterator` で消費すると、要素は購読者間で分かれます (全購読者へ
/// 同じ要素は届きません)。複数購読者へ同じイベントを配送するため、購読者ごとに stream と
/// `Continuation` を持ちます。buffer / drop 方針 / 終端も購読者ごとに独立します。
///
/// `@unchecked Sendable` を認める根拠は、可変状態 (`subscriptions` / `nextSubscriptionID` /
/// `sequence` / `closed`) の読み書きをすべて単一の `lock` に閉じることです。保持する値は
/// `AsyncStream.Continuation` (`Sendable`) だけで、SDK 内部の参照型は保持しません。
/// `lock` 自身は `let` で不変に保持し、排他はその内部状態が担います。
///
/// 配送は `lock` を解放してから行います。`Continuation.yield` が購読者の継続を再開しても lock を
/// 保持していないため、購読者のコードからこの storage を触っても deadlock しません。
final class SoraEventPublisher: @unchecked Sendable {
  private let lock = NSLock()

  /// 購読 ID ごとの continuation です。購読の解除で entry を削除します。
  private var subscriptions: [UInt64: AsyncStream<SoraEvent>.Continuation] = [:]

  /// 購読 ID の採番に使う値です。
  private var nextSubscriptionID: UInt64 = 0

  /// イベントの通し番号です。購読者が欠落を検出できるように、配送のたびに進めます。
  private var sequence: UInt64 = 0

  /// 終端済みかどうかです。終端後の購読には終端済みの stream を返し、配送は行いません。
  private var closed = false

  /// 新しい購読を開始します。
  ///
  /// - parameter bufferingPolicy: 購読者ごとの buffer と drop 方針
  /// - returns: 購読者だけが消費する stream。終端済みの場合は終端済みの stream
  func subscribe(
    bufferingPolicy: AsyncStream<SoraEvent>.Continuation.BufferingPolicy
  ) -> AsyncStream<SoraEvent> {
    let (stream, continuation) = AsyncStream<SoraEvent>.makeStream(
      bufferingPolicy: bufferingPolicy)

    lock.lock()
    if closed {
      lock.unlock()
      continuation.finish()
      return stream
    }
    nextSubscriptionID &+= 1
    let id = nextSubscriptionID
    subscriptions[id] = continuation
    lock.unlock()

    // Task の cancel と、購読に使った stream の解放で解除される。iterator だけを解放した場合は
    // 解除されない (stream が continuation を保持し続けるため)。購読 ID は採番済みの値だけを
    // 捕捉するため、storage を強参照しない。
    continuation.onTermination = { [weak self] _ in
      self?.removeSubscription(id)
    }
    return stream
  }

  /// イベントを全購読者へ配送します。
  ///
  /// 通し番号はこのメソッドで採番します。呼び出し側は owner の排他区間を保持せずに呼びます。
  /// 採番と購読者の取り出しだけを `lock` で行い、配送は `lock` を解放してから行うため、複数の
  /// スレッドから同時に呼ばれた場合は buffer に入る順序が通し番号の順序と一致しないことがあります。
  ///
  /// - parameter event: 配送するイベント (通し番号は上書きされます)
  func publish(_ event: SoraEvent) {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    sequence &+= 1
    let event = event.assigningSequence(sequence)
    let continuations = Array(subscriptions.values)
    lock.unlock()

    // イベントごとのログは出さない。DataChannel のメッセージなど高頻度のイベントがあり、
    // 既存の配送点が既に必要なログを出しているためである。
    for continuation in continuations {
      continuation.yield(event)
    }
  }

  #if DEBUG
    /// 現在の購読者の数です。
    ///
    /// 購読の解除が購読者の管理からも消えていることをテストから確認するために公開します。
    var subscriptionCountForTesting: Int {
      lock.lock()
      defer { lock.unlock() }
      return subscriptions.count
    }
  #endif

  /// 全購読を終端します。以降の購読には終端済みの stream を返します。
  func finish() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    let continuations = Array(subscriptions.values)
    subscriptions.removeAll()
    lock.unlock()

    for continuation in continuations {
      continuation.finish()
    }
  }

  /// 購読を 1 つ解除します。
  ///
  /// - parameter id: 解除する購読 ID
  private func removeSubscription(_ id: UInt64) {
    lock.lock()
    subscriptions.removeValue(forKey: id)
    lock.unlock()
  }
}
