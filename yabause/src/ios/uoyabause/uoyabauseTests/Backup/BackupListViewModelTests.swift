import XCTest
@testable import YabaSnashiro

@MainActor
final class BackupListViewModelTests: XCTestCase {
    private var viewModel: BackupListViewModel!

    override func setUpWithError() throws {
        try? FileManager.default.removeItem(atPath: BackupFile.internalMemory.path)
        viewModel = BackupListViewModel(repository: LocalBackupRepository())
    }

    override func tearDownWithError() throws {
        BackupSession.shared.closeIfOpen()
        try? FileManager.default.removeItem(atPath: BackupFile.internalMemory.path)
    }

    private func seed(_ names: [(String, String)]) throws {
        let repository = LocalBackupRepository()
        for (name, comment) in names {
            try repository.debugCreateSave(named: name, comment: comment,
                                           in: .internalMemory, byteCount: 1024)
        }
    }

    func testLoadPublishesSaves() async throws {
        try seed([("BSAVE", "SECOND"), ("ASAVE", "FIRST")])
        await viewModel.load()
        XCTAssertEqual(viewModel.displaySaves.count, 2)
        XCTAssertNotNil(viewModel.status)
    }

    func testSortByNameAscendingIsDefault() async throws {
        try seed([("BSAVE", "B"), ("ASAVE", "A")])
        await viewModel.load()
        XCTAssertEqual(viewModel.sortMode, .dateDescending)
        viewModel.sortMode = .nameAscending
        XCTAssertEqual(viewModel.displaySaves.map(\.filename), ["ASAVE", "BSAVE"])
    }

    func testSortByNameDescending() async throws {
        try seed([("ASAVE", "A"), ("BSAVE", "B")])
        await viewModel.load()
        viewModel.sortMode = .nameDescending
        XCTAssertEqual(viewModel.displaySaves.map(\.filename), ["BSAVE", "ASAVE"])
    }

    func testSearchFiltersByNameAndComment() async throws {
        try seed([("ASAVE", "SONIC"), ("BSAVE", "NIGHTS")])
        await viewModel.load()
        viewModel.searchText = "sonic"
        XCTAssertEqual(viewModel.displaySaves.map(\.filename), ["ASAVE"])
        viewModel.searchText = "bsa"
        XCTAssertEqual(viewModel.displaySaves.map(\.filename), ["BSAVE"])
        viewModel.searchText = ""
        XCTAssertEqual(viewModel.displaySaves.count, 2)
    }

    func testAvailableFilesIncludesInternalMemory() async {
        await viewModel.load()
        XCTAssertTrue(viewModel.availableFiles.contains(.internalMemory))
    }

    /// The copy targets are whatever the repository offered minus the file
    /// being looked at, so with no cartridge configured there is nowhere to
    /// copy to.
    func testCopyDestinationsWithoutACartridgeIsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupListViewModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.plist").path
        let repository = LocalBackupRepository(
            cartridgeSetting: BackupCartridgeSetting(settingsPath: path))
        let model = BackupListViewModel(repository: repository)

        await model.load()

        XCTAssertEqual(model.availableFiles, [.internalMemory])
        XCTAssertEqual(model.copyDestinations(), [])
    }

    func testDeleteRemovesFromList() async throws {
        try seed([("ASAVE", "A")])
        await viewModel.load()
        await viewModel.delete(filename: "ASAVE")
        XCTAssertEqual(viewModel.displaySaves.count, 0)
    }

    func testSuccessfulLoadClearsTheLoadFailedFlag() async throws {
        try seed([("ASAVE", "A")])
        await viewModel.load()
        XCTAssertFalse(viewModel.loadFailed)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// Both side stores are keyed by backup file, so a save copied to the
    /// cartridge shows up there with no image and no game unless the copy
    /// carries them over.
    func testCopyCarriesTheScreenshotAndGameToTheDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupListViewModelTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshots = BackupScreenshotStore(rootDirectory: directory)
        let suite = "BackupListViewModelTests-copy"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = BackupMetadataStore(defaults: defaults)

        try seed([("ASAVE", "A")])
        defer { try? FileManager.default.removeItem(atPath: BackupFile.cartridge4Mbit.path) }
        screenshots.save(pngData: Data([9, 9, 9]), fileKey: "memory", filename: "ASAVE")
        metadata.record(gameTitle: "NiGHTS", productNumber: "GS-9046",
                        fileKey: "memory", filename: "ASAVE")
        let model = BackupListViewModel(repository: LocalBackupRepository(),
                                        metadata: metadata, screenshots: screenshots)
        await model.load()

        await model.copy(filename: "ASAVE", to: .cartridge4Mbit)

        let path = try XCTUnwrap(screenshots.path(fileKey: "backup4", filename: "ASAVE"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([9, 9, 9]))
        XCTAssertEqual(metadata.lookup(fileKey: "backup4", filename: "ASAVE")?.gameTitle,
                       "NiGHTS")
    }
}
