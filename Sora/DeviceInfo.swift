import Foundation
import SystemConfiguration

/// :nodoc:
public enum DeviceModel {

    case unknown(String)
    case simulatorI386
    case simulatorX86_64

    public init(machine: String) {
        let nameDict: [String: DeviceModel] = [
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
            case .simulatorI386:
                return "Simulator (i386)"
            case .simulatorX86_64:
                return "Simulator (x86_64)"
            }
        }
    }
    
}

/// :nodoc:
public struct DeviceInfo {

    public static var current: DeviceInfo = {
        return DeviceInfo(model: DeviceModel.current())
    }()

    public let model: DeviceModel

    public var description: String {
        get {
            return "\(model.name);"
        }
    }

    init(model: DeviceModel) {
        self.model = model
    }

}
