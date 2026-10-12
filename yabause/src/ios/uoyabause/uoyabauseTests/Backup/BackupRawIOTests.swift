import XCTest
@testable import YabaSnashiro

/// Verifies the raw byte export/import bridge and that the date encoder is
/// the exact inverse of the decoder the core uses when listing saves.
final class BackupRawIOTests: XCTestCase {
    override func setUpWithError() throws {
        try? FileManager.default.removeItem(atPath: BackupFile.internalMemory.path)
    }

    override func tearDownWithError() throws {
        BackupSession.shared.closeIfOpen()
        try? FileManager.default.removeItem(atPath: BackupFile.internalMemory.path)
    }

    private func components(of date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    func testDateEncoderRoundTripsThroughTheCoreDecoder() throws {
        let cases: [(Int, Int, Int, Int, Int)] = [
            (1998, 5, 12, 9, 30),
            (1996, 1, 1, 0, 0),
            (2000, 2, 29, 23, 59),   // leap day
            (1999, 12, 31, 12, 0),
            (2024, 7, 4, 6, 45),
        ]

        for (index, expected) in cases.enumerated() {
            let (year, month, day, hour, minute) = expected
            let packed = YSBupEncodeDate(Int32(year), Int32(month), Int32(day),
                                         Int32(hour), Int32(minute))
            XCTAssertNotEqual(packed, 0, "\(year)-\(month)-\(day) could not be encoded")

            let name = "DATE\(index)"
            try BackupSession.shared.withSession(cartridge: nil) {
                let payload = [UInt8](repeating: 0x5A, count: 512)
                let result = name.withCString { namePtr in
                    "T".withCString { commentPtr in
                        payload.withUnsafeBufferPointer { bytes in
                            YSBupStandaloneImport(0, namePtr, commentPtr, 0, packed,
                                                  bytes.baseAddress, 512)
                        }
                    }
                }
                XCTAssertEqual(result, 0, "import failed for \(name)")
            }

            let saves = try LocalBackupRepository().saves(in: .internalMemory)
            guard let save = saves.first(where: { $0.filename == name }),
                  let decoded = save.saveDate else {
                return XCTFail("\(name) was not listed back with a date")
            }
            let parts = components(of: decoded)
            XCTAssertEqual(parts.year, year, "year mismatch for \(name)")
            XCTAssertEqual(parts.month, month, "month mismatch for \(name)")
            XCTAssertEqual(parts.day, day, "day mismatch for \(name)")
            XCTAssertEqual(parts.hour, hour, "hour mismatch for \(name)")
            XCTAssertEqual(parts.minute, minute, "minute mismatch for \(name)")
        }
    }

    func testEncoderRejectsImpossibleDates() {
        XCTAssertEqual(YSBupEncodeDate(1979, 1, 1, 0, 0), 0)
        XCTAssertEqual(YSBupEncodeDate(1998, 13, 1, 0, 0), 0)
        XCTAssertEqual(YSBupEncodeDate(1998, 1, 1, 24, 0), 0)
        XCTAssertEqual(YSBupEncodeDate(1999, 2, 30, 0, 0), 0)  // not a real day
    }

    func testExportThenImportPreservesBytes() throws {
        let payload = (0..<1024).map { UInt8($0 % 251) }

        try BackupSession.shared.withSession(cartridge: nil) {
            let packed = YSBupEncodeDate(1998, 5, 12, 9, 30)
            let written = "RAWTEST".withCString { namePtr in
                "BYTES".withCString { commentPtr in
                    payload.withUnsafeBufferPointer { bytes in
                        YSBupStandaloneImport(0, namePtr, commentPtr, 0, packed,
                                              bytes.baseAddress, Int32(payload.count))
                    }
                }
            }
            XCTAssertEqual(written, 0)
        }

        var exported: [UInt8] = []
        try BackupSession.shared.withSession(cartridge: nil) {
            var buffer: UnsafeMutableRawPointer?
            var size: Int32 = 0
            let result = "RAWTEST".withCString {
                YSBupStandaloneExport(0, $0, &buffer, &size)
            }
            XCTAssertEqual(result, 0)
            guard let buffer = buffer else { return XCTFail("export gave no buffer") }
            exported = Array(UnsafeRawBufferPointer(start: buffer, count: Int(size)))
            free(buffer)
        }

        XCTAssertEqual(exported.count, payload.count)
        XCTAssertEqual(exported, payload)
    }
}
