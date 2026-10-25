import XCTest

final class HTTPParserTests: XCTestCase {
    private func request(_ text: String) -> HTTPParseResult {
        HTTPParser.parse(Data(text.utf8))
    }

    func testSimpleGet() {
        guard case let .complete(req, consumed) = request("GET /abc/live.m3u8?x=1 HTTP/1.1\r\nHost: 1.2.3.4\r\nUser-Agent: CrKey\r\n\r\n") else {
            return XCTFail("expected complete")
        }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.target, "/abc/live.m3u8?x=1")
        XCTAssertEqual(req.path, "/abc/live.m3u8")
        XCTAssertEqual(req.headers["user-agent"], "CrKey")
        XCTAssertEqual(consumed, 69)
        XCTAssertTrue(req.keepAlive)
    }

    func testIncomplete() {
        XCTAssertEqual(request("GET / HTTP/1.1\r\nHost: a\r\n"), .incomplete)
        XCTAssertEqual(request(""), .incomplete)
    }

    func testInvalid() {
        XCTAssertEqual(request("HELLO\r\n\r\n"), .invalid)
        XCTAssertEqual(request("GET / SPDY/3\r\n\r\n"), .invalid)
        XCTAssertEqual(request("GET / HTTP/1.1\r\nbroken header\r\n\r\n"), .invalid)
        XCTAssertEqual(HTTPParser.parse(Data(repeating: 65, count: HTTPParser.maxHeaderBytes + 1)), .invalid)
    }

    func testPipelinedRequests() {
        let first = "GET /a HTTP/1.1\r\n\r\n"
        let data = Data((first + "GET /b HTTP/1.1\r\n\r\n").utf8)
        guard case let .complete(a, consumed) = HTTPParser.parse(data) else { return XCTFail() }
        XCTAssertEqual(a.path, "/a")
        XCTAssertEqual(consumed, first.utf8.count)
        guard case let .complete(b, _) = HTTPParser.parse(Data(data.dropFirst(consumed))) else { return XCTFail() }
        XCTAssertEqual(b.path, "/b")
    }

    func testSlicedBufferWithNonZeroStartIndex() {
        let data = Data("xxGET /s HTTP/1.1\r\n\r\n".utf8).dropFirst(2)
        guard case let .complete(req, consumed) = HTTPParser.parse(data) else { return XCTFail() }
        XCTAssertEqual(req.path, "/s")
        XCTAssertEqual(consumed, data.count)
    }

    func testBodyIsConsumed() {
        XCTAssertEqual(request("POST /x HTTP/1.1\r\nContent-Length: 4\r\n\r\nab"), .incomplete)
        guard case let .complete(_, consumed) = request("POST /x HTTP/1.1\r\nContent-Length: 2\r\n\r\nab") else { return XCTFail() }
        XCTAssertEqual(consumed, 41)
    }

    func testKeepAlive() {
        guard case let .complete(close, _) = request("GET / HTTP/1.1\r\nConnection: close\r\n\r\n"),
              case let .complete(old, _) = request("GET / HTTP/1.0\r\n\r\n"),
              case let .complete(oldKeep, _) = request("GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n")
        else { return XCTFail() }
        XCTAssertFalse(close.keepAlive)
        XCTAssertFalse(old.keepAlive)
        XCTAssertTrue(oldKeep.keepAlive)
    }
}

final class HTTPResponseTests: XCTestCase {
    func testSerialization() {
        let response = HTTPResponse(status: 200, headers: ["Content-Type": "text/plain"], body: Data("hi".utf8))
        let text = String(decoding: response.serialized(includeBody: true, keepAlive: true), as: UTF8.self)
        XCTAssertEqual(text, "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 2\r\nContent-Type: text/plain\r\n\r\nhi")
    }

    func testHeadKeepsLengthWithoutBody() {
        let response = HTTPResponse(status: 200, body: Data("hello".utf8))
        let text = String(decoding: response.serialized(includeBody: false, keepAlive: false), as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Length: 5\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }
}

final class StreamRouterTests: XCTestCase {
    private let router = StreamRouter(token: "tok")

    private func snapshot() -> StreamSnapshot {
        StreamSnapshot(
            initSegment: Data([1, 2, 3]),
            playlistSegments: [MediaSegment(sequence: 5, duration: 1, data: Data([5]))],
            storedSegments: [MediaSegment(sequence: 4, duration: 1, data: Data([4])),
                             MediaSegment(sequence: 5, duration: 1, data: Data([5]))],
            codecs: "avc1.64001f", bandwidth: 1000, width: 1280, height: 720, frameRate: 30)
    }

    private func get(_ path: String, method: String = "GET", headers: [String: String] = [:]) -> HTTPResponse {
        router.respond(to: HTTPRequest(method: method, target: path, path: path, version: "HTTP/1.1", headers: headers),
                       snapshot: snapshot())
    }

    func testPlaylists() {
        let master = get("/tok/live.m3u8")
        XCTAssertEqual(master.status, 200)
        XCTAssertEqual(master.headers["Content-Type"], "application/vnd.apple.mpegurl")
        XCTAssertEqual(master.headers["Access-Control-Allow-Origin"], "*")
        XCTAssertTrue(String(decoding: master.body, as: UTF8.self).contains("media.m3u8"))

        let media = get("/tok/media.m3u8")
        XCTAssertEqual(media.status, 200)
        XCTAssertTrue(String(decoding: media.body, as: UTF8.self).contains("seg5.m4s"))
        XCTAssertEqual(media.headers["Cache-Control"], "no-cache, no-store")
    }

    func testSegments() {
        XCTAssertEqual(get("/tok/init.mp4").body, Data([1, 2, 3]))
        XCTAssertEqual(get("/tok/init.mp4").headers["Content-Type"], "video/mp4")
        XCTAssertEqual(get("/tok/seg4.m4s").body, Data([4]), "older stored segments are still served")
        XCTAssertEqual(get("/tok/seg3.m4s").status, 404)
        XCTAssertEqual(get("/tok/seg5.m4s").headers["Access-Control-Allow-Origin"], "*")
    }

    func testWrongTokenOrPath() {
        XCTAssertEqual(get("/other/live.m3u8").status, 404)
        XCTAssertEqual(get("/live.m3u8").status, 404)
        XCTAssertEqual(get("/tok/../tok/live.m3u8").status, 404)
    }

    func testPreflightAndMethods() {
        let preflight = get("/tok/live.m3u8", method: "OPTIONS", headers: ["access-control-request-headers": "range"])
        XCTAssertEqual(preflight.status, 204)
        XCTAssertEqual(preflight.headers["Access-Control-Allow-Origin"], "*")
        XCTAssertEqual(preflight.headers["Access-Control-Allow-Headers"], "range")
        XCTAssertTrue(preflight.headers["Access-Control-Allow-Methods"]?.contains("GET") ?? false)
        XCTAssertEqual(get("/tok/live.m3u8", method: "POST").status, 405)
        XCTAssertEqual(get("/tok/live.m3u8", method: "HEAD").status, 200)
    }

    func testInitMissing() {
        var snap = snapshot()
        snap.initSegment = nil
        let response = router.respond(to: HTTPRequest(method: "GET", target: "/tok/init.mp4", path: "/tok/init.mp4",
                                                      version: "HTTP/1.1", headers: [:]), snapshot: snap)
        XCTAssertEqual(response.status, 404)
    }
}

final class NetworkInfoTests: XCTestCase {
    func testPrivateAddresses() {
        for address in ["192.168.0.10", "10.1.2.3", "172.16.0.1", "172.31.255.255", "169.254.1.1", "127.0.0.1",
                        "fe80::1%en0", "fd12::1", "::1", "::ffff:192.168.1.2"] {
            XCTAssertTrue(NetworkInfo.isPrivate(address), address)
        }
        for address in ["8.8.8.8", "172.32.0.1", "192.169.0.1", "2001:db8::1", "1.2.3", "300.1.1.1", "example.com"] {
            XCTAssertFalse(NetworkInfo.isPrivate(address), address)
        }
    }
}
