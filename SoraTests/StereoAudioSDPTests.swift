import XCTest

@testable import Sora

/// Answer SDP のステレオ Opus パラメーター変換を検証します。
///
/// 実際の SDP と同じ media section と属性行を入力し、モックやスタブを使わずに
/// 変換結果を直接確認します。
final class StereoAudioSDPTests: XCTestCase {
  /// fmtp 行がない場合は Opus の rtpmap 行の直後へ追加することを確認する
  func testAddsFmtpWhenMissing() throws {
    let sdp =
      "v=0\n"
      + "m=audio 9 UDP/TLS/RTP/SAVPF 109\n"
      + "a=rtpmap:109 opus/48000/2\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertEqual(
      result,
      "v=0\n"
        + "m=audio 9 UDP/TLS/RTP/SAVPF 109\n"
        + "a=rtpmap:109 opus/48000/2\n"
        + "a=fmtp:109 stereo=1\n")
  }

  /// 既存 fmtp に stereo がない場合は、他のパラメーターを維持して追加することを確認する
  func testAddsStereoToExistingFmtp() throws {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=rtpmap:111 opus/48000/2\n"
      + "a=fmtp:111 minptime=10;useinbandfec=1\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertTrue(result.contains("a=fmtp:111 minptime=10;useinbandfec=1;stereo=1"))
    XCTAssertFalse(result.contains("sprop-stereo"))
  }

  /// stereo=0 は stereo=1 に置換し、他のパラメーターを維持することを確認する
  func testReplacesStereoZero() throws {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=rtpmap:111 opus/48000/2\n"
      + "a=fmtp:111 minptime=10;stereo=0;useinbandfec=1\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertTrue(result.contains("a=fmtp:111 minptime=10;stereo=1;useinbandfec=1"))
    XCTAssertFalse(result.contains("stereo=0"))
  }

  /// stereo=1 が設定済みの場合は SDP を変更しないことを確認する
  func testKeepsExistingStereoOne() throws {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=rtpmap:111 opus/48000/2\n"
      + "a=fmtp:111 minptime=10;stereo=1\n"

    XCTAssertEqual(try StereoAudioSDP.enableStereo(in: sdp), sdp)
  }

  /// 複数の音声 payload type があっても Opus に対応する fmtp だけを変更することを確認する
  func testChangesOnlyOpusPayloadType() throws {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 96 109 111\n"
      + "a=rtpmap:96 PCMU/8000\n"
      + "a=fmtp:96 mode=sample\n"
      + "a=rtpmap:109 opus/48000/2\n"
      + "a=fmtp:109 minptime=10\n"
      + "a=rtpmap:111 telephone-event/48000\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertTrue(result.contains("a=fmtp:96 mode=sample"))
    XCTAssertTrue(result.contains("a=fmtp:109 minptime=10;stereo=1"))
    XCTAssertFalse(result.contains("a=fmtp:111 stereo=1"))
  }

  /// audio section に複数の Opus payload type がある場合はすべてに設定することを確認する
  func testChangesAllOpusPayloadTypes() throws {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 109 110\n"
      + "a=rtpmap:109 opus/48000/2\n"
      + "a=rtpmap:110 OPUS/48000/2\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertTrue(result.contains("a=fmtp:109 stereo=1"))
    XCTAssertTrue(result.contains("a=fmtp:110 stereo=1"))
  }

  /// Opus payload がない場合は成立しない Answer としてエラーにすることを確認する
  func testThrowsWhenOpusPayloadIsMissing() {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 0\n"
      + "a=rtpmap:0 PCMU/8000\n"

    XCTAssertThrowsError(try StereoAudioSDP.enableStereo(in: sdp)) { error in
      guard case SoraError.peerChannelError = error else {
        XCTFail("SoraError.peerChannelError が返ること: \(error)")
        return
      }
    }
  }

  /// 複数の受信 audio section の一部に Opus がなければエラーにすることを確認する
  func testThrowsWhenReceivingAudioSectionDoesNotHaveOpus() {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=rtpmap:111 opus/48000/2\n"
      + "m=audio 9 UDP/TLS/RTP/SAVPF 0\n"
      + "a=recvonly\n"
      + "a=rtpmap:0 PCMU/8000\n"

    XCTAssertThrowsError(try StereoAudioSDP.enableStereo(in: sdp)) { error in
      guard case SoraError.peerChannelError = error else {
        XCTFail("SoraError.peerChannelError が返ること: \(error)")
        return
      }
    }
  }

  /// 送信専用の audio section は受信ステレオ設定の対象外として変更しないことを確認する
  func testIgnoresSendonlyAudioSectionWithoutOpus() throws {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=recvonly\n"
      + "a=rtpmap:111 opus/48000/2\n"
      + "m=audio 9 UDP/TLS/RTP/SAVPF 0\n"
      + "a=sendonly\n"
      + "a=rtpmap:0 PCMU/8000\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertTrue(result.contains("a=fmtp:111 stereo=1"))
    XCTAssertFalse(result.contains("a=fmtp:0 stereo=1"))
  }

  /// Answer が送信専用のみなら受信音声がないため、Opus がなくても SDP を維持することを確認する
  func testKeepsSendonlyOnlyAnswerWithoutOpus() throws {
    let sdp =
      "v=0\n"
      + "a=sendonly\n"
      + "m=audio 9 UDP/TLS/RTP/SAVPF 0\n"
      + "a=rtpmap:0 PCMU/8000\n"

    XCTAssertEqual(try StereoAudioSDP.enableStereo(in: sdp), sdp)
  }

  /// 無効化された audio section に Opus がなくても active section を変換できることを確認する
  func testIgnoresInactiveAudioSectionWithoutOpus() throws {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=rtpmap:111 opus/48000/2\n"
      + "m=audio 0 UDP/TLS/RTP/SAVPF 0\n"
      + "a=rtpmap:0 PCMU/8000\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertTrue(result.contains("a=fmtp:111 stereo=1"))
    XCTAssertFalse(result.contains("a=fmtp:0 stereo=1"))
  }

  /// `0/2` 形式の port で無効化された audio section も変更しないことを確認する
  func testIgnoresZeroPortWithPortCount() throws {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=rtpmap:111 opus/48000/2\n"
      + "m=audio 0/2 UDP/TLS/RTP/SAVPF 0\n"
      + "a=rtpmap:0 PCMU/8000\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertTrue(result.contains("a=fmtp:111 stereo=1"))
    XCTAssertFalse(result.contains("a=fmtp:0 stereo=1"))
  }

  /// `a=inactive` の audio section は port が非 0 でも変更しないことを確認する
  func testIgnoresInactiveDirectionAudioSection() throws {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=inactive\n"
      + "a=rtpmap:111 opus/48000/2\n"
      + "m=audio 9 UDP/TLS/RTP/SAVPF 109\n"
      + "a=rtpmap:109 opus/48000/2\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertFalse(result.contains("a=fmtp:111 stereo=1"))
    XCTAssertTrue(result.contains("a=fmtp:109 stereo=1"))
  }

  /// media-level の direction がなければ session-level の inactive を継承することを確認する
  func testInheritsSessionInactiveDirection() throws {
    let sdp =
      "v=0\n"
      + "a=inactive\n"
      + "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=rtpmap:111 opus/48000/2\n"
      + "m=audio 9 UDP/TLS/RTP/SAVPF 109\n"
      + "a=sendrecv\n"
      + "a=rtpmap:109 opus/48000/2\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertFalse(result.contains("a=fmtp:111 stereo=1"))
    XCTAssertTrue(result.contains("a=fmtp:109 stereo=1"))
  }

  /// session-level の recvonly を継承した audio section は active として変更することを確認する
  func testInheritsSessionRecvonlyDirectionAsActive() throws {
    let sdp =
      "v=0\n"
      + "a=recvonly\n"
      + "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=rtpmap:111 opus/48000/2\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertTrue(result.contains("a=fmtp:111 stereo=1"))
  }

  /// m-line にない Opus rtpmap は交渉対象として扱わないことを確認する
  func testThrowsWhenOpusPayloadIsNotListedInMediaLine() {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 0\n"
      + "a=rtpmap:0 PCMU/8000\n"
      + "a=rtpmap:111 opus/48000/2\n"

    XCTAssertThrowsError(try StereoAudioSDP.enableStereo(in: sdp)) { error in
      guard case SoraError.peerChannelError = error else {
        XCTFail("SoraError.peerChannelError が返ること: \(error)")
        return
      }
    }
  }

  /// video section で同じ payload type を使っていても、その fmtp を変更しないことを確認する
  func testKeepsVideoFmtpWithSamePayloadType() throws {
    let sdp =
      "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=rtpmap:111 opus/48000/2\n"
      + "a=fmtp:111 minptime=10\n"
      + "m=video 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=rtpmap:111 H264/90000\n"
      + "a=fmtp:111 profile-level-id=42e01f\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertTrue(result.contains("a=fmtp:111 minptime=10;stereo=1"))
    XCTAssertTrue(result.contains("a=fmtp:111 profile-level-id=42e01f"))
    XCTAssertFalse(result.contains("profile-level-id=42e01f;stereo=1"))
  }

  /// CRLF の SDP は CRLF と末尾改行を維持することを確認する
  func testPreservesCRLF() throws {
    let sdp =
      "v=0\r\n"
      + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
      + "a=rtpmap:111 opus/48000/2\r\n"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertTrue(result.hasSuffix("\r\n"))
    XCTAssertFalse(result.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    XCTAssertTrue(result.contains("a=fmtp:111 stereo=1\r\n"))
  }

  /// LF の SDP は LF のまま維持し、CR を追加しないことを確認する
  func testPreservesLF() throws {
    let sdp =
      "v=0\n"
      + "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
      + "a=rtpmap:111 opus/48000/2"

    let result = try StereoAudioSDP.enableStereo(in: sdp)

    XCTAssertFalse(result.contains("\r"))
    XCTAssertFalse(result.hasSuffix("\n"))
    XCTAssertTrue(result.hasSuffix("a=fmtp:111 stereo=1"))
  }
}
