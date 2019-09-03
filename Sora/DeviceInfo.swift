import Foundation
import UIKit

// :nodoc:
public enum DeviceModel {

    case unknown(String)
    case iPhone1st
    case iPhone3G
    case iPhone3GS
    case iPhone4
    case iPhone4GSM
    case iPhone4CDMA
    case iPhone4S
    case iPhone4SGSM
    case iPhone4SCDMA
    case iPhone5GSM
    case iPhone5CDMA
    case iPhone5CGSM
    case iPhone5CCDMA
    case iPhone5SGSM
    case iPhone5SCDMA
    case iPhone6Plus
    case iPhone6
    case iPhone6S
    case iPhone6SPlus
    case iPhoneSE
    case iPhone7
    case iPhone7Plus
    case iPhone7GSM
    case iPhone7PlusGSM
    case iPhone8
    case iPhone8Plus
    case iPhoneX
    case iPhone8GSM
    case iPhone8PlusGSM
    case iPhoneXGSM
    case iPhoneXS
    case iPhoneXSMax
    case iPhoneXR
    case iPodTouch1st
    case iPodTouch2nd
    case iPodTouch3rd
    case iPodTouch4th
    case iPodTouch5th
    case iPodTouch6th
    case iPodTouch7th
    case iPad
    case iPad2WiFi
    case iPad2GSM
    case iPad2CDMA
    case iPad2WiFi2
    case iPadMiniWiFi
    case iPadMiniGSM
    case iPadMiniCDMA
    case iPad3rdWiFi
    case iPad3rdCDMA
    case iPad3rdGSM
    case iPad4thWiFi
    case iPad4thGSM
    case iPad4thCDMA
    case iPadAirWiFi
    case iPadAirGSM
    case iPadAirLTE
    case iPadMini2WiFi
    case iPadMini2GSM
    case iPadMini2LTE
    case iPadMini3WiFi
    case iPadMini3GSM
    case iPadMini3LTE
    case iPadMini4WiFi
    case iPadMini4GSM
    case iPadPro9InchWiFi
    case iPadPro9InchGSM
    case iPadPro12InchWiFi
    case iPadPro12InchGSM
    case iPad5thWiFi
    case iPad5thGSM
    case iPadPro12Inch2ndWiFi
    case iPadPro12Inch2ndGSM
    case iPadPro10InchWiFi
    case iPadPro10InchGSM
    case iPad6thWiFi
    case iPad6thGSM
    case iPadPro11InchWiFi
    case iPadPro11InchGSM
    case iPadPro12Inch3rdWiFi
    case iPadPro12Inch3rdGSM
    case iPadMini5thWiFi
    case iPadMini5thGSM
    case iPadAir3rdWiFi
    case iPadAir3rdGSM
    case simulatorI386
    case simulatorX86_64

    public init(machine: String) {
        let nameDict: [String: DeviceModel] = [
            "iPhone1,1": .iPhone1st,
            "iPhone1,2": .iPhone3G,
            "iPhone2,1": .iPhone3GS,
            "iPhone3,1": .iPhone4,
            "iPhone3,2": .iPhone4GSM,
            "iPhone3,3": .iPhone4CDMA,
            "iPhone4,1": .iPhone4S,
            "iPhone4,2": .iPhone4SGSM,
            "iPhone4,3": .iPhone4SCDMA,
            "iPhone5,1": .iPhone5GSM,
            "iPhone5,2": .iPhone5CDMA,
            "iPhone5,3": .iPhone5CGSM,
            "iPhone5,4": .iPhone5CCDMA,
            "iPhone6,1": .iPhone5SGSM,
            "iPhone6,2": .iPhone5SCDMA,
            "iPhone7,1": .iPhone6Plus,
            "iPhone7,2": .iPhone6,
            "iPhone8,1": .iPhone6S,
            "iPhone8,2": .iPhone6SPlus,
            "iPhone8,4": .iPhoneSE,
            "iPhone9,1": .iPhone7,
            "iPhone9,2": .iPhone7Plus,
            "iPhone9,3": .iPhone7GSM,
            "iPhone9,4": .iPhone7PlusGSM,
            "iPhone10,1": .iPhone8,
            "iPhone10,2": .iPhone8Plus,
            "iPhone10,3": .iPhoneX,
            "iPhone10,4": .iPhone8GSM,
            "iPhone10,5": .iPhone8PlusGSM,
            "iPhone10,6": .iPhoneXGSM,
            "iPhone11,2": .iPhoneXS,
            "iPhone11,6": .iPhoneXSMax,
            "iPhone11,8": .iPhoneXR,
            "iPod1,1": .iPodTouch1st,
            "iPod2,1": .iPodTouch2nd,
            "iPod3,1": .iPodTouch3rd,
            "iPod4,1": .iPodTouch4th,
            "iPod5,1": .iPodTouch5th,
            "iPod7,1": .iPodTouch6th,
            "iPod9,1": .iPodTouch7th,
            "iPad1,1": .iPad,
            "iPad2,1": .iPad2WiFi,
            "iPad2,2": .iPad2GSM,
            "iPad2,3": .iPad2CDMA,
            "iPad2,4": .iPad2WiFi2,
            "iPad2,5": .iPadMiniWiFi,
            "iPad2,6": .iPadMiniGSM,
            "iPad2,7": .iPadMiniCDMA,
            "iPad3,1": .iPad3rdWiFi,
            "iPad3,2": .iPad3rdCDMA,
            "iPad3,3": .iPad3rdGSM,
            "iPad3,4": .iPad4thWiFi,
            "iPad3,5": .iPad4thGSM,
            "iPad3,6": .iPad4thCDMA,
            "iPad4,1": .iPadAirWiFi,
            "iPad4,2": .iPadAirGSM,
            "iPad4,3": .iPadAirLTE,
            "iPad4,4": .iPadMini2WiFi,
            "iPad4,5": .iPadMini2GSM,
            "iPad4,6": .iPadMini2LTE,
            "iPad4,7": .iPadMini3WiFi,
            "iPad4,8": .iPadMini3GSM,
            "iPad4,9": .iPadMini3LTE,
            "iPad5,1": .iPadMini4WiFi,
            "iPad5,2": .iPadMini4GSM,
            "iPad6,3": .iPadPro9InchWiFi,
            "iPad6,4": .iPadPro9InchGSM,
            "iPad6,7": .iPadPro12InchWiFi,
            "iPad6,8": .iPadPro12InchGSM,
            "iPad6,11": .iPad5thWiFi,
            "iPad6,12": .iPad5thGSM,
            "iPad7,1": .iPadPro12Inch2ndWiFi,
            "iPad7,2": .iPadPro12Inch2ndGSM,
            "iPad7,3": .iPadPro10InchWiFi,
            "iPad7,4": .iPadPro10InchGSM,
            "iPad7,5": .iPad6thWiFi,
            "iPad7,6": .iPad6thGSM,
            "iPad8,1": .iPadPro11InchWiFi,
            "iPad8,2": .iPadPro11InchWiFi,
            "iPad8,3": .iPadPro11InchGSM,
            "iPad8,4": .iPadPro11InchGSM,
            "iPad8,5": .iPadPro12Inch3rdWiFi,
            "iPad8,6": .iPadPro12Inch3rdWiFi,
            "iPad8,7": .iPadPro12Inch3rdGSM,
            "iPad8,8": .iPadPro12Inch3rdGSM,
            "iPad11,1": .iPadMini5thWiFi,
            "iPad11,2": .iPadMini5thGSM,
            "iPad11,3": .iPadAir3rdWiFi,
            "iPad11,4": .iPadAir3rdGSM,
            "i386": .simulatorI386,
            "x86_64": .simulatorX86_64,
        ]

        if let model = nameDict[machine] {
            self = model
        } else {
            self = .unknown(machine)
        }
    }

    public static func current() -> DeviceModel {
        let machineKey = "hw.machine"
        let machineKeyPtr = UnsafeMutableBufferPointer<Int8>
            .allocate(capacity: machineKey.utf8CString.count)
        let _ = machineKeyPtr.initialize(from: machineKey.utf8CString)
        var machineNameLen = 0
        sysctlbyname(machineKeyPtr.baseAddress!, nil, &machineNameLen, nil, 0)
        let machineNamePtr = UnsafeMutableBufferPointer<Int8>
            .allocate(capacity: machineNameLen)
        sysctlbyname(machineKeyPtr.baseAddress!,
                     machineNamePtr.baseAddress!,
                     &machineNameLen, nil, 0)
        let machineName = String.init(cString: machineNamePtr.baseAddress!)
        machineKeyPtr.deallocate()
        machineNamePtr.deallocate()
        return DeviceModel(machine: machineName)
    }

    public var name: String {
        get {
            switch self {
            case .unknown(let name):
                return "Unknown (\(name))"
            case .iPhone1st:
                return "iPhone (1st)"
            case .iPhone3G:
                return "iPhone 3G"
            case .iPhone3GS:
                return "iPhone 3GS"
            case .iPhone4:
                return "iPhone 4"
            case .iPhone4GSM:
                return "iPhone 4 (GSM)"
            case .iPhone4CDMA:
                return "iPhone 4 (CDMA)"
            case .iPhone4S:
                return "iPhone 4S"
            case .iPhone4SGSM:
                return "iPhone 4S (GSM)"
            case .iPhone4SCDMA:
                return "iPhone 4S (CDMA)"
            case .iPhone5GSM:
                return "iPhone 5 (GSM)"
            case .iPhone5CDMA:
                return "iPhone 5 (CDMA)"
            case .iPhone5CGSM:
                return "iPhone 5c (GSM)"
            case .iPhone5CCDMA:
                return "iPhone 5c (CDMA)"
            case .iPhone5SGSM:
                return "iPhone 5s (GSM)"
            case .iPhone5SCDMA:
                return "iPhone 5s (CDMA)"
            case .iPhone6Plus:
                return "iPhone 6 Plus"
            case .iPhone6:
                return "iPhone 6"
            case .iPhone6S:
                return "iPhone 6s"
            case .iPhone6SPlus:
                return "iPhone 6s Plus"
            case .iPhoneSE:
                return "iPhone SE"
            case .iPhone7:
                return "iPhone 7"
            case .iPhone7Plus:
                return "iPhone 7 Plus"
            case .iPhone7GSM:
                return "iPhone 7 (GSM)"
            case .iPhone7PlusGSM:
                return "iPhone 7 Plus (GSM)"
            case .iPhone8:
                return "iPhone 8"
            case .iPhone8Plus:
                return "iPhone 8 Plus"
            case .iPhoneX:
                return "iPhone X"
            case .iPhone8GSM:
                return "iPhone 8 (GSM)"
            case .iPhone8PlusGSM:
                return "iPhone 8 Plus (GSM)"
            case .iPhoneXGSM:
                return "iPhone X (GSM)"
            case .iPhoneXS:
                return "iPhone XS"
            case .iPhoneXSMax:
                return "iPhone XS Max"
            case .iPhoneXR:
                return "iPhone XR"
            case .iPodTouch1st:
                return "iPod touch (1st)"
            case .iPodTouch2nd:
                return "iPod touch (2nd)"
            case .iPodTouch3rd:
                return "iPod touch (3rd)"
            case .iPodTouch4th:
                return "iPod touch (4th)"
            case .iPodTouch5th:
                return "iPod touch (5th)"
            case .iPodTouch6th:
                return "iPod touch (6th)"
            case .iPodTouch7th:
                return "iPod touch (7th)"
            case .iPad:
                return "iPad (1st)"
            case .iPad2WiFi:
                return "iPad 2 (Wi-Fi, [iPad2,1])"
            case .iPad2GSM:
                return "iPad 2 (GSM)"
            case .iPad2CDMA:
                return "iPad 2 (CDMA)"
            case .iPad2WiFi2:
                return "iPad 2 (Wi-Fi, [iPad2,4])"
            case .iPadMiniWiFi:
                return "iPad mini (1st, Wi-Fi)"
            case .iPadMiniGSM:
                return "iPad mini (1st, GSM)"
            case .iPadMiniCDMA:
                return "iPad mini (1st, CDMA)"
            case .iPad3rdWiFi:
                return "iPad (3rd, Wi-Fi)"
            case .iPad3rdCDMA:
                return "iPad (3rd, CDMA)"
            case .iPad3rdGSM:
                return "iPad (3rd, GSM)"
            case .iPad4thWiFi:
                return "iPad (4th, Wi-Fi)"
            case .iPad4thGSM:
                return "iPad (4th, GSM)"
            case .iPad4thCDMA:
                return "iPad (4th, CDMA)"
            case .iPadAirWiFi:
                return "iPad Air (Wi-Fi)"
            case .iPadAirGSM:
                return "iPad Air (GSM)"
            case .iPadAirLTE:
                return "iPad Air (LTE)"
            case .iPadMini2WiFi:
                return "iPad mini 2 (Wi-Fi)"
            case .iPadMini2GSM:
                return "iPad mini 2 (GSM)"
            case .iPadMini2LTE:
                return "iPad mini 2 (LTE)"
            case .iPadMini3WiFi:
                return "iPad mini 3 (Wi-Fi)"
            case .iPadMini3GSM:
                return "iPad mini 3 (GSM)"
            case .iPadMini3LTE:
                return "iPad mini 3 (LTE)"
            case .iPadMini4WiFi:
                return "iPad mini 4 (Wi-Fi)"
            case .iPadMini4GSM:
                return "iPad mini 4 (GSM)"
            case .iPadPro9InchWiFi:
                return "iPad Pro 9.7-inch (Wi-Fi)"
            case .iPadPro9InchGSM:
                return "iPad Pro 9.7-inch (GSM)"
            case .iPadPro12InchWiFi:
                return "iPad Pro 12.9-inch (Wi-Fi)"
            case .iPadPro12InchGSM:
                return "iPad Pro 12.9-inch (GSM)"
            case .iPad5thWiFi:
                return "iPad (5th, Wi-Fi)"
            case .iPad5thGSM:
                return "iPad (5th, GSM)"
            case .iPadPro12Inch2ndWiFi:
                return "iPad Pro 12.9-inch (2nd, Wi-Fi)"
            case .iPadPro12Inch2ndGSM:
                return "iPad Pro 12.9-inch (2nd, GSM)"
            case .iPadPro10InchWiFi:
                return "iPad Pro 10.5-inch (Wi-Fi)"
            case .iPadPro10InchGSM:
                return "iPad Pro 10.5-inch (GSM)"
            case .iPad6thWiFi:
                return "iPad (6th, Wi-Fi)"
            case .iPad6thGSM:
                return "iPad (6th, GSM)"
            case .iPadPro11InchWiFi:
                return "iPad Pro 11-inch (Wi-Fi)"
            case .iPadPro11InchGSM:
                return "iPad Pro 11-inch (GSM)"
            case .iPadPro12Inch3rdWiFi:
                return "iPad Pro 12-inch (3rd, Wi-Fi)"
            case .iPadPro12Inch3rdGSM:
                return "iPad Pro 12-inch (3rd, GSM)"
            case .iPadMini5thWiFi:
                return "iPad mini (5th, Wi-Fi)"
            case .iPadMini5thGSM:
                return "iPad mini (5th, GSM)"
            case .iPadAir3rdWiFi:
                return "iPad Air (3rd, Wi-Fi)"
            case .iPadAir3rdGSM:
                return "iPad Air (3rd, GSM)"
            case .simulatorI386:
                return "iOS Simulator (i386)"
            case .simulatorX86_64:
                return "iOS Simulator (x86_64)"
            }
        }
    }
    
}

// :nodoc:
public struct DeviceInfo {

    public static var current: DeviceInfo = {
        return DeviceInfo(device: UIDevice.current,
                          model: DeviceModel.current())
    }()

    public let model: DeviceModel

    public var description: String {
        get {
            return "\(model.name); \(device.systemName) \(device.systemVersion)"
        }
    }

    private let device: UIDevice

    init(device: UIDevice, model: DeviceModel) {
        self.model = model
        self.device = device
    }

}
