import Foundation
import WebRTC

/// 映像の描画に必要な機能を定義したプロトコルです。
///
/// SDK が呼ぶ callback の配送 executor はすべて main queue です。`VideoRenderer` の実装は
/// main queue 上で呼ばれる前提で書けますが、利用者が任意のスレッドから直接呼ぶ契約は
/// 変わりません。この protocol は `@MainActor` 隔離を持たないため、main queue 配送は
/// 実行時の取り決めであり、型では保証されません。
public protocol VideoRenderer: AnyObject {
  /// 映像のサイズが変更されたときに呼ばれます。
  ///
  /// この callback は main queue 上で呼ばれます。
  /// - parameter size: 変更後のサイズ
  func onChange(size: CGSize)
  /// 映像フレームを描画します。
  ///
  /// この callback は main queue 上で呼ばれます。
  /// - parameter videoFrame: 描画する映像フレーム
  func render(videoFrame: VideoFrame?)
  /// 接続解除時に呼ばれます。
  ///
  /// この callback は main queue 上で呼ばれます。
  /// - parameter from: 接続解除するメディアチャンネル
  func onDisconnect(from: MediaChannel?)
  /// ストリームへの追加時に呼ばれます。
  ///
  /// この callback は main queue 上で呼ばれます。
  /// - parameter from: 追加されるストリーム
  func onAdded(from: MediaStream)
  /// ストリームからの除去時に呼ばれます。
  ///
  /// この callback は main queue 上で呼ばれます。`MediaStream.videoRenderer` の setter で
  /// 交換または `nil` を代入したときに、以前の renderer へ 1 回だけ呼ばれます。
  /// - parameter from: 除去されるストリーム
  func onRemoved(from: MediaStream)
  /// 映像の可否の設定の変更時に呼ばれます。
  ///
  /// この callback は main queue 上で呼ばれます。`MediaStreamHandlers.onSwitchVideo` の
  /// 実行 executor とは異なり、相対順序は保証されません。
  /// - parameter video: 映像の可否
  func onSwitch(video: Bool)
  /// 音声の可否の設定の変更時に呼ばれます。
  ///
  /// この callback は main queue 上で呼ばれます。`MediaStreamHandlers.onSwitchAudio` の
  /// 実行 executor とは異なり、相対順序は保証されません。
  /// - parameter audio: 音声の可否
  func onSwitch(audio: Bool)
}

/// `RTCVideoRenderer` が受け取った frame と size を `StreamFrameOwner` へ中継する adapter です。
///
/// frame と size は owner の owner queue へ非同期に投入し、順序付けと世代の判定は owner が
/// 行います。`RTCVideoSource.capturer(_:didCapture:)` は owner queue から呼ばれるため、同じ
/// video track の renderer へ同期配送されると `renderFrame` は owner queue 上で呼ばれ得ます。
/// owner への投入に同期処理を使うと自己デッドロックするため、必ず非同期で投入します。
///
/// adapter は owner を弱参照し、世代は owner が `setRenderer` で採番した値を init で受け取って
/// 不変値として保持します。owner が解放された場合は何も配送しません (renderer の callback も
/// 呼ばれません)。
///
/// この配送方式 (main queue への 1 hop) は `@MainActor` 隔離を持つ描画 protocol を追加するまでの
/// 暫定であり、main queue 配送は型では保証されません。
class VideoRendererAdapter: NSObject, RTCVideoRenderer {
  /// 配送先の renderer です。adapter は renderer の寿命を延長しません。
  private(set) weak var videoRenderer: VideoRenderer?

  /// 中継先の owner です。owner の寿命は `BasicMediaStream` が保ちます。
  private weak var owner: StreamFrameOwner?

  /// owner が採番した世代です。init 後に書き換えないため lock は不要です。
  private let generation: UInt64

  init(videoRenderer: VideoRenderer, owner: StreamFrameOwner, generation: UInt64) {
    self.videoRenderer = videoRenderer
    self.owner = owner
    self.generation = generation
  }

  /// 映像のサイズを owner へ中継します。
  ///
  /// - parameter size: 変更後のサイズ
  func setSize(_ size: CGSize) {
    owner?.submitRendererSize(size, generation: generation)
  }

  /// 映像フレームを owner へ中継します。
  ///
  /// - parameter frame: 描画する映像フレーム
  func renderFrame(_ frame: RTCVideoFrame?) {
    owner?.submitRendererFrame(frame, generation: generation)
  }
}
