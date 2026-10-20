import Foundation

/// イベントハンドラのプロパティ (クロージャ) と、それを保持するクラスの参照を `NSLock` で排他して
/// 保持する storage です。
///
/// 保持する値は、利用者が任意の executor から設定し、SDK が配送側 (signaling の owner queue、
/// libwebrtc の callback スレッド、DataChannel の delegate スレッド、frame ごとの owner queue
/// など) から読む closure、またはハンドラを保持するクラスの参照である。単純な stored property では、この
/// 設定と読み取りが排他されずデータ競合になるため、get / set を同じ lock で排他する。
///
/// get は lock を解放してから値を返す。配送側が lock を保持したまま closure を呼ぶと、closure の
/// 中から別の handler を設定したときに非再帰の `NSLock` で deadlock するためである。
///
/// set は旧値の解放 (捕捉した object の `deinit`) を lock の外で行う。lock を保持したまま解放
/// すると、同じ理由で deadlock し得る。
///
/// `Sendable` に準拠しない。この storage は SDK 内部の lock 付きアクセサに閉じ、concurrency
/// domain へ渡さない。現在の用途で `Value` が取るのは非 `Sendable` な closure や非 `Sendable` な
/// ハンドラクラスであり、`@unchecked Sendable` を付けると、それらを保持したまま storage を `@Sendable`
/// closure へ渡し、別の executor で取り出して呼ぶ経路が型検査を通過してしまう。この storage が
/// 担うのは保持する値の読み書きの排他だけであり、呼び出された closure の実行は利用者の責任である。
final class HandlerStorage<Value> {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  /// 保持している値です。参照型の場合は同じ instance を返すため、返した先での in-place 変更は
  /// 保持側にも反映されます。値を返す前に lock を解放します。
  var current: Value {
    get {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    set {
      lock.lock()
      let previous = value
      value = newValue
      lock.unlock()
      // 旧値の解放を lock の外で行うため、unlock 後も previous の寿命を伸ばす。
      withExtendedLifetime(previous) {}
    }
  }
}
