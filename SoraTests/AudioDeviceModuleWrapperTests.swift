import WebRTC
import XCTest

@testable import Sora

final class AudioDeviceModuleWrapperTests: XCTestCase {
  /// 最初の解除要求も実際の ADM に渡し、未初期化による失敗を成功扱いにしない。
  func testFirstUnmutePropagatesActualADMFailure() {
    // factory に渡していない実際の ADM を使い、音声入出力を開始せず確認する。
    let wrapper = AudioDeviceModuleWrapper(audioDeviceModule: RTCAudioDeviceModule())
    XCTAssertFalse(wrapper.setAudioHardMute(false), "最初の解除要求で ADM の失敗を返すこと")
    XCTAssertFalse(wrapper.setAudioHardMute(false), "失敗後の同じ要求を再試行すること")
  }
}
