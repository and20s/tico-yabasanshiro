import XCTest
@testable import YabaSnashiro

final class CartridgeFileMigrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "CartridgeFileMigrationTests")
        defaults.removePersistentDomain(forName: "CartridgeFileMigrationTests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: "CartridgeFileMigrationTests")
    }

    private func writeInvalidFile(byteCount: Int) throws {
        let data = Data(repeating: 0, count: byteCount)
        try data.write(to: directory.appendingPathComponent("invalid.ram"))
    }

    private func run() -> CartridgeFileMigration.Outcome {
        CartridgeFileMigration(cartDirectory: directory, defaults: defaults).run()
    }

    func testRenamesBySize() throws {
        try writeInvalidFile(byteCount: 0x200000) // 8 Mbit
        XCTAssertEqual(run(), .migrated(to: .cartridge8Mbit))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("backup8.ram").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("invalid.ram").path))
    }

    func testUnknownSizeIsLeftAlone() throws {
        try writeInvalidFile(byteCount: 1234)
        XCTAssertEqual(run(), .skippedUnknownSize)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("invalid.ram").path))
    }

    func testExistingDestinationIsLeftAlone() throws {
        try writeInvalidFile(byteCount: 0x100000)
        try Data(repeating: 1, count: 8).write(
            to: directory.appendingPathComponent("backup4.ram"))
        XCTAssertEqual(run(), .skippedDestinationExists)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("invalid.ram").path))
        // The pre-existing destination is not overwritten.
        let existing = try Data(contentsOf: directory.appendingPathComponent("backup4.ram"))
        XCTAssertEqual(existing.count, 8)
    }

    func testNoFileIsNoOp() {
        XCTAssertEqual(run(), .nothingToDo)
    }

    func testRunsOnlyOnce() throws {
        try writeInvalidFile(byteCount: 0x100000)
        XCTAssertEqual(run(), .migrated(to: .cartridge4Mbit))
        // A second invalid.ram appearing later must not be touched again.
        try writeInvalidFile(byteCount: 0x200000)
        XCTAssertEqual(run(), .alreadyRun)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("invalid.ram").path))
    }
}
