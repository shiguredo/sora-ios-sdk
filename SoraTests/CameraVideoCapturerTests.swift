import CoreMedia
import XCTest

@testable import Sora

/// `CameraVideoCapturer` の flip の解像度決定と目標解像度の読み書きを検証します。
final class CameraVideoCapturerTests: XCTestCase {
  /// 目標解像度が設定されている場合はその寸法を返すことを確認する
  func testFlipTargetDimensionsUsesTargetResolution() {
    let dimensions = CameraVideoCapturer.flipTargetDimensions(
      targetResolution: .hd1080p,
      currentDimensions: CMVideoDimensions(width: 1280, height: 720))

    XCTAssertEqual(dimensions.width, 1920, "目標解像度の幅を返すこと")
    XCTAssertEqual(dimensions.height, 1080, "目標解像度の高さを返すこと")
  }

  /// 目標解像度が未設定の場合は現在のフォーマットの寸法を返すことを確認する
  func testFlipTargetDimensionsFallsBackToCurrentDimensions() {
    let current = CMVideoDimensions(width: 1280, height: 720)
    let dimensions = CameraVideoCapturer.flipTargetDimensions(
      targetResolution: nil,
      currentDimensions: current)

    XCTAssertEqual(dimensions.width, current.width, "現在のフォーマットの幅を返すこと")
    XCTAssertEqual(dimensions.height, current.height, "現在のフォーマットの高さを返すこと")
  }

  /// capturer の目標解像度が owner 経由で読み書きされることを確認する
  func testCapturerTargetResolutionUsesOwner() throws {
    try XCTSkipIf(
      CameraVideoCapturer.devices.isEmpty, "実カメラが無いため capturer を生成できません")
    let device = try XCTUnwrap(CameraVideoCapturer.devices.first)
    let capturer = CameraVideoCapturer(device: device)

    capturer.targetResolution = .hd1080p
    XCTAssertEqual(capturer.targetResolution, .hd1080p, "設定した目標解像度を読み出せること")
    XCTAssertEqual(
      CameraStateOwner.shared.targetResolution(id: capturer.id), .hd1080p,
      "owner に目標解像度が保持されること")

    capturer.targetResolution = nil
    XCTAssertNil(capturer.targetResolution, "nil を設定すると未設定に戻ること")
    XCTAssertNil(
      CameraStateOwner.shared.targetResolution(id: capturer.id),
      "owner の目標解像度が未設定に戻ること")
  }
}
