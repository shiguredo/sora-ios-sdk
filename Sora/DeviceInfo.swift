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
  // 逆に main thread 以外では MainActor.assumeIsolated を直接呼べないため、
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

/// `DeviceInfo.current` の初期 snapshot と、利用者が設定した値を保持する storage です。
///
/// `@unchecked Sendable` としている根拠は、保持する `DeviceInfo?` への全アクセスが
/// 単一の `NSLock` 区間であることです。この lock は葉として扱い、保持したまま
/// MainActor や main queue を同期 wait しません。
final class DeviceInfoStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: DeviceInfo?

  var value: DeviceInfo? {
    lock.lock()
    defer { lock.unlock() }
    return storedValue
  }

  /// storage が保持している値を返します。未設定の場合は `create` で生成します。
  ///
  /// `create` は lock を保持せずに呼び出し元の thread で実行します。次の契約に従うこと。
  /// - 設定済みの場合は `create` を呼びません。
  /// - 未設定の場合は `create` の結果を publish し、その値を返します。
  /// - 並行に複数回呼ばれ得ます。publish されるのは、生成後に publish 用の lock を最初に
  ///   取った 1 回の結果だけで、他の生成結果は破棄されます。
  /// - `create` の実行中に setter または別の呼び出しが値を publish した場合は、その値を
  ///   返します。
  /// - `create` から `current(create:)` を再帰呼び出ししないこと (publish 前に再入すると
  ///   `create` が再び呼ばれ、無限に再帰します)。
  /// - `create` から `set(_:)` を呼ぶことはできます。setter の値が優先されます。
  func current(create: () -> DeviceInfo) -> DeviceInfo {
    // 最初の lock 区間では値の確認だけを行い、publish は 2 回目の lock 区間で行います。
    // 生成はどちらの lock 区間でも行いません。
    if let value = self.value {
      return value
    }
    let created = create()
    lock.lock()
    defer { lock.unlock() }
    if let value = storedValue {
      return value
    }
    storedValue = created
    return created
  }

  /// 値を設定します。以後の取得はこの値を返します。
  func set(_ value: DeviceInfo) {
    lock.lock()
    defer { lock.unlock() }
    storedValue = value
  }
}

/// :nodoc:
public struct DeviceInfo: Sendable {
  /// 初期 snapshot と setter の値を保持する storage です。
  ///
  /// stored な `static var` は `nonisolated(unsafe)` を付けない限り Swift 6 で error に
  /// なるため、mutable な値は `static let` の storage に閉じ込めています。
  /// `static let` の初期化子では storage の生成だけを行います。ここで初期 snapshot を
  /// 生成すると、Swift の static 初期化ロックを保持したまま `currentSystemInfo()` が
  /// `DispatchQueue.main.sync` を呼び、main thread が同じ static 初期化を待つと deadlock する
  /// 経路があります。
  private static let storage = DeviceInfoStorage()

  /// 現在の端末情報です。
  ///
  /// getter / setter は SDK 内部の lock で保護され、任意の thread から読み書きできます。
  /// setter はプロセス全体の値に影響します。
  /// 初期 snapshot は未設定のまま最初の getter を呼んだときに生成します。setter が先に
  /// 呼ばれた場合は生成しません。
  /// 生成は storage の lock の外で行うため、storage の lock を保持したまま main queue を
  /// 待つことはありません。main thread 以外から呼んだ `currentSystemInfo()` は main queue へ同期するため、
  /// main thread を塞いだ状態から background thread が初回取得する呼び出し側の待ちは
  /// SDK では防げません。
  /// setter は source compatibility 維持のために残しています。
  public static var current: DeviceInfo {
    get {
      storage.current(create: DeviceInfo.makeSnapshot)
    }
    set {
      storage.set(newValue)
    }
  }

  /// 現在の端末情報から `DeviceInfo` を生成します。
  ///
  /// `current` の初期 snapshot の生成と、テストからの実生成経路の検証で共有します。
  /// main thread 以外から呼ぶと `currentSystemInfo()` が main queue へ同期するため、main queue を
  /// 停止させた状態から呼ばないこと。
  static func makeSnapshot() -> DeviceInfo {
    let system = currentSystemInfo()
    return DeviceInfo(
      machineName: currentMachineName(),
      systemName: system.systemName,
      systemVersion: system.systemVersion)
  }

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
