import XCTest
@testable import YabaSnashiro

final class BackupSessionTests: XCTestCase {
    override func tearDown() {
        BackupSession.shared.closeIfOpen()
        super.tearDown()
    }

    func testWithSessionOpensAndCloses() throws {
        var ranBody = false
        try BackupSession.shared.withSession(cartridge: nil) {
            ranBody = true
            XCTAssertTrue(BackupSession.shared.isOpen)
        }
        XCTAssertTrue(ranBody)
        XCTAssertFalse(BackupSession.shared.isOpen)
    }

    func testWithSessionClosesOnThrow() {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try BackupSession.shared.withSession(cartridge: nil) {
                throw Boom()
            })
        XCTAssertFalse(BackupSession.shared.isOpen)
    }

    func testNestedSessionThrows() throws {
        try BackupSession.shared.withSession(cartridge: nil) {
            XCTAssertThrowsError(
                try BackupSession.shared.withSession(cartridge: nil) {})
        }
    }

    func testOpeningWithCartridgeCreatesTheFile() throws {
        let file = BackupFile.cartridge4Mbit
        try? FileManager.default.removeItem(atPath: file.path)
        try BackupSession.shared.withSession(cartridge: file) {
            XCTAssertTrue(BackupSession.shared.isOpen)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(atPath: file.path)
    }
}
