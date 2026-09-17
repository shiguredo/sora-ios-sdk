import AVFoundation
import Foundation

/// 同期 getter が読む lock-backed な snapshot storage です。
///
/// `CameraVideoCapturer` 等の同期 getter は単一所有者の同期 wait を行わず、
/// この storage を NSLock で読み込んで snapshot を返します。
///
/// `@unchecked Sendable` としているのは、可変状態が `state` だけで、その読み書きを
/// すべて `lock` で排他しているためです。返す `CameraState` は値型なので、返却後に
/// 別スレッドが更新しても呼び出し側の値は変わりません。
private final class CameraSnapshotStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var state = CameraState()

  /// 現在の snapshot を返します。
  func current() -> CameraState {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  /// snapshot を更新します。
  func publish(state: CameraState) {
    lock.lock()
    defer { lock.unlock() }
    self.state = state
  }
}

/// non-Sendable な実資源を capturer ID ごとに保持するテーブルです。
///
/// format (`AVCaptureDevice.Format`) と送信先 stream (`MediaStream`) を保持します。
/// 読み取りは NSLock で保護し、任意のスレッドから行えます。 native の呼び出しと
/// format の差し替えは libwebrtc の capture session queue 上で行います。
///
/// stream は弱参照で保持します。このテーブルは process-wide な owner が持つため、
/// 強参照にすると `MediaStream` が保持する `PeerChannel` ごと接続終了後も
/// プロセス終了まで残ります。capturer が stream を生存させていた旧実装とは
/// 生存期間の意味が異なり、利用者が capturer 以外に強参照を持たない stream は
/// 解放されます。解放後は `nil` を返します。
///
/// `@unchecked Sendable` としているのは、可変状態が `formats` / `streams` だけで、
/// その読み書きをすべて `lock` で排他しているためです。
private final class CameraResourceTable: @unchecked Sendable {
  /// `MediaStream` を弱参照で包む内部ラッパーです。
  ///
  /// `@unchecked Sendable` としているのは、`value` の読み書きが外側の
  /// `CameraResourceTable` の lock 下でのみ行われるためです。
  private final class WeakStream: @unchecked Sendable {
    weak var value: MediaStream?

    init(_ value: MediaStream) {
      self.value = value
    }
  }

  private let lock = NSLock()
  private var formats: [CameraCapturerID: AVCaptureDevice.Format] = [:]
  private var streams: [CameraCapturerID: WeakStream] = [:]

  /// format を記録します。
  func setFormat(_ format: AVCaptureDevice.Format, id: CameraCapturerID) {
    lock.lock()
    defer { lock.unlock() }
    formats[id] = format
  }

  /// format を返します。
  func format(id: CameraCapturerID) -> AVCaptureDevice.Format? {
    lock.lock()
    defer { lock.unlock() }
    return formats[id]
  }

  /// 送信先 stream を返します。
  func stream(id: CameraCapturerID) -> MediaStream? {
    lock.lock()
    defer { lock.unlock() }
    return streams[id]?.value
  }

  /// 送信先 stream を設定します。
  func setStream(_ stream: MediaStream?, id: CameraCapturerID) {
    lock.lock()
    defer { lock.unlock() }
    if let stream {
      streams[id] = WeakStream(stream)
    } else {
      streams[id] = nil
    }
  }

  /// 現在の値が `expected` と同一の場合だけ書き換えます (compare-and-swap)。
  ///
  /// command の失敗時に rollback する際、利用者が実行中に代入した値を
  /// 破壊しないために使います。
  @discardableResult
  func compareAndSetStream(
    _ expected: MediaStream?,
    to newValue: MediaStream?,
    id: CameraCapturerID
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard streams[id]?.value === expected else {
      return false
    }
    if let newValue {
      streams[id] = WeakStream(newValue)
    } else {
      streams[id] = nil
    }
    return true
  }

  /// 指定した capturer の資源を破棄します。
  ///
  /// capturer instance の解放時に呼び、`AVCaptureDevice.Format` を保持し続けません。
  func remove(id: CameraCapturerID) {
    lock.lock()
    defer { lock.unlock() }
    formats[id] = nil
    streams[id] = nil
  }
}

/// capturer instance を弱参照で保持し、ID から解決するテーブルです。
///
/// instance の生存はこのテーブルでは保証しません。`CameraStrongStorage` と
/// command 入力が強参照を持ちます。
///
/// `@unchecked Sendable` としているのは、可変状態が `instances` だけで、
/// その読み書きをすべて `lock` で排他しているためです。
private final class CameraInstanceTable: @unchecked Sendable {
  /// `CameraVideoCapturer` を弱参照で包む内部ラッパーです。
  ///
  /// `@unchecked Sendable` としているのは、`value` の読み書きが外側の
  /// `CameraInstanceTable` の lock 下でのみ行われるためです。
  private final class WeakCapturer: @unchecked Sendable {
    weak var value: CameraVideoCapturer?

    init(_ value: CameraVideoCapturer) {
      self.value = value
    }
  }

  private let lock = NSLock()
  private var instances: [CameraCapturerID: WeakCapturer] = [:]

  /// instance を登録します。
  func register(id: CameraCapturerID, instance: CameraVideoCapturer) {
    lock.lock()
    defer { lock.unlock() }
    instances[id] = WeakCapturer(instance)
  }

  /// ID から instance を解決します。
  func instance(id: CameraCapturerID) -> CameraVideoCapturer? {
    lock.lock()
    defer { lock.unlock() }
    return instances[id]?.value
  }

  /// 登録を解除します。
  ///
  /// capturer instance の解放時に呼び、弱参照エントリを残しません。
  func remove(id: CameraCapturerID) {
    lock.lock()
    defer { lock.unlock() }
    instances[id] = nil
  }
}

/// active / front / back と pin された capturer を強参照で保持する storage です。
///
/// `current` / `front` / `back` は computed property として owner から解決するため、
/// この storage が唯一の強参照元になります。これにより、command のローカル変数が
/// 解放された後も動作中の instance が生存します。
/// `pin` は lease が capturer を ID のみで保持している間の生存を保証します。
///
/// `@unchecked Sendable` としているのは、可変状態が `active` / `front` / `back` /
/// `pinned` だけで、その読み書きをすべて `lock` で排他しているためです。
private final class CameraStrongStorage: @unchecked Sendable {
  /// pin された instance と、その保持者数です。
  private struct PinnedEntry {
    let capturer: CameraVideoCapturer
    var count: Int
  }

  private let lock = NSLock()
  private var active: CameraVideoCapturer?
  private var front: CameraVideoCapturer?
  private var back: CameraVideoCapturer?
  private var pinned: [CameraCapturerID: PinnedEntry] = [:]

  /// active capturer を設定します。`nil` で解除します。
  func setActive(_ capturer: CameraVideoCapturer?) {
    lock.lock()
    defer { lock.unlock() }
    active = capturer
  }

  /// front capturer を返します。未生成なら `nil` です。
  func frontCapturer() -> CameraVideoCapturer? {
    lock.lock()
    defer { lock.unlock() }
    return front
  }

  /// back capturer を返します。未生成なら `nil` です。
  func backCapturer() -> CameraVideoCapturer? {
    lock.lock()
    defer { lock.unlock() }
    return back
  }

  /// 未生成の場合だけ front capturer として保持し、保持している instance を返します。
  ///
  /// 生成は lock の外で行い、保持の可否だけを lock 内で判定します。同時アクセスで
  /// 負けた instance は保持せず、先に保持された instance を返します。これにより
  /// 同じ position に 2 つの instance が存在しません。
  func setFrontIfAbsent(_ capturer: CameraVideoCapturer) -> CameraVideoCapturer {
    lock.lock()
    defer { lock.unlock() }
    if let front {
      return front
    }
    front = capturer
    return capturer
  }

  /// 未生成の場合だけ back capturer として保持し、保持している instance を返します。
  func setBackIfAbsent(_ capturer: CameraVideoCapturer) -> CameraVideoCapturer {
    lock.lock()
    defer { lock.unlock() }
    if let back {
      return back
    }
    back = capturer
    return capturer
  }

  /// instance を pin して生存させます。
  ///
  /// `VideoHardMuteActor` が capturer を ID のみで保持している間、instance が
  /// 解放されないようにするために使います。同じ ID を複数の保持者が pin できるよう、
  /// 保持者数を数えて 1 回の unpin では解放しません。
  func pin(_ capturer: CameraVideoCapturer, id: CameraCapturerID) {
    lock.lock()
    defer { lock.unlock() }
    if let entry = pinned[id] {
      pinned[id] = PinnedEntry(capturer: entry.capturer, count: entry.count + 1)
    } else {
      pinned[id] = PinnedEntry(capturer: capturer, count: 1)
    }
  }

  /// pin を 1 つ解除します。保持者がいなくなったら解放します。
  func unpin(id: CameraCapturerID) {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = pinned[id] else {
      return
    }
    if entry.count <= 1 {
      pinned[id] = nil
    } else {
      pinned[id] = PinnedEntry(capturer: entry.capturer, count: entry.count - 1)
    }
  }
}

/// カメラ状態の単一所有者です。
///
/// reducer とカメラに属する mutable state を所有し、直列化された ingress を通じて
/// イベントを直列に処理します。state の更新はいつもこの所有者の上で行われます。
///
/// 同期 API から await で呼び出さずに済むよう、actor ではなく `DispatchQueue` (serial)
/// による直列化を採用しています。
///
/// 初期化順の注意: この型の `init` では `CameraVideoCapturer` を生成しません。
/// `front` / `back` は初回アクセス時に遅延生成します。これにより `shared` の
/// 初期化中に `CameraVideoCapturer.init` が owner を再入参照しません。
///
/// `@unchecked Sendable` としているのは、可変状態が `eventQueue` 上でのみ読み書きする
/// `currentState` と、それぞれが lock を持つ storage / テーブルだけであり、
/// いずれも `let` で差し替えないためです。
final class CameraStateOwner: @unchecked Sendable {
  /// プロセス全体で共有する所有者です。
  static let shared = CameraStateOwner()

  /// イベントを直列処理するための serial DispatchQueue です。
  private let eventQueue = DispatchQueue(
    label: "jp.shiguredo.sora.CameraStateOwner")

  /// 現在の reducer state です。`eventQueue` 上の直列処理でのみ読み書きします。
  private var currentState = CameraState()

  /// 同期 getter が読む snapshot storage です。
  private let snapshotStorage: CameraSnapshotStorage

  /// ID から instance を解決する弱参照テーブルです。
  private let instanceTable: CameraInstanceTable

  /// non-Sendable な実資源を保持するテーブルです。
  private let resourceTable: CameraResourceTable

  /// active capturer と front / back の強参照ストレージです。
  private let strongStorage: CameraStrongStorage

  init() {
    self.snapshotStorage = CameraSnapshotStorage()
    self.instanceTable = CameraInstanceTable()
    self.resourceTable = CameraResourceTable()
    self.strongStorage = CameraStrongStorage()
  }

  /// イベントを直列に処理し、実行すべき effect を返します。
  ///
  /// state の更新と、active capturer の強参照ストレージの追随を同じ直列区間で行います。
  /// 戻り値は reducer が返した effect です。`publishSnapshot` はこの中で実行済みのため、
  /// 呼び出し側で実行する必要はありません (`CameraEffect` に将来ケースを足す場合だけ
  /// 戻り値を使います)。
  @discardableResult
  func handle(_ event: CameraEvent) -> [CameraEffect] {
    eventQueue.sync {
      let previousActiveID = currentState.activeCapturerID
      let (newState, effects) = CameraStateReducer.reduce(
        state: currentState, event: event)
      currentState = newState

      publishSnapshot(state: newState, effects: effects)

      // active capturer が変わった場合は強参照ストレージを追随させる。
      // (instance テーブルは弱参照のため、ここで強参照を保たないと解放される)
      if previousActiveID != newState.activeCapturerID {
        strongStorage.setActive(
          newState.activeCapturerID.flatMap { instanceTable.instance(id: $0) })
      }

      return effects
    }
  }

  /// effect に publishSnapshot が含まれる場合だけ snapshot を更新します。
  private func publishSnapshot(state: CameraState, effects: [CameraEffect]) {
    if effects.contains(.publishSnapshot) {
      snapshotStorage.publish(state: state)
    }
  }

  /// instance を ID と対応付けて登録します。
  ///
  /// `CameraVideoCapturer` が自身で採番した ID を渡します。owner は採番しません。
  func register(id: CameraCapturerID, instance: CameraVideoCapturer) {
    instanceTable.register(id: id, instance: instance)
  }

  /// 現在の snapshot を返します。
  var snapshot: CameraState {
    snapshotStorage.current()
  }

  /// 現在動作中の capturer を返します。
  var currentCapturer: CameraVideoCapturer? {
    let state = snapshotStorage.current()
    guard let id = state.activeCapturerID else {
      return nil
    }
    return instanceTable.instance(id: id)
  }

  /// 指定した ID の instance を返します。
  ///
  /// `VideoHardMuteActor` が保存した capturer を解決するために使います。
  /// instance の生存は `pin` で保証します。
  func capturer(id: CameraCapturerID) -> CameraVideoCapturer? {
    instanceTable.instance(id: id)
  }

  /// instance を pin して生存させます。
  ///
  /// `VideoHardMuteActor` が capturer を ID のみで保持する間、instance が解放されると
  /// ハードミュート解除時の再開ができなくなるため、owner が強参照を保ちます。
  /// 同じ ID を複数の保持者が pin できるよう保持者数を数え、`unpin` は 1 つ分だけ解除します。
  func pin(id: CameraCapturerID, instance: CameraVideoCapturer) {
    strongStorage.pin(instance, id: id)
  }

  /// pin を 1 つ解除します。保持者がいなくなったら instance を解放します。
  func unpin(id: CameraCapturerID) {
    strongStorage.unpin(id: id)
  }

  /// capturer instance が解放されたことを記録し、その ID の資源と state を破棄します。
  ///
  /// `CameraVideoCapturer.deinit` から呼びます。資源の破棄と state の更新を同じ直列区間
  /// (`eventQueue`) にまとめて投入します。分けて実行すると「instance は消えたが state は
  /// active / running のまま」の窓ができ、`current` と `isRunning` の整合が崩れます。
  ///
  /// deinit は `CameraStrongStorage` の lock 保持中にも `eventQueue` 上にも起こり得るため、
  /// ここから `CameraStrongStorage` を触ったり `handle` を同期で呼んだりすると
  /// 非再帰 lock で deadlock します。解放中の instance は `pin` されておらず
  /// (pin は強参照を保つため deinit しない)、unpin も不要です。active の instance も
  /// `CameraStrongStorage` が強参照するため deinit せず、強参照ストレージの追随は
  /// 必要ありません (`.capturerReleased` の active 解除は不変条件が崩れた場合の防御です)。
  func release(id: CameraCapturerID) {
    eventQueue.async { [self] in
      resourceTable.remove(id: id)
      instanceTable.remove(id: id)
      let (newState, effects) = CameraStateReducer.reduce(
        state: currentState, event: .capturerReleased(id: id))
      currentState = newState
      publishSnapshot(state: newState, effects: effects)
    }
  }

  /// 次の操作世代を採番します。
  ///
  /// 世代は `eventQueue` 上の直列区間で進めます。採番と `handle` は別の呼び出しですが、
  /// 世代を使うカメラ操作は `CameraVideoCaptureCoordinator` が直列化するため、
  /// 採番した世代の操作に別のコマンドが割り込むことはありません。
  ///
  /// snapshot は publish しません。`operationGeneration` は reducer の内部照合にだけ
  /// 使い、snapshot から読む経路が無いためです。
  func nextGeneration() -> UInt64 {
    eventQueue.sync {
      currentState.operationGeneration &+= 1
      return currentState.operationGeneration
    }
  }

  /// front capturer を遅延生成して返します。
  ///
  /// owner の `init` 中には生成しません。初回アクセス時に生成し、instance が自身で ID を採番します。
  /// 生成は lock の外で行うため、同時アクセスでは負けた instance を保持せず、
  /// 先に保持された instance を返します。
  func frontCapturer() -> CameraVideoCapturer? {
    if let capturer = strongStorage.frontCapturer() {
      return capturer
    }
    guard let device = CameraVideoCapturer.device(for: .front) else {
      return nil
    }
    return strongStorage.setFrontIfAbsent(CameraVideoCapturer(device: device))
  }

  /// back capturer を遅延生成して返します。
  func backCapturer() -> CameraVideoCapturer? {
    if let capturer = strongStorage.backCapturer() {
      return capturer
    }
    guard let device = CameraVideoCapturer.device(for: .back) else {
      return nil
    }
    return strongStorage.setBackIfAbsent(CameraVideoCapturer(device: device))
  }

  /// 送信先 stream を設定します。
  func setStream(_ stream: MediaStream?, id: CameraCapturerID) {
    resourceTable.setStream(stream, id: id)
  }

  /// 送信先 stream を返します。
  func stream(id: CameraCapturerID) -> MediaStream? {
    resourceTable.stream(id: id)
  }

  /// 送信先 stream を compare-and-swap で書き換えます。
  @discardableResult
  func compareAndSetStream(
    _ expected: MediaStream?,
    to newValue: MediaStream?,
    id: CameraCapturerID
  ) -> Bool {
    resourceTable.compareAndSetStream(expected, to: newValue, id: id)
  }

  /// capturer が動作中かを返します。
  func isRunning(id: CameraCapturerID) -> Bool {
    snapshotStorage.current().runningCapturers.contains(id)
  }

  /// capturer のフレームレートを返します。
  func frameRate(id: CameraCapturerID) -> Int? {
    snapshotStorage.current().frameRates[id]
  }

  /// format を記録します。
  ///
  /// format は世代を持たない resource テーブルへ、frameRate は世代で破棄される reducer の
  /// state へ記録します。隔離とカメラ操作は coordinator が直列化するため、最終状態が
  /// 食い違うことはありません (別 storage のため、読み手が一時的に新しい format と
  /// 古い frameRate を観測することはあります)。
  func setFormat(_ format: AVCaptureDevice.Format, id: CameraCapturerID) {
    resourceTable.setFormat(format, id: id)
  }

  /// format を返します。
  func format(id: CameraCapturerID) -> AVCaptureDevice.Format? {
    resourceTable.format(id: id)
  }
}
