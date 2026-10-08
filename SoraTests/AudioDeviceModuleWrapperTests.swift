import WebRTC
import XCTest

@testable import Sora

/// 非 Sendable な `AudioDeviceModuleWrapper` を `@Sendable` closure へ capture せずに渡す box です
/// (`SoraTests/LoggerCallUnderLockTests.swift` の `MediaChannelEntryBox` と同じ理由)。
private final class AudioDeviceModuleWrapperEntryBox: @unchecked Sendable {
  private let wrapper: AudioDeviceModuleWrapper

  init(_ wrapper: AudioDeviceModuleWrapper) {
    self.wrapper = wrapper
  }

  func setAudioHardMute() {
    _ = wrapper.setAudioHardMute(false)
  }
}

final class AudioDeviceModuleWrapperTests: XCTestCase {
  /// factory に束縛していない wrapper は、worker を特定できないため失敗を返す。
  ///
  /// m155 以降の ADM は録音の pause/resume を WebRTC の worker スレッド上で実行する契約で、
  /// SDK は factory 経由で実行する。factory が無い状態で成功を返すと、worker 以外の
  /// スレッドから ADM を操作したことになり契約違反になるため、明示的に失敗させる。
  func testUnboundWrapperFailsWithoutFactory() {
    let wrapper = AudioDeviceModuleWrapper(audioDeviceModule: RTCAudioDeviceModule())
    XCTAssertFalse(wrapper.setAudioHardMute(false), "factory 未束縛では解除要求を失敗させること")
    XCTAssertFalse(wrapper.setAudioHardMute(true), "factory 未束縛ではミュート要求も失敗させること")
  }

  /// 実際の ADM を worker 上で操作し、未初期化による失敗を成功扱いにしない。
  ///
  /// factory に渡した ADM は worker スレッドを持つが、音声入出力を開始していないため
  /// 録音操作は失敗する。wrapper がその戻り値をそのまま結果に反映することを確認する。
  func testBoundWrapperPropagatesActualADMFailure() throws {
    // factory へ渡した ADM を実際に worker 上で操作し、モックやスタブを使わずに確認する。
    // 同じ ADM を複数の factory へ渡すと nil になるため、ここでは 1 つの factory だけに渡す。
    let adm: RTCAudioDeviceModule = RTCAudioDeviceModule()
    let encoder = RTCDefaultVideoEncoderFactory()
    let decoder = RTCDefaultVideoDecoderFactory()
    let created = RTCPeerConnectionFactory(
      encoderFactory: encoder,
      decoderFactory: decoder,
      audioDeviceModule: adm)
    let factory = try XCTUnwrap(created)
    let wrapper = AudioDeviceModuleWrapper(audioDeviceModule: adm)
    wrapper.bindToFactory(factory)
    XCTAssertFalse(wrapper.setAudioHardMute(false), "最初の解除要求で ADM の失敗を返すこと")
    XCTAssertFalse(wrapper.setAudioHardMute(false), "失敗後の同じ要求を再試行すること")
  }

  /// 出力 handler から同じ wrapper の `setAudioHardMute(_:)` を呼んでも deadlock しない
  ///
  /// この wrapper は factory 未束縛で `pauseRecording` / `resumeRecording` を実行できないため
  /// `Logger.error` の経路になる。ログは `queue.sync` の外で出すため、handler からの再入が停止しない。
  /// handler は 1 段だけ再入する (制限が無いと修正後は再入が無限に続く)。
  func testSetAudioHardMuteFromOutputHandlerDoesNotDeadlock() {
    let wrapper = AudioDeviceModuleWrapper(audioDeviceModule: RTCAudioDeviceModule())
    let originalLevel = Logger.shared.level
    let originalGroups = Logger.shared.groups
    let originalOnOutputHandler = Logger.shared.onOutputHandler
    defer {
      Logger.shared.onOutputHandler = originalOnOutputHandler
      Logger.shared.level = originalLevel
      Logger.shared.groups = originalGroups
    }

    Logger.shared.level = .debug
    Logger.shared.groups = [.channels]

    let collector = LoggerCallUnderLockLogCollector()
    let limiter = LoggerCallUnderLockReentrancyLimiter()
    let readerQueue = DispatchQueue(
      label: "jp.shiguredo.sora.tests.audioDeviceModuleWrapper.reader")
    let reentered = expectation(description: "handler から setAudioHardMute を呼ぶ")
    Logger.shared.onOutputHandler = { log in
      collector.append(log)
      guard log.type.isMediaChannel,
        log.message.hasPrefix("setAudioHardMute via RTCAudioDeviceModule")
      else {
        return
      }
      guard limiter.consume() else {
        return
      }
      readerQueue.sync { _ = wrapper.setAudioHardMute(false) }
      reentered.fulfill()
    }

    let entryBox = AudioDeviceModuleWrapperEntryBox(wrapper)
    DispatchQueue(label: "jp.shiguredo.sora.tests.audioDeviceModuleWrapper.entry").async {
      entryBox.setAudioHardMute()
    }

    let result = XCTWaiter.wait(for: [reentered], timeout: 5)
    XCTAssertEqual(result, .completed, "handler からの setAudioHardMute が 5 秒以内に戻ること")
    let log = collector.firstLog {
      $0.type.isMediaChannel && $0.message.hasPrefix("setAudioHardMute via RTCAudioDeviceModule")
    }
    XCTAssertNotNil(log, "対象ログを handler が受け取ること")
    XCTAssertEqual(log?.level, .error, "ADM の失敗ログの level")
    XCTAssertEqual(log?.type.isMediaChannel, true, "ADM の失敗ログの type")
    XCTAssertEqual(log?.message.hasSuffix(" failed"), true, "ADM の失敗ログの message")
  }
}
