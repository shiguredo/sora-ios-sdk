import Compression
import Foundation
import WebRTC
import zlib

// https://developer.apple.com/documentation/accelerate/compressing_and_decompressing_data_with_buffer_compression
fileprivate class ZLibUtil {
    
    static func zip(_ input: Data) -> Data? {
        if input.isEmpty {
            return nil
        }
        
        // TODO: 毎回確保するには大きいので、 stream を利用して圧縮する API への置き換えを検討する
        // 2021年10月時点では、 DataChannel の最大メッセージサイズは 262,144 バイトだが、これを拡張する RFC が提案されている
        // https://sora-doc.shiguredo.jp/DATA_CHANNEL_SIGNALING#48cff8
        // https://www.rfc-editor.org/rfc/rfc8260.html
        let bufferSize = 262_144
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        
        var sourceBuffer = [UInt8](input)
        let size = compression_encode_buffer(destinationBuffer, bufferSize,
                                             &sourceBuffer, sourceBuffer.count,
                                             nil,
                                             COMPRESSION_ZLIB)
        if size == 0 {
            return nil
        }
        
        var zipped = Data(capacity: size + 6) // ヘッダー: 2バイト, チェックサム: 4バイト
        zipped.append(contentsOf: [0x78, 0x5e]) // ヘッダーを追加
        zipped.append(destinationBuffer, count: size)
        
        let checksum = input.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> UInt32 in
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
        if (input.isEmpty) {
            return nil
        }
        
        // TODO: zip と同様に、 stream を利用して解凍する API への置き換えを検討する
        let bufferSize = 262_144
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        
        var sourceBuffer = [UInt8](input)
        
        // header を削除
        sourceBuffer.removeFirst(2)
        
        // checksum も削除
        let checksum = Data(sourceBuffer.suffix(4))
        sourceBuffer.removeLast(4)
        
        let size = compression_decode_buffer(destinationBuffer, bufferSize,
                                             &sourceBuffer, sourceBuffer.count,
                                             nil,
                                             COMPRESSION_ZLIB)
        
        if size == 0 {
            return nil
        }
        
        let data = Data(referencing: NSData(bytes: destinationBuffer, length: size))
        
        let calculatedChecksum = data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Data in
            let bytef = p.baseAddress!.assumingMemoryBound(to: Bytef.self)
            var result = UInt32(adler32(1, bytef, UInt32(data.count))).bigEndian
            return Data(bytes: &result, count: MemoryLayout<UInt32>.size)
        }
        
        // checksum の検証が成功したら data を返す
        return checksum == calculatedChecksum ? data : nil
    }
}

class BasicDataChannelDelegate: NSObject, RTCDataChannelDelegate {
    
    let compress: Bool
    weak var peerChannel: BasicPeerChannel?
    weak var mediaChannel: MediaChannel?
    
    init(compress: Bool, mediaChannel: MediaChannel?, peerChannel: BasicPeerChannel?) {
        self.compress = compress
        self.mediaChannel = mediaChannel
        self.peerChannel = peerChannel
    }
    
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Logger.debug(type: .dataChannel, message: "\(#function): label => \(dataChannel.label), state => \(dataChannel.readyState.rawValue)")
        
        if dataChannel.readyState == RTCDataChannelState.closed {
            if let handler = peerChannel?.handlers.onCloseDataChannel {
                handler(dataChannel.label)
            }
            
            if let mediaChannel = mediaChannel, let handler = mediaChannel.handlers.onCloseDataChannel {
                handler(mediaChannel, dataChannel.label)
            }
        }
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        Logger.debug(type: .dataChannel, message: "\(#function): label => \(dataChannel.label), amount => \(amount)")

        if let handler = peerChannel?.handlers.onDataChannelBufferedAmount {
            handler(dataChannel.label, amount)
        }
        
        if let mediaChannel = mediaChannel, let handler = mediaChannel.handlers.onDataChannelBufferedAmount {
            handler(mediaChannel, dataChannel.label, amount)
        }
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Logger.debug(type: .dataChannel, message: "\(#function): label => \(dataChannel.label)")
        
        guard let peerChannel = peerChannel else {
            Logger.error(type: .dataChannel, message: "peerChannel is unavailable")
            return
        }
        
        guard let dc = peerChannel.dataChannelInstances[dataChannel.label] else {
            Logger.error(type: .dataChannel, message: "DataChannel for label: \(dataChannel.label) is unavailable")
            return
        }
        
        guard let data = dc.compress ? ZLibUtil.unzip(buffer.data) : buffer.data else {
            Logger.error(type: .dataChannel, message: "failed to decompress data channel message")
            return
        }
        
        guard let message = String(data: data, encoding: .utf8) else {
            Logger.error(type: .dataChannel, message: "failed to convert data to message")
            return
        }
        Logger.info(type: .dataChannel, message: "received data channel message: \(String(describing: message))")
        
        switch dataChannel.label {
        case "stats":
            peerChannel.context.nativeChannel.statistics {
                // NOTE: stats の型を Signaling.swift に定義していない
                let reports = Statistics(contentsOf: $0).jsonObject
                let json: [String: Any] = ["type": "stats",
                                           "reports": reports]
                do {
                    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
                    dc.send(data)
                } catch {
                    Logger.error(type: .dataChannel, message: "failed to encode statistic data to json")
                }
            }
            
        case "push", "notify":
            break
        case "signaling":
            do {
                let reOffer = try JSONDecoder().decode(SignalingReOffer.self, from: data)
                peerChannel.context.createAndSendReAnswerOnDataChannel(forReOffer: reOffer.sdp)
            } catch {
                Logger.error(type: .dataChannel, message: "failed to decode SignalingReOffer")
            }
        case "e2ee":
            Logger.error(type: .dataChannel, message: "NOT IMPLEMENTED: label => \(dataChannel.label)")
        default:
            Logger.error(type: .dataChannel, message: "unknown data channel label: \(dataChannel.label)")
        }
        
        if let handler = peerChannel.handlers.onDataChannelMessage {
            handler(dataChannel.label, data)
        }
        
        if let mediaChannel = mediaChannel, let handler = mediaChannel.handlers.onDataChannelMessage {
            handler(mediaChannel, dataChannel.label, data)
        }
    }
}

class DataChannel {
    
    let native: RTCDataChannel
    let delegate: BasicDataChannelDelegate
    
    init(dataChannel: RTCDataChannel, compress: Bool, mediaChannel: MediaChannel?, peerChannel: BasicPeerChannel?) {
        Logger.info(type: .dataChannel, message: "initialize DataChannel: label => \(dataChannel.label), compress => \(compress)")
        native = dataChannel
        self.delegate = BasicDataChannelDelegate(compress: compress, mediaChannel: mediaChannel, peerChannel: peerChannel)
        native.delegate = self.delegate
    }
    
    var label: String {
        return native.label
    }
    
    var compress: Bool {
        return delegate.compress
    }

    func send(_ data: Data) {
        Logger.debug(type: .dataChannel, message: "\(String(describing:type(of: self))):\(#function): label => \(label), data => \(data.base64EncodedString())")

        guard let data = compress ? ZLibUtil.zip(data) : data else {
            Logger.error(type: .dataChannel, message: "failed to compress message")
            return
        }
        native.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
}
