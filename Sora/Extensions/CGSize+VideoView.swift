import Foundation

extension CGSize {
    
    public func scaleAspectFill(contentsSize: CGSize) -> CGSize {
        let baseW = CGSize(width: width,
                           height: width * (contentsSize.height / contentsSize.width))
        let baseH = CGSize(width: height * (contentsSize.width / contentsSize.height),
                           height: height)
        return ([baseW, baseH].first { size in
            size.width >= width && size.height >= height
        }) ?? baseW
    }
    
    public func scaleAspectFit(contentsSize: CGSize) -> CGSize {
        let baseW = CGSize(width: width,
                           height: width * (contentsSize.height / contentsSize.width))
        let baseH = CGSize(width: height * (contentsSize.width / contentsSize.height),
                           height: height)
        return ([baseW, baseH].first { size in
            size.width <= width && size.height <= height
        }) ?? baseW
    }
    
    // 4:3
    public func scaleAspectStandard() -> CGSize {
        return CGSize(width: width, height: width / 4 * 3)
    }
    
    // 16:9
    public func scaleAspectWide() -> CGSize {
        return CGSize(width: width, height: width / 16 * 9)
    }
    
}
