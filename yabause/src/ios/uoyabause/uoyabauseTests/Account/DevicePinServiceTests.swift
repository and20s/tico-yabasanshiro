import XCTest
@testable import YabaSnashiro

/// URLProtocol stub so the PIN endpoints are never actually called.
final class PinMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = PinMockURLProtocol.handler else {
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

final class DevicePinServiceTests: XCTestCase {
    private var service: DevicePinService!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PinMockURLProtocol.self]
        service = DevicePinService(
            session: URLSession(configuration: configuration),
            endpoints: DevicePinService.Endpoints(
                issueURL: URL(string: "https://example.com/issue")!,
                issueApiKey: "issue-key",
                revokeURL: URL(string: "https://example.com/revoke")!,
                revokeApiKey: "revoke-key"))
    }

    override func tearDown() {
        PinMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testIssueParsesThePinFromJson() async throws {
        PinMockURLProtocol.handler = { _ in (200, Data(#"{"pinin":"4821"}"#.utf8)) }
        let pin = try await service.issuePin(googleIDToken: "token")
        XCTAssertEqual(pin, "4821")
    }

    func testIssueSendsTheTokenAndApiKey() async throws {
        PinMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "issue-key")
            let body = String(data: request.bodyStreamData ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("\"token\""))
            XCTAssertTrue(body.contains("abc123"))
            return (200, Data(#"{"pinin":"1111"}"#.utf8))
        }
        _ = try await service.issuePin(googleIDToken: "abc123")
    }

    func testIssueThrowsOnNonSuccessStatus() async {
        PinMockURLProtocol.handler = { _ in (500, Data()) }
        do {
            _ = try await service.issuePin(googleIDToken: "token")
            XCTFail("expected a failure")
        } catch {
            // expected
        }
    }

    func testIssueThrowsWhenThePinIsMissing() async {
        PinMockURLProtocol.handler = { _ in (200, Data(#"{"unexpected":true}"#.utf8)) }
        do {
            _ = try await service.issuePin(googleIDToken: "token")
            XCTFail("expected a failure")
        } catch {
            // expected
        }
    }

    func testRevokeSendsThePinAsKey() async throws {
        PinMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "revoke-key")
            let body = String(data: request.bodyStreamData ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("\"key\""))
            XCTAssertTrue(body.contains("4821"))
            // The revoke endpoint answers with the raw token, not JSON.
            return (200, Data("a.raw.google.token".utf8))
        }
        try await service.revokePin("4821")
    }

    func testRevokeIgnoringErrorsSwallowsAFailure() async {
        // Revoking is best effort: a failure must not surface to the user.
        PinMockURLProtocol.handler = { _ in (404, Data()) }
        await service.revokePinIgnoringErrors("4821")
    }

    func testUnconfiguredServiceThrows() async {
        let unconfigured = DevicePinService(endpoints: nil)
        XCTAssertFalse(unconfigured.isConfigured)
        do {
            _ = try await unconfigured.issuePin(googleIDToken: "token")
            XCTFail("expected a failure")
        } catch {
            // expected
        }
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
