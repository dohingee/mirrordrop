import Foundation

struct HTTPRequest: Equatable {
    var method: String
    var target: String
    var path: String
    var version: String
    /// Header names are lowercased.
    var headers: [String: String]

    var keepAlive: Bool {
        let connection = headers["connection"]?.lowercased() ?? ""
        if version == "HTTP/1.0" { return connection.contains("keep-alive") }
        return !connection.contains("close")
    }
}

enum HTTPParseResult: Equatable {
    case incomplete
    case invalid
    case complete(HTTPRequest, consumed: Int)
}

enum HTTPParser {
    static let maxHeaderBytes = 16 * 1024
    private static let headerEnd = Data("\r\n\r\n".utf8)

    /// Parses one request from the front of `buffer`. Request bodies are skipped (Content-Length only).
    static func parse(_ buffer: Data) -> HTTPParseResult {
        guard let end = buffer.range(of: headerEnd) else {
            return buffer.count > maxHeaderBytes ? .invalid : .incomplete
        }
        let headerLength = end.lowerBound - buffer.startIndex
        guard headerLength <= maxHeaderBytes,
              let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .isoLatin1)
        else { return .invalid }

        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), !parts[0].isEmpty,
              parts[1].hasPrefix("/") || parts[1] == "*"
        else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid }
            headers[name] = value
        }

        var consumed = end.upperBound - buffer.startIndex
        if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else { return .invalid }
            if buffer.count < consumed + length { return .incomplete }
            consumed += length
        }

        let target = parts[1]
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        let request = HTTPRequest(method: parts[0].uppercased(), target: target, path: path, version: parts[2], headers: headers)
        return .complete(request, consumed: consumed)
    }
}

struct HTTPResponse: Equatable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    /// HEAD responses keep Content-Length but drop the body.
    func serialized(includeBody: Bool, keepAlive: Bool) -> Data {
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = keepAlive ? "keep-alive" : "close"
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for name in all.keys.sorted() {
            head += "\(name): \(all[name] ?? "")\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if includeBody { data.append(body) }
        return data
    }
}

/// What the server can hand out at one moment.
struct StreamSnapshot {
    var initSegment: Data?
    /// Segments listed in the playlist (newest window).
    var playlistSegments: [MediaSegment]
    /// Everything still in memory (a bit more than the playlist, for slow clients).
    var storedSegments: [MediaSegment]
    var codecs: String?
    var bandwidth: Int
    var width: Int
    var height: Int
    var frameRate: Double
}

/// Maps a request to a response. Paths look like /<token>/live.m3u8.
struct StreamRouter {
    let token: String

    static let corsHeaders = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Expose-Headers": "Content-Length, Content-Type",
    ]

    func respond(to request: HTTPRequest, snapshot: StreamSnapshot) -> HTTPResponse {
        if request.method == "OPTIONS" {
            var response = HTTPResponse(status: 204, headers: Self.corsHeaders)
            response.headers["Access-Control-Allow-Headers"] = request.headers["access-control-request-headers"] ?? "*"
            response.headers["Access-Control-Max-Age"] = "600"
            return response
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            return plain(405, "method not allowed")
        }
        let prefix = "/\(token)/"
        guard request.path.hasPrefix(prefix) else { return plain(404, "not found") }
        let name = String(request.path.dropFirst(prefix.count))

        switch name {
        case HLSPlaylist.masterName:
            let text = HLSPlaylist.master(bandwidth: snapshot.bandwidth, codecs: snapshot.codecs,
                                          width: snapshot.width, height: snapshot.height, frameRate: snapshot.frameRate)
            return playlist(text)
        case HLSPlaylist.mediaName:
            return playlist(HLSPlaylist.media(snapshot.playlistSegments))
        case HLSPlaylist.initName:
            guard let data = snapshot.initSegment else { return plain(404, "not ready") }
            return media(data, cache: "max-age=3600")
        default:
            guard let sequence = HLSPlaylist.sequence(fromSegmentName: name),
                  let segment = snapshot.storedSegments.first(where: { $0.sequence == sequence })
            else { return plain(404, "not found") }
            return media(segment.data, cache: "max-age=60")
        }
    }

    private func playlist(_ text: String) -> HTTPResponse {
        var headers = Self.corsHeaders
        headers["Content-Type"] = "application/vnd.apple.mpegurl"
        headers["Cache-Control"] = "no-cache, no-store"
        return HTTPResponse(status: 200, headers: headers, body: Data(text.utf8))
    }

    private func media(_ data: Data, cache: String) -> HTTPResponse {
        var headers = Self.corsHeaders
        headers["Content-Type"] = "video/mp4"
        headers["Cache-Control"] = cache
        return HTTPResponse(status: 200, headers: headers, body: data)
    }

    func plain(_ status: Int, _ text: String) -> HTTPResponse {
        var headers = Self.corsHeaders
        headers["Content-Type"] = "text/plain; charset=utf-8"
        return HTTPResponse(status: status, headers: headers, body: Data(text.utf8))
    }
}
