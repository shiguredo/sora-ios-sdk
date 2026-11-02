import Foundation
import XCTest

@testable import Sora

/// 同梱したプライバシーマニフェストの配置と Required Reason API の申告内容を検証する
///
/// Sora ターゲットはシステム起動時刻 API (`ProcessInfo.processInfo.systemUptime` と
/// `mach_absolute_time()`) を利用するため、配布物の resource bundle 直下に
/// `PrivacyInfo.xcprivacy` を同梱する必要がある。同梱が外れたり、宣言したカテゴリや
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
      Set(reasons), Set(["35F9.1", "8FFB.1"]),
      "理由コードが利用用途 (フレーム間隔の判定 = 35F9.1、絶対タイムスタンプの算出 = 8FFB.1) に対応すること")
    XCTAssertEqual(
      manifest["NSPrivacyTracking"] as? Bool, false,
      "トラッキングを行わないことを宣言していること")
  }
}
