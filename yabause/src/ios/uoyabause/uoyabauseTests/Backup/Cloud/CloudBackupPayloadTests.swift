import XCTest
@testable import YabaSnashiro

final class CloudBackupPayloadTests: XCTestCase {
    private func makeEnvelope(bytes: [UInt8]) -> Data {
        let content = Data(bytes).base64EncodedString()
        let json = """
        {"header":{"filename":"U09OSUM=","comment":"","language":0,"date":9657210,
                   "year":18,"month":5,"day":12,"hour":9,"minute":30,"week":0,
                   "datasize":\(bytes.count),"blocksize":5},
         "data":{"size":\(bytes.count),"content":"\(content)"}}
        """
        return Data(json.utf8)
    }

    func testUnwrapsLegacyEnvelope() throws {
        let payload = [UInt8](repeating: 0xA5, count: 64)
        let bytes = try CloudBackupPayload.saveBytes(from: makeEnvelope(bytes: payload))
        XCTAssertEqual(Array(bytes), payload)
    }

    func testPassesRawBytesThrough() throws {
        let payload = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
        XCTAssertEqual(try CloudBackupPayload.saveBytes(from: payload), payload)
    }

    func testRawBytesThatHappenToBeJsonWithoutHeaderPassThrough() throws {
        // A save whose bytes are valid JSON but not our envelope must not be
        // mistaken for one.
        let payload = Data(#"{"score":100}"#.utf8)
        XCTAssertEqual(try CloudBackupPayload.saveBytes(from: payload), payload)
    }

    func testEmptyDataThrows() {
        XCTAssertThrowsError(try CloudBackupPayload.saveBytes(from: Data()))
    }

    func testEnvelopeWithBadBase64Throws() {
        let json = Data(#"{"header":{"filename":"x"},"data":{"size":4,"content":"!!!!"}}"#.utf8)
        XCTAssertThrowsError(try CloudBackupPayload.saveBytes(from: json))
    }

    func testEnvelopeWithoutContentThrows() {
        let json = Data(#"{"header":{"filename":"x"},"data":{"size":4}}"#.utf8)
        XCTAssertThrowsError(try CloudBackupPayload.saveBytes(from: json))
    }
}
