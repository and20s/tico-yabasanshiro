import XCTest
@testable import YabaSnashiro

final class BackupMetadataStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: BackupMetadataStore!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "BackupMetadataStoreTests")
        defaults.removePersistentDomain(forName: "BackupMetadataStoreTests")
        store = BackupMetadataStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: "BackupMetadataStoreTests")
    }

    func testRecordAndLookup() {
        store.record(gameTitle: "Sonic R", productNumber: "GS-9099",
                     fileKey: "memory", filename: "SONICR_01")
        let info = store.lookup(fileKey: "memory", filename: "SONICR_01")
        XCTAssertEqual(info?.gameTitle, "Sonic R")
        XCTAssertEqual(info?.productNumber, "GS-9099")
    }

    func testLookupUnknownReturnsNil() {
        XCTAssertNil(store.lookup(fileKey: "memory", filename: "NOPE"))
    }

    func testKeysAreScopedByFile() {
        store.record(gameTitle: "Sonic R", productNumber: "GS-9099",
                     fileKey: "memory", filename: "SAVE01")
        XCTAssertNil(store.lookup(fileKey: "backup4", filename: "SAVE01"))
    }

    func testRecordOverwrites() {
        store.record(gameTitle: "Old", productNumber: "GS-0001",
                     fileKey: "memory", filename: "SAVE01")
        store.record(gameTitle: "New", productNumber: "GS-0002",
                     fileKey: "memory", filename: "SAVE01")
        XCTAssertEqual(store.lookup(fileKey: "memory", filename: "SAVE01")?.gameTitle,
                       "New")
    }

    /// The keys include the file, so a save copied to another backup file
    /// arrives without a game unless the entry is carried over too.
    func testCopyCarriesTheGameToTheDestinationFile() {
        store.record(gameTitle: "Sonic R", productNumber: "GS-9099",
                     fileKey: "memory", filename: "SAVE01")

        store.copy(fileKey: "memory", filename: "SAVE01", toFileKey: "backup4")

        let info = store.lookup(fileKey: "backup4", filename: "SAVE01")
        XCTAssertEqual(info?.gameTitle, "Sonic R")
        XCTAssertEqual(info?.productNumber, "GS-9099")
    }

    func testCopyOfAnUnknownSaveRecordsNothing() {
        store.copy(fileKey: "memory", filename: "NOPE", toFileKey: "backup4")
        XCTAssertNil(store.lookup(fileKey: "backup4", filename: "NOPE"))
    }
}
