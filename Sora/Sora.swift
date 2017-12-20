import Foundation
import WebRTC

/// `Sora` オブジェクトのイベントハンドラです。
public final class SoraHandlers {
    
    /// 接続成功時に呼ばれるブロック
    public var onConnectHandler: ((MediaChannel?, Error?) -> Void)?
    
    /// 接続解除時に呼ばれるブロック
    public var onDisconnectHandler: ((MediaChannel, Error?) -> Void)?
    
    /// メディアチャネルが追加されたときに呼ばれるブロック
    public var onAddMediaChannelHandler: ((MediaChannel) -> Void)?
    
    /// メディアチャネルが除去されたときに呼ばれるブロック
    public var onRemoveMediaChannelHandler: ((MediaChannel) -> Void)?

}

/**
 サーバーへのインターフェースです。
 `Sora` オブジェクトを使用してサーバーへの接続を行います。
 */
public final class Sora {
    
    // MARK: - SDK の操作
    
    private static let isInitialized: Bool = {
        initialize()
        return true
    }()
    
    private static func initialize() {
        Logger.debug(type: .sora, message: "initialize SDK")
        RTCInitializeSSL()
        RTCEnableMetrics()
    }
    
    /**
     SDK の終了処理を行います。
     アプリケーションの終了と同時に SDK の使用を終了する場合、
     この関数を呼ぶ必要はありません。
     */
    public static func finish() {
        Logger.debug(type: .sora, message: "finish SDK")
        RTCShutdownInternalTracer()
        RTCCleanupSSL()
    }
    
    /**
     ログレベル。指定したレベルより高いログは出力されません。
     デフォルトは `info` です。
     */
    public static var logLevel: LogLevel {
        get {
            return Logger.shared.level
        }
        set {
            Logger.shared.level = newValue
        }
    }
    
    // MARK: - プロパティ
    
    /// リンクしている WebRTC フレームワークの情報。
    /// Sora iOS SDK が指定するバイナリでなければ ``nil`` 。
    public let webRTCInfo: WebRTCInfo? = WebRTCInfo.load()

    /// 接続中のメディアチャネルのリスト
    public private(set) var mediaChannels: [MediaChannel] = []
    
    /// イベントハンドラ
    public let handlers: SoraHandlers = SoraHandlers()
    
    // MARK: - インスタンスの生成と取得
    
    /// シングルトンインスタンス
    public static let shared: Sora = Sora()
    
    /**
     初期化します。
     大抵の用途ではシングルトンインスタンスで問題なく、
     インスタンスを生成する必要はないでしょう。
     メディアチャネルのリストをグループに分けたい、
     または複数のイベントハンドラを使いたいなどの場合に
     インスタンスを生成してください。
     */
    public init() {
        // This will guarantee that `Sora.initialize()` is called only once.
        // - It works even if user initialized `Sora` directly
        // - It works even if user directly use `Sora.shared`
        // - It guarantees `initialize()` is called only once thanks to the `static let` https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Properties.html#//apple_ref/doc/uid/TP40014097-CH14-ID254
        let initialized = Sora.isInitialized
        // This looks silly, but this will ensure `Sora.isInitialized` is not be omitted,
        // no matter how clang optimizes compilation.
        // If we go for `let _ = Sora.isInitialized`, clang may omit this line,
        // which is fatal to the initialization logic.
        // The following line will NEVER fail.
        if !initialized { fatalError() }
    }
    
    // MARK: - メディアチャネルの管理
    
    func add(mediaChannel: MediaChannel) {
        if !mediaChannels.contains(mediaChannel) {
            Logger.debug(type: .sora, message: "add media channel")
            mediaChannels.append(mediaChannel)
            handlers.onAddMediaChannelHandler?(mediaChannel)
        }
    }
    
    func remove(mediaChannel: MediaChannel) {
        if mediaChannels.contains(mediaChannel) {
            Logger.debug(type: .sora, message: "remove media channel")
            mediaChannels.remove(mediaChannel)
            handlers.onAddMediaChannelHandler?(mediaChannel)
        }
    }
    
    // MARK: - 接続
    
    /**
     サーバーに接続します。
     
     - parameter configuration: クライアントの設定
     - parameter webRTCConfiguration: WebRTC の設定
     - parameter handler: 接続試行後に呼ばれるブロック。
     - parameter mediaChannel: (接続成功時のみ) メディアチャネル
     - parameter error: (接続失敗時のみ) エラー
     */
    public func connect(configuration: Configuration,
                        webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration(),
                        handler: @escaping (_ mediaChannel: MediaChannel?,
        _ error: Error?) -> Void) {
        Logger.debug(type: .sora, message: "connecting \(configuration.url.absoluteString)")
        let mediaChan = MediaChannel(manager: self, configuration: configuration)
        mediaChan.connect(webRTCConfiguration: webRTCConfiguration) { error in
            if let error = error {
                handler(nil, error)
                self.handlers.onConnectHandler?(nil, error)
                return
            }
            
            mediaChan.internalHandlers.onDisconnectHandler = { error in
                self.remove(mediaChannel: mediaChan)
                self.handlers.onDisconnectHandler?(mediaChan, error)
            }
            
            self.add(mediaChannel: mediaChan)
            handler(mediaChan, nil)
            self.handlers.onConnectHandler?(mediaChan, nil)
        }
    }
    
    // MARK: - 音声ユニットの操作
    
    /**
     * 音声ユニットの手動による初期化の可否。
     * ``false`` をセットした場合、音声トラックの生成時に音声ユニットが自動的に初期化されます。
     * (音声ユニットを使用するには ``audioEnabled`` に ``true`` をセットして初期化する必要があります)
     * ``true`` をセットした場合、音声ユニットは自動的に初期化されません。
     * デフォルトは ``false`` です。
     */
    public var usesManualAudio: Bool {
        get {
            return RTCAudioSession.sharedInstance().useManualAudio
        }
        set {
            RTCAudioSession.sharedInstance().useManualAudio = newValue
        }
    }
    
    /**
     * 音声ユニットの使用の可否。
     * このプロパティは ``usesManualAudio`` が ``true`` の場合のみ有効です。
     * デフォルトは ``false`` です。
     *
     * ``true`` をセットした場合、音声ユニットは必要に応じて初期化されます。
     * ``false`` をセットした場合、すでに音声ユニットが初期化済みで起動されていれば、
     * 音声ユニットを停止します。
     *
     * このプロパティを使用すると、音声ユニットの初期化によって
     * AVPlayer などによる再生中の音声が中断されてしまうことを防げます。
     */
    public var audioEnabled: Bool {
        get {
            return RTCAudioSession.sharedInstance().isAudioEnabled
        }
        set {
            RTCAudioSession.sharedInstance().isAudioEnabled = newValue
        }
    }
    
    /**
     * ``AVAudioSession`` の設定を変更する際に使います。
     * WebRTC で使用中のスレッドをロックします。
     * このメソッドは次のプロパティとメソッドの使用時に使ってください。
     *
     * - ``category``
     * - ``categoryOptions``
     * - ``mode``
     * - ``secondaryAudioShouldBeSilencedHint``
     * - ``currentRoute``
     * - ``maximumInputNumberOfChannels``
     * - ``maximumOutputNumberOfChannels``
     * - ``inputGain``
     * - ``inputGainSettable``
     * - ``inputAvailable``
     * - ``inputDataSources``
     * - ``inputDataSource``
     * - ``outputDataSources``
     * - ``outputDataSource``
     * - ``sampleRate``
     * - ``preferredSampleRate``
     * - ``inputNumberOfChannels``
     * - ``outputNumberOfChannels``
     * - ``outputVolume``
     * - ``inputLatency``
     * - ``outputLatency``
     * - ``ioBufferDuration``
     * - ``preferredIOBufferDuration``
     * - ``setCategory(_:withOptions:)``
     * - ``setMode(_:)``
     * - ``setInputGain(_:)``
     * - ``setPreferredSampleRate(_:)``
     * - ``setPreferredIOBufferDuration(_:)``
     * - ``setPreferredInputNumberOfChannels(_:)``
     * - ``setPreferredOutputNumberOfChannels(_:)``
     * - ``overrideOutputAudioPort(_:)``
     * - ``setPreferredInput(_:)``
     * - ``setInputDataSource(_:)``
     * - ``setOutputDataSource(_:)``
     *
     * - parameter block: ロック中に実行されるブロック
     */
    public func configureAudioSession(block: () -> Void) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        block()
        session.unlockForConfiguration()
    }
    
}
