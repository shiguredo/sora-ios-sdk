import AVFoundation
import Foundation

/// 音声モード。
///  ``AVAudioSession`` の音声モードと音声カテゴリを変更します。
///  詳細な設定を行いたい場合は ``AVAudioSession`` を使用して下さい。
///
///  音声カテゴリのオプションは次の値が指定されます:
///
///  - ``allowBluetooth``
///  - ``allowBluetoothA2DP``
///  - ``allowAirPlay``
public enum AudioMode {
    /**
     * デフォルト。
     * ``AVAudioSession`` の音声モードを ``default`` に変更します。
     * 音声カテゴリを ``category`` の値に変更します。
     * 音声出力先の変更は、指定した音声出力先に音声カテゴリが対応している場合のみ有効です。
     * 詳細は ``AVAudioSession`` のドキュメントを参照して下さい。
     *
     * - parameter category: 音声カテゴリ
     * - parameter output: 音声出力先
     */
    case `default`(category: AVAudioSession.Category, output: AudioOutput)

    /**
     * ビデオチャット。
     * ``AVAudioSession`` の音声モードを ``videoChat`` に変更します。
     * 音声カテゴリを ``playAndRecord`` に変更します。
     * 音声はスピーカーから出力されます。
     */
    case videoChat

    /**
     * ボイスチャット。
     * ``AVAudioSession`` の音声モードを ``voiceChat`` に変更します。
     * 音声カテゴリを ``playAndRecord`` に変更します。
     *
     * - parameter output: 音声出力先
     */
    case voiceChat(output: AudioOutput)
}

/// 音声出力先
public enum AudioOutput {
    /// デフォルト。端末の状態に依存します。
    case `default`

    /// スピーカー
    case speaker

    var portOverride: AVAudioSession.PortOverride {
        switch self {
        case .default:
            return .none
        case .speaker:
            return .speaker
        }
    }
}
