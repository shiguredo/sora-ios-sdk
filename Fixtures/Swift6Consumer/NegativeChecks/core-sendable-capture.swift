// EXPECT-DIAGNOSTIC: SendableClosureCaptures
// 検査する契約: MediaChannel は Sendable ではないため、@Sendable closure へ
// キャプチャすると compile できないこと。
// 期待する診断: SendableClosureCaptures (error)
// この file はどの target にも含めない。
import Sora

nonisolated func captureMediaChannel(_ mediaChannel: MediaChannel) {
  let closure: @Sendable () -> Void = {
    _ = mediaChannel
  }
  _ = closure
}
