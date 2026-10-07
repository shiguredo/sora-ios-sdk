import Compression
import Foundation
import WebRTC
import zlib

// Apple が提供する圧縮を扱う API は zlib のヘッダーとチェックサムをサポートしていないため、当該処理を実装する必要があった
// https://developer.apple.com/documentation/accelerate/compressing_and_decompressing_data_with_buffer_compression
//
// TODO: iOS 12 のサポートが不要になれば、 Compression Framework の関数を、 NSData の compressed(using), decompressed(using:) に書き換えることができる
// それに伴い、処理に必要なバッファーのサイズを指定する必要もなくなる
private enum ZLibUtil {
  static func zip(_ input: Data) -> Data? {
    if input.isEmpty {
      return nil
    }

    // TODO: 毎回確保するには大きいので、 stream を利用して圧縮する API、もしくは NSData の compressed(using:) を使用することを検討する
    // 2021年10月時点では、 DataChannel の最大メッセージサイズは 262,144 バイトだが、これを拡張する RFC が提案されている
    // https://sora-doc.shiguredo.jp/DATA_CHANNEL_SIGNALING#48cff8
    // https://www.rfc-editor.org/rfc/rfc8260.html
    let bufferSize = 262_144
    let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer {
      destinationBuffer.deallocate()
    }

    var sourceBuffer = [UInt8](input)
    let size = compression_encode_buffer(
      destinationBuffer, bufferSize,
      &sourceBuffer, sourceBuffer.count,
      nil,
      COMPRESSION_ZLIB)
    if size == 0 {
      return nil
    }

    var zipped = Data(capacity: size + 6)  // ヘッダー: 2バイト, チェックサム: 4バイト
    zipped.append(contentsOf: [0x78, 0x5E])  // ヘッダーを追加
    zipped.append(destinationBuffer, count: size)

    let checksum = input.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> UInt32 in
      // 空でない Data の withUnsafeBytes 内では baseAddress は非 nil
      // swiftlint:disable:next force_unwrapping
      let bytef = p.baseAddress!.assumingMemoryBound(to: Bytef.self)
      return UInt32(adler32(1, bytef, UInt32(input.count)))
    }

    zipped.append(UInt8(checksum >> 24 & 0xFF))
    zipped.append(UInt8(checksum >> 16 & 0xFF))
    zipped.append(UInt8(checksum >> 8 & 0xFF))
    zipped.append(UInt8(checksum & 0xFF))
    return zipped
  }

  static func unzip(_ input: Data) -> Data? {
    // ヘッダー (2 バイト) + 圧縮データ (1 バイト以上) + チェックサム (4 バイト) = 最低 7 バイト必要
    if input.count < 7 {
      return nil
    }

    // TODO: zip と同様に、stream を利用して解凍する API、もしくは NSData の decompressed(using:) を使用することを検討する
    let bufferSize = 262_144
    let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

    var sourceBuffer = [UInt8](input)

    // header を削除
    sourceBuffer.removeFirst(2)

    // checksum も削除
    let checksum = Data(sourceBuffer.suffix(4))
    sourceBuffer.removeLast(4)

    let size = compression_decode_buffer(
      destinationBuffer, bufferSize,
      &sourceBuffer, sourceBuffer.count,
      nil,
      COMPRESSION_ZLIB)

    if size == 0 {
      // 正常系では Data(bytesNoCopy:deallocator:.free) で所有権を移譲するが、
      // このパスでは Data を生成しないため明示的に解放する
      destinationBuffer.deallocate()
      return nil
    }

    let data = Data(bytesNoCopy: destinationBuffer, count: size, deallocator: .free)

    let calculatedChecksum = data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Data in
      // 非空 Data の withUnsafeBytes 内では baseAddress は非 nil
      // swiftlint:disable:next force_unwrapping
      let bytef = p.baseAddress!.assumingMemoryBound(to: Bytef.self)
      var result = UInt32(adler32(1, bytef, UInt32(data.count))).bigEndian
      return Data(bytes: &result, count: MemoryLayout<UInt32>.size)
    }

    // checksum の検証が成功したら data を返す
    return checksum == calculatedChecksum ? data : nil
  }
}

/// `BasicDataChannelDelegate.dataChannel(_:didReceiveMessageWith:)` の `statistics` 完了 block が
/// `DataChannel` を参照するための、用途限定の参照保持 box です。
///
/// `@unchecked Sendable` を認める根拠は、次の 3 条件をすべて満たすことです。
/// - 可変状態を持たず、保持する `DataChannel` の参照は `init` で確定した `let` であること。
///   box は参照を保持して block へ渡すだけで、状態を読み書きしないこと
/// - 変更前から `DataChannel` を捕捉していた `RTCPeerConnection.statistics` の完了 block を
///   包み直すだけで、配送先・通知順序・呼び出し回数を変えず、別系統の境界へ新たに渡さないこと
/// - 保持する `DataChannel` に対して closure が行う状態アクセスが、`init` で確定した不変値に
///   閉じること。`DataChannel` の格納プロパティは `let native` と `let delegate` の 2 つだけで
///   可変状態を持たない。`compress` は `delegate.compress` (`let`) を返す computed property で、
///   `send(_:)` は `delegate.compress` を読んで `native.sendData(_:)` を呼ぶ。
///   `BasicDataChannelDelegate` の `weak var peerChannel` / `weak var mediaChannel` への代入は
///   `init` の 2 箇所だけで、代入後に値を書き換えない
///
/// この `@unchecked Sendable` は「この box を使う経路で closure が行う状態アクセスが
/// 安全である」という限定した主張であり、`DataChannel` 全体が thread-safe であることも、
/// `DataChannel` に `Sendable` 準拠を追加することも主張しません。
/// 参照の同一性は変更前の capture と同じで、`DataChannel` の生存期間は box が保持する間だけ
/// 延びます。
///
/// 生成は `didReceiveMessageWith` の `stats` ラベルの 1 箇所だけで、1 つの block へ
/// 1 回だけ渡して 1 回だけ実行する使用契約です (型では強制されません)。
private final class DataChannelSendBox: @unchecked Sendable {
  let value: DataChannel

  init(_ value: DataChannel) {
    self.value = value
  }
}

class BasicDataChannelDelegate: NSObject, RTCDataChannelDelegate {
  let compress: Bool
  weak var peerChannel: PeerChannel?
  weak var mediaChannel: MediaChannel?

  /// この DataChannel が生成された時点の PeerChannel の世代。
  /// リダイレクト時の旧接続の通知を無視するために dataChannelDidChangeState で照合する。
  let generation: Int

  init(
    compress: Bool, mediaChannel: MediaChannel?, peerChannel: PeerChannel?,
    generation: Int
  ) {
    self.compress = compress
    self.mediaChannel = mediaChannel
    self.peerChannel = peerChannel
    self.generation = generation
  }

  func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    Logger.debug(
      type: .dataChannel,
      message:
        "\(#function): label => \(dataChannel.label), state => \(WebRTCEnumDescription.dataChannelState(dataChannel.readyState))"
    )

    // リダイレクト前に生成された DataChannel からの通知は無視する。
    // これにより、旧 RTCPeerConnection の close() に伴う .closed 通知が
    // 切断 (DisconnectReason.dataChannelClosed) として誤認されたり、
    // 旧接続の .open 通知が新接続の OPEN 追跡状態を汚染したりするのを防ぐ。
    guard generation == peerChannel?.dataChannelGeneration else {
      return
    }

    if dataChannel.readyState == .open {
      // DataChannel がクライアント側で OPEN になったことを通知する。
      // onDataChannel / onDataChannelOpened の発火は MediaChannel 側で行う。
      peerChannel?.internalHandlers.onOpenDataChannel?(dataChannel.label)
    } else if dataChannel.readyState == .closed {
      if let peerChannel {
        // DataChannel が切断されたタイミングで PeerChannel を切断する
        // PeerChannel -> DataChannel の順に切断されるパターンも存在するが、
        // PeerChannel.disconnect(error:reason:) 側で排他処理が実装されているため問題ない
        peerChannel.disconnect(error: nil, reason: DisconnectReason.dataChannelClosed)
      }
    }
  }

  func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
    Logger.debug(
      type: .dataChannel,
      message: "\(#function): label => \(dataChannel.label), amount => \(amount)")
  }

  func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    Logger.debug(type: .dataChannel, message: "\(#function): label => \(dataChannel.label)")

    // リダイレクト前に生成された DataChannel からのメッセージは無視する。
    // (リダイレクト前に配送済みだったメッセージが遅延到着すると、
    // signaling ラベル経由の旧 reOffer が新接続に誤適用されたり、
    // WebSocket 切断スケジュールが誤って実行されたりするため)
    guard generation == peerChannel?.dataChannelGeneration else {
      return
    }

    guard let peerChannel else {
      Logger.error(type: .dataChannel, message: "peerChannel is unavailable")
      return
    }

    // 登録済みの `DataChannel` の参照は `PeerChannel` の排他単位で読む。
    // (redirect の無効化と並行しても辞書の読み書きにデータ競合が生じない)
    guard let dc = peerChannel.dataChannel(label: dataChannel.label) else {
      Logger.error(
        type: .dataChannel,
        message: "DataChannel for label: \(dataChannel.label) is unavailable")
      return
    }

    guard let data = dc.compress ? ZLibUtil.unzip(buffer.data) : buffer.data else {
      Logger.error(type: .dataChannel, message: "failed to decompress data channel message")
      return
    }

    let messageJSON = String(data: data, encoding: .utf8)
    if let messageJSON {
      Logger.info(
        type: .dataChannel,
        message: "received data channel message: \(String(describing: messageJSON))")
    }

    // Sora から送られてきたメッセージ
    if !dataChannel.label.starts(with: "#") {
      switch dataChannel.label {
      case "stats":
        // statistics の完了 block は @Sendable として取り込まれるため、DataChannel を
        // 直接捕捉せず、用途限定の参照保持 box 経由で参照する。
        let sendBox = DataChannelSendBox(dc)
        peerChannel.nativeChannel?.statistics {
          // NOTE: stats の型を Signaling.swift に定義していない
          let reports = Statistics(contentsOf: $0).jsonObject
          let json: [String: Any] = [
            "type": "stats",
            "reports": reports,
          ]

          var data: Data?
          do {
            data = try JSONSerialization.data(
              withJSONObject: json, options: [.prettyPrinted])
          } catch {
            Logger.error(
              type: .dataChannel, message: "failed to encode stats data to json")
          }

          if let data {
            let ok = sendBox.value.send(data)
            if !ok {
              Logger.error(
                type: .dataChannel,
                message: "failed to send stats data over DataChannel")
            }
          }
        }

      case "signaling", "push", "notify":
        if let messageJSON {
          peerChannel.internalHandlers.onReceiveSignalingJSON?(messageJSON)
        }
        switch Signaling.decode(data) {
        case .success(let signaling):
          // signaling ラベルの DataChannel でメッセージを受信した時点を
          // DataChannel シグナリング確立の証拠として WebSocket 切断をスケジュールする
          if dataChannel.label == "signaling" {
            peerChannel.scheduleWebSocketDisconnectIfNeeded()
          }
          peerChannel.handleSignalingOverDataChannel(signaling)
        case .failure(let error):
          Logger.error(
            type: .dataChannel,
            message: "decode failed (\(error.localizedDescription)) => ")
        }
      case "rpc":
        peerChannel.handleRPCMessage(data)
      case "e2ee":
        Logger.error(
          type: .dataChannel, message: "NOT IMPLEMENTED: label => \(dataChannel.label)")
      default:
        Logger.error(
          type: .dataChannel, message: "unknown data channel label: \(dataChannel.label)")
      }
    }
    if let mediaChannel, let handler = mediaChannel.handlers.onDataChannelMessage {
      handler(mediaChannel, dataChannel.label, data)
    }
  }
}

/// `DataChannel.sendWithoutLogging(_:)` の結果です。
///
/// 送信ログは排他区間の外で出す必要があるため、送信の失敗を種類ごとに呼び出し側へ返します。
enum DataChannelSendResult {
  /// 送信できた
  case sent
  /// 圧縮に失敗した
  case compressionFailed
  /// 送信要求が失敗した
  case sendFailed
}

class DataChannel {
  let native: RTCDataChannel
  let delegate: BasicDataChannelDelegate

  init(
    dataChannel: RTCDataChannel, compress: Bool, mediaChannel: MediaChannel?,
    peerChannel: PeerChannel?, generation: Int
  ) {
    Logger.info(
      type: .dataChannel,
      message:
        "initialize DataChannel: label => \(dataChannel.label), compress => \(compress)")
    native = dataChannel
    delegate = BasicDataChannelDelegate(
      compress: compress, mediaChannel: mediaChannel, peerChannel: peerChannel,
      generation: generation)
    native.delegate = delegate
  }

  var label: String {
    native.label
  }

  var compress: Bool {
    delegate.compress
  }

  var readyState: RTCDataChannelState {
    native.readyState
  }

  /// メッセージを送信します。送信ログも本メソッドで出します。
  ///
  /// 排他区間の中で送信する経路 (`MediaChannel.sendMessage`) は
  /// `sendWithoutLogging(_:)` を使い、ログは区間の外で出します。
  func send(_ data: Data) -> Bool {
    logSendAttempt(data)
    let result = sendWithoutLogging(data)
    logCompressionFailureIfNeeded(result)
    return result == .sent
  }

  /// メッセージを送信します。ログは出しません。
  ///
  /// `MediaChannel.sendMessage` が排他区間の中で呼びます。区間の中で `Logger` を呼ぶと、
  /// 利用者の出力 handler が同じ排他単位を取る送信経路を再入したときにデッドロックするため、
  /// ログは呼び出し側が区間の外で `logSendAttempt(_:)` と `logCompressionFailureIfNeeded(_:)` を
  /// 呼んで出します。
  func sendWithoutLogging(_ data: Data) -> DataChannelSendResult {
    guard let data = compress ? ZLibUtil.zip(data) : data else {
      return .compressionFailed
    }
    return native.sendData(RTCDataBuffer(data: data, isBinary: true)) ? .sent : .sendFailed
  }

  /// 送信を試みたデータのログを出します。排他区間の外から呼びます。
  ///
  /// `send(_:)` は送信の前に、`MediaChannel.sendMessage` は区間の外で送信の後に呼びます。
  /// メッセージの関数名は変更前の `DataChannel.send(_:)` の `#function` と同じ `"send(_:)"` を
  /// 使います。呼び出し経路 (`send(_:)` / `MediaChannel.sendMessage`) によって文言を
  /// 変えないためです。
  func logSendAttempt(_ data: Data) {
    Logger.debug(
      type: .dataChannel,
      message:
        "\(String(describing: type(of: self))):send(_:): label => \(label), data => \(data.base64EncodedString())"
    )
  }

  /// 圧縮に失敗した場合のログを出します。排他区間の外から呼びます。
  ///
  /// `MediaChannel.sendMessage` は送信の失敗を一律に `SoraError.messagingError` として返すため、
  /// 利用者へ返る reason からは圧縮の失敗を区別できません。その原因を残すために
  /// `.compressionFailed` だけを error ログにします (`.sendFailed` は変更前と同じく追加の
  /// ログを出しません)。`logSendAttempt(_:)` と対で呼びます。
  func logCompressionFailureIfNeeded(_ result: DataChannelSendResult) {
    guard result == .compressionFailed else {
      return
    }
    Logger.error(type: .dataChannel, message: "failed to compress message")
  }
}
