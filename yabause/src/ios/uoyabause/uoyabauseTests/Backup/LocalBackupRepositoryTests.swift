import XCTest
@testable import YabaSnashiro

final class LocalBackupRepositoryTests: XCTestCase {
    private var repository: LocalBackupRepository!
    /// Temporary directory holding the settings.plist injected into the
    /// repository, so the tests never read the real app settings.
    private var settingsDirectory: URL!

    override func setUpWithError() throws {
        // Start from a clean internal memory file so counts are deterministic.
        try? FileManager.default.removeItem(atPath: BackupFile.internalMemory.path)
        try? FileManager.default.removeItem(atPath: BackupFile.cartridge4Mbit.path)
        settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalBackupRepositoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: settingsDirectory,
                                                withIntermediateDirectories: true)
        repository = makeRepository(cartridgeValue: nil)
    }

    override func tearDownWithError() throws {
        BackupSession.shared.closeIfOpen()
        try? FileManager.default.removeItem(atPath: BackupFile.internalMemory.path)
        try? FileManager.default.removeItem(atPath: BackupFile.cartridge4Mbit.path)
        try? FileManager.default.removeItem(at: settingsDirectory)
    }

    /// A repository whose cartridge setting comes from a throwaway plist.
    /// A nil value writes no plist at all, meaning "no cartridge configured".
    private func makeRepository(cartridgeValue: Int?) -> LocalBackupRepository {
        let path = settingsDirectory
            .appendingPathComponent("settings-\(cartridgeValue.map(String.init) ?? "none").plist")
            .path
        if let cartridgeValue {
            XCTAssertTrue((["cartridge": cartridgeValue] as NSDictionary)
                .write(toFile: path, atomically: true))
        }
        return LocalBackupRepository(
            cartridgeSetting: BackupCartridgeSetting(settingsPath: path))
    }

    func testAvailableFilesAlwaysIncludesInternalMemory() {
        XCTAssertTrue(repository.availableFiles().contains(.internalMemory))
    }

    func testAvailableFilesWithoutAConfiguredCartridgeIsInternalMemoryOnly() {
        XCTAssertEqual(repository.availableFiles(), [.internalMemory])
    }

    func testAvailableFilesOffersOnlyTheConfiguredCartridge() {
        let configured = makeRepository(cartridgeValue: 3)
        XCTAssertEqual(configured.availableFiles(),
                       [.internalMemory, .cartridge8Mbit])
    }

    func testListOnFreshFileIsEmpty() throws {
        XCTAssertEqual(try repository.saves(in: .internalMemory).count, 0)
    }

    func testStatusOnFreshFileHasFreeSpace() throws {
        let status = try repository.status(of: .internalMemory)
        XCTAssertGreaterThan(status.totalBlock, 0)
        XCTAssertEqual(status.freeBlock, status.totalBlock - status.usedBlock)
        XCTAssertGreaterThan(status.freeSize, 0)
    }

    func testWriteThenListRoundTrip() throws {
        try repository.debugCreateSave(named: "TESTSAVE01", comment: "HELLO",
                                       in: .internalMemory, byteCount: 1024)
        let saves = try repository.saves(in: .internalMemory)
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(saves[0].filename, "TESTSAVE01")
        XCTAssertEqual(saves[0].comment, "HELLO")
        XCTAssertGreaterThan(saves[0].blockSize, 0)
    }

    func testStatusReflectsWrittenSave() throws {
        let before = try repository.status(of: .internalMemory)
        try repository.debugCreateSave(named: "TESTSAVE01", comment: "HELLO",
                                       in: .internalMemory, byteCount: 1024)
        let after = try repository.status(of: .internalMemory)
        XCTAssertLessThan(after.freeBlock, before.freeBlock)
    }

    func testDeleteRemovesTheSave() throws {
        try repository.debugCreateSave(named: "TESTSAVE01", comment: "HELLO",
                                       in: .internalMemory, byteCount: 1024)
        XCTAssertEqual(try repository.saves(in: .internalMemory).count, 1)

        try repository.delete(filename: "TESTSAVE01", in: .internalMemory)
        XCTAssertEqual(try repository.saves(in: .internalMemory).count, 0)
    }

    func testDeleteUnknownSaveThrows() throws {
        XCTAssertThrowsError(
            try repository.delete(filename: "NOSUCHSAVE", in: .internalMemory))
    }

    func testCopyInternalToCartridge() throws {
        try repository.debugCreateSave(named: "TESTSAVE01", comment: "HELLO",
                                       in: .internalMemory, byteCount: 1024)

        try repository.copy(filename: "TESTSAVE01",
                            from: .internalMemory, to: .cartridge4Mbit)

        let copied = try repository.saves(in: .cartridge4Mbit)
        XCTAssertEqual(copied.map(\.filename), ["TESTSAVE01"])
        // The source is untouched.
        XCTAssertEqual(try repository.saves(in: .internalMemory).map(\.filename),
                       ["TESTSAVE01"])
    }

    func testCopyToSameFileThrows() throws {
        try repository.debugCreateSave(named: "TESTSAVE01", comment: "HELLO",
                                       in: .internalMemory, byteCount: 1024)
        XCTAssertThrowsError(
            try repository.copy(filename: "TESTSAVE01",
                                from: .internalMemory, to: .internalMemory))
    }

    func testSaveExistsChecksDestination() throws {
        try repository.debugCreateSave(named: "TESTSAVE01", comment: "HELLO",
                                       in: .internalMemory, byteCount: 1024)
        XCTAssertTrue(try repository.saveExists(filename: "TESTSAVE01",
                                                in: .internalMemory))
        XCTAssertFalse(try repository.saveExists(filename: "TESTSAVE01",
                                                 in: .cartridge4Mbit))
    }

    func testExportRawReturnsTheSavedBytes() throws {
        try repository.debugCreateSave(named: "EXPORTME", comment: "HELLO",
                                       in: .internalMemory, byteCount: 1024)
        let bytes = try repository.exportRaw(filename: "EXPORTME", in: .internalMemory)
        XCTAssertEqual(bytes.count, 1024)
    }

    func testExportRawOnMissingSaveThrows() {
        XCTAssertThrowsError(
            try repository.exportRaw(filename: "NOSUCHSAVE", in: .internalMemory))
    }

    func testImportRawCreatesAListedSave() throws {
        let payload = Data(repeating: 0x33, count: 2048)
        try repository.importRaw(filename: "IMPORTED", comment: "FROMCLOUD",
                                 language: 0,
                                 saveDate: Date(timeIntervalSince1970: 894969000),
                                 data: payload, into: .internalMemory)

        let saves = try repository.saves(in: .internalMemory)
        XCTAssertEqual(saves.map(\.filename), ["IMPORTED"])
        XCTAssertEqual(saves[0].comment, "FROMCLOUD")
        XCTAssertEqual(saves[0].dataSize, 2048)
    }

    func testImportRawThenExportRawRoundTrips() throws {
        let payload = Data((0..<1500).map { UInt8($0 % 241) })
        try repository.importRaw(filename: "ROUNDTRIP", comment: "X", language: 0,
                                 saveDate: Date(timeIntervalSince1970: 894969000),
                                 data: payload, into: .internalMemory)
        let read = try repository.exportRaw(filename: "ROUNDTRIP", in: .internalMemory)
        XCTAssertEqual(read, payload)
    }
}
