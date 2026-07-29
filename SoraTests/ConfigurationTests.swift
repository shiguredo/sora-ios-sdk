import XCTest

@testable import Sora

/// Configuration.caCertificate のテスト
///
/// PEM 解析の全ブロック成功必須（all-or-nothing）の仕様を検証する。
final class ConfigurationTests: XCTestCase {

  private static let validPEM = """
    -----BEGIN CERTIFICATE-----
    MIICmjCCAYICCQDJnKe/u7waBjANBgkqhkiG9w0BAQsFADAPMQ0wCwYDVQQDDAR0
    ZXN0MB4XDTI2MDYyNjAzMjM1NloXDTM2MDYyMzAzMjM1NlowDzENMAsGA1UEAwwE
    dGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANBvJkJsaFQPUH7v
    nIFX3/s5jfQANCbPnYwVDxHiJDyqEt7iNgvKI9LpmH5S8fGk6miJtUy2DZoeNRZ+
    lGum+02hHIN/TbIt6p1n7nif6G5nJXbljyfW4D5UMaK2MtBUd8tE0nJHMFmQIqD1
    v6R5/7rGoOaxEqEzdEzopB3BuGq5CHjyPUt7VqBUeFDSj8jxhTfajUeYqHZ+6UYA
    MXwKx+PawGWS7XEiIDBW/bNzfnF9xBSGl81eTXuydnl9z1C6W2/ySCv5Wp4Y3T5y
    LRUz2sc/Oej/QcSUnP8zWZxNa9fhJrhnhoJCeaAIR1P8Io4YM6ZHm8GuI5CajtQD
    4LBZZ70CAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAcj037i8vEI0Vd3nlW4MZ7DQk
    6q6DFbGrAOatZfa2+xg+rGtImglgGYxZTgTUxwUf5xM3SE9OyVwP4JA/ZrLFpnPS
    wuan7mpyE/fWEvSfe9c7qKt4ln3CE6hqywgehP5X7Pbo3Ml3Wee594xDD/aRYaBc
    Dwfit/n3zMXu+9WdDB6SqxKAvwW4ma4/45tsnPKA25JH5vNicRI9D8QvZR2lCtO4
    E6K9yYC+ltyhj8IECZ7Dx9a67JBATuQjqAxhQudQrJ35v2cvsLf8+hXJv82Q4c6a
    tv7jvLS9uSEBvrzmQClJGunVjVsG4MHzel5yohFhWoC7eWbk4HmMYvW+AoQowg==
    -----END CERTIFICATE-----
    """

  /// caCertificate が nil の場合、後方互換のため nil を返しエラーは出さない
  func testNilCertificateReturnsNil() throws {
    var config = Configuration(
      urlCandidates: [URL(string: "wss://example.com")!],
      channelId: "test",
      role: .recvonly)
    config.caCertificate = nil
    let result = try config.parsedCACertificates()
    XCTAssertNil(result)
  }

  /// 有効な PEM 1 件が正しく SecCertificate に変換される
  func testValidPEMReturnsSecCertificate() throws {
    var config = Configuration(
      urlCandidates: [URL(string: "wss://example.com")!],
      channelId: "test",
      role: .recvonly)
    config.caCertificate = Self.validPEM
    let result = try config.parsedCACertificates()
    XCTAssertEqual(result?.count, 1)
  }

  /// 複数の有効な PEM ブロックが連結された場合、全ブロックが変換される
  func testMultiplePEMBlocksReturnsMultipleCertificates() throws {
    var config = Configuration(
      urlCandidates: [URL(string: "wss://example.com")!],
      channelId: "test",
      role: .recvonly)
    config.caCertificate = Self.validPEM + Self.validPEM
    let result = try config.parsedCACertificates()
    XCTAssertEqual(result?.count, 2)
  }

  /// 有効 PEM と不正 PEM が混在する場合、部分成功を許さず configurationError を throw する
  func testMixedValidAndInvalidPEMThrowsError() throws {
    var config = Configuration(
      urlCandidates: [URL(string: "wss://example.com")!],
      channelId: "test",
      role: .recvonly)
    config.caCertificate =
      Self.validPEM + """
        -----BEGIN CERTIFICATE-----
        !!!invalid base64!!!
        -----END CERTIFICATE-----
        """
    XCTAssertThrowsError(try config.parsedCACertificates()) { error in
      guard case SoraError.configurationError = error else {
        XCTFail("expected SoraError.configurationError, got \(error)")
        return
      }
    }
  }

  /// PEM ブロックが 1 件も含まれない文字列は configurationError になる
  func testEmptyPEMThrowsError() throws {
    var config = Configuration(
      urlCandidates: [URL(string: "wss://example.com")!],
      channelId: "test",
      role: .recvonly)
    config.caCertificate = "not a valid pem"
    XCTAssertThrowsError(try config.parsedCACertificates()) { error in
      guard case SoraError.configurationError = error else {
        XCTFail("expected SoraError.configurationError, got \(error)")
        return
      }
    }
  }

  /// PEM ヘッダ/フッタは正しいが Base64 が不正な場合、configurationError になる
  func testInvalidBase64PEMThrowsError() throws {
    var config = Configuration(
      urlCandidates: [URL(string: "wss://example.com")!],
      channelId: "test",
      role: .recvonly)
    config.caCertificate = """
      -----BEGIN CERTIFICATE-----
      !!!invalid base64!!!
      -----END CERTIFICATE-----
      """
    XCTAssertThrowsError(try config.parsedCACertificates()) { error in
      guard case SoraError.configurationError = error else {
        XCTFail("expected SoraError.configurationError, got \(error)")
        return
      }
    }
  }
}
