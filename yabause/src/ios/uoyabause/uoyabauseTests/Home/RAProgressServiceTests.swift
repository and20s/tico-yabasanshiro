import XCTest
@testable import YabaSnashiro

/// URLProtocol stub that returns a canned response for every request.
final class RAMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = RAMockURLProtocol.handler else {
            fatalError("handler not set")
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RAProgressServiceTests: XCTestCase {
    private var service: RAProgressService!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RAMockURLProtocol.self]
        service = RAProgressService(session: URLSession(configuration: config),
                                    hashGenerator: { _ in nil })
    }

    override func tearDown() {
        RAMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testResolveGameParsesGameIdAndTotal() async {
        RAMockURLProtocol.handler = { _ in
            let json = """
            {"Success":true,"GameId":24213,"Title":"After Burner II",
             "Sets":[{"Achievements":[{"ID":1},{"ID":2},{"ID":3}]}]}
            """
            return (200, Data(json.utf8))
        }
        let result = await service.resolveGame(
            hash: "0123456789abcdef0123456789abcdef", username: "user", token: "tok")
        XCTAssertEqual(result?.gameId, 24213)
        XCTAssertEqual(result?.total, 3)
    }

    func testResolveGameRejectsInvalidHash() async {
        let result = await service.resolveGame(hash: "short", username: "u", token: "t")
        XCTAssertNil(result)
    }

    func testResolveGameReturnsNilOnApiError() async {
        RAMockURLProtocol.handler = { _ in
            (200, Data(#"{"Success":false,"Error":"bad"}"#.utf8))
        }
        let result = await service.resolveGame(
            hash: "0123456789abcdef0123456789abcdef", username: "u", token: "t")
        XCTAssertNil(result)
    }

    func testFetchAllUserProgressParsesMap() async {
        RAMockURLProtocol.handler = { _ in
            let json = """
            {"Success":true,"Response":{
               "24213":{"Unlocked":12,"UnlockedHardcore":7},
               "555":{"Unlocked":1,"UnlockedHardcore":0}}}
            """
            return (200, Data(json.utf8))
        }
        let map = await service.fetchAllUserProgress(username: "u", token: "t")
        XCTAssertEqual(map?[24213]?.unlocked, 12)
        XCTAssertEqual(map?[24213]?.hardcore, 7)
        XCTAssertEqual(map?[555]?.unlocked, 1)
    }

    func testUpdateProgressFillsItemsAndMarksUnsupported() async {
        // Game A resolves to gameId 100 with 20 achievements and progress 5/2.
        // Game B fails hash resolution -> marked raNotSupported.
        RAMockURLProtocol.handler = { request in
            let body = String(data: request.bodyStreamData ?? Data(), encoding: .utf8) ?? ""
            if body.contains("r=achievementsets") {
                if body.contains("m=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") {
                    let json = """
                    {"Success":true,"GameId":100,
                     "Sets":[{"Achievements":[\(Array(repeating: "{}", count: 20).joined(separator: ","))]}]}
                    """
                    return (200, Data(json.utf8))
                }
                return (200, Data(#"{"Success":false,"Error":"not found"}"#.utf8))
            }
            // r=allprogress
            return (200, Data(#"{"Success":true,"Response":{"100":{"Unlocked":5,"UnlockedHardcore":2}}}"#.utf8))
        }

        var gi = GameInfo()
        gi.filePath = "/a.cue"; gi.displayName = "A"; gi.productNumber = "P-A"
        let itemA = GameItem(gameInfo: gi)
        gi.filePath = "/b.cue"; gi.displayName = "B"; gi.productNumber = "P-B"
        let itemB = GameItem(gameInfo: gi)

        let hashes = ["/a.cue": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                      "/b.cue": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RAMockURLProtocol.self]
        let svc = RAProgressService(session: URLSession(configuration: config),
                                    hashGenerator: { hashes[$0] })

        let updated = await svc.updateProgress(items: [itemA, itemB],
                                               username: "u", token: "t")
        let a = updated.first { $0.filePath == "/a.cue" }!
        let b = updated.first { $0.filePath == "/b.cue" }!
        XCTAssertEqual(a.raGameId, 100)
        XCTAssertEqual(a.raTotal, 20)
        XCTAssertEqual(a.raUnlocked, 5)
        XCTAssertEqual(a.raUnlockedHardcore, 2)
        XCTAssertTrue(b.raNotSupported)
    }
}

private extension URLRequest {
    /// URLSession moves httpBody into a stream for URLProtocol; read it back.
    var bodyStreamData: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
