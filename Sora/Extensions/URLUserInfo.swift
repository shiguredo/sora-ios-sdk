import Foundation

/// URL に含まれる userinfo (ユーザー名とパスワード) を除くヘルパーです。
///
/// `wss://user:pass@example.com/signaling` のような URL をそのままログへ出すと
/// 認証情報が残ります。ログへ出す前にこのヘルパーを通します。
enum URLUserInfo {
  /// `URL` から userinfo を除いた URL を返します。
  ///
  /// authority の userinfo (ユーザー名とパスワード) だけを対象にします。userinfo を
  /// 含まない URL はそのまま返します。`URLComponents` で表せない URL は、文字列版で
  /// userinfo を除いた URL を返します。
  static func removed(from url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      // userinfo がある場合、`URLComponents` は空のユーザー名でも user を nil 以外にします。
      components.user != nil
    else {
      return url
    }
    components.user = nil
    components.password = nil
    if let stripped = components.url {
      return stripped
    }
    // `URLComponents` で表せない URL でも userinfo を残さないよう、文字列版で除去します。
    return URL(string: removed(from: url.absoluteString)) ?? url
  }

  /// 文字列から userinfo を除いた文字列を返します。
  ///
  /// `URL` として解釈できない文字列 (redirect の location など) も対象にするため、
  /// 文字列ベースで処理します。authority の開始位置は、文字列の先頭にある
  /// `<scheme>://` の後ろ、または scheme 相対の参照 (`//user:pass@host/path`) の
  /// `//` の後ろです。authority の終端は `/` `?` `#` のいずれか (無ければ文字列の末尾)
  /// とし、その範囲に `@` があれば `@` より前を除去します。`@` が query や fragment に
  /// 現れる場合は除去しません。authority (`//`) を持たない文字列には userinfo が無いため
  /// 対象外とします。先頭の空白は読み飛ばし、元の表記は残します。
  static func removed(from string: String) -> String {
    // 先頭の空白は URL の一部ではないため読み飛ばします。
    let contentStart = string.firstIndex(where: { !$0.isWhitespace }) ?? string.endIndex
    let content = string[contentStart...]
    let authorityStart: String.Index
    if content.hasPrefix("//") {
      authorityStart = string.index(contentStart, offsetBy: 2)
    } else if let separator = schemeSeparator(in: content) {
      authorityStart = separator.upperBound
    } else {
      return string
    }
    let authorityEnd =
      string[authorityStart...].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
      ?? string.endIndex
    guard let at = string[authorityStart..<authorityEnd].lastIndex(of: "@") else {
      return string
    }
    let afterUserInfo = string.index(after: at)
    return String(string[..<authorityStart]) + String(string[afterUserInfo...])
  }

  /// 文字列の先頭にある `<scheme>://` の `://` の範囲を返します。
  ///
  /// path の中の `://` を scheme と誤認しないよう、文字列の先頭から scheme の文法
  /// (RFC 3986 の `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`) に一致する場合だけを
  /// 対象にします。
  private static func schemeSeparator<S: StringProtocol>(in string: S) -> Range<String.Index>?
  where S.Index == String.Index {
    guard let separator = string.range(of: "://") else {
      return nil
    }
    let scheme = string[..<separator.lowerBound]
    guard let first = scheme.first, first.isASCII, first.isLetter,
      scheme.dropFirst().allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
      })
    else {
      return nil
    }
    return separator
  }
}
