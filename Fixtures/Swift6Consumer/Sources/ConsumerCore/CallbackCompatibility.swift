// 検査する契約:
//   - handler 型に属さない公開 closure プロパティ (Logger / ScreenCaptureSettings) に
//     nonisolated な文脈から closure を代入できること
//   - 公開メソッドの closure 引数 (CameraVideoCapturer の完了 handler と
//     Sora.configureAudioSession の block) に closure を渡せること
// 期待する診断: なし (error 0 件、warning 0 件)
import CoreMedia
import Sora

/// Logger の出力 handler を代入する。
func makeLogOutputHandler() -> Logger {
  let logger = Logger.shared
  logger.onOutputHandler = { log in
    _ = log
  }
  return logger
}

/// ScreenCaptureSettings の closure を init の引数と property の両方で受け渡す。
func makeScreenCaptureSettings() -> ScreenCaptureSettings {
  var settings = ScreenCaptureSettings(
    targetFPS: 30,
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
/// start(format:frameRate:completionHandler:) は実機の AVCaptureDevice.Format が必要なため
/// この file では扱わない。
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
  Sora.shared.configureAudioSession {
    // ここは音声セッションのロック中に実行される
  }
}
