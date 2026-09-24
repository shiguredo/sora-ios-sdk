// 検査する契約:
//   - handler 型に属さない公開 closure プロパティ (Logger / ScreenCaptureSettings) に
//     nonisolated な文脈から closure を代入できること
//   - 公開メソッドの closure 引数 (CameraVideoCapturer の完了 handler と
//     Sora.configureAudioSession の block) に closure を渡せること
//   - Sora が標準型へ追加している公開 closure 引数 (Optional.unwrap(ifNone:) と
//     Array.remove(_:where:)) に nonisolated な文脈から closure を渡せること
// 期待する診断: なし (error 0 件、warning 0 件)
import Sora

/// Logger の出力 handler を代入する。
func makeLogOutputHandler() {
  Logger.shared.onOutputHandler = { log in
    _ = log
  }
}

/// ScreenCaptureSettings の closure を init の引数と property の両方で受け渡す。
func makeScreenCaptureSettings() -> ScreenCaptureSettings {
  var settings = ScreenCaptureSettings(
    videoSampleBufferTransformer: { sampleBuffer in
      sampleBuffer
    },
    onRuntimeError: { error in
      _ = error
    }
  )
  settings.videoSampleBufferTransformer = { sampleBuffer in
    sampleBuffer
  }
  settings.onRuntimeError = { error in
    _ = error
  }
  return settings
}

/// CameraVideoCapturer の完了 handler を渡す。
/// start は実機の AVCaptureDevice.Format が必要なため扱わない。
func useCameraCompletionHandlers() {
  let capturer = CameraVideoCapturer.current
  capturer?.stop { error in
    _ = error
  }
  capturer?.restart { error in
    _ = error
  }
  capturer?.change { error in
    _ = error
  }
}

/// 音声セッション設定の block を渡す。
func configureAudioSession() {
  Sora.shared.configureAudioSession {}
}

/// Optional の unwrap(ifNone:) に closure を渡す。
/// 非 Sendable な値を capture し、closure 型に @Sendable が付いた場合に検出できるようにする。
func unwrapOptional(_ value: Int?, capturing mediaChannel: MediaChannel) -> Int {
  value.unwrap(ifNone: {
    _ = mediaChannel
    return 0
  })
}

/// Array の remove(_:where:) に closure を渡す。
/// 非 Sendable な値を capture し、closure 型に @Sendable が付いた場合に検出できるようにする。
func removeFromArray(_ values: inout [Int], capturing mediaChannel: MediaChannel) {
  values.remove(
    0,
    where: { value in
      _ = mediaChannel
      return value == 0
    })
}

/// CameraVideoCapturer の向きを切り替える static メソッドへ完了 handler を渡す。
func flipCamera() {
  if let capturer = CameraVideoCapturer.current {
    CameraVideoCapturer.flip(capturer) { error in
      _ = error
    }
  }
}
