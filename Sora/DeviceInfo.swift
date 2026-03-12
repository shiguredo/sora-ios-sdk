import Foundation

/// :nodoc:
func currentMachineName() -> String {
  let machineKey = "hw.machine"
  let machineKeyPtr = UnsafeMutableBufferPointer<Int8>
    .allocate(capacity: machineKey.utf8CString.count)
  _ = machineKeyPtr.initialize(from: machineKey.utf8CString)
  var machineNameLen = 0
  sysctlbyname(machineKeyPtr.baseAddress!, nil, &machineNameLen, nil, 0)
  let machineNamePtr = UnsafeMutableBufferPointer<Int8>
    .allocate(capacity: machineNameLen)
  sysctlbyname(
    machineKeyPtr.baseAddress!,
    machineNamePtr.baseAddress!,
    &machineNameLen, nil, 0)
  let machineName = String.init(cString: machineNamePtr.baseAddress!)
  machineKeyPtr.deallocate()
  machineNamePtr.deallocate()
  return machineName
}

/// :nodoc:
func currentSystemVersion() -> String {
  let version = ProcessInfo.processInfo.operatingSystemVersion
  return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
}

/// :nodoc:
func currentSystemName() -> String {
  #if targetEnvironment(macCatalyst)
    return "macOS"
  #else
    return "iOS"
  #endif
}

/// :nodoc:
public struct DeviceInfo: Sendable {
  // 公開 API 互換性維持のため writable のままにします。
  // `nonisolated(unsafe)` はスレッド安全性をコンパイラが検証しないため、
  // 利用側が同時書き換えを行わない前提です。
  nonisolated(unsafe) public static var current: DeviceInfo = .init(
    machineName: currentMachineName(),
    systemName: currentSystemName(),
    systemVersion: currentSystemVersion())

  public let machineName: String
  public let systemName: String
  public let systemVersion: String

  public var description: String {
    "\(machineName); \(systemName) \(systemVersion)"
  }

  init(machineName: String, systemName: String, systemVersion: String) {
    self.machineName = machineName
    self.systemName = systemName
    self.systemVersion = systemVersion
  }
}
