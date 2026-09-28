import Foundation

/// 並行実行した結果を集めるためのスレッド安全な collector です。
///
/// handler は複数の executor から並行に呼ばれ得るため、可変配列を直接 capture せず、
/// lock と配列をこの型に閉じ込めます。`Logger.shared.onOutputHandler` で集めた文字列を
/// 検証するテスト (`LoggerTests` / `RTCDescriptionTests`) で共有します。
final class StringCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  func append(_ value: String) {
    lock.lock()
    defer { lock.unlock() }
    values.append(value)
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    values.removeAll()
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return values.count
  }
}
