import Foundation
import WebRTC

/// :nodoc:
public enum Utilities {
  fileprivate static let randomBaseString =
    "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ0123456789"
  fileprivate static let randomBaseChars =
    randomBaseString.map { c in String(c) }

  public static func randomString(length: Int = 8) -> String {
    var chars: [String] = []
    chars.reserveCapacity(length)
    for _ in 0..<length {
      let index = UInt32.random(in: 0..<UInt32(Utilities.randomBaseChars.count))
      chars.append(randomBaseChars[Int(index)])
    }
    return chars.joined()
  }

  public final class Stopwatch {
    private var timer: Timer?
    private let storage: StopwatchStorage

    public init(handler: @escaping (String) -> Void) {
      // closure には self ではなく、このローカル束縛の storage だけを捕捉させる。
      // self.storage として参照すると closure が self を捕捉してしまう。
      let storage = StopwatchStorage(handler: handler)
      self.storage = storage
      timer = Timer(timeInterval: 1, repeats: true) { _ in
        // 経過秒数の読み出しと加算は storage の lock 区間に閉じる。利用者の handler の
        // 呼び出しは区間の外で行い、加算はその呼び出しの後の別区間で行う。handler の中で
        // stop() が呼ばれて経過秒数が 0 に戻された場合の結果は変更前と同じになる。
        let seconds = storage.elapsedSeconds()
        let text = String(
          format: "%02d:%02d:%02d",
          arguments: [
            seconds / (60 * 60),
            seconds / 60,
            seconds % 60,
          ])
        storage.handler(text)
        storage.increment()
      }
    }

    public func run() {
      storage.reset()
      guard let timer else {
        return
      }
      RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
      // fire() は closure を同期実行し、その closure が storage の非再帰 lock を取る。
      // lock 区間は storage の中で閉じるため、保持したまま呼ぶことはない。
      timer.fire()
    }

    public func stop() {
      timer?.invalidate()
      storage.reset()
    }
  }
}

/// `Utilities.Stopwatch` の `Timer` の block が参照する可変状態 (`seconds`) を保持する storage。
///
/// block に捕捉させるのはこの型だけであり、`Stopwatch` は捕捉させない。`@unchecked Sendable`
/// として認める根拠は、可変状態を持つ型に対する 3 条件の適用である。
/// - 条件 (1) は「可変状態を持たないこと」を求めるが、ここでは「`seconds` の読み書きがすべて
///   単一の `NSLock` 区間内に閉じていること」と読み替えて適用する (`LoggerStateStorage` /
///   `PeerChannelTransportStorage` と同じ形)
/// - 条件 (2) は、block の配送先 (`Timer(timeInterval:repeats:block:)` と `RunLoop.main` への
///   登録) と通知の順序・呼び出し回数を変えず、別系統の境界へ新たに渡すこともないこと
/// - 条件 (3) は、保持するのが `init` で確定する利用者の `handler` と `seconds` (値型) だけで、
///   `Timer` / `RunLoop` / `Stopwatch` の参照を保持しないこと
///
/// 保証するのは `seconds` の同期だけであり、`handler` の closure 自体が `Sendable` であることは
/// 主張しない。`handler` は不変の `let` で、利用者コードでもあるため `lock` 区間の外で呼ぶ。
/// `lock` は非再帰であり、保持したまま呼ぶと、その中から `Stopwatch` へ入る経路 (例えば
/// `run()` の `fire()` や `stop()`) が同じ `lock` を再取得して deadlock する。
private final class StopwatchStorage: @unchecked Sendable {
  /// `seconds` の読み書きを保護する排他ロック。`Timer` の block と `Stopwatch` の `run()` /
  /// `stop()` が同じスレッドで呼ばれる保証は無いため、アクセスを直列化する。
  private let lock = NSLock()

  /// 利用者の handler。`init` で確定した後は書き換えないため、lock では保護しない。
  let handler: (String) -> Void

  /// 経過秒数。読み書きはすべて `lock` 区間内で行う。
  private var seconds: Int = 0

  init(handler: @escaping (String) -> Void) {
    self.handler = handler
  }

  /// 現在の経過秒数を返す。返した値の整形と利用者への通知は、呼び出し側が `lock` 区間の外で
  /// 行う。
  func elapsedSeconds() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return seconds
  }

  /// 経過秒数を 1 増やす。利用者の handler の呼び出し後に、別の `lock` 区間で行う。
  func increment() {
    lock.lock()
    defer { lock.unlock() }
    seconds += 1
  }

  /// 経過秒数を 0 に戻す。`lock` 区間はこの中で閉じる。
  func reset() {
    lock.lock()
    defer { lock.unlock() }
    seconds = 0
  }
}

struct PairTable<T: Equatable & Sendable, U: Equatable & Sendable>: Sendable {
  let name: String

  private let pairs: [(T, U)]

  init(name: String, pairs: [(T, U)]) {
    self.name = name
    self.pairs = pairs
  }

  func left(other: U) -> T? {
    let found = pairs.first { pair in other == pair.1 }
    return found.map { pair in pair.0 }
  }

  func right(other: T) -> U? {
    let found = pairs.first { pair in other == pair.0 }
    return found.map { pair in pair.1 }
  }
}

/// :nodoc:
extension PairTable where T == String {
  func decode(from decoder: Decoder) throws -> U {
    let container = try decoder.singleValueContainer()
    let key = try container.decode(String.self)
    return try right(other: key).unwrap {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "\(self.name) cannot decode '\(key)'")
    }
  }

  func encode(_ value: U, to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    if let key = left(other: value) {
      try container.encode(key)
    } else {
      throw EncodingError.invalidValue(
        value,
        EncodingError.Context(
          codingPath: [], debugDescription: "\(name) cannot encode \(value)"))
    }
  }
}

/// :nodoc:
extension Optional {
  public func unwrap(ifNone: () throws -> Wrapped) rethrows -> Wrapped {
    switch self {
    case .some(let value):
      return value
    case .none:
      return try ifNone()
    }
  }
}
