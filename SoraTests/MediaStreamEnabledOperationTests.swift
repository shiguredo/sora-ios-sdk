import XCTest

@testable import Sora

/// `onSwitchVideo` / `onSwitchAudio` が受け取った値を発火順に記録する実 handler 用の recorder です。
///
/// モックやスタブではなく、SDK から実際に呼ばれた値だけを記録します。handler は値の確定を
/// 行ったスレッドから同期で呼ばれるため、複数スレッドから呼ばれる場合に備えて lock で保護します。
private final class EnabledSwitchRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Bool] = []

  /// 発火した値を記録します。
  func append(_ value: Bool) {
    lock.lock()
    recorded.append(value)
    lock.unlock()
  }

  /// 発火した値を発火順に返します。
  var values: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

/// `videoEnabled` / `audioEnabled` の operation 単位の直列化を検証するユニットテスト
///
/// 同じストリームの有効フラグを `MediaChannel.setVideoSoftMute` / `MediaChannel.setAudioSoftMute` /
/// `MediaChannel.setVideoHardMute` / `MediaStream.videoEnabled` への直接代入から並行に変更しても、
/// 線形順で最後に確定した operation の値が getter と native track の `isEnabled` の両方で最終値に
/// なることを確認します。あわせて、`setVideoHardMute(true)` が失敗して復元する operation の復元が
/// 後続の operation の値を上書きしないことと、handler の発火回数を確認します。
///
/// モックやスタブは使用せず、実 `BasicMediaStream` と実 WebRTC の track、SDK が実際に使う
/// operation の世代 API だけを使います。`MediaChannel` の mute API は接続状態を要求するため、
/// ここでは公開 API が使う入口と確定の手順 (`beginVideoOperation` / `commitVideoEnabled`) を
/// 直接検証します (接続を伴う経路は E2E テストの担当です)。
final class MediaStreamEnabledOperationTests: XCTestCase {
  /// テスト用の sender stream を構築します。
  ///
  /// `videoTrackId` / `audioTrackId` に `nil` を指定した track は作りません。`BasicMediaStream` の
  /// `nativeVideoTrack` / `nativeAudioTrack` が `nil` になり、track を持たない stream の挙動を
  /// 検証できます。
  private func makeSenderStream(
    mediaChannel: MediaChannel,
    videoTrackId: String?,
    audioTrackId: String?
  ) -> BasicMediaStream {
    let nativeFactory = mediaChannel.peerChannel.nativePeerChannelFactory
    let nativeStream = nativeFactory.createNativeSenderStream(
      streamId: "test-stream",
      videoTrackId: videoTrackId,
      audioTrackId: audioTrackId,
      constraints: MediaConstraints())
    return BasicMediaStream(peerChannel: mediaChannel.peerChannel, nativeStream: nativeStream)
  }

  /// 線形順で最後に確定した映像 operation の値が getter と native track の両方で最終値になることを確認する
  ///
  /// operation 1 (false) → operation 2 (true) → operation 1 の遅延した書き込み (false) の順に
  /// 確定を試みます。operation 1 の遅延した書き込みは破棄されるため、getter と native track の
  /// `isEnabled` の両方が operation 2 の true のままであることを検証します。
  func testLastCommittedVideoOperationWinsInGetterAndNativeTrack() throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStream(
      mediaChannel: mediaChannel, videoTrackId: "video", audioTrackId: nil)
    XCTAssertTrue(stream.videoEnabled, "前提: video track は既定で有効であること")
    XCTAssertEqual(
      stream.nativeVideoTrack?.isEnabled, true, "前提: native track の isEnabled が有効であること")

    // operation 1: 黒塗りにする
    let first = stream.beginVideoOperation()
    XCTAssertTrue(
      stream.commitVideoEnabled(false, generation: first), "最新の世代の書き込みが確定すること")
    XCTAssertFalse(stream.videoEnabled, "確定値が false になること")
    XCTAssertEqual(stream.nativeVideoTrack?.isEnabled, false, "native track が false になること")

    // operation 2: 有効に戻す
    let second = stream.beginVideoOperation()
    XCTAssertTrue(
      stream.commitVideoEnabled(true, generation: second), "後続の世代の書き込みが確定すること")
    XCTAssertTrue(stream.videoEnabled, "確定値が true になること")
    XCTAssertEqual(stream.nativeVideoTrack?.isEnabled, true, "native track が true になること")

    // operation 1 が遅延して書き込んでも、後続の operation の値を上書きしない
    XCTAssertFalse(
      stream.commitVideoEnabled(false, generation: first), "古い世代の書き込みが破棄されること")
    XCTAssertTrue(stream.videoEnabled, "getter が後続の operation の値のままであること")
    XCTAssertEqual(
      stream.nativeVideoTrack?.isEnabled, true,
      "native track も後続の operation の値のままであること")
  }

  /// 線形順で最後に確定した音声 operation の値が getter と native track の両方で最終値になることを確認する
  func testLastCommittedAudioOperationWinsInGetterAndNativeTrack() throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStream(
      mediaChannel: mediaChannel, videoTrackId: nil, audioTrackId: "audio")
    XCTAssertTrue(stream.audioEnabled, "前提: audio track は既定で有効であること")

    let first = stream.beginAudioOperation()
    XCTAssertTrue(stream.commitAudioEnabled(false, generation: first))
    XCTAssertFalse(stream.audioEnabled, "確定値が false になること")
    XCTAssertEqual(stream.nativeAudioTrack?.isEnabled, false, "native track が false になること")

    let second = stream.beginAudioOperation()
    XCTAssertTrue(stream.commitAudioEnabled(true, generation: second))
    XCTAssertTrue(stream.audioEnabled, "確定値が true になること")
    XCTAssertEqual(stream.nativeAudioTrack?.isEnabled, true, "native track が true になること")

    XCTAssertFalse(
      stream.commitAudioEnabled(false, generation: first), "古い世代の書き込みが破棄されること")
    XCTAssertTrue(stream.audioEnabled, "getter が後続の operation の値のままであること")
    XCTAssertEqual(
      stream.nativeAudioTrack?.isEnabled, true, "native track も後続の operation の値のままであること")
  }

  /// 後続の operation が開始したが値を確定しなかった場合に、先行 operation の復元が破棄されないことを確認する
  ///
  /// `VideoHardMuteActor` は `operationTracker.begin` の拒否など、開始しても値を確定せずに終わる
  /// operation を持ち得ます。この場合に先行 operation の復元まで破棄すると、「設定後に lease が
  /// 有効なまま失敗した場合は基準値へ復元する」という契約が壊れます。破棄は「後続の operation が
  /// 実際に値を確定した場合」に限ることを検証します。
  func testStartedButNotCommittedLaterOperationDoesNotDiscardRestore() throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStream(
      mediaChannel: mediaChannel, videoTrackId: "video", audioTrackId: nil)

    // ハードミュート有効化: 直列化区間へ入った時点の基準値を読んで false を確定する
    let hardMute = stream.beginVideoOperation()
    let baseline = stream.videoEnabled
    XCTAssertTrue(baseline, "前提: 基準値が有効であること")
    XCTAssertTrue(stream.commitVideoEnabled(false, generation: hardMute))
    XCTAssertFalse(stream.videoEnabled)

    // 後続の operation が開始したが、値を確定しなかった (拒否された setVideoHardMute など)
    _ = stream.beginVideoOperation()

    // 先行 operation の復元は破棄されず、基準値へ戻る
    XCTAssertTrue(
      stream.commitVideoEnabled(baseline, generation: hardMute),
      "値を確定しなかった後続の operation は先行の復元を破棄しないこと")
    XCTAssertTrue(stream.videoEnabled, "基準値へ復元されること")
    XCTAssertEqual(stream.nativeVideoTrack?.isEnabled, true, "native track も基準値へ戻ること")
  }

  /// 後続の operation が値を確定した場合は、先行 operation の復元が破棄されることを確認する
  ///
  /// 基準値が false (黒塗り) の状態でハードミュート有効化を開始し、直接代入が後続の operation と
  /// して true を確定します。先行 operation が基準値 (false) へ復元しようとしても、後続の
  /// operation の値 (true) を上書きしないことを検証します。
  func testDirectAssignmentAfterHardMuteSetDiscardsRestore() throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStream(
      mediaChannel: mediaChannel, videoTrackId: "video", audioTrackId: nil)

    // ハードミュート有効化の基準値を false にする
    stream.videoEnabled = false
    XCTAssertFalse(stream.videoEnabled, "前提: 黒塗りになっていること")
    let recorder = EnabledSwitchRecorder()
    stream.handlers.onSwitchVideo = { recorder.append($0) }

    let hardMute = stream.beginVideoOperation()
    let baseline = stream.videoEnabled
    XCTAssertFalse(baseline, "前提: 基準値が黒塗りであること")
    // 基準値と同じ値の書き込みは確定するが、値も handler も変更しない
    XCTAssertTrue(
      stream.commitVideoEnabled(false, generation: hardMute),
      "値が変化しなくても同じ世代の書き込みが確定すること")
    XCTAssertFalse(stream.videoEnabled, "値が変化しないため確定値が変わらないこと")
    XCTAssertEqual(recorder.values, [], "値が変化しないため handler が呼ばれないこと")

    // 利用者の直接代入が後続の operation として true を確定する
    stream.videoEnabled = true
    XCTAssertTrue(stream.videoEnabled)

    // ハードミュートの復元 (基準値 false) は後続の true を上書きしない
    XCTAssertFalse(
      stream.commitVideoEnabled(baseline, generation: hardMute),
      "後続の operation が確定している場合は復元が破棄されること")
    XCTAssertTrue(stream.videoEnabled, "後続の operation の値が保たれること")
    XCTAssertEqual(stream.nativeVideoTrack?.isEnabled, true, "native track も後続の値のままであること")
    XCTAssertEqual(
      recorder.values, [true],
      "確定した operation の値の変化だけが通知され、破棄された復元では通知されないこと")
  }

  /// 後続の operation が無い場合は、同じ世代の復元が基準値へ書き戻すことを確認する
  ///
  /// 復元の基準値は `setMute` が直列化区間へ入った時点で読んだ値です。
  /// 設定と復元を同じ世代で確定できること、値が false → true と 2 回変化するため handler が
  /// 2 回呼ばれることも検証します。
  func testRestoreUsesBaselineWhenNoLaterOperationCommitted() throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStream(
      mediaChannel: mediaChannel, videoTrackId: "video", audioTrackId: nil)
    let recorder = EnabledSwitchRecorder()
    stream.handlers.onSwitchVideo = { recorder.append($0) }

    let hardMute = stream.beginVideoOperation()
    let baseline = stream.videoEnabled
    XCTAssertTrue(baseline, "前提: 基準値が有効であること")

    // 設定: true -> false (1 回目の発火)
    XCTAssertTrue(stream.commitVideoEnabled(false, generation: hardMute))
    XCTAssertFalse(stream.videoEnabled)

    // 失敗したため復元: false -> true (2 回目の発火)
    XCTAssertTrue(stream.commitVideoEnabled(baseline, generation: hardMute))
    XCTAssertTrue(stream.videoEnabled, "基準値へ復元されること")
    XCTAssertEqual(stream.nativeVideoTrack?.isEnabled, true, "native track も基準値へ戻ること")

    XCTAssertEqual(
      recorder.values, [false, true],
      "復元する operation は false -> true の順に 1 回ずつ handler を呼ぶこと")
  }

  /// handler が値の変化のたびに 1 回だけ呼ばれ、値が変化しない書き込みでは呼ばれないことを確認する
  func testOnSwitchVideoIsCalledOncePerValueChange() throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStream(
      mediaChannel: mediaChannel, videoTrackId: "video", audioTrackId: nil)
    let recorder = EnabledSwitchRecorder()
    stream.handlers.onSwitchVideo = { recorder.append($0) }

    // 有効 -> 黒塗り
    stream.videoEnabled = false
    XCTAssertEqual(recorder.values, [false], "変化したときだけ 1 回呼ばれること")

    // 同じ値の再代入では呼ばれない
    stream.videoEnabled = false
    XCTAssertEqual(recorder.values, [false], "値が変化しない書き込みでは呼ばれないこと")

    // 黒塗り -> 有効
    stream.videoEnabled = true
    XCTAssertEqual(recorder.values, [false, true], "変化のたびに 1 回呼ばれること")

    // 復元する operation は false -> true の 2 回
    let hardMute = stream.beginVideoOperation()
    XCTAssertTrue(stream.commitVideoEnabled(false, generation: hardMute))
    XCTAssertTrue(stream.commitVideoEnabled(true, generation: hardMute))
    XCTAssertEqual(
      recorder.values, [false, true, false, true],
      "復元する operation は false -> true の順に 1 回ずつ呼ばれること")
  }

  /// handler が音声の値の変化のたびに 1 回だけ呼ばれることを確認する
  func testOnSwitchAudioIsCalledOncePerValueChange() throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStream(
      mediaChannel: mediaChannel, videoTrackId: nil, audioTrackId: "audio")
    let recorder = EnabledSwitchRecorder()
    stream.handlers.onSwitchAudio = { recorder.append($0) }

    stream.audioEnabled = false
    stream.audioEnabled = false
    stream.audioEnabled = true
    XCTAssertEqual(recorder.values, [false, true], "変化のたびに 1 回だけ呼ばれること")
  }

  /// native track を持たない stream では直接代入が確定値も handler も変更しないことを確認する
  ///
  /// `setVideoSoftMute` / `setAudioSoftMute` / `setVideoHardMute` は `hasVideoTrack` /
  /// `hasAudioTrack` を要求するため、この扱いが必要になるのは利用者による直接代入だけです。
  func testDirectAssignmentWithoutTracksKeepsDisabledValue() throws {
    let mediaChannel = try makeTestMediaChannel()
    // video track も audio track も作らない
    let stream = makeSenderStream(
      mediaChannel: mediaChannel, videoTrackId: nil, audioTrackId: nil)
    XCTAssertFalse(stream.hasVideoTrack, "前提: video track を持たないこと")
    XCTAssertFalse(stream.hasAudioTrack, "前提: audio track を持たないこと")
    XCTAssertFalse(stream.videoEnabled, "前提: getter が false であること")
    XCTAssertFalse(stream.audioEnabled, "前提: getter が false であること")

    let videoRecorder = EnabledSwitchRecorder()
    let audioRecorder = EnabledSwitchRecorder()
    stream.handlers.onSwitchVideo = { videoRecorder.append($0) }
    stream.handlers.onSwitchAudio = { audioRecorder.append($0) }

    stream.videoEnabled = true
    stream.audioEnabled = true

    XCTAssertFalse(stream.videoEnabled, "直接代入しても getter が false のままであること")
    XCTAssertFalse(stream.audioEnabled, "直接代入しても getter が false のままであること")
    XCTAssertEqual(videoRecorder.values, [], "handler が呼ばれないこと")
    XCTAssertEqual(audioRecorder.values, [], "handler が呼ばれないこと")

    // 世代付きの確定でも値と handler を変更しない
    let videoGeneration = stream.beginVideoOperation()
    let audioGeneration = stream.beginAudioOperation()
    XCTAssertFalse(
      stream.commitVideoEnabled(true, generation: videoGeneration), "値を確定しないこと")
    XCTAssertFalse(
      stream.commitAudioEnabled(true, generation: audioGeneration), "値を確定しないこと")
    XCTAssertFalse(stream.videoEnabled, "確定しないため getter が false のままであること")
    XCTAssertFalse(stream.audioEnabled, "確定しないため getter が false のままであること")
    XCTAssertEqual(videoRecorder.values, [], "handler が呼ばれないこと")
    XCTAssertEqual(audioRecorder.values, [], "handler が呼ばれないこと")
  }

  /// 古い世代の `VideoHardMuteActor.setMute` が後続の operation の値を上書きしないことを確認する
  ///
  /// 実 `VideoHardMuteActor` の `mute = true` 経路は、実カメラが未起動の場合は設定の確定後に冪等
  /// 成功として戻り、実カメラが current の場合は所有権エラーを投げます。ハードミュートの世代を
  /// 取得した後に後続の operation が値を確定した場合、古い世代の設定 (失敗時の復元を含む) が
  /// 破棄され、getter と native track が後続の値のままであることを検証します。
  /// 実カメラが current の場合は actor が所有権エラーを投げるため例外を許容します。実カメラの
  /// 起動・停止を伴う復元経路はこの経路で検証されます。
  func testHardMuteActorDoesNotOverrideLaterOperation() async throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStream(
      mediaChannel: mediaChannel, videoTrackId: "video", audioTrackId: nil)
    let actor = VideoHardMuteActor()
    let lease = VideoHardMuteLease()

    // ハードミュートの operation の世代を取得した後、後続の operation が true を確定する
    let hardMuteGeneration = stream.beginVideoOperation()
    let laterGeneration = stream.beginVideoOperation()
    XCTAssertTrue(
      stream.commitVideoEnabled(true, generation: laterGeneration),
      "後続の operation が値を確定すること")

    // 古い世代のハードミュート有効化は黒塗りを確定しない
    // 実カメラが current の場合は所有権エラーを投げるため、例外の有無は問わない
    try? await actor.setMute(
      mute: true,
      generation: hardMuteGeneration,
      lease: lease,
      senderStream: SenderStreamBox(stream: stream),
      cameraSettings: CameraSettingsSnapshot(mediaChannel.configuration.cameraSettings))

    XCTAssertTrue(stream.videoEnabled, "後続の operation の値が保たれること")
    XCTAssertEqual(stream.nativeVideoTrack?.isEnabled, true, "native track も後続の値のままであること")
  }

  /// 複数スレッドから確定しても、確定値と native track の `isEnabled` が食い違わないことを確認する
  ///
  /// 確定値の更新と native track への反映を同じ lock 区間で行うため、全 operation の完了後に getter が
  /// 返す値と native track の `isEnabled` は一致します。どの operation の値が最終値になるかは実行順に
  /// 依存するため、ここでは一致だけを検証します (値ごとの発火回数は単一スレッドのテストで検証します)。
  /// 世代 CAS による破棄の検証は単一スレッドのテストが担い、このテストは全 operation 完了後の
  /// getter と native track の一致を検証します。併せて、破棄される書き込みが `false` を返すことも
  /// 確定的な 1 手順で確認します。
  /// handler bag の読み書きを並行させると bag 自体の data race になるため、このテストでは handler を
  /// 設定しません。
  func testConcurrentCommitsKeepGetterAndNativeTrackConsistent() throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStream(
      mediaChannel: mediaChannel, videoTrackId: "video", audioTrackId: nil)
    // `MediaStream` は Sendable ではないため、既存の actor 境界用ラッパー経由で @Sendable closure へ渡す
    let streamBox = SenderStreamBox(stream: stream)
    XCTAssertNotNil(streamBox.basicStream, "前提: SDK の sender stream が BasicMediaStream であること")

    // 破棄される書き込みは false を返し、確定値を変えない
    let committedGeneration = stream.beginVideoOperation()
    XCTAssertTrue(
      stream.commitVideoEnabled(true, generation: committedGeneration),
      "最新の世代の書き込みが確定すること")
    XCTAssertFalse(
      stream.commitVideoEnabled(false, generation: committedGeneration - 1),
      "確定済みの世代より古い書き込みが破棄されること")
    XCTAssertTrue(stream.videoEnabled, "破棄された書き込みが確定値を変えないこと")

    for _ in 0..<8 {
      DispatchQueue.concurrentPerform(iterations: 64) { index in
        guard let basicStream = streamBox.basicStream else {
          return
        }
        let generation = basicStream.beginVideoOperation()
        basicStream.commitVideoEnabled(index.isMultiple(of: 2), generation: generation)
      }
      XCTAssertEqual(
        stream.videoEnabled, stream.nativeVideoTrack?.isEnabled ?? false,
        "全 operation の完了後に確定値と native track が一致すること")
    }

    // 完了後に新しい operation を確定すると、getter と native track がその値になる
    let finalGeneration = stream.beginVideoOperation()
    XCTAssertTrue(stream.commitVideoEnabled(false, generation: finalGeneration))
    XCTAssertFalse(stream.videoEnabled, "新しい operation の値が最終値になること")
    XCTAssertEqual(
      stream.nativeVideoTrack?.isEnabled, false, "native track も新しい operation の値になること")
  }
}
