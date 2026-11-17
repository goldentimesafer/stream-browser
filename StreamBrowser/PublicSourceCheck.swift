import Foundation

final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum PublicSourceCheck {
    struct FileInfo {
        let fileExtension: String
        let byteCount: Int64?
    }

    static func configuration(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return configuration
    }

    static func verify(_ url: URL, mode: TransferMode, hosts: Set<String>) async throws -> FileInfo {
        guard MediaPolicy.publicURL(url, hosts: hosts) else { throw MediaError.untrustedSource }
        let config = configuration(.ephemeral)
        config.timeoutIntervalForResource = 20
        config.allowsCellularAccess = false
        let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        if mode == .hls {
            var stack: [(URL, Set<URL>)] = [(url, [])]
            var seen: Set<URL> = []
            var foundVOD = false
            while let (playlist, ancestors) = stack.popLast() {
                try Task.checkCancellation()
                guard ancestors.count <= 3, !ancestors.contains(playlist) else { throw MediaError.hls }
                if !seen.insert(playlist).inserted { continue }
                guard seen.count <= 16 else { throw MediaError.hls }
                let (stream, response) = try await session.bytes(from: playlist)
                try validate(response, expected: playlist, partial: false)
                var data = Data()
                for try await byte in stream {
                    guard data.count < 256 * 1024 else { throw MediaError.hls }
                    data.append(byte)
                }
                guard let text = String(data: data, encoding: .utf8) else { throw MediaError.hls }
                let manifest = try HLSManifest(text, base: playlist, hosts: hosts)
                if manifest.playlists.isEmpty { foundVOD = true }
                guard manifest.playlists.count <= 16 else { throw MediaError.hls }
                stack += manifest.playlists.map { ($0, ancestors.union([playlist])) }
            }
            guard foundVOD else { throw MediaError.hls }
            return FileInfo(fileExtension: "m3u8", byteCount: nil)
        } else {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let (_, response) = try await session.bytes(for: request)
            try validate(response, expected: url, partial: true)
            guard let fileExtension = MediaPolicy.mediaExtension(response) else { throw MediaError.format }
            return FileInfo(fileExtension: fileExtension, byteCount: MediaPolicy.responseByteCount(response))
        }
    }

    private static func validate(_ response: URLResponse, expected: URL, partial: Bool) throws {
        guard let http = response as? HTTPURLResponse else { throw MediaError.response }
        guard response.url == expected, !(300..<400).contains(http.statusCode) else { throw MediaError.redirect }
        if let error = MediaError.httpStatus(http.statusCode) { throw error }
        guard http.statusCode == 200 || partial && http.statusCode == 206 else { throw MediaError.response }
    }
}
