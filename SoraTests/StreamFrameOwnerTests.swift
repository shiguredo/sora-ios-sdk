import CoreGraphics
import WebRTC
import XCTest

@testable import Sora

/// `StreamFrameOwner` の frame ingress と renderer 配送の契約を検証するユニットテスト
///
/// frame の受理順 (`sequence`) と `VideoFilter` の実行順、上限超過の破棄、`terminate()` の
/// 冪等性、renderer callback の順序と世代判定を確認します。モックやスタブは使用せず、
/// 実 `VideoFilter` / 実 `VideoRenderer` と実 WebRTC の frame だけを使います。
final class StreamFrameOwnerTests: XCTestCase {
  /// 複数スレッドから並行に送信しても、 filter が直列に呼ばれ、採番順に実行されることを確認する
  ///
  /// `maxPendingFrameCount` と同数の frame を並行実行を試みて投入し、 filter の同時実行が 0 で
  /// あること、 `sequence` が昇順で処理されること、 frame の欠落も重複も無いことを検査します。
  func testVideoFilterIsCalledSeriallyInSequenceOrder() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = RecordingVideoFilter()
    // 直列化が壊れている場合に同時実行を観測できるよう、 filter の実行時間を延ばす
    filter.executionInterval = 0.002
    senderStream.videoFilter = filter

    // 上限 (`maxPendingFrameCount`) と同数の frame を投入する。同時に投入された frame が
    // すべて受理される最大数であり、これを超えると ingress で破棄される。
    let frameCount = StreamFrameOwner.maxPendingFrameCount
    // `MediaStream` は Sendable ではないため、既存の actor 境界用ラッパー経由で
    // @Sendable closure へ渡す。frame は closure の中で生成する。
    let streamBox = SenderStreamBox(stream: senderStream)
    DispatchQueue.concurrentPerform(iterations: frameCount) { index in
      guard let frame = makeVideoFrameForTesting(timeStampNs: Int64(index)) else {
        XCTFail("テスト用の VideoFrame を生成できること")
        return
      }
      streamBox.stream.send(videoFrame: frame)
    }
    drainOwnerAndMainQueue(senderStream)

    let owner = ownerForTesting(senderStream)
    XCTAssertEqual(filter.count, frameCount, "すべての frame が filter へ到達すること")
    XCTAssertEqual(
      filter.timestamps.sorted(), Array(0..<Int64(frameCount)),
      "frame の欠落も重複も無いこと")
    XCTAssertEqual(filter.concurrentCount, 0, "filter が同時に 2 つの frame で実行されないこと")
    XCTAssertEqual(
      owner.lastAcceptedSequenceForTesting, UInt64(frameCount),
      "受理した frame の最後の sequence が frame 数と一致すること")
    XCTAssertEqual(
      owner.processedSequencesForTesting, Array(1...UInt64(frameCount)),
      "sequence が昇順で処理されること")
    XCTAssertEqual(owner.discardedFrameCountForTesting, 0, "上限を超えないため破棄されないこと")
  }

  /// 条件 1 と条件 2 の破棄では sequence を消費せず、破棄数にも加算しないことを確認する
  ///
  /// `nil` の frame と、 video track を持たない (video source が `nil` の) stream への frame は
  /// どちらも `VideoFilter` へ到達しません。
  func testIngressDropsNilFrameAndFrameWithoutVideoSource() throws {
    let mediaChannel = try makeTestMediaChannel()
    // createNativeStream は video track を作らないため video source が nil になる
    let nativeStream = mediaChannel.peerChannel.nativePeerChannelFactory.createNativeStream(
      streamId: "test-stream")
    let senderStream = BasicMediaStream(
      peerChannel: mediaChannel.peerChannel, nativeStream: nativeStream)
    let filter = RecordingVideoFilter()
    senderStream.videoFilter = filter

    senderStream.send(videoFrame: nil)
    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 1))
    drainOwnerAndMainQueue(senderStream)

    let owner = ownerForTesting(senderStream)
    XCTAssertEqual(filter.count, 0, "filter が呼ばれないこと")
    XCTAssertEqual(owner.lastAcceptedSequenceForTesting, 0, "sequence を消費しないこと")
    XCTAssertEqual(owner.discardedFrameCountForTesting, 0, "破棄数に加算しないこと")
    XCTAssertEqual(owner.processedSequencesForTesting, [], "処理済みに含まれないこと")
  }

  /// 未処理数が上限に達したら新しい frame を破棄し、破棄数に加算することを確認する
  ///
  /// 処理中の 1 件も未処理数に含めるため、 filter を停止した状態では `maxPendingFrameCount`
  /// (4) 件まで受理し、それを超える frame は ingress で破棄されます。
  func testIngressDropsFrameOverPendingLimit() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let gate = SynchronousFilterGate()
    let filter = RecordingVideoFilter()
    filter.gate = gate
    senderStream.videoFilter = filter

    // 1 つ目の frame を filter の中で停止させる (処理中 1 件)
    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 1))
    XCTAssertTrue(gate.waitUntilFilterIsBlocked(), "1 つ目の frame が filter で停止すること")

    // 待ちを 3 件積んで上限 (4 件) に到達させる
    for index in 2...4 {
      senderStream.send(videoFrame: requireVideoFrame(timeStampNs: Int64(index)))
    }
    // 上限を超える 5 つ目と 6 つ目は ingress で破棄される
    for index in 5...6 {
      senderStream.send(videoFrame: requireVideoFrame(timeStampNs: Int64(index)))
    }

    let owner = ownerForTesting(senderStream)
    XCTAssertEqual(
      owner.lastAcceptedSequenceForTesting, UInt64(StreamFrameOwner.maxPendingFrameCount),
      "上限までの frame だけを受理すること")
    XCTAssertEqual(owner.discardedFrameCountForTesting, 2, "上限を超えた frame を破棄数に加算すること")

    gate.resumeFilter()
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(
      owner.processedSequencesForTesting, Array(1...UInt64(StreamFrameOwner.maxPendingFrameCount)),
      "上限までの frame だけが処理されること")
    XCTAssertEqual(
      filter.count, StreamFrameOwner.maxPendingFrameCount, "上限を超えた frame は filter へ到達しないこと")
    XCTAssertEqual(owner.discardedFrameCountForTesting, 2, "処理後も破棄数が変わらないこと")
  }

  /// terminate() が受理済みの frame を破棄し、冪等で、 onDisconnect を 1 回だけ配送することを確認する
  ///
  /// filter の実行中に terminate() を呼び、処理中の frame はそのまま完了し、 owner queue で
  /// 待っている受理済みの frame は配送されないことを確認します。
  func testTerminateDropsAcceptedFrameAndDeliversDisconnectOnce() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let gate = SynchronousFilterGate()
    let filter = RecordingVideoFilter()
    filter.gate = gate
    senderStream.videoFilter = filter
    let renderer = RecordingVideoRenderer()
    senderStream.videoRenderer = renderer

    // 1 つ目の frame を filter の中で停止させ、 2 つ目の frame を owner queue で待たせる
    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 1))
    XCTAssertTrue(gate.waitUntilFilterIsBlocked(), "1 つ目の frame が filter で停止すること")
    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 2))

    // 停止中に terminate() を 2 回呼ぶ
    senderStream.terminate()
    senderStream.terminate()

    gate.resumeFilter()
    drainOwnerAndMainQueue(senderStream)

    let owner = ownerForTesting(senderStream)
    XCTAssertEqual(owner.lastAcceptedSequenceForTesting, 2, "受理した frame は 2 件であること")
    XCTAssertEqual(
      owner.processedSequencesForTesting, [1],
      "無効化の後に処理された frame は処理済みに含まれないこと")
    XCTAssertEqual(owner.discardedFrameCountForTesting, 0, "無効化による破棄は破棄数に加算しないこと")
    XCTAssertEqual(filter.count, 1, "無効化の後に処理された frame は filter を通らないこと")
    // frame は実 `RTCVideoSource` へ配送されるため、 libwebrtc が登録済みの adapter へ
    // frame / size を配送することがある。ここでは無効化の配送だけを数える。
    XCTAssertEqual(
      renderer.callbacks.filter { $0 == .disconnect }.count, 1,
      "onDisconnect が 1 回だけ配送されること")
    XCTAssertFalse(renderer.callbacks.contains(.removed), "onRemoved を配送しないこと")
    XCTAssertFalse(renderer.onMainThread.contains(false), "すべての callback が main queue で呼ばれること")
  }

  /// terminate() の後に投入した frame が配送されないことを確認する
  func testTerminateDropsFrameSentAfterTerminate() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let filter = RecordingVideoFilter()
    senderStream.videoFilter = filter

    senderStream.terminate()
    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 1))
    drainOwnerAndMainQueue(senderStream)

    let owner = ownerForTesting(senderStream)
    XCTAssertEqual(filter.count, 0, "filter が呼ばれないこと")
    XCTAssertEqual(owner.lastAcceptedSequenceForTesting, 0, "sequence を消費しないこと")
    XCTAssertEqual(owner.discardedFrameCountForTesting, 0, "破棄数に加算しないこと")
  }

  /// filter を交換しても、各 frame が使う filter が一意に決まることを確認する
  ///
  /// 「停止 → 投入 → 交換 → 再開」の順で実行し、投入済みの frame が交換前の filter を、
  /// 交換後の frame が新しい filter を使うことを決定的に確認します。
  func testVideoFilterExchangeKeepsEachFrameOnASingleFilter() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let gate = SynchronousFilterGate()
    let firstFilter = RecordingVideoFilter()
    let secondFilter = RecordingVideoFilter()
    firstFilter.gate = gate
    senderStream.videoFilter = firstFilter

    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 1))
    XCTAssertTrue(gate.waitUntilFilterIsBlocked(), "1 つ目の frame が filter で停止すること")

    // 停止中に filter を交換し、 2 つ目の frame を投入する
    senderStream.videoFilter = secondFilter
    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 2))

    gate.resumeFilter()
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(firstFilter.timestamps, [1], "交換前の frame は交換前の filter だけを通ること")
    XCTAssertEqual(secondFilter.timestamps, [2], "交換後の frame は新しい filter だけを通ること")
    XCTAssertEqual(
      ownerForTesting(senderStream).processedSequencesForTesting, [1, 2],
      "sequence の順に処理されること")
  }

  /// renderer callback が main queue 上で投入順に配送されることを確認する
  ///
  /// `onAdded` / `onChange(size:)` / `render` / `onSwitch(video:)` / `onDisconnect` / `onRemoved`
  /// の 6 種類を同じ stream で発生させ、配送順と実行 executor を検査します。
  /// `frame` / `size` / `switch` は main queue 上で現在の世代と比較されるため、 1 段ずつ配送を
  /// 待ってから次の event を発生させます。
  func testRendererCallbacksAreDeliveredOnMainQueueInOrder() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let renderer = RecordingVideoRenderer()
    senderStream.videoRenderer = renderer

    guard
      let adapter = (senderStream as? BasicMediaStream)?.videoRendererAdapterForTesting
    else {
      XCTFail("renderer を設定すると adapter が生成されること")
      return
    }

    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(renderer.callbacks, [.added], "onAdded が配送されること")

    // libwebrtc から frame と size が届いた状態を再現する
    adapter.setSize(CGSize(width: 64, height: 48))
    adapter.renderFrame(requireNativeVideoFrame(timeStampNs: 1))
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      renderer.callbacks,
      [.added, .size(CGSize(width: 64, height: 48)), .render(frameWidth: 64)],
      "size と frame が投入順に配送されること")

    // 映像の有効 / 無効の変更
    senderStream.videoEnabled = false
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      renderer.callbacks,
      [.added, .size(CGSize(width: 64, height: 48)), .render(frameWidth: 64), .switchVideo(false)],
      "switch が配送されること")

    // terminate による onDisconnect (renderer が設置されている間だけ配送される)
    senderStream.terminate()
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      renderer.callbacks,
      [
        .added, .size(CGSize(width: 64, height: 48)), .render(frameWidth: 64),
        .switchVideo(false), .disconnect,
      ],
      "onDisconnect が配送されること")

    // renderer の取り外しによる onRemoved
    senderStream.videoRenderer = nil
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      renderer.callbacks,
      [
        .added, .size(CGSize(width: 64, height: 48)), .render(frameWidth: 64),
        .switchVideo(false), .disconnect, .removed,
      ],
      "callback が投入順に配送されること")
    XCTAssertEqual(
      renderer.onMainThread, Array(repeating: true, count: renderer.callbacks.count),
      "すべての callback が main queue で呼ばれること")
  }

  /// terminate() の後に届いた renderer の frame / size / switch を配送しないことを確認する
  ///
  /// 無効化は配送中の処理と同期しないため、受理済みの frame は完了し得ますが、無効化の後に
  /// owner へ届いた renderer の frame / size / switch は配送されません。
  func testTerminateDropsRendererEventsAfterTerminate() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let renderer = RecordingVideoRenderer()
    senderStream.videoRenderer = renderer
    guard
      let adapter = (senderStream as? BasicMediaStream)?.videoRendererAdapterForTesting
    else {
      XCTFail("renderer を設定すると adapter が生成されること")
      return
    }

    drainOwnerAndMainQueue(senderStream)
    senderStream.terminate()
    drainOwnerAndMainQueue(senderStream)
    let callbackCountAfterTerminate = renderer.callbacks.count
    XCTAssertEqual(
      renderer.callbacks.filter { $0 == .disconnect }.count, 1,
      "onDisconnect が 1 回配送されること")

    // 無効化の後に renderer の event を発生させる
    adapter.setSize(CGSize(width: 32, height: 24))
    adapter.renderFrame(requireNativeVideoFrame(timeStampNs: 1, width: 32))
    senderStream.videoEnabled = false
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(
      renderer.callbacks.count, callbackCountAfterTerminate,
      "無効化の後に届いた renderer の frame / size / switch を配送しないこと")
  }

  /// terminate() の直後に renderer を取り外しても、 onDisconnect が無効化時の renderer へ届くことを確認する
  ///
  /// 配送先を配送時点で解決すると、`terminate()` の後に `videoRenderer = nil` した場合は
  /// `onDisconnect` が誰にも届きません (main queue の配送前に取り外されるため)。
  func testTerminateFixesDisconnectTargetWhenRendererIsRemoved() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let renderer = RecordingVideoRenderer()
    senderStream.videoRenderer = renderer

    // main queue を drain せずに terminate と取り外しを続けて行う
    senderStream.terminate()
    senderStream.videoRenderer = nil
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(
      renderer.callbacks, [.added, .disconnect, .removed],
      "無効化時の renderer へ onDisconnect が届き、その後 onRemoved が届くこと")
  }

  /// terminate() の後に別の renderer を設定しても何も配送されないことを確認する
  ///
  /// 無効化の後に設置を受け付けると、`onAdded` だけを受け取って `onDisconnect` が届かない
  /// renderer が生まれます。getter は無効化時の renderer を返し続けます。
  func testTerminateIgnoresRendererSetAfterTerminate() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let firstRenderer = RecordingVideoRenderer()
    senderStream.videoRenderer = firstRenderer

    senderStream.terminate()
    let secondRenderer = RecordingVideoRenderer()
    senderStream.videoRenderer = secondRenderer
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(
      firstRenderer.callbacks, [.added, .disconnect],
      "無効化時の renderer へ onAdded と onDisconnect が届くこと")
    XCTAssertEqual(
      secondRenderer.callbacks, [], "無効化の後に設定した renderer へは何も配送されないこと")
    XCTAssertTrue(
      senderStream.videoRenderer === firstRenderer,
      "無効化の後に設定した renderer は設置されないこと")
  }

  /// renderer 経由の frame の配送待ち件数が上限で制限されることを確認する
  ///
  /// main queue が止まっている間に届いた frame は `maxPendingRendererFrameCount` まで積み、
  /// 超過分は破棄します。配送で減算されるため、次の frame は再び受理されます。
  func testRendererFrameDeliveryBacklogIsBounded() throws {
    // 上限は main queue が配送を進めない間に効くため、main thread で実行することが前提です。
    XCTAssertTrue(Thread.isMainThread, "main queue を回さない前提で検査すること")
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let renderer = RecordingVideoRenderer()
    senderStream.videoRenderer = renderer
    guard
      let adapter = (senderStream as? BasicMediaStream)?.videoRendererAdapterForTesting
    else {
      XCTFail("renderer を設定すると adapter が生成されること")
      return
    }
    drainOwnerAndMainQueue(senderStream)

    // main queue を drain しないため、上限まで積んだ後の frame は破棄される
    for index in 0..<(StreamFrameOwner.maxPendingRendererFrameCount * 3) {
      adapter.renderFrame(requireNativeVideoFrame(timeStampNs: Int64(index), width: 32))
    }
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      renderer.renderCount, StreamFrameOwner.maxPendingRendererFrameCount,
      "上限までの frame だけが配送されること")

    // 配送で減算されるため、次の frame も同じ上限まで受理される
    for index in 0..<(StreamFrameOwner.maxPendingRendererFrameCount * 3) {
      adapter.renderFrame(requireNativeVideoFrame(timeStampNs: Int64(index), width: 32))
    }
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      renderer.renderCount, StreamFrameOwner.maxPendingRendererFrameCount * 2,
      "配送後に減算され、次の frame も上限まで配送されること")
    XCTAssertEqual(
      ownerForTesting(senderStream).lastAcceptedSequenceForTesting, 0,
      "renderer 経由の frame は ingress の sequence を消費しないこと")
    XCTAssertEqual(
      ownerForTesting(senderStream).discardedFrameCountForTesting, 0,
      "renderer 経由の破棄は ingress の破棄数に加算しないこと")
  }

  /// 現在の世代で `nil` の frame が配送されることを確認する
  ///
  /// libwebrtc は描画のクリアに `renderFrame(nil)` を使い得るため、`nil` も配送対象です。
  func testRendererNilFrameIsDeliveredOnCurrentGeneration() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let renderer = RecordingVideoRenderer()
    senderStream.videoRenderer = renderer
    guard
      let adapter = (senderStream as? BasicMediaStream)?.videoRendererAdapterForTesting
    else {
      XCTFail("renderer を設定すると adapter が生成されること")
      return
    }

    adapter.renderFrame(nil)
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      renderer.callbacks, [.added, .render(frameWidth: nil)],
      "現在の世代では nil の frame も配送されること")
  }

  /// switch が世代不一致のときに配送されないことを確認する
  ///
  /// switch は投入時に採番されるため、投入後に renderer を交換すると世代が進み、配送されません。
  func testSwitchWithStaleGenerationIsNotDelivered() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let renderer = RecordingVideoRenderer()
    senderStream.videoRenderer = renderer
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(renderer.callbacks, [.added], "onAdded が配送されること")

    // switch を投入した直後に renderer を取り外し、世代を進める
    senderStream.videoEnabled = false
    senderStream.videoRenderer = nil
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(
      renderer.callbacks, [.added, .removed],
      "世代が進んだ switch は配送されないこと")
  }

  /// 音声の有効 / 無効の変更が main queue で renderer へ配送されることを確認する
  ///
  /// `audioEnabled` の setter は音声トラックを持つ stream でだけ renderer へ通知します。
  func testAudioSwitchIsDeliveredToRenderer() throws {
    let mediaChannel = try makeTestMediaChannel()
    let nativeFactory = mediaChannel.peerChannel.nativePeerChannelFactory
    let nativeStream = nativeFactory.createNativeSenderStream(
      streamId: "test-stream",
      videoTrackId: "test-video-track",
      audioTrackId: "test-audio-track",
      constraints: MediaConstraints())
    let senderStream = BasicMediaStream(
      peerChannel: mediaChannel.peerChannel, nativeStream: nativeStream)
    let renderer = RecordingVideoRenderer()
    senderStream.videoRenderer = renderer

    senderStream.audioEnabled = false
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(
      renderer.callbacks, [.added, .switchAudio(false)],
      "音声の切り替えが main queue で配送されること")
    XCTAssertEqual(renderer.onMainThread, [true, true], "callback が main queue で呼ばれること")
  }

  /// renderer を交換すると、交換前の adapter の frame / size が配送されないことを確認する
  ///
  /// 世代は `setRenderer` だけが採番し、 adapter は自分の世代を持つ frame / size を owner へ
  /// 渡します。交換前の adapter から届いた frame / size は世代が一致しないため破棄されます。
  func testRendererExchangeDropsFramesFromPreviousAdapter() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let firstRenderer = RecordingVideoRenderer()
    senderStream.videoRenderer = firstRenderer
    guard
      let firstAdapter = (senderStream as? BasicMediaStream)?.videoRendererAdapterForTesting
    else {
      XCTFail("renderer を設定すると adapter が生成されること")
      return
    }

    // 交換前は frame と size が配送される
    firstAdapter.renderFrame(requireNativeVideoFrame(timeStampNs: 1, width: 64))
    firstAdapter.setSize(CGSize(width: 32, height: 24))
    drainOwnerAndMainQueue(senderStream)

    // renderer を交換する
    let secondRenderer = RecordingVideoRenderer()
    senderStream.videoRenderer = secondRenderer
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      firstRenderer.callbacks,
      [.added, .render(frameWidth: 64), .size(CGSize(width: 32, height: 24)), .removed],
      "交換で以前の renderer へ onRemoved が 1 回配送されること")
    XCTAssertEqual(secondRenderer.callbacks, [.added], "新しい renderer へ onAdded が配送されること")
    guard
      let secondAdapter = (senderStream as? BasicMediaStream)?.videoRendererAdapterForTesting
    else {
      XCTFail("交換後も adapter が存在すること")
      return
    }

    // 交換前の adapter の frame / size は破棄され、交換後の adapter の frame / size だけが配送される
    firstAdapter.renderFrame(requireNativeVideoFrame(timeStampNs: 2, width: 16))
    firstAdapter.setSize(CGSize(width: 8, height: 8))
    secondAdapter.renderFrame(requireNativeVideoFrame(timeStampNs: 3, width: 32))
    secondAdapter.setSize(CGSize(width: 48, height: 32))
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(
      secondRenderer.callbacks,
      [.added, .render(frameWidth: 32), .size(CGSize(width: 48, height: 32))],
      "交換前の adapter の frame / size が配送されないこと")
    XCTAssertEqual(
      firstRenderer.callbacks,
      [.added, .render(frameWidth: 64), .size(CGSize(width: 32, height: 24)), .removed],
      "交換後の配送が以前の renderer へ届かないこと")
  }

  /// 同じ renderer の再設定と nil から nil への代入では何も配送されないことを確認する
  ///
  /// 同一 instance へ `onRemoved` を配送すると、 `VideoView` の描画が停止したままになります。
  /// 世代も進めないため、 frame は引き続き同じ renderer へ配送されます。
  func testSettingSameRendererDeliversNothing() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let renderer = RecordingVideoRenderer()
    senderStream.videoRenderer = renderer
    guard
      let adapter = (senderStream as? BasicMediaStream)?.videoRendererAdapterForTesting
    else {
      XCTFail("renderer を設定すると adapter が生成されること")
      return
    }
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(renderer.callbacks, [.added], "最初の設定で onAdded が配送されること")

    // 同じ instance を再設定しても何も配送されない
    senderStream.videoRenderer = renderer
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(renderer.callbacks, [.added], "同一 instance の再設定では何も配送されないこと")

    // 世代が進んでいないため frame は引き続き配送される
    adapter.renderFrame(requireNativeVideoFrame(timeStampNs: 1, width: 32))
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      renderer.callbacks, [.added, .render(frameWidth: 32)],
      "同一 instance の再設定では世代が進まず frame が配送されること")

    // nil を nil へ代入しても何も配送されない
    senderStream.videoRenderer = nil
    senderStream.videoRenderer = nil
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      renderer.callbacks, [.added, .render(frameWidth: 32), .removed],
      "nil の代入で onRemoved が 1 回だけ配送されること")
  }

  /// 解放された renderer を交換すると、 onRemoved を配送せず新しい renderer へ onAdded を配送することを確認する
  ///
  /// owner と adapter は renderer を弱参照するため、利用者が参照を手放した renderer には
  /// callback を配送できません。この場合でも新しい renderer の世代は進みます。
  func testSettingRendererAfterPreviousRendererIsReleased() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    var firstRenderer: RecordingVideoRenderer? = RecordingVideoRenderer()
    weak var weakFirstRenderer = firstRenderer
    senderStream.videoRenderer = firstRenderer
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(firstRenderer?.callbacks, [.added], "最初の設定で onAdded が配送されること")

    // 配送完了後は owner も adapter も renderer を強参照しないため、参照を手放すと解放される
    firstRenderer = nil
    XCTAssertNil(
      weakFirstRenderer, "配送完了後は owner も adapter も renderer を強参照しないこと")

    let secondRenderer = RecordingVideoRenderer()
    senderStream.videoRenderer = secondRenderer
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(secondRenderer.callbacks, [.added], "新しい renderer へ onAdded が配送されること")
    XCTAssertEqual(
      secondRenderer.onMainThread, [true], "callback が main queue で呼ばれること")
  }

  /// videoRenderer の get / set を並行実行しても、選択されている renderer が一意に定まることを確認する
  ///
  /// setter は内部の lock で直列化されるため、adapter が指す renderer と owner が世代を照合する
  /// renderer が食い違いません。食い違うと、選ばれている renderer に frame が 1 枚も届かなく
  /// なります (無音の破損)。並行実行の窓は狭いため 1 ラウンドでは滅多に踏まないので、ラウンドを
  /// 重ねて検出力を上げます。data race そのものの検出は Thread Sanitizer を有効にした実行の
  /// 担当で、このテストは論理的な一意性を検査します。
  func testConcurrentVideoRendererSetKeepsStateConsistent() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    // `MediaStream` は Sendable ではないため、既存の actor 境界用ラッパー経由で @Sendable
    // closure へ渡す。renderer は closure の中で生成し、並行実行の直後に getter から取り出す。
    let streamBox = SenderStreamBox(stream: senderStream)
    let frameWidth = 32
    var inconsistentRounds = 0

    for _ in 0..<20 {
      DispatchQueue.concurrentPerform(iterations: 64) { index in
        if index % 4 == 0 {
          // 並行 get
          _ = streamBox.stream.videoRenderer
        } else {
          streamBox.stream.videoRenderer = RecordingVideoRenderer()
        }
      }

      // main queue を drain する前に adapter が指す renderer を取り出す。所有権は未配送の
      // 配送要素が保っているため、この時点でも生存している。
      guard let renderer = senderStream.videoRenderer as? RecordingVideoRenderer else {
        XCTFail("並行実行の直後でも renderer が設定されていること")
        return
      }
      // 同一 instance の再設定は no-op のため、この時点の adapter と世代がそのまま使われる。
      // setter が非原子的だと adapter と owner の世代が食い違い、frame が配送されない。
      senderStream.videoRenderer = renderer

      guard
        let adapter = (senderStream as? BasicMediaStream)?.videoRendererAdapterForTesting
      else {
        XCTFail("renderer を設定すると adapter が生成されること")
        return
      }
      adapter.renderFrame(requireNativeVideoFrame(timeStampNs: 1, width: frameWidth))
      drainOwnerAndMainQueue(senderStream)
      if !renderer.callbacks.contains(.render(frameWidth: frameWidth)) {
        inconsistentRounds += 1
      }
    }

    XCTAssertEqual(
      inconsistentRounds, 0,
      "並行 set / get の後でも、選択されている renderer に frame が配送されること")
  }

  /// videoFilter の get / set を並行実行しても、確定した filter が frame の加工に使われることを確認する
  ///
  /// filter は owner の lock 付き storage が保持するため、getter で取り出した instance が
  /// そのまま frame の加工に使われます。このテストが保証するのは storage への配線であり、
  /// data race そのものの検出は Thread Sanitizer を有効にした実行の担当です。
  func testConcurrentVideoFilterSetKeepsStateConsistent() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let streamBox = SenderStreamBox(stream: senderStream)

    DispatchQueue.concurrentPerform(iterations: 64) { index in
      if index % 4 == 0 {
        // 並行 get
        _ = streamBox.stream.videoFilter
      } else {
        streamBox.stream.videoFilter = RecordingVideoFilter()
      }
    }

    guard let filter = senderStream.videoFilter as? RecordingVideoFilter else {
      XCTFail("並行実行の直後でも filter が設定されていること")
      return
    }
    XCTAssertEqual(filter.count, 0, "まだ frame は処理されていないこと")

    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 1))
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(filter.count, 1, "確定した filter が frame の加工に使われること")
  }
  /// VideoFilter が未設定でも owner queue で処理まで進んだ frame が記録されることを確認する
  ///
  /// 記録は filter の有無に関係なく行います (filter が無い stream でも上限と破棄の会計が
  /// 観測できるようにするため)。
  func testProcessedSequencesAreRecordedWithoutVideoFilter() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)

    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 1))
    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 2))
    drainOwnerAndMainQueue(senderStream)

    let owner = ownerForTesting(senderStream)
    XCTAssertEqual(owner.lastAcceptedSequenceForTesting, 2, "2 件受理されること")
    XCTAssertEqual(owner.processedSequencesForTesting, [1, 2], "filter 未設定でも記録されること")
    XCTAssertEqual(owner.discardedFrameCountForTesting, 0, "破棄されないこと")
  }

  /// filter を停止させたまま send が戻ることを、別スレッドの送信と期限付きの待ち合わせで検査する
  ///
  /// filter を呼び出し元の executor で実行する (または配送完了を待つ) 実装に戻すと、この send は
  /// 戻らないため、期限付きの待ち合わせで失敗として検出します。`defer` で必ず filter を再開する
  /// ため、回帰時もハングしません。
  func testSendReturnsBeforeVideoFilterCompletes() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let gate = SynchronousFilterGate()
    let filter = RecordingVideoFilter()
    filter.gate = gate
    senderStream.videoFilter = filter

    // `MediaStream` は Sendable ではないため、既存の actor 境界用ラッパー経由で @Sendable
    // closure へ渡す。frame は closure の中で生成する。
    let streamBox = SenderStreamBox(stream: senderStream)
    defer { gate.resumeFilter() }

    let firstReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      if let frame = makeVideoFrameForTesting(timeStampNs: 1) {
        streamBox.stream.send(videoFrame: frame)
      }
      firstReturned.signal()
    }
    XCTAssertEqual(
      firstReturned.wait(timeout: .now() + 5), .success,
      "filter の実行を待たずに send が戻ること")
    XCTAssertTrue(gate.waitUntilFilterIsBlocked(), "1 件目が filter で停止すること")

    let secondReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      if let frame = makeVideoFrameForTesting(timeStampNs: 2) {
        streamBox.stream.send(videoFrame: frame)
      }
      secondReturned.signal()
    }
    XCTAssertEqual(
      secondReturned.wait(timeout: .now() + 5), .success,
      "filter が停止していても 2 件目の send が戻ること")

    gate.resumeFilter()
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(filter.count, 2, "停止を解除すると 2 件とも処理されること")
  }

  /// 交換後に投入した frame が新しい filter を使うことを確認する
  func testVideoFilterExchangeBeforeSubmitUsesNewFilter() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let gate = SynchronousFilterGate()
    let firstFilter = RecordingVideoFilter()
    let secondFilter = RecordingVideoFilter()
    secondFilter.gate = gate

    senderStream.videoFilter = firstFilter
    senderStream.videoFilter = secondFilter
    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 1))
    XCTAssertTrue(gate.waitUntilFilterIsBlocked(), "新しい filter が frame で停止すること")

    gate.resumeFilter()
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(firstFilter.timestamps, [], "交換前の filter は使われないこと")
    XCTAssertEqual(secondFilter.timestamps, [1], "交換後の filter が使われること")
  }

  /// 投入済みで owner queue に待っている frame が、実行直前に読んだ filter を使うことを確認する
  ///
  /// filter を submit 時に payload へ固定する実装では 2 件目が交換前の filter を通るため、
  /// このテストで検出できます。
  func testVideoFilterExchangeAfterSubmitUsesFilterAtProcessTime() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let gate = SynchronousFilterGate()
    let firstFilter = RecordingVideoFilter()
    let secondFilter = RecordingVideoFilter()
    firstFilter.gate = gate
    senderStream.videoFilter = firstFilter

    // 1 件目を filter で停止させ、2 件目を owner queue で待たせる
    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 1))
    XCTAssertTrue(gate.waitUntilFilterIsBlocked(), "1 件目が filter で停止すること")
    senderStream.send(videoFrame: requireVideoFrame(timeStampNs: 2))

    // 2 件目が実行される前に filter を交換する
    senderStream.videoFilter = secondFilter
    gate.resumeFilter()
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(firstFilter.timestamps, [1], "実行中の frame は交換前の filter を使うこと")
    XCTAssertEqual(secondFilter.timestamps, [2], "待っている frame は交換後の filter を使うこと")
    XCTAssertEqual(
      ownerForTesting(senderStream).processedSequencesForTesting, [1, 2],
      "受理順に処理されること")
  }

  /// BasicMediaStream ごとに別の owner を持つことを確認する
  func testEachMediaStreamHasItsOwnOwner() throws {
    let mediaChannel = try makeTestMediaChannel()
    let firstStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let secondStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    XCTAssertFalse(
      ownerForTesting(firstStream) === ownerForTesting(secondStream),
      "stream ごとに owner が分かれること")

    let filter = RecordingVideoFilter()
    firstStream.videoFilter = filter
    firstStream.send(videoFrame: requireVideoFrame(timeStampNs: 1))
    drainOwnerAndMainQueue(firstStream)

    XCTAssertEqual(
      ownerForTesting(firstStream).lastAcceptedSequenceForTesting, 1,
      "送信した stream の sequence が進むこと")
    XCTAssertEqual(
      ownerForTesting(secondStream).lastAcceptedSequenceForTesting, 0,
      "別の stream の sequence は進まないこと")
    XCTAssertEqual(
      ownerForTesting(secondStream).processedSequencesForTesting, [],
      "別の stream の処理に漏れないこと")
  }

  /// generation 0 の frame / size が配送されないことを確認する
  ///
  /// adapter は `setRenderer` が採番した世代 (1 以上) しか持たないため、generation 0 は
  /// owner へ直接投入して検査します。
  func testRendererEventsWithGenerationZeroAreNotDelivered() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let renderer = RecordingVideoRenderer()
    senderStream.videoRenderer = renderer
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(renderer.callbacks, [.added], "onAdded が配送されること")

    guard
      let adapter = (senderStream as? BasicMediaStream)?.videoRendererAdapterForTesting
    else {
      XCTFail("renderer を設定すると adapter が生成されること")
      return
    }

    // generation 0 の event は配送されない
    let owner = ownerForTesting(senderStream)
    owner.submitRendererSize(CGSize(width: 32, height: 24), generation: 0)
    owner.submitRendererFrame(
      requireNativeVideoFrame(timeStampNs: 1, width: 32), generation: 0)
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      renderer.callbacks, [.added], "generation 0 の frame / size は配送されないこと")

    // adapter が持つ現在の世代の event は配送される (破棄理由が世代不一致だけであること)
    adapter.setSize(CGSize(width: 32, height: 24))
    adapter.renderFrame(requireNativeVideoFrame(timeStampNs: 2, width: 32))
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      renderer.callbacks,
      [.added, .size(CGSize(width: 32, height: 24)), .render(frameWidth: 32)],
      "現在の世代の frame / size は配送されること")
  }

  /// 解放された renderer を交換した後も、旧 adapter の frame / size が配送されないことを確認する
  func testRendererExchangeAfterPreviousRendererIsReleasedDropsOldAdapterEvents() throws {
    let mediaChannel = try makeTestMediaChannel()
    let senderStream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    var firstRenderer: RecordingVideoRenderer? = RecordingVideoRenderer()
    weak var weakFirstRenderer = firstRenderer
    senderStream.videoRenderer = firstRenderer
    guard
      let firstAdapter = (senderStream as? BasicMediaStream)?.videoRendererAdapterForTesting
    else {
      XCTFail("renderer を設定すると adapter が生成されること")
      return
    }
    drainOwnerAndMainQueue(senderStream)

    // 配送完了後は owner も adapter も renderer を強参照しないため、参照を手放すと解放される
    firstRenderer = nil
    XCTAssertNil(
      weakFirstRenderer, "配送完了後は owner も adapter も renderer を強参照しないこと")

    let secondRenderer = RecordingVideoRenderer()
    senderStream.videoRenderer = secondRenderer
    drainOwnerAndMainQueue(senderStream)
    XCTAssertEqual(
      secondRenderer.callbacks, [.added],
      "解放済みの renderer を飛ばして新しい renderer へ onAdded が配送されること")
    guard
      let secondAdapter = (senderStream as? BasicMediaStream)?.videoRendererAdapterForTesting
    else {
      XCTFail("交換後も adapter が存在すること")
      return
    }

    firstAdapter.renderFrame(requireNativeVideoFrame(timeStampNs: 1, width: 16))
    firstAdapter.setSize(CGSize(width: 8, height: 8))
    secondAdapter.renderFrame(requireNativeVideoFrame(timeStampNs: 2, width: 32))
    secondAdapter.setSize(CGSize(width: 48, height: 32))
    drainOwnerAndMainQueue(senderStream)

    XCTAssertEqual(
      secondRenderer.callbacks,
      [.added, .render(frameWidth: 32), .size(CGSize(width: 48, height: 32))],
      "解放済みの renderer の旧 adapter の frame / size が配送されないこと")
  }
}
