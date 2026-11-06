import Foundation
import XCTest

@testable import Sora

/// 同梱したプライバシーマニフェストの配置と Required Reason API の申告内容を検証する
///
/// Sora ターゲットは画面キャプチャのフレーム間隔の判定のため、`CACurrentMediaTime()` で
/// 取得した時刻の差分から経過時間を測定している。`CACurrentMediaTime()` は内部で
/// `mach_absolute_time()` を呼ぶため、Required Reason API の SystemBootTime の理由コード
/// `35F9.1` (経過時間の測定) に該当する。`CACurrentMediaTime()` という名前は Apple の一覧に
/// ないものの、審査で指摘される可能性を否定できないため、配布物の resource bundle 直下に
/// `PrivacyInfo.xcprivacy` を同梱して利用理由を申告する。同梱が外れたり、宣言したカテゴリや
/// 理由コードが変わったりしても CI で気付けるよう、実物の bundle を検査する。
final class PrivacyManifestTests: XCTestCase {
  /// マニフェストが resource bundle 直下にあり、必要なカテゴリと理由だけを宣言していることを確認する
  func testManifestIsBundledWithSystemBootTimeReasons() throws {
    // SoraTests は resources を持たないため、@testable import Sora 経由で Sora の内部 accessor
    // (Bundle.module) を参照する。SoraTests に resources を追加するとテスト側の accessor が
    // 使われるようになり、Sora の resource bundle を検査できなくなる
    let bundleURL = Bundle.module.bundleURL
    let expectedURL = bundleURL.appendingPathComponent("PrivacyInfo.xcprivacy")
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
      "resource bundle に PrivacyInfo.xcprivacy が含まれていること")
    XCTAssertEqual(
      url.standardizedFileURL, expectedURL.standardizedFileURL,
      "PrivacyInfo.xcprivacy は resource bundle の直下に配置すること")

    let data = try Data(contentsOf: url)
    let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
    let manifest = try XCTUnwrap(
      propertyList as? [String: Any],
      "PrivacyInfo.xcprivacy が property list として読めること")
    let accessedAPITypes = try XCTUnwrap(
      manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
      "NSPrivacyAccessedAPITypes を宣言していること")
    XCTAssertEqual(
      accessedAPITypes.count, 1,
      "利用している Required Reason API のカテゴリだけを宣言していること")
    let accessedAPIType = try XCTUnwrap(
      accessedAPITypes.first,
      "Required Reason API のカテゴリを宣言していること")
    XCTAssertEqual(
      accessedAPIType["NSPrivacyAccessedAPIType"] as? String,
      "NSPrivacyAccessedAPICategorySystemBootTime",
      "宣言するカテゴリがシステム起動時刻 API であること")
    let reasons = try XCTUnwrap(
      accessedAPIType["NSPrivacyAccessedAPITypeReasons"] as? [String],
      "システム起動時刻 API の理由コードを宣言していること")
    XCTAssertEqual(
      Set(reasons), Set(["35F9.1"]),
      "理由コードが利用用途 (フレーム間隔の判定 = 35F9.1) に対応すること")
    XCTAssertEqual(
      manifest["NSPrivacyTracking"] as? Bool, false,
      "トラッキングを行わないことを宣言していること")
    let collectedDataTypes = try XCTUnwrap(
      manifest["NSPrivacyCollectedDataTypes"] as? [Any],
      "NSPrivacyCollectedDataTypes を宣言していること")
    XCTAssertEqual(
      collectedDataTypes.count, 0,
      "収集するデータがないことを宣言していること")
  }
}
