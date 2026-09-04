import AVFoundation
import Foundation
import WebRTC

/// 接続が利用する AudioUnit の種類を表します。
enum AudioSessionProfile: Equatable {
  case voiceProcessing
  case stereoRemoteIO
  case custom
}

/// 接続が必要とする音声セッションの利用方法を表します。
enum AudioSessionUsage {
  case none
  case voiceProcessing(requiresPlayAndRecord: Bool)
  case stereoRemoteIO
  case custom

  var profile: AudioSessionProfile? {
    switch self {
    case .none:
      return nil
    case .voiceProcessing:
      return .voiceProcessing
    case .stereoRemoteIO:
      return .stereoRemoteIO
    case .custom:
      return .custom
    }
  }

  var requiresPlayAndRecord: Bool {
    switch self {
    case .voiceProcessing(let requiresPlayAndRecord):
      return requiresPlayAndRecord
    case .stereoRemoteIO:
      return true
    case .none, .custom:
      return false
    }
  }

  var stereoPlayoutEnabled: Bool {
    if case .stereoRemoteIO = self {
      return true
    }
    return false
  }
}

/// 複数の接続が共有する libwebrtc の音声セッション設定を管理します。
///
/// AudioUnit profile の競合を接続開始前に検出します。また、最初の要求で
/// `RTCAudioSessionConfiguration` template の元のカテゴリを保存し、最後の要求が
/// 解放された時点で元に戻します。
final class AudioSessionCoordinator: @unchecked Sendable {
  static let shared = AudioSessionCoordinator()

  private let lock = NSLock()
  private var activeProfiles: [UUID: AudioSessionProfile] = [:]
  private var playAndRecordRequirementIDs: Set<UUID> = []
  private var pendingPlayAndRecordRequirementIDs: Set<UUID> = []
  private var originalCategory: String?

  /// AudioUnit profile を予約します。
  ///
  /// WebRTC-Build m150.7871.3.2 では複数の RemoteIO が同時に AudioSession mode を
  /// 再設定すると共有 template を壊す可能性があります。そのため stereo RemoteIO は
  /// 1 接続に限定し、他の音声接続とも排他にします。
  func acquire(
    profile: AudioSessionProfile,
    requiresPlayAndRecord: Bool = false
  ) throws -> AudioSessionRequirement {
    lock.lock()
    defer { lock.unlock() }

    switch profile {
    case .stereoRemoteIO:
      guard activeProfiles.isEmpty else {
        throw SoraError.connectionBusy(
          reason: "stereo audio output cannot be used while another audio connection is active")
      }
    case .voiceProcessing, .custom:
      guard !activeProfiles.values.contains(.stereoRemoteIO) else {
        throw SoraError.connectionBusy(
          reason: "another audio connection cannot be used while stereo audio output is active")
      }
    }

    // category の初回変更は、既存 ADM が存在しない状態に限定する。
    // これにより libwebrtc が共有 template を読み書きしている間に、SDK が
    // nonatomic な category を変更するデータ競合を防ぐ。
    if requiresPlayAndRecord, originalCategory == nil, !activeProfiles.isEmpty {
      throw SoraError.connectionBusy(
        reason:
          "an audio connection requiring PlayAndRecord cannot start while another audio connection is active"
      )
    }
    // 最初の要求が category を確定する前は、別接続の ADM を生成させない。
    guard pendingPlayAndRecordRequirementIDs.isEmpty else {
      throw SoraError.connectionBusy(
        reason: "audio session category configuration is in progress")
    }

    let id = UUID()
    activeProfiles[id] = profile
    if requiresPlayAndRecord {
      pendingPlayAndRecordRequirementIDs.insert(id)
    }
    return AudioSessionRequirement(id: id, coordinator: self)
  }

  /// テストで、接続が保持する profile の要求数を確認するために利用します。
  var activeRequirementCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return activeProfiles.count
  }

  /// テストで、カテゴリを必要とする要求数を確認するために利用します。
  var activePlayAndRecordRequirementCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return playAndRecordRequirementIDs.count
  }

  fileprivate func requirePlayAndRecord(id: UUID) {
    lock.lock()
    defer { lock.unlock() }

    guard activeProfiles[id] != nil else {
      return
    }
    guard
      pendingPlayAndRecordRequirementIDs.remove(id) != nil
        || playAndRecordRequirementIDs.contains(id)
    else {
      return
    }
    guard playAndRecordRequirementIDs.insert(id).inserted else {
      return
    }

    let configuration = RTCAudioSessionConfiguration.webRTC()
    if playAndRecordRequirementIDs.count == 1 {
      originalCategory = configuration.category
      configuration.category = AVAudioSession.Category.playAndRecord.rawValue
    }
  }

  fileprivate func release(id: UUID) {
    lock.lock()
    defer { lock.unlock() }

    guard activeProfiles.removeValue(forKey: id) != nil else {
      return
    }
    pendingPlayAndRecordRequirementIDs.remove(id)
    playAndRecordRequirementIDs.remove(id)

    // 一度変更した共有 template は、要求元だけでなく全 ADM が破棄されるまで維持する。
    // category の復元と libwebrtc による template 参照を並行させないため、
    // profile が 1 つでも残っている間は復元しない。
    guard activeProfiles.isEmpty else {
      return
    }

    if let originalCategory {
      RTCAudioSessionConfiguration.webRTC().category = originalCategory
      self.originalCategory = nil
    }
    playAndRecordRequirementIDs.removeAll()
    pendingPlayAndRecordRequirementIDs.removeAll()
  }
}

/// 音声セッションに対する 1 接続分の要求を表します。
final class AudioSessionRequirement: @unchecked Sendable {
  private let id: UUID
  private let coordinator: AudioSessionCoordinator

  fileprivate init(id: UUID, coordinator: AudioSessionCoordinator) {
    self.id = id
    self.coordinator = coordinator
  }

  /// `playAndRecord` カテゴリの利用を登録します。
  func requirePlayAndRecord() {
    coordinator.requirePlayAndRecord(id: id)
  }

  /// 要求を解放します。同じ要求を複数回解放しても状態は変化しません。
  func release() {
    coordinator.release(id: id)
  }

  deinit {
    release()
  }
}
