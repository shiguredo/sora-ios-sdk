// 検査する契約:
//   - Sora.subscribeEvents(bufferingPolicy:) を nonisolated な文脈から呼べること
//   - MediaChannel.subscribeEvents(bufferingPolicy:) を nonisolated な文脈から呼べること
//   - 戻り値の AsyncStream<SoraEvent> を Task の境界へ渡せること (SoraEvent が Sendable であること)
//   - SoraEventKind を等価比較と default を伴う switch で判定できること
//     (SDK が種別を追加しても switch が網羅でなくてよいこと)
//   - SoraEvent の payload を nonisolated な文脈で読めること
//   - @MainActor の文脈から購読できること
//   - nonisolated な actor の境界へ購読した stream を渡し、actor でイベントを消費できること
// 期待する診断: なし (error 0 件、warning 0 件)
import AVFoundation
import Foundation
import Sora

/// Sora インスタンスのイベントを購読し、最初の 1 件を受け取る。
func firstSoraEvent(from sora: Sora) async -> SoraEvent? {
  var iterator = sora.subscribeEvents().makeAsyncIterator()
  return await iterator.next()
}

/// MediaChannel のイベントを buffer 方針つきで購読し、最初の 1 件を受け取る。
func firstChannelEvent(from mediaChannel: MediaChannel) async -> SoraEvent? {
  var iterator = mediaChannel.subscribeEvents(bufferingPolicy: .bufferingNewest(64))
    .makeAsyncIterator()
  return await iterator.next()
}

/// 購読した stream を Task の境界へ渡し、最初の 1 件を受け取る。
/// SoraEvent が Sendable でない場合、この関数はコンパイルできない。
func firstChannelEventThroughTask(from mediaChannel: MediaChannel) async -> SoraEvent? {
  let stream = mediaChannel.subscribeEvents()
  return await Task { () -> SoraEvent? in
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
  }.value
}

/// イベントの種別を判定する。
/// SoraEventKind は RawRepresentable な struct のため、switch には default が必要になる。
func describeEvent(_ event: SoraEvent) -> String {
  switch event.kind {
  case .connected:
    return "connected"
  case .disconnected:
    return "disconnected"
  default:
    return event.kind.rawValue
  }
}

/// イベントの種別を等価比較で判定する。
func isDisconnected(_ event: SoraEvent) -> Bool {
  event.kind == .disconnected
}

/// イベントの payload を読む。
func readEventPayload(_ event: SoraEvent) -> (String?, UInt64, SoraEventError?) {
  (event.connectionId, event.sequence, event.error)
}

/// 音声入出力ルートのイベント payload を読む。
func readAudioRoute(_ event: SoraEvent) -> (AVAudioSession.RouteChangeReason, Int)? {
  guard let audioRoute = event.audioRoute else {
    return nil
  }
  return (audioRoute.reason, audioRoute.previousRoute.inputs.count)
}

/// @MainActor の文脈から購読し、最初の 1 件を受け取る。
@MainActor
func firstChannelEventOnMainActor(from mediaChannel: MediaChannel) async -> SoraEvent? {
  var iterator = mediaChannel.subscribeEvents().makeAsyncIterator()
  return await iterator.next()
}

/// nonisolated な actor で購読した stream を消費する scenario。
actor SoraEventActorScenario {
  /// 購読した stream から最初の 1 件を受け取る。
  ///
  /// `AsyncStream` は `Sendable` のため actor の境界を越えて渡せる。
  func firstEvent(in stream: AsyncStream<SoraEvent>) async -> SoraEvent? {
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
  }
}

/// 接続ごとのイベントを購読し、nonisolated な actor へ stream を渡して消費する。
func firstChannelEventInActor(from mediaChannel: MediaChannel) async -> SoraEvent? {
  let stream = mediaChannel.subscribeEvents()
  return await SoraEventActorScenario().firstEvent(in: stream)
}
