import Foundation
import UIKit

/// :nodoc:
func currentMachineName() -> String {
  let machineKey = "hw.machine"
  let machineKeyPtr = UnsafeMutableBufferPointer<Int8>
    .allocate(capacity: machineKey.utf8CString.count)
  _ = machineKeyPtr.initialize(from: machineKey.utf8CString)
  var machineNameLen = 0
  // allocate 直後の UnsafeMutableBufferPointer は非 nil が保証される
  // swiftlint:disable:next force_unwrapping
  sysctlbyname(machineKeyPtr.baseAddress!, nil, &machineNameLen, nil, 0)
  let machineNamePtr = UnsafeMutableBufferPointer<Int8>
    .allocate(capacity: machineNameLen)
  sysctlbyname(
    // allocate 直後の UnsafeMutableBufferPointer は非 nil が保証される
    // swiftlint:disable:next force_unwrapping
    machineKeyPtr.baseAddress!,
    // allocate 直後の UnsafeMutableBufferPointer は非 nil が保証される
    // swiftlint:disable:next force_unwrapping
    machineNamePtr.baseAddress!,
    &machineNameLen, nil, 0)
  // allocate 直後の UnsafeMutableBufferPointer は非 nil が保証される
  // swiftlint:disable:next force_unwrapping
  let machineName = String.init(cString: machineNamePtr.baseAddress!)
  machineKeyPtr.deallocate()
  machineNamePtr.deallocate()
  return machineName
}

/// :nodoc:
func currentSystemInfo() -> (systemName: String, systemVersion: String) {
  // main thread で DispatchQueue.main.sync を呼ぶとデッドロックするため分岐します。
  // 逆に off-main では MainActor.assumeIsolated を直接呼べないため、
  // main queue へ同期してから UIDevice.current を参照します。
  if Thread.isMainThread {
    return MainActor.assumeIsolated {
      (UIDevice.current.systemName, UIDevice.current.systemVersion)
    }
  }
  return DispatchQueue.main.sync {
    MainActor.assumeIsolated {
      (UIDevice.current.systemName, UIDevice.current.systemVersion)
    }
  }
}

/// :nodoc:
public struct DeviceInfo: Sendable {
  // 公開 API 互換性維持のため writable のままにします。
  // `nonisolated(unsafe)` はスレッド安全性をコンパイラが検証しないため、
  // 利用側が同時書き換えを行わない前提です。
  nonisolated(unsafe) public static var current: DeviceInfo = {
    let system = currentSystemInfo()
    return .init(
      machineName: currentMachineName(),
      systemName: system.systemName,
      systemVersion: system.systemVersion)
  }()

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
