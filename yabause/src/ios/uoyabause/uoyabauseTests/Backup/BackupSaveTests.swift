import XCTest
@testable import YabaSnashiro

final class BackupSaveTests: XCTestCase {
    private func makeRawSave(filename: String, comment: String,
                             year: UInt8 = 18, month: UInt8 = 5, day: UInt8 = 12,
                             hour: UInt8 = 9, minute: UInt8 = 30,
                             dataSize: UInt32 = 12288,
                             blockSize: UInt16 = 24) -> YSBupSave {
        var raw = YSBupSave()
        withUnsafeMutableBytes(of: &raw.filename) { buffer in
            for (index, byte) in Array(filename.utf8).prefix(11).enumerated() {
                buffer[index] = byte
            }
        }
        withUnsafeMutableBytes(of: &raw.comment) { buffer in
            for (index, byte) in Array(comment.utf8).prefix(10).enumerated() {
                buffer[index] = byte
            }
        }
        raw.year = year
        raw.month = month
        raw.day = day
        raw.hour = hour
        raw.minute = minute
        raw.datasize = dataSize
        raw.blocksize = blockSize
        return raw
    }

    func testInitFromRawTrimsAndDecodes() {
        let save = BackupSave(raw: makeRawSave(filename: "SONICR_01",
                                               comment: "STAGE3"),
                              file: .internalMemory)
        XCTAssertEqual(save.filename, "SONICR_01")
        XCTAssertEqual(save.comment, "STAGE3")
        XCTAssertEqual(save.dataSize, 12288)
        XCTAssertEqual(save.blockSize, 24)
        XCTAssertEqual(save.file, .internalMemory)
        XCTAssertEqual(save.id, "memory/SONICR_01")
    }

    func testSaveDateUsesSaturnEpochYearOffset() {
        // The core stores the year as an offset from 1980.
        let save = BackupSave(raw: makeRawSave(filename: "A", comment: "B",
                                               year: 18, month: 5, day: 12,
                                               hour: 9, minute: 30),
                              file: .internalMemory)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: save.saveDate!)
        XCTAssertEqual(components.year, 1998)
        XCTAssertEqual(components.month, 5)
        XCTAssertEqual(components.day, 12)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 30)
    }

    func testInvalidDateIsNil() {
        let save = BackupSave(raw: makeRawSave(filename: "A", comment: "B",
                                               year: 0, month: 0, day: 0),
                              file: .internalMemory)
        XCTAssertNil(save.saveDate)
    }

    func testDisplaySize() {
        let small = BackupSave(raw: makeRawSave(filename: "A", comment: "B",
                                                dataSize: 512),
                               file: .internalMemory)
        XCTAssertEqual(small.displaySize, "512 B")
        let large = BackupSave(raw: makeRawSave(filename: "A", comment: "B",
                                                dataSize: 12288),
                               file: .internalMemory)
        XCTAssertEqual(large.displaySize, "12 KB")
    }
}
