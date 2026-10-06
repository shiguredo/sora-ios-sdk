// このファイルは `#if DEBUG` のテスト用アクセサに依存するため、Debug 構成でのみビルドできます。

import Foundation
import WebRTC
import XCTest

@testable import Sora

/// `getStatsSnapshot` の handler が観測した結果と呼び出し回数を、テストスレッドへ排他して
/// 受け渡します。
///
/// `@unchecked Sendable` としているのは、可変状態 (結果と呼び出し回数) の読み書きをすべて
/// `lock` で排他しており、Sendable な `StatisticsSnapshot` を handler の内側からテスト側へ
/// 渡すためだけに保持するためです (handler は WebRTC のスレッドから呼ばれます)。
/// 同じテストターゲットの他のテストファイルからも使うため internal とします。
final class StatisticsSnapshotObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<StatisticsSnapshot, any Error>?
  private var callCount = 0

  /// handler の結果と呼び出し回数を記録します。
  func record(_ result: Result<StatisticsSnapshot, any Error>) {
    lock.lock()
    defer { lock.unlock() }
    self.result = result
    callCount += 1
  }

  var recordedResult: Result<StatisticsSnapshot, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }

  var recordedCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }
}

/// テスト用フック (`@Sendable`) から expectation を fulfil するための箱です。
///
/// `XCTestExpectation` は `Sendable` ではないため、`@Sendable` なフックの closure へ直接
/// capture できません。expectation は `init` で確定する不変の参照で、`fulfill()` はどの
/// スレッドから呼んでも安全です。
private final class StatisticsSnapshotHookExpectation: @unchecked Sendable {
  let expectation: XCTestExpectation

  init(_ expectation: XCTestExpectation) {
    self.expectation = expectation
  }

  /// 保持している expectation を fulfil します。
  func fulfill() {
    expectation.fulfill()
  }
}

/// 同一の `RTCStatisticsReport` から legacy の `Statistics` と `StatisticsSnapshot` を作り、
/// `JSONValue` へ正規化した値をテストスレッドへ渡すための箱です。
///
/// `@unchecked Sendable` としているのは、可変状態 (結果とエラー) の読み書きをすべて `lock` で
/// 排他しているためです。`Statistics` は非 Sendable のため、WebRTC のスレッドの中で `JSONValue`
/// へ写してから保持します。
private final class SameReportStatisticsConversion: @unchecked Sendable {
  /// 正規化済みの legacy のエントリーです。
  struct LegacyEntry {
    /// エントリー ID
    let id: String
    /// 統計種別
    let type: String
    /// `Statistics.jsonObject` から `id` / `type` / `timestamp` を取り除いた値
    let values: [String: JSONValue]
  }

  /// 変換結果です。
  struct Result {
    /// snapshot 側の結果
    let snapshot: StatisticsSnapshot
    /// legacy 側の収集時刻
    let legacyTimestamp: CFTimeInterval
    /// legacy 側のエントリー
    let legacyEntries: [LegacyEntry]
  }

  private let lock = NSLock()
  private var result: Result?
  private var error: (any Error)?

  /// 同じ report を両方の型へ変換して記録します。
  /// - parameter report: libwebrtc が返した統計レポート
  func record(report: RTCStatisticsReport) {
    do {
      let snapshot = try StatisticsSnapshot(contentsOf: report)
      let legacy = Statistics(contentsOf: report)
      let legacyEntries = try Self.normalize(legacy)
      lock.lock()
      result = Result(
        snapshot: snapshot, legacyTimestamp: legacy.timestamp, legacyEntries: legacyEntries)
      lock.unlock()
    } catch {
      lock.lock()
      self.error = error
      lock.unlock()
    }
  }

  var recordedResult: Result? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }

  var recordedError: (any Error)? {
    lock.lock()
    defer { lock.unlock() }
    return error
  }

  /// `Statistics.jsonObject` を snapshot と同じ変換経路で `JSONValue` へ正規化します。
  ///
  /// `Statistics.jsonObject` は entry の `id` / `type` / `timestamp` を値と同じ辞書へ載せるため、
  /// snapshot の値と比較できるよう 3 つを取り除きます (`Statistics.jsonObject` 自体は変えません)。
  private static func normalize(_ statistics: Statistics) throws -> [LegacyEntry] {
    guard case .array(let entries) = try JSONValue.fromJSONSerializationValue(statistics.jsonObject)
    else {
      throw SoraError.mediaChannelError(reason: "legacy statistics are not a JSON array")
    }
    return entries.compactMap { value in
      guard case .object(var object) = value,
        let idValue = object["id"],
        let typeValue = object["type"],
        case .string(let id) = idValue,
        case .string(let type) = typeValue
      else {
        return nil
      }
      object["id"] = nil
      object["type"] = nil
      object["timestamp"] = nil
      return LegacyEntry(id: id, type: type, values: object)
    }
  }
}

/// statistics snapshot API の値の変換と終端を、実 `RTCPeerConnection` で固定するテストです。
///
/// 値の変換は実 report に現れない値型も対象にするため internal な関数へ直接与えます。終端は
/// `#if DEBUG` のテスト用フック (`setConnectionStateForTesting(_:)` /
/// `getStatsSnapshotWillEvaluateForTesting`) で確定的に作ります。モックやスタブは使用しません。
final class StatisticsSnapshotTests: XCTestCase {
  /// テスト用の最小の接続設定を作ります。
  private func makeConfiguration() throws -> Configuration {
    let url = try XCTUnwrap(URL(string: "wss://example.com"), "テスト URL を生成できること")
    return Configuration(
      urlCandidates: [url],
      channelId: "test",
      role: .recvonly)
  }

  /// 接続済みの `MediaChannel` と実 `RTCPeerConnection` を用意します。
  ///
  /// 返す箱 (`MediaChannelOwner`) が `MediaChannel` の唯一の強参照です。テスト側は
  /// `owner.current` 経由で一時的に参照し、完了 block の内側で最後の参照を解放できるようにします。
  /// `PeerChannel` はテストが強参照で保持して `MediaChannel` の解放後も生存させます
  /// (`PeerChannel` も解放されると、終端フラグの確認を削っても `transportStorage` の nil ガードが
  /// 同じ失敗を返すため、終端フラグの退行を検出できません)。
  private func makeConnectedChannel() throws -> (
    owner: MediaChannelOwner, peerChannel: PeerChannel, nativeChannel: RTCPeerConnection
  ) {
    let owner = MediaChannelOwner(try MediaChannel(configuration: makeConfiguration()))
    let peerChannel = try XCTUnwrap(owner.current?.peerChannel, "PeerChannel を取得できること")
    let nativeChannel = try XCTUnwrap(
      peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        webRTCConfiguration: WebRTCConfigurationSnapshot(WebRTCConfiguration()),
        delegate: peerChannel),
      "RTCPeerConnection を生成できること")
    peerChannel.nativeChannel = nativeChannel
    owner.current?.setConnectionStateForTesting(.connected)
    return (owner, peerChannel, nativeChannel)
  }

  /// テストが失敗しても `RTCPeerConnection` を後始末します。
  ///
  /// 解放経路のテストでは `MediaChannel` の `deinit` が既に PC を閉じているため、
  /// `.closed` でない場合だけ閉じます。
  /// - Parameters:
  ///   - peerChannel: `nativeChannel` を戻す `PeerChannel`
  ///   - owner: `MediaChannel` を保持する箱 (解放済みなら何もしない)
  ///   - nativeChannel: 後始末の対象
  private func cleanup(
    peerChannel: PeerChannel, owner: MediaChannelOwner, nativeChannel: RTCPeerConnection
  ) {
    peerChannel.nativeChannel = nil
    owner.current?.setConnectionStateForTesting(.disconnected)
    if nativeChannel.connectionState != .closed {
      nativeChannel.close()
    }
  }

  // MARK: - 値の変換

  /// 実 report に現れる value (number / string / bool / null / sequence / map) を `JSONValue` へ
  /// 変換できることを確認する
  ///
  /// `values` は `[String: NSObject]` のため、全ての値が silent drop されずに変換されることと、
  /// 数値が `Double` へ落ちずに `Decimal` として読めることを固定します。実 report の値は
  /// `NSNumber` / `NSString` / `NSArray` / `NSDictionary` で構成されます。
  func testValuesConvertToJSONValues() throws {
    let values: [String: NSObject] = [
      "number": NSNumber(value: 42),
      "decimal": NSNumber(value: 0.5),
      "bool": NSNumber(value: true),
      "string": "sora" as NSString,
      "null": NSNull(),
      "sequence": [NSNumber(value: 1), "a" as NSString] as NSArray,
      "map": ["nested": NSNumber(value: 2)] as NSDictionary,
      "uint64": NSNumber(value: UInt64.max),
      "decimalNumber": NSDecimalNumber(string: "0.1"),
      "doubleDecimal": NSNumber(value: 0.1),
      "emptyMap": [:] as NSDictionary,
      "emptySequence": [] as NSArray,
      // entry の id / type / timestamp と同じ名前の統計値も、値としてそのまま残る
      // (legacy の `Statistics.jsonObject` は entry 側を優先するため、この点だけ挙動が異なる)。
      "id": "entry-id" as NSString,
      "type": "entry-type" as NSString,
      "timestamp": NSNumber(value: 1.5),
    ]

    let converted = try StatisticsEntrySnapshot.jsonValues(from: values)

    XCTAssertEqual(converted.count, values.count, "全ての値が変換されること (silent drop しない)")
    XCTAssertEqual(
      converted["number"], JSONValue.decimal(Decimal(42)), "整数は Decimal として読めること")
    XCTAssertEqual(
      converted["decimal"],
      JSONValue.decimal(try XCTUnwrap(Decimal(string: "0.5"))),
      "小数は Decimal として読めること")
    XCTAssertEqual(converted["bool"], JSONValue.bool(true), "bool は bool として読めること")
    XCTAssertEqual(converted["string"], JSONValue.string("sora"), "string は string として読めること")
    XCTAssertEqual(converted["null"], JSONValue.null, "null は null として読めること")
    XCTAssertEqual(
      converted["sequence"],
      JSONValue.array([.decimal(Decimal(1)), .string("a")]),
      "sequence は array として読めること")
    XCTAssertEqual(
      converted["map"],
      JSONValue.object(["nested": .decimal(Decimal(2))]),
      "map は object として読めること")
    XCTAssertEqual(
      converted["uint64"], JSONValue.decimal(Decimal(UInt64.max)),
      "UInt64.max でも精度が落ちないこと")
    XCTAssertEqual(
      converted["decimalNumber"],
      JSONValue.decimal(try XCTUnwrap(Decimal(string: "0.1"))),
      "NSDecimalNumber は Decimal の値として読めること")
    XCTAssertNotEqual(
      converted["doubleDecimal"], converted["decimalNumber"],
      "Double 由来の小数は JSONSerialization 経由のため NSDecimalNumber と同じ値にならないこと")
    XCTAssertEqual(converted["emptyMap"], JSONValue.object([:]), "空の map も object になること")
    XCTAssertEqual(converted["emptySequence"], JSONValue.array([]), "空の sequence も array になること")
    XCTAssertEqual(converted["id"], JSONValue.string("entry-id"), "id と同名の値も残ること")
    XCTAssertEqual(converted["type"], JSONValue.string("entry-type"), "type と同名の値も残ること")
    XCTAssertEqual(
      converted["timestamp"], JSONValue.decimal(try XCTUnwrap(Decimal(string: "1.5"))),
      "timestamp と同名の値も残ること")
  }

  /// `JSONValue` として表現できない値は silent drop せず、呼び出し全体が
  /// `SoraError.mediaChannelError` で失敗することを確認する
  ///
  /// 実 report には現れない値型を直接与えます。`JSONSerialization.isValidJSONObject` による
  /// 事前検証が無い経路では、捕捉できない NSException でプロセスが終了します。実 report の値は
  /// array / dictionary に入れ子で現れるため、入れ子の場合も固定します。
  func testValuesThrowMediaChannelErrorWhenJSONValueCannotRepresentTheValue() throws {
    // Date は JSONSerialization が JSON の値として受理しない。
    let withDate: [String: NSObject] = ["number": NSNumber(value: 1), "date": NSDate()]
    // -inf は JSON の数値として表現できない。
    let withInfinity: [String: NSObject] = [
      "number": NSNumber(value: 1),
      "infinity": NSNumber(value: -Double.infinity),
    ]
    // array に入れ子になった Date。
    let withNestedDate: [String: NSObject] = ["sequence": [NSDate()] as NSArray]
    // dictionary に入れ子になった Date。
    let withNestedDateMap: [String: NSObject] = ["map": ["date": NSDate()] as NSDictionary]
    // NaN は JSON の数値として表現できない。
    let withNaN: [String: NSObject] = ["nan": NSNumber(value: Double.nan)]
    // 深い入れ子の Date。
    let withDeeplyNestedDate: [String: NSObject] = [
      "map": ["nested": ["date": NSDate()] as NSDictionary] as NSDictionary
    ]
    // NSString 以外の key を持つ dictionary。
    let withNonStringKey: [String: NSObject] = [
      "map": [NSNumber(value: 1): "a" as NSString] as NSDictionary
    ]

    for values in [
      withDate, withInfinity, withNestedDate, withNestedDateMap, withNaN,
      withDeeplyNestedDate, withNonStringKey,
    ] {
      XCTAssertThrowsError(
        try StatisticsEntrySnapshot.jsonValues(from: values),
        "JSON へ変換できない値を含む場合は失敗すること"
      ) { error in
        guard let soraError = error as? SoraError,
          case .mediaChannelError(let reason) = soraError
        else {
          XCTFail("SoraError.mediaChannelError で失敗すること (error: \(error))")
          return
        }
        XCTAssertFalse(reason.isEmpty, "失敗理由が空でないこと")
      }
    }
  }

  // MARK: - 終端

  /// `MediaChannel` の解放開始後に完了 block が走った場合に、成功を返さず
  /// `MediaChannel is unavailable` の失敗を 1 回だけ返すことを確認する
  ///
  /// 解放は完了 block の判定の先頭で呼ばれる `getStatsSnapshotWillEvaluateForTesting` の
  /// 中で行います。解放の確認を削ると完了 block が成功を返すため、このテストが失敗します。
  func testGetStatsSnapshotFailsWhenMediaChannelIsDeinitializedInCompletionBlock() throws {
    let (owner, peerChannel, nativeChannel) = try makeConnectedChannel()
    defer {
      cleanup(peerChannel: peerChannel, owner: owner, nativeChannel: nativeChannel)
    }

    // 解放が起きない場合に MediaChannel を延命しないよう、箱は弱参照で捕捉します。
    let release = GetStatsHookAction { [weak owner] in owner?.release() }
    owner.current?.getStatsSnapshotWillEvaluateForTesting = { release.perform() }

    let statsExpectation = expectation(
      description: "解放開始後に完了 block が走った場合は handler が失敗で 1 回呼ばれること")
    let observation = StatisticsSnapshotObservation()
    owner.current?.getStatsSnapshot { result in
      // handler は WebRTC のスレッドから呼ばれるため、assertion はテスト側で行います。
      observation.record(result)
      statsExpectation.fulfill()
    }
    wait(for: [statsExpectation], timeout: 5)

    XCTAssertEqual(
      observation.recordedCallCount, 1,
      "getStatsSnapshot の handler が 1 回だけ呼ばれること")
    guard case .failure(let error) = observation.recordedResult,
      let soraError = error as? SoraError,
      case .peerChannelError(let reason) = soraError
    else {
      XCTFail(
        "解放開始後に完了 block が走った場合は失敗すること (result: \(String(describing: observation.recordedResult)))"
      )
      return
    }
    XCTAssertEqual(
      reason, "MediaChannel is unavailable",
      "getStats と同じ失敗理由であること (reason: \(reason))")
  }

  /// 解放と接続状態の変更が同じ完了 block の内側で起きた場合に、解放の確認が優先されることを
  /// 確認する
  ///
  /// 解放の確認が `state == .connected` の確認より前にあることを、失敗理由で固定します
  /// (`.disconnected` へ遷移させてから解放するため、順序が逆だと `MediaChannel is not connected`
  /// が返ります)。解放の手順と前提は
  /// `testGetStatsSnapshotFailsWhenMediaChannelIsDeinitializedInCompletionBlock` と同じです。
  func testGetStatsSnapshotReportsUnavailableWhenStateChangesBeforeDeinitialization() throws {
    let (owner, peerChannel, nativeChannel) = try makeConnectedChannel()
    defer {
      cleanup(peerChannel: peerChannel, owner: owner, nativeChannel: nativeChannel)
    }

    // テスト用フックの内側では、先に接続状態を `.disconnected` にしてから最後の強参照を
    // 解放します (フックが戻る前に解放が起きるため、次に進む前に `MediaChannel` はいません)。
    let releaseAndDisconnect = GetStatsHookAction { [weak owner] in
      owner?.current?.setConnectionStateForTesting(.disconnected)
      owner?.release()
    }
    owner.current?.getStatsSnapshotWillEvaluateForTesting = { releaseAndDisconnect.perform() }

    let statsExpectation = expectation(
      description: "接続状態の変更後に解放された場合は handler が失敗で 1 回呼ばれること")
    let observation = StatisticsSnapshotObservation()
    owner.current?.getStatsSnapshot { result in
      // handler は WebRTC のスレッドから呼ばれるため、 assertion はテスト側で行います。
      observation.record(result)
      statsExpectation.fulfill()
    }
    wait(for: [statsExpectation], timeout: 5)

    XCTAssertEqual(
      observation.recordedCallCount, 1,
      "getStatsSnapshot の handler が 1 回だけ呼ばれること")
    guard case .failure(let error) = observation.recordedResult,
      let soraError = error as? SoraError,
      case .peerChannelError(let reason) = soraError
    else {
      XCTFail(
        "接続状態の変更後に解放された場合は失敗すること (result: \(String(describing: observation.recordedResult)))"
      )
      return
    }
    XCTAssertEqual(
      reason, "MediaChannel is unavailable",
      "解放の確認が state の確認より前に行われること (reason: \(reason))")
  }

  /// async 版でも、完了 block の評価時に接続状態が変わった場合は失敗で 1 回終端することを
  /// 確認する
  ///
  /// `getStatsSnapshot()` は `getStatsSnapshot(handler:)` の完了 block を共通で使うため、
  /// 失敗の理由と回数は callback 版と同じです。
  func testGetStatsSnapshotAsyncReportsUnavailableWhenConnectionStateChanges() async throws {
    let (owner, peerChannel, nativeChannel) = try makeConnectedChannel()
    defer {
      cleanup(peerChannel: peerChannel, owner: owner, nativeChannel: nativeChannel)
    }

    let completion = expectation(description: "統計取得の完了 block が走ること")
    let hook = StatisticsSnapshotHookExpectation(completion)
    let disconnect = GetStatsHookAction { [weak owner] in
      owner?.current?.setConnectionStateForTesting(.disconnected)
    }
    owner.current?.getStatsSnapshotWillEvaluateForTesting = {
      disconnect.perform()
      hook.fulfill()
    }

    let task = snapshotTask(owner: owner)
    // 完了 block が走るのを待ってから結果を確認します。完了 block が来ない退行では待ち合わせが
    // タイムアウトするため、その場合はタスクをキャンセルして `await` が止まるのを防ぎます。
    let waitResult = await XCTWaiter.fulfillment(of: [completion], timeout: 5)
    if waitResult != .completed {
      task.cancel()
    }
    let result = await waitForSnapshot(task)
    XCTAssertEqual(waitResult, .completed, "統計取得の完了 block が走ること")

    guard case .failure(let error) = result,
      let soraError = error as? SoraError,
      case .peerChannelError(let reason) = soraError
    else {
      XCTFail(
        "接続状態の変更後は失敗すること (result: \(String(describing: result)))")
      return
    }
    XCTAssertTrue(
      reason.contains("MediaChannel is not connected"),
      "切断後の失敗理由が接続状態を示すこと (reason: \(reason))")
  }

  /// キャンセル済みのタスクは `CancellationError` で終端し、キャンセル後に届いた完了 block の
  /// 結果を返さないことを確認する
  ///
  /// `withTaskCancellationHandler` の `onCancel` は `operation` より先に呼ばれるため、
  /// continuation は `CancellationError` で終端します。libwebrtc に統計取得をキャンセルする API が
  /// 無いため `RTCPeerConnection.statistics` は開始され、完了 block は走りますが、終端済みの
  /// ため結果は返しません (`resume` を 2 回行うとテストはクラッシュします)。
  /// 「完了 block が先に終端し、その後にキャンセルが届く」順序は、完了 block の評価開始から
  /// operation の終了までが短く、外から確定的に作れないためこのテストでは扱いません。終端の
  /// 1 回性は、continuation を終端した側が `nil` にすることで担保します。
  func testGetStatsSnapshotAsyncThrowsCancellationErrorAndDiscardsLateResult() async throws {
    let (owner, peerChannel, nativeChannel) = try makeConnectedChannel()
    defer {
      cleanup(peerChannel: peerChannel, owner: owner, nativeChannel: nativeChannel)
    }

    let completion = expectation(description: "キャンセル後も統計取得の完了 block が走ること")
    let hook = StatisticsSnapshotHookExpectation(completion)
    owner.current?.getStatsSnapshotWillEvaluateForTesting = { hook.fulfill() }

    // このテストだけは呼び出し前にタスク自身をキャンセルするため、`snapshotTask(owner:)` を
    // 使わずにインラインで作ります。
    let task = Task { [weak owner] in
      withUnsafeCurrentTask { $0?.cancel() }
      guard let channel = owner?.current else {
        throw SoraError.peerChannelError(reason: "MediaChannel is unavailable")
      }
      return try await channel.getStatsSnapshot()
    }
    // キャンセル後も完了 block が走ることを待ってから結果を確認します。待ち合わせがタイムアウト
    // しても、キャンセル済みのタスクは終端しているため `await` は止まりません。
    let waitResult = await XCTWaiter.fulfillment(of: [completion], timeout: 5)
    let result = await waitForSnapshot(task)
    XCTAssertEqual(waitResult, .completed, "キャンセル後も統計取得の完了 block が走ること")

    guard case .failure(let error) = result else {
      XCTFail("キャンセル済みのタスクでは成功しないこと (result: \(String(describing: result)))")
      return
    }
    XCTAssertTrue(
      error is CancellationError,
      "キャンセルは CancellationError で終端すること (error: \(error))")
  }

  /// 接続済みのチャンネルから snapshot を取得できることを確認する
  ///
  /// 実 Sora サーバーへ接続しないため統計は空になり得ますが、`RTCPeerConnection.statistics` の
  /// 完了 block から `StatisticsSnapshot` が返る経路を固定します。
  func testGetStatsSnapshotAsyncReturnsSnapshot() async throws {
    let (owner, peerChannel, nativeChannel) = try makeConnectedChannel()
    defer {
      cleanup(peerChannel: peerChannel, owner: owner, nativeChannel: nativeChannel)
    }

    let completion = expectation(description: "統計取得の完了 block が走ること")
    let hook = StatisticsSnapshotHookExpectation(completion)
    owner.current?.getStatsSnapshotWillEvaluateForTesting = { hook.fulfill() }

    let task = snapshotTask(owner: owner)
    // 完了 block が走るのを待ってから結果を確認します。完了 block が来ない退行では待ち合わせが
    // タイムアウトするため、その場合はタスクをキャンセルして `await` が止まるのを防ぎます。
    let waitResult = await XCTWaiter.fulfillment(of: [completion], timeout: 5)
    if waitResult != .completed {
      task.cancel()
    }
    let result = await waitForSnapshot(task)
    XCTAssertEqual(waitResult, .completed, "統計取得の完了 block が走ること")

    guard case .success(let snapshot) = result else {
      XCTFail("接続中は snapshot を返すこと (result: \(String(describing: result)))")
      return
    }
    XCTAssertGreaterThan(snapshot.timestamp, 0, "収集時刻が入ること")
    for entry in snapshot.entries {
      XCTAssertFalse(entry.id.isEmpty, "エントリー ID が空でないこと")
      XCTAssertFalse(entry.type.isEmpty, "統計種別が空でないこと")
    }
  }

  // MARK: - 入口の判定と同一性判定

  /// 入口の前段判定で失敗する場合は、handler が呼び出し元のスレッドから同期的に 1 回呼ばれる
  /// ことを確認する
  ///
  /// この 2 経路は完了 block を経由せず同期で終端するため、`wait` を使わずに呼び出し直後へ
  /// 判定します (呼び出しが戻った時点で handler が呼ばれていることが同期呼び出しの証明です)。
  func testGetStatsSnapshotFailsAtEntryGuards() throws {
    let mediaChannel = try MediaChannel(configuration: makeConfiguration())
    let peerChannel = mediaChannel.peerChannel
    defer {
      peerChannel.nativeChannel = nil
      mediaChannel.setConnectionStateForTesting(.disconnected)
    }

    // 接続状態が .connected でない場合は、nativeChannel が nil でも state の guard で終端する。
    // handler が呼び出し元のスレッドから同期的に呼ばれることは、handler の中のスレッド判定と、
    // 待たずに読み出した呼び出し回数で確認する (このテストは main thread で動く)。
    let notConnected = StatisticsSnapshotObservation()
    mediaChannel.getStatsSnapshot { result in
      XCTAssertTrue(
        Thread.isMainThread,
        "入口の判定の handler が呼び出し元のスレッドから呼ばれること")
      notConnected.record(result)
    }
    XCTAssertEqual(
      notConnected.recordedCallCount, 1,
      "未接続では handler が同期的に 1 回呼ばれること")
    assertPeerChannelError(
      notConnected.recordedResult, contains: "MediaChannel is not connected")

    // 接続状態が .connected でも nativeChannel が nil の場合は、nativeChannel の guard で終端する。
    mediaChannel.setConnectionStateForTesting(.connected)
    XCTAssertNil(peerChannel.nativeChannel, "nativeChannel が未設定であること")
    let unavailable = StatisticsSnapshotObservation()
    mediaChannel.getStatsSnapshot { result in
      XCTAssertTrue(
        Thread.isMainThread,
        "入口の判定の handler が呼び出し元のスレッドから呼ばれること")
      unavailable.record(result)
    }
    XCTAssertEqual(
      unavailable.recordedCallCount, 1,
      "nativeChannel が nil では handler が同期的に 1 回呼ばれること")
    assertPeerChannelError(
      unavailable.recordedResult,
      contains: "RTCPeerConnection is unavailable (nativeChannel: nil)")
  }

  /// async 版でも入口の前段判定で失敗し、1 回だけ終端することを確認する
  ///
  /// 入口の判定は `getStatsSnapshot(handler:)` と共通のため、失敗の種類と理由も同じです。
  func testGetStatsSnapshotAsyncFailsAtEntryGuards() async throws {
    let owner = MediaChannelOwner(try MediaChannel(configuration: makeConfiguration()))
    let peerChannel = try XCTUnwrap(owner.current?.peerChannel, "PeerChannel を取得できること")
    defer {
      peerChannel.nativeChannel = nil
      owner.current?.setConnectionStateForTesting(.disconnected)
    }

    let notConnected = await waitForSnapshot(snapshotTask(owner: owner))
    assertPeerChannelError(notConnected, contains: "MediaChannel is not connected")

    // 接続状態が .connected でも nativeChannel が nil の場合は nativeChannel の guard で終端する。
    owner.current?.setConnectionStateForTesting(.connected)
    XCTAssertNil(peerChannel.nativeChannel, "nativeChannel が未設定であること")
    let unavailable = await waitForSnapshot(snapshotTask(owner: owner))
    assertPeerChannelError(
      unavailable, contains: "RTCPeerConnection is unavailable (nativeChannel: nil)")
  }

  /// 統計を要求した後に `nativeChannel` が差し替わった場合は、失敗を 1 回だけ返すことを確認する
  ///
  /// 差し替えは完了 block の判定の先頭で呼ばれる `getStatsSnapshotWillEvaluateForTesting` で
  /// 行い、完了 block が評価する時点の状態を確定的に作ります。同一性判定
  /// (`currentPeerConnection === context.peerConnection`) を削ると handler が成功を返すため、
  /// このテストが失敗します。
  func testGetStatsSnapshotFailsWhenNativeChannelIsReplaced() throws {
    let owner = MediaChannelOwner(try MediaChannel(configuration: makeConfiguration()))
    let peerChannel = try XCTUnwrap(owner.current?.peerChannel, "PeerChannel を取得できること")
    guard
      let requestedChannel = peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        webRTCConfiguration: WebRTCConfigurationSnapshot(WebRTCConfiguration()),
        delegate: peerChannel),
      let replacementChannel = peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        webRTCConfiguration: WebRTCConfigurationSnapshot(WebRTCConfiguration()),
        delegate: peerChannel)
    else {
      XCTFail("RTCPeerConnection を 2 つ生成できること")
      return
    }

    // 後始末: 失敗してもテスト用フック・接続状態・PC を戻す。
    defer {
      owner.current?.getStatsSnapshotWillEvaluateForTesting = nil
      peerChannel.nativeChannel = nil
      owner.current?.setConnectionStateForTesting(.disconnected)
      requestedChannel.close()
      replacementChannel.close()
    }

    // 統計を要求した時点の PC と、完了 block が評価する時点の PC を別にする。
    let replacement = GetStatsHookAction { peerChannel.nativeChannel = replacementChannel }
    peerChannel.nativeChannel = requestedChannel
    owner.current?.setConnectionStateForTesting(.connected)
    owner.current?.getStatsSnapshotWillEvaluateForTesting = { replacement.perform() }

    let statsExpectation = expectation(
      description: "nativeChannel が差し替わった場合は handler が失敗で 1 回呼ばれること")
    let observation = StatisticsSnapshotObservation()
    owner.current?.getStatsSnapshot { result in
      // handler は WebRTC のスレッドから呼ばれるため、assertion はテスト側で行います。
      observation.record(result)
      statsExpectation.fulfill()
    }
    wait(for: [statsExpectation], timeout: 5)

    XCTAssertEqual(
      observation.recordedCallCount, 1,
      "getStatsSnapshot の handler が 1 回だけ呼ばれること")
    assertPeerChannelError(
      observation.recordedResult, contains: "nativeChannel changed")
  }

  // MARK: - 値の変換 (同一の report)

  /// 同一の `RTCStatisticsReport` を legacy の `Statistics` と `StatisticsSnapshot` の両方へ
  /// 変換し、同じ `JSONValue` として比較する
  ///
  /// 同じ report を使うため、カウンタが動いても結果は決定的です。`RTCStatisticsReport` は
  /// テストから生成できないため、実 `RTCPeerConnection` が返した report をその場で両方へ渡します。
  /// legacy 側は `Statistics.jsonObject` を snapshot と同じ変換経路へ通し、数値を `Double` へ
  /// 落とさずに比較します。エントリーを落とす退行は件数の比較で検出します。
  func testSnapshotValuesMatchLegacyStatisticsForTheSameReport() throws {
    let (owner, peerChannel, nativeChannel) = try makeConnectedChannel()
    defer {
      cleanup(peerChannel: peerChannel, owner: owner, nativeChannel: nativeChannel)
    }

    let conversion = SameReportStatisticsConversion()
    let reportExpectation = expectation(
      description: "実 RTCPeerConnection から統計レポートを取得できること")
    nativeChannel.statistics { report in
      // 完了 block は libwebrtc のスレッドから呼ばれるため、変換もその中で行います。
      conversion.record(report: report)
      reportExpectation.fulfill()
    }
    wait(for: [reportExpectation], timeout: 5)

    if let error = conversion.recordedError {
      XCTFail("同じ report を両方の型へ変換できること (error: \(error))")
      return
    }
    let result = try XCTUnwrap(conversion.recordedResult, "変換結果が記録されていること")

    XCTAssertEqual(
      result.snapshot.timestamp, result.legacyTimestamp,
      "収集時刻が legacy と同じであること")
    XCTAssertEqual(
      result.snapshot.entries.count, result.legacyEntries.count,
      "snapshot と legacy が同じ件数のエントリーを返すこと (エントリーを落とすと落ちる)")
    XCTAssertFalse(
      result.snapshot.entries.isEmpty,
      "実 RTCPeerConnection の report にエントリーがあること")
    for entry in result.snapshot.entries {
      guard
        let legacyEntry = result.legacyEntries.first(where: {
          $0.id == entry.id && $0.type == entry.type
        })
      else {
        XCTFail("legacy の統計に同じエントリーがあること (entry: \(entry.id))")
        continue
      }
      // `Statistics.jsonObject` は entry の id / type / timestamp を値と同じ辞書へ載せるため、
      // snapshot 側からも同じ 3 つを取り除いて比較する (同名の統計値があっても比較できる)。
      var snapshotValues = entry.values
      snapshotValues["id"] = nil
      snapshotValues["type"] = nil
      snapshotValues["timestamp"] = nil
      XCTAssertEqual(
        snapshotValues, legacyEntry.values,
        "snapshot の値が legacy と同じ JSONValue であること (entry: \(entry.id))")
    }
  }

  /// `MediaChannel` を保持する箱から snapshot を async 版で取得する `Task` を作ります。
  ///
  /// `MediaChannel` は `Sendable` ではないため、箱を経由して非分離の async API を呼びます。
  /// - Parameter owner: `MediaChannel` の唯一の強参照を保持する箱
  private func snapshotTask(
    owner: MediaChannelOwner
  ) -> Task<StatisticsSnapshot, any Error> {
    Task { [weak owner] in
      guard let channel = owner?.current else {
        throw SoraError.peerChannelError(reason: "MediaChannel is unavailable")
      }
      return try await channel.getStatsSnapshot()
    }
  }

  /// `Task` の完了を待ちます。
  ///
  /// `timeout` 秒でタスクをキャンセルします。完了 block が届かない退行は `CancellationError` と
  /// して観測され、assertion が失敗します。terminal の終端経路そのものが壊れた退行では
  /// キャンセルでも resume されないため、この待ち合わせは戻りません (CI では job のタイムアウトで
  /// 検出します)。
  /// - Parameters:
  ///   - task: 待つ `Task`
  ///   - timeout: 打ち切りまでの秒数
  private func waitForSnapshot(
    _ task: Task<StatisticsSnapshot, any Error>,
    timeout: TimeInterval = 5
  ) async -> Result<StatisticsSnapshot, any Error> {
    let watchdog = Task {
      try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      task.cancel()
    }
    let result = await task.result
    watchdog.cancel()
    return result
  }

  /// `peerChannelError` の `reason` が指定の文字列を含むことを確認します。
  /// - Parameters:
  ///   - result: handler または async 版が返した結果
  ///   - expected: `reason` に含まれることを期待する文字列
  private func assertPeerChannelError(
    _ result: Result<StatisticsSnapshot, any Error>?,
    contains expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .failure(let error) = result,
      let soraError = error as? SoraError,
      case .peerChannelError(let reason) = soraError
    else {
      XCTFail(
        "SoraError.peerChannelError で失敗すること (result: \(String(describing: result)))",
        file: file, line: line)
      return
    }
    XCTAssertTrue(
      reason.contains(expected),
      "失敗理由が \(expected) を含むこと (reason: \(reason))",
      file: file, line: line)
  }
}
