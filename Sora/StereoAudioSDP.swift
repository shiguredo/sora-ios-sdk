import Foundation

/// Answer SDP の Opus 音声形式へステレオ受信指定を追加します。
enum StereoAudioSDP {
  /// 受信方向を持つ音声メディア節のすべての Opus ペイロードへ `stereo=1` を設定します。
  ///
  /// SDP の改行形式、音声以外のメディア節、Opus 以外の属性は変更しません。
  static func enableStereo(in sdp: String) throws -> String {
    let lineEnding = sdp.contains("\r\n") ? "\r\n" : "\n"
    let hasTrailingLineEnding = sdp.hasSuffix(lineEnding)
    var lines = sdp.components(separatedBy: lineEnding)
    if hasTrailingLineEnding {
      lines.removeLast()
    }

    let firstMediaLineIndex =
      lines.firstIndex {
        $0.lowercased().hasPrefix("m=")
      } ?? lines.endIndex
    // RFC 8866 では media-level の direction が省略された場合、session-level の
    // direction を継承する。どちらにもなければ sendrecv として扱う。
    let sessionDirection = direction(in: Array(lines[..<firstMediaLineIndex])) ?? "a=sendrecv"

    var transformed: [String] = []
    var section: [String] = []
    var foundReceivingAudioSectionWithoutOpus = false

    func appendSection(_ section: [String], to output: inout [String]) {
      guard let mediaLine = section.first,
        mediaLine.lowercased().hasPrefix("m=audio ")
      else {
        output.append(contentsOf: section)
        return
      }

      let mediaComponents = mediaLine.split(whereSeparator: { $0.isWhitespace })
      let port = mediaComponents.count >= 2 ? mediaComponents[1].split(separator: "/").first : nil
      let mediaDirection = direction(in: section) ?? sessionDirection
      let canReceive = mediaDirection == "a=sendrecv" || mediaDirection == "a=recvonly"
      let isReceiving = port != nil && port != "0" && canReceive
      guard isReceiving else {
        output.append(contentsOf: section)
        return
      }

      // rtpmap 属性が残っていても m-line の format 一覧にない payload は交渉対象ではない。
      let mediaPayloadTypes = Set(mediaComponents.dropFirst(3).map(String.init))
      let opusPayloadTypes = section.compactMap(opusPayloadType(from:)).filter {
        mediaPayloadTypes.contains($0)
      }
      if opusPayloadTypes.isEmpty {
        foundReceivingAudioSectionWithoutOpus = true
      }
      let opusPayloadTypeSet = Set(opusPayloadTypes)

      var payloadTypesWithFmtp: Set<String> = []
      var updatedSection = section.map { line -> String in
        guard let fmtp = parseFmtp(line), opusPayloadTypeSet.contains(fmtp.payloadType) else {
          return line
        }
        payloadTypesWithFmtp.insert(fmtp.payloadType)
        return "a=fmtp:\(fmtp.payloadType) \(parametersEnablingStereo(fmtp.parameters))"
      }

      if payloadTypesWithFmtp.count != opusPayloadTypeSet.count {
        var sectionWithAddedFmtp: [String] = []
        for line in updatedSection {
          sectionWithAddedFmtp.append(line)
          guard let payloadType = opusPayloadType(from: line),
            !payloadTypesWithFmtp.contains(payloadType)
          else {
            continue
          }
          sectionWithAddedFmtp.append("a=fmtp:\(payloadType) stereo=1")
          payloadTypesWithFmtp.insert(payloadType)
        }
        updatedSection = sectionWithAddedFmtp
      }

      output.append(contentsOf: updatedSection)
    }

    for line in lines {
      if line.lowercased().hasPrefix("m="), !section.isEmpty {
        appendSection(section, to: &transformed)
        section = []
      }
      section.append(line)
    }
    appendSection(section, to: &transformed)

    guard !foundReceivingAudioSectionWithoutOpus else {
      throw SoraError.peerChannelError(
        reason: "Opus payload type was not found in a receiving audio section of the answer SDP")
    }

    let result = transformed.joined(separator: lineEnding)
    return hasTrailingLineEnding ? result + lineEnding : result
  }

  /// SDP 節に明示された送受信方向を返します。
  private static func direction(in lines: [String]) -> String? {
    lines.lazy.map { $0.lowercased() }.first {
      $0 == "a=sendrecv" || $0 == "a=sendonly" || $0 == "a=recvonly" || $0 == "a=inactive"
    }
  }

  /// `a=rtpmap` 行がステレオ Opus を表す場合にペイロードタイプを返します。
  private static func opusPayloadType(from line: String) -> String? {
    let prefix = "a=rtpmap:"
    guard line.count >= prefix.count,
      line.prefix(prefix.count).lowercased() == prefix
    else {
      return nil
    }

    let value = line.dropFirst(prefix.count)
    let components = value.split(whereSeparator: { $0.isWhitespace })
    guard components.count >= 2,
      components[1].lowercased() == "opus/48000/2"
    else {
      return nil
    }
    return String(components[0])
  }

  /// `a=fmtp` 行をペイロードタイプとパラメーターへ分解します。
  private static func parseFmtp(_ line: String) -> (payloadType: String, parameters: String)? {
    let prefix = "a=fmtp:"
    guard line.count >= prefix.count,
      line.prefix(prefix.count).lowercased() == prefix
    else {
      return nil
    }

    let value = line.dropFirst(prefix.count)
    guard let separator = value.firstIndex(where: { $0.isWhitespace }) else {
      return (String(value), "")
    }
    let payloadType = String(value[..<separator])
    let parameters = String(value[separator...]).trimmingCharacters(in: .whitespaces)
    return (payloadType, parameters)
  }

  /// 既存パラメーターの順序を維持しながら `stereo` だけを追加または置換します。
  private static func parametersEnablingStereo(_ parameters: String) -> String {
    var values = parameters.split(separator: ";", omittingEmptySubsequences: true).map {
      String($0).trimmingCharacters(in: .whitespaces)
    }
    var replaced = false
    for index in values.indices {
      let key = values[index].split(separator: "=", maxSplits: 1).first?
        .trimmingCharacters(in: .whitespaces)
        .lowercased()
      if key == "stereo" {
        values[index] = "stereo=1"
        replaced = true
      }
    }
    if !replaced {
      values.append("stereo=1")
    }
    return values.joined(separator: ";")
  }
}
