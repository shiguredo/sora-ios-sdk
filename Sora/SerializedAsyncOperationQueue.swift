import Foundation

/// 非同期操作を、それぞれの完了まで含めて投入順に直列化します。
final class SerializedAsyncOperationQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var nextOperationID: UInt64 = 0
  private var tail: (id: UInt64, task: Task<Void, Never>)?

  /// 直前の操作完了後に処理を実行する Task を返します。
  @discardableResult
  func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    lock.lock()
    nextOperationID += 1
    let operationID = nextOperationID
    let previousTask = tail?.task
    let task = Task.detached { [weak self] in
      await previousTask?.value
      await operation()
      self?.finish(operationID: operationID)
    }
    tail = (operationID, task)
    lock.unlock()
    return task
  }

  /// 直前の操作完了後に値を返す処理を実行します。
  func perform<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
    await withCheckedContinuation { continuation in
      enqueue {
        continuation.resume(returning: await operation())
      }
    }
  }

  /// 直前の操作完了後に、エラーを返し得る処理を実行します。
  func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      enqueue {
        do {
          continuation.resume(returning: try await operation())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// 最後の操作が完了した時点で Task の保持を解きます。
  private func finish(operationID: UInt64) {
    lock.lock()
    if tail?.id == operationID {
      tail = nil
    }
    lock.unlock()
  }
}
