// EXPECT-DIAGNOSTIC: SendableClosureCaptures
// 検査する契約: PutSignalingNotifyMetadataParams の Sendable は conditional のため、
// 型パラメータの Metadata が Sendable と分からない文脈では @Sendable closure へキャプチャできないこと。
// (Sendable な Metadata の場合に準拠することは SoraTests/SendableConformanceTests.swift が表明する)
// この file はどの target にも含めない。
import Sora

/// `Metadata` が `Sendable` と分からない文脈で、conditional `Sendable` が効かないことを確認する。
///
/// `Metadata: Codable` だけを要求し `Sendable` を要求しないため、関数本体では
/// `PutSignalingNotifyMetadataParams<Metadata>` が `Sendable` であることをコンパイラが証明できない。
/// この状態で `@Sendable` closure へキャプチャすると
/// `capture of 'params' with non-Sendable type 'PutSignalingNotifyMetadataParams<Metadata>'` になる。
///
/// この形では `Metadata` が非 `Sendable` であること自体を理由に `SendableMetatypes` の
/// warning も出るが、`make consumer-check-negative` が検査するのは `EXPECT-DIAGNOSTIC` の
/// group 名を持つ error であり、意図した診断は `SendableClosureCaptures` の方である。
func captureConditionalSendableMetadataParams<Metadata: Codable>(
  _ params: PutSignalingNotifyMetadataParams<Metadata>
) {
  let closure: @Sendable () -> Void = {
    _ = params
  }
  _ = closure
}
