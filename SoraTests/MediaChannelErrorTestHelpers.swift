import XCTest

@testable import Sora

// テスト用のヘルパーです。モックやスタブは使用せず、実装が返したエラーの値だけを使います。

/// `SoraError.mediaChannelError` の reason を取り出すテスト用ヘルパーです。
///
/// reason の文言は、`SoraError` がエラーの種別を構造化するまで唯一の判別材料です。実装側の
/// メッセージ定義を変更するときは、このヘルパーで理由を検証しているテストも合わせて更新して
/// ください。エラーが nil の場合、`SoraError` 以外のエラーの場合、`.mediaChannelError` 以外の
/// `SoraError` の場合は、呼び出し元のテストを失敗させます。
func mediaChannelErrorReason(
  _ error: Error?,
  file: StaticString = #filePath,
  line: UInt = #line
) -> String? {
  guard let soraError = error as? SoraError else {
    XCTFail("SoraError が返ること: \(String(describing: error))", file: file, line: line)
    return nil
  }
  guard case .mediaChannelError(let reason) = soraError else {
    XCTFail("mediaChannelError が返ること: \(soraError)", file: file, line: line)
    return nil
  }
  return reason
}
