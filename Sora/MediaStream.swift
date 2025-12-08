import Foundation
import WebRTC

/// ストリームの音声のボリュームの定数のリストです。
public enum MediaStreamAudioVolume {
  /// 最小値
  public static let min: Double = 0

  /// 最大値
  public static let max: Double = 10
}

/// ストリームのイベントハンドラです。
public final class MediaStreamHandlers {
  /// 映像トラックが有効または無効にセットされたときに呼ばれるクロージャー
  public var onSwitchVideo: ((_ isEnabled: Bool) -> Void)?

  /// 音声トラックが有効または無効にセットされたときに呼ばれるクロージャー
  public var onSwitchAudio: ((_ isEnabled: Bool) -> Void)?

  /// 初期化します。
  public init() {}
}

/// メディアストリームの機能を定義したプロトコルです。
/// デフォルトの実装は非公開 (`internal`) であり、カスタマイズはイベントハンドラでのみ可能です。
/// ソースコードは公開していますので、実装の詳細はそちらを参照してください。
///
/// メディアストリームは映像と音声の送受信を行います。
/// メディアストリーム 1 つにつき、 1 つの映像と 1 つの音声を送受信可能です。
public protocol MediaStream: AnyObject {
  // MARK: - イベントハンドラ

  /// イベントハンドラ
  var handlers: MediaStreamHandlers { get }

  // MARK: - 接続情報

  /// ストリーム ID
  var streamId: String { get }

  /// 接続開始時刻
  var creationTime: Date { get }

  /// メディアチャンネル
  var mediaChannel: MediaChannel? { get }

  // MARK: - 映像と音声の可否

  /// 映像の可否。
  /// ``false`` をセットすると、サーバーへの映像の送受信を停止します。
  /// ``true`` をセットすると送受信を再開します。
  var videoEnabled: Bool { get set }

  /// 音声の可否。
  /// ``false`` をセットすると、サーバーへの音声の送受信を停止します。
  /// ``true`` をセットすると送受信を再開します。
  ///
  /// サーバーへの送受信を停止しても、マイクはミュートされませんので注意してください。
  var audioEnabled: Bool { get set }

  /// 受信した音声のボリューム。 0 から 10 (含む) までの値をセットします。
  /// このプロパティはロールがサブスクライバーの場合のみ有効です。
  var remoteAudioVolume: Double? { get set }

  // MARK: 映像フレームの送信

  /// 映像フィルター
  var videoFilter: VideoFilter? { get set }

  /// 映像レンダラー。
  var videoRenderer: VideoRenderer? { get set }

  /// 映像フレームをサーバーに送信します。
  /// 送信される映像フレームは映像フィルターを通して加工されます。
  /// 映像レンダラーがセットされていれば、加工後の映像フレームが
  /// 映像レンダラーによって描画されます。
  ///
  /// - parameter videoFrame: 描画する映像フレーム。
  ///                         `nil` を指定すると空の映像フレームを送信します。
  func send(videoFrame: VideoFrame?)

  // MARK: 終了処理

  /// ストリームの終了処理を行います。
  func terminate()

  // MARK: libwbrtc API
  var nativeStream: RTCMediaStream { get }
  var nativeVideoTrack: RTCVideoTrack? { get }
  var nativeAudioTrack: RTCAudioTrack? { get }
}

class BasicMediaStream: MediaStream {
  let handlers = MediaStreamHandlers()

  var peerChannel: PeerChannel

  var streamId: String = ""
  var videoTrackId: String = ""
  var audioTrackId: String = ""
  var creationTime: Date

  var mediaChannel: MediaChannel? {
    // MediaChannel は必ず存在するが、 MediaChannel と PeerChannel の循環参照を避けるために、 PeerChannel は MediaChannel を弱参照で保持している
    // mediaChannel を force unwrapping することも検討したが、エラーによる切断処理中なども安全である確信が持てなかったため、
    // SDK 側で force unwrapping することは避ける
    peerChannel.mediaChannel
  }

  var videoFilter: VideoFilter?

  var videoRenderer: VideoRenderer? {
    get {
      videoRendererAdapter?.videoRenderer
    }
    set {
      if let value = newValue {
        videoRendererAdapter =
          VideoRendererAdapter(videoRenderer: value)
        value.onAdded(from: self)
      } else {
        videoRendererAdapter?.videoRenderer?
          .onRemoved(from: self)
        videoRendererAdapter = nil
      }
    }
  }

  private var videoRendererAdapter: VideoRendererAdapter? {
    willSet {
      guard let videoTrack = nativeVideoTrack else { return }
      guard let adapter = videoRendererAdapter else { return }
      Logger.debug(
        type: .videoRenderer,
        message: "remove old video renderer \(adapter) from nativeVideoTrack")
      videoTrack.remove(adapter)
    }
    didSet {
      guard let videoTrack = nativeVideoTrack else { return }
      guard let adapter = videoRendererAdapter else { return }
      Logger.debug(
        type: .videoRenderer,
        message: "add new video renderer \(adapter) to nativeVideoTrack")
      videoTrack.add(adapter)
    }
  }

  var nativeStream: RTCMediaStream

  var nativeVideoTrack: RTCVideoTrack? {
    nativeStream.videoTracks.first
  }

  var nativeVideoSource: RTCVideoSource? {
    nativeVideoTrack?.source
  }

  var nativeAudioTrack: RTCAudioTrack? {
    nativeStream.audioTracks.first
  }

  var videoEnabled: Bool {
    get {
      nativeVideoTrack?.isEnabled ?? false
    }
    set {
      guard videoEnabled != newValue else {
        return
      }
      if let track = nativeVideoTrack {
        track.isEnabled = newValue
        handlers.onSwitchVideo?(newValue)
        videoRenderer?.onSwitch(video: newValue)
      }
    }
  }

  var audioEnabled: Bool {
    get {
      nativeAudioTrack?.isEnabled ?? false
    }
    set {
      guard audioEnabled != newValue else {
        return
      }
      if let track = nativeAudioTrack {
        track.isEnabled = newValue
        handlers.onSwitchAudio?(newValue)
        videoRenderer?.onSwitch(audio: newValue)
      }
    }
  }

  var remoteAudioVolume: Double? {
    get {
      nativeAudioTrack?.source.volume
    }
    set {
      guard let newValue else {
        return
      }
      if let track = nativeAudioTrack {
        var volume = newValue
        if volume < MediaStreamAudioVolume.min {
          volume = MediaStreamAudioVolume.min
        } else if volume > MediaStreamAudioVolume.max {
          volume = MediaStreamAudioVolume.max
        }
        track.source.volume = volume
        Logger.debug(
          type: .mediaStream,
          message: "set audio volume \(volume)")
      }
    }
  }

  init(peerChannel: PeerChannel, nativeStream: RTCMediaStream) {
    self.peerChannel = peerChannel
    self.nativeStream = nativeStream
    streamId = nativeStream.streamId
    creationTime = Date()
  }

  func terminate() {
    videoRendererAdapter?.videoRenderer?.onDisconnect(from: peerChannel.mediaChannel ?? nil)
  }

  private static let dummyCapturer = RTCVideoCapturer()
  func send(videoFrame: VideoFrame?) {
    if let frame = videoFrame {
      // フィルターを通す
      let frame = videoFilter?.filter(videoFrame: frame) ?? frame
      switch frame {
      case .native(let capturer, let nativeFrame):
        // RTCVideoSource.capturer(_:didCapture:) の最初の引数は
        // 現在使われてないのでダミーでも可？ -> ダミーにしました
        nativeVideoSource?.capturer(
          capturer ?? BasicMediaStream.dummyCapturer,
          didCapture: nativeFrame)
      }
    } else {
    }
  }
}

