import Foundation

/**
 `Sora` の `Configuration` 内で使用するプロトコルです。
 
 `Configuration` 内で `videoEnabled` が有効になっている際に、映像の配信とその停止を行う処理を提供します。
 */
public protocol VideoCapturerDevice {
    
    /// 映像を配信します
    func stream(to: MediaStream)
    
    /// 映像の配信を停止します
    func terminate()
    
}
