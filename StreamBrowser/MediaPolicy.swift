import Foundation

enum MediaKind: String, Codable {
    case file, hls
}

enum TransferMode: String, Codable {
    case web, backgroundFile, hls

    var kind: MediaKind { self == .hls ? .hls : .file }
    var usesSystemSession: Bool { self != .web }
    var label: String {
        switch self {
        case .web: "비공개 전경 저장"
        case .backgroundFile: "백그라운드 파일"
        case .hls: "HLS 오프라인"
        }
    }
}

enum MediaError: String, Error {
    case address, untrustedSource, redirect, response, format, storage, hls, interrupted, busy
    case offline, timeout, authentication, missing, throttled, certificate, selection

    static func httpStatus(_ code: Int) -> MediaError? {
        switch code {
        case 200, 206: return nil
        case 401, 403: return .authentication
        case 404, 410: return .missing
        case 429, 503: return .throttled
        case 300..<400: return .redirect
        default: return .response
        }
    }

    static func classify(_ error: Error) -> MediaError {
        if let error = error as? MediaError { return error }
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain {
            if value.code == NSFileWriteOutOfSpaceError || value.code == NSFileReadNoPermissionError || value.code == NSFileWriteNoPermissionError { return .storage }
        }
        guard value.domain == NSURLErrorDomain else { return .response }
        switch value.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed: return .offline
        case NSURLErrorTimedOut: return .timeout
        case NSURLErrorUserAuthenticationRequired: return .authentication
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed: return .certificate
        case NSURLErrorCancelled: return .interrupted
        case NSURLErrorCannotWriteToFile: return .storage
        default: return .response
        }
    }

    var message: String {
        switch self {
        case .address: "지원되는 HTTPS 영상 주소를 입력하세요."
        case .untrustedSource: "인증 없는 공개 출처를 설정에서 등록하세요."
        case .redirect: "주소가 변경되었습니다. 최종 HTTPS 주소를 확인하세요."
        case .response: "서버에서 영상을 받지 못했습니다. 링크와 권한을 확인하세요."
        case .format: "지원되는 영상 파일이나 오프라인 자산을 확인할 수 없습니다."
        case .storage: "저장공간 또는 파일 보호 상태를 확인하세요."
        case .hls: "검증된 HTTPS 비암호화 주문형 HLS만 저장할 수 있습니다."
        case .interrupted: "작업이 중단되었습니다. 링크를 확인하고 다시 시작하세요."
        case .busy: "진행 중인 작업이 많습니다. 잠시 후 다시 시도하세요."
        case .offline: "네트워크 연결이 끊겼거나 Wi-Fi가 필요합니다. 연결을 확인하고 다시 시도하세요."
        case .timeout: "서버 응답 시간이 초과되었습니다. 잠시 후 다시 시도하세요."
        case .authentication: "로그인 또는 접근 권한이 필요합니다. 공개 전송에는 인증 없는 주소를 사용하세요."
        case .missing: "영상 주소가 만료되었거나 파일이 없습니다. 새 링크를 입력하세요."
        case .throttled: "서버가 요청을 제한하거나 일시적으로 사용할 수 없습니다. 잠시 후 다시 시도하세요."
        case .certificate: "서버의 보안 인증서를 확인할 수 없어 연결을 중단했습니다."
        case .selection: "선택한 오디오·자막을 제공하지 않는 영상입니다. 언어를 기본으로 바꾸거나 다른 언어를 선택하세요."
        }
    }
}

enum MediaPolicy {
    static func responseByteCount(_ response: URLResponse) -> Int64? {
        if let http = response as? HTTPURLResponse, http.statusCode == 206 {
            // Content-Length in a ranged response describes only the selected bytes.
            guard let value = http.value(forHTTPHeaderField: "Content-Range"),
                  let separator = value.lastIndex(of: "/"),
                  let total = Int64(value[value.index(after: separator)...]), total > 0 else { return nil }
            return total
        }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    static func secureWebURL(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty else { return false }
        return c.user == nil && c.password == nil
    }

    static func publicHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, parts.count >= 2, let last = parts.last,
              last.allSatisfy({ $0.isASCII && $0.isLetter }) || last.hasPrefix("xn--"),
              !["local", "localhost", "internal", "lan", "home", "onion", "test"].contains(String(last)),
              parts.allSatisfy({ part in
                  !part.isEmpty && part.utf8.count <= 63 && part.first != "-" && part.last != "-" &&
                  part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }) else { return nil }
        return host
    }

    static func publicURL(_ url: URL, hosts: Set<String>) -> Bool {
        guard secureWebURL(url), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = c.host.flatMap(publicHost), hosts.contains(host),
              c.port == nil || c.port == 443 else { return false }
        return c.percentEncodedQuery == nil && c.fragment == nil
    }

    static func videoExtension(_ response: URLResponse, suggested: String? = nil) -> String? {
        let byType: [String: String] = ["video/mp4": "mp4", "video/quicktime": "mov", "video/x-m4v": "m4v"]
        let mime = response.mimeType?.lowercased()
        if let mime, let ext = byType[mime] { return ext }
        guard mime == nil || mime == "application/octet-stream" else { return nil }
        let candidates = [response.url?.pathExtension, suggested.map { ($0 as NSString).pathExtension }]
        return candidates.compactMap { $0?.lowercased() }.first { ["mp4", "mov", "m4v"].contains($0) }
    }

    static func displayName(_ input: String, fallback: String = "영상") -> String {
        let scalars = input.unicodeScalars.prefix(160).filter {
            !CharacterSet.controlCharacters.contains($0) && !$0.properties.isBidiControl &&
                $0.value != 47 && $0.value != 92 && $0.value != 58
        }
        let result = String(scalars.map(Character.init)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == "." || result == ".." ? fallback : result
    }

    static func hasMovieHeader(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = Array(data.prefix(16))
        let atom = String(decoding: bytes[4..<8], as: UTF8.self)
        return ["ftyp", "moov", "mdat", "wide", "free"].contains(atom)
    }
}

struct HLSManifest {
    let playlists: [URL]

    init(_ text: String, base: URL, hosts: Set<String>) throws {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U" else { throw MediaError.hls }
        var children: [URL] = []
        var segments = 0
        var nextIsPlaylist = false
        var nextIsSegment = false
        var endList = false
        let simpleTags: Set<String> = [
            "#EXTM3U", "#EXT-X-VERSION", "#EXT-X-TARGETDURATION", "#EXT-X-MEDIA-SEQUENCE",
            "#EXT-X-DISCONTINUITY-SEQUENCE", "#EXT-X-PLAYLIST-TYPE", "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-DISCONTINUITY", "#EXT-X-PROGRAM-DATE-TIME", "#EXT-X-BYTERANGE",
            "#EXT-X-GAP", "#EXT-X-START"
        ]
        func checked(_ value: String) throws -> URL {
            guard !value.isEmpty, !value.contains("{"), !value.contains("}"), !value.contains("\\"),
                  let url = URL(string: value, relativeTo: base)?.absoluteURL,
                  MediaPolicy.publicURL(url, hosts: hosts) else { throw MediaError.hls }
            return url
        }
        for line in lines.dropFirst() where !line.isEmpty {
            guard !endList else { throw MediaError.hls }
            if !line.hasPrefix("#") {
                let url = try checked(line)
                if nextIsPlaylist { children.append(url) }
                else if nextIsSegment { segments += 1 }
                else { throw MediaError.hls }
                nextIsPlaylist = false
                nextIsSegment = false
                continue
            }
            if !line.hasPrefix("#EXT") { continue }
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let tag = String(pair[0])
            let value = pair.count > 1 ? String(pair[1]) : ""
            switch tag {
            case "#EXT-X-STREAM-INF":
                guard !nextIsPlaylist, !nextIsSegment else { throw MediaError.hls }
                let metadata = try Self.attributes(value)
                guard metadata["URI"] == nil, let bandwidth = metadata["BANDWIDTH"],
                      let rate = Int(bandwidth), rate > 0 else { throw MediaError.hls }
                nextIsPlaylist = true
            case "#EXTINF":
                guard !nextIsPlaylist, !nextIsSegment,
                      let field = value.split(separator: ",", maxSplits: 1).first,
                      let duration = Double(field), duration.isFinite, duration > 0 else { throw MediaError.hls }
                nextIsSegment = true
            case "#EXT-X-MEDIA", "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-MAP":
                let attributes = try Self.attributes(value)
                if let uri = attributes["URI"] {
                    let url = try checked(uri)
                    if tag != "#EXT-X-MAP" { children.append(url) }
                } else if tag != "#EXT-X-MEDIA" { throw MediaError.hls }
            case "#EXT-X-KEY":
                guard value == "METHOD=NONE" else { throw MediaError.hls }
            case "#EXT-X-ENDLIST": endList = true
            default:
                guard simpleTags.contains(tag) else { throw MediaError.hls }
                if tag == "#EXT-X-PLAYLIST-TYPE", value != "VOD" { throw MediaError.hls }
            }
        }
        guard !nextIsPlaylist, !nextIsSegment,
              (segments > 0 && endList && children.isEmpty || segments == 0 && !children.isEmpty && !endList) else {
            throw MediaError.hls
        }
        playlists = children
    }

    private static func attributes(_ value: String) throws -> [String: String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        for c in value {
            if c == "\"" { quoted.toggle() }
            if c == "," && !quoted { fields.append(field); field = "" } else { field.append(c) }
        }
        guard !quoted else { throw MediaError.hls }
        fields.append(field)
        var result: [String: String] = [:]
        for field in fields {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty else { throw MediaError.hls }
            let key = String(pair[0])
            guard result[key] == nil else { throw MediaError.hls }
            let item = pair[1]
            if key == "URI" {
                guard item.count > 2, item.first == "\"", item.last == "\"" else { throw MediaError.hls }
                result[key] = String(item.dropFirst().dropLast())
            } else {
                guard !key.hasSuffix("URI"), !key.contains("URL") else { throw MediaError.hls }
                result[key] = String(item)
            }
        }
        return result
    }
}
