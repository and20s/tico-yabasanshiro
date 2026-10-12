import XCTest
@testable import YabaSnashiro

@MainActor
final class SharedBackupImportTests: XCTestCase {
    private var database: FakeSharedBackupDatabase!
    private var storage: FakeSharedStorage!
    private var viewModel: SharedBackupBrowseViewModel!

    override func setUp() {
        super.setUp()
        database = FakeSharedBackupDatabase()
        storage = FakeSharedStorage()
        viewModel = SharedBackupBrowseViewModel(
            repository: SharedBackupRepository(database: database, storage: storage),
            isSignedIn: { true })
    }

    /// Importing a community save is a Pro feature, so every test about the
    /// import mechanics has to say who the user is. Leaving it to the default
    /// entitlement makes the result depend on when the app host's launch-time
    /// StoreKit read happens to land, which is how these tests passed while
    /// reading `.checking` and failed once it settled on `.locked`.
    private let unlocked = ProEntitlement(showsAdvertising: false,
                                          legacy: .legacyPaid, purchase: .none)

    private func makeItem(filename: String = "NIGHTS_01",
                          screenshotURL: String? = nil) -> SharedBackupItem {
        var data: [String: Any] = [
            "ownerId": "uid", "ownerName": "Shinya",
            "gameTitle": "NiGHTS", "productNumber": "GS-9046",
            "filename": filename, "comment": "stage 3", "description": "",
            "saveDate": "1996/07/05 12:34:56",
            "downloadUrl": "https://example.com/save",
            "downloadCount": 4, "isPublic": true,
            "ratings": ["average": 0.0, "count": 0],
            "dataSize": 2048, "blockSize": 4,
        ]
        if let screenshotURL { data["screenshotUrl"] = screenshotURL }
        return SharedBackupItem(id: "abc", data: data)!
    }

    func testImportWritesTheDownloadedBytesIntoTheChosenFile() async {
        storage.data = Data([1, 2, 3, 4])
        let local = FakeLocalImportTarget()

        let ok = await viewModel.import(item: makeItem(), into: .internalMemory,
                                        using: local, entitlement: unlocked)

        XCTAssertTrue(ok)
        XCTAssertEqual(local.imported.count, 1)
        XCTAssertEqual(local.imported.first?.filename, "NIGHTS_01")
        XCTAssertEqual(local.imported.first?.data, Data([1, 2, 3, 4]))
        XCTAssertEqual(local.imported.first?.file, .internalMemory)
    }

    /// The shared document carries no language field, so the import has to
    /// pick one. Android writes 0; matching it keeps the two apps' imports
    /// producing the same local save.
    func testImportUsesLanguageZeroBecauseTheDocumentHasNone() async {
        storage.data = Data([1])
        let local = FakeLocalImportTarget()
        _ = await viewModel.import(item: makeItem(), into: .internalMemory,
                                   using: local, entitlement: unlocked)
        XCTAssertEqual(local.imported.first?.language, 0)
    }

    /// An empty download must never reach the user's local saves.
    func testACorruptDownloadIsRejectedBeforeWriting() async {
        storage.data = Data()
        let local = FakeLocalImportTarget()

        let ok = await viewModel.import(item: makeItem(), into: .internalMemory,
                                        using: local, entitlement: unlocked)

        XCTAssertFalse(ok)
        XCTAssertTrue(local.imported.isEmpty, "a corrupt payload was written")
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// A full destination is a user-facing condition, not a generic failure.
    func testAFullDestinationReportsItsOwnMessage() async {
        storage.data = Data([1])
        let local = FakeLocalImportTarget()
        local.error = LocalBackupError.destinationFull

        let ok = await viewModel.import(item: makeItem(), into: .internalMemory,
                                        using: local, entitlement: unlocked)

        XCTAssertFalse(ok)
        XCTAssertEqual(viewModel.errorMessage,
                       String(localized: "Not enough space on the destination.",
                              comment: "Restore full error"))
    }

    /// Counting the download is bookkeeping: it must not decide whether the
    /// user got the save.
    func testImportSucceedsEvenWhenTheCountCannotBeWritten() async {
        storage.data = Data([1])
        database.incrementFails = true
        let local = FakeLocalImportTarget()

        let ok = await viewModel.import(item: makeItem(), into: .internalMemory,
                                        using: local, entitlement: unlocked)
        XCTAssertTrue(ok)
    }

    /// The row shows the new count straight away rather than waiting for a
    /// refetch that may never come.
    func testASuccessfulImportBumpsTheVisibleDownloadCount() async {
        storage.data = Data([1])
        database.pages = [SharedBackupPage(items: [makeItem()], cursor: nil)]
        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.items.first?.downloadCount, 4)

        _ = await viewModel.import(item: makeItem(), into: .internalMemory,
                                   using: FakeLocalImportTarget(),
                                   entitlement: unlocked)
        XCTAssertEqual(viewModel.items.first?.downloadCount, 5)
    }

    /// A failed import must not inflate the count.
    func testAFailedImportDoesNotBumpTheCount() async {
        storage.data = Data()
        database.pages = [SharedBackupPage(items: [makeItem()], cursor: nil)]
        await viewModel.loadInitial()

        _ = await viewModel.import(item: makeItem(), into: .internalMemory,
                                   using: FakeLocalImportTarget(),
                                   entitlement: unlocked)
        XCTAssertEqual(viewModel.items.first?.downloadCount, 4)
    }

    /// The image and the game live in local side stores keyed by file and
    /// name, not in the save, so an import that writes only the bytes lands
    /// with neither.
    func testImportCarriesTheScreenshotAndGameIntoTheLocalStores() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshots = BackupScreenshotStore(rootDirectory: directory)
        let suite = "SharedBackupImportTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = BackupMetadataStore(defaults: defaults)

        storage.data = Data([1, 2, 3, 4])
        storage.dataByURL["https://example.com/shot"] = Data([9, 9, 9])
        let item = makeItem(screenshotURL: "https://example.com/shot")

        let ok = await viewModel.import(item: item, into: .internalMemory,
                                        using: FakeLocalImportTarget(),
                                        screenshots: screenshots, metadata: metadata,
                                        entitlement: unlocked)

        XCTAssertTrue(ok)
        let path = try XCTUnwrap(screenshots.path(fileKey: "memory", filename: "NIGHTS_01"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([9, 9, 9]))
        XCTAssertEqual(metadata.lookup(fileKey: "memory", filename: "NIGHTS_01")?.gameTitle,
                       "NiGHTS")
    }

    /// A shared save with no image imports like any other.
    func testImportWithoutAScreenshotStillSucceeds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshots = BackupScreenshotStore(rootDirectory: directory)

        storage.data = Data([1, 2, 3, 4])

        let ok = await viewModel.import(item: makeItem(), into: .internalMemory,
                                        using: FakeLocalImportTarget(),
                                        screenshots: screenshots,
                                        entitlement: unlocked)

        XCTAssertTrue(ok)
        XCTAssertNil(screenshots.path(fileKey: "memory", filename: "NIGHTS_01"))
    }

    /// Android limits import and rating to Pro while leaving browsing open.
    func testImportIsRefusedWithoutAnEntitlement() async {
        storage.data = Data([1, 2, 3, 4])
        let local = FakeLocalImportTarget()

        let ok = await viewModel.import(item: makeItem(), into: .internalMemory,
                                        using: local,
                                        entitlement: ProEntitlement(showsAdvertising: true,
                                                                    legacy: .notLegacy,
                                                                    purchase: .none))

        XCTAssertFalse(ok)
        XCTAssertTrue(local.imported.isEmpty, "a locked import still wrote")
        XCTAssertNotNil(viewModel.gateReason, "the user was refused with no way to fix it")
    }

    func testImportGoesThroughForAProUser() async {
        storage.data = Data([1, 2, 3, 4])
        let local = FakeLocalImportTarget()

        let ok = await viewModel.import(item: makeItem(), into: .internalMemory,
                                        using: local,
                                        entitlement: ProEntitlement(showsAdvertising: true,
                                                                    legacy: .notLegacy,
                                                                    purchase: .lifetime))

        XCTAssertTrue(ok)
        XCTAssertEqual(local.imported.count, 1)
        XCTAssertNil(viewModel.gateReason)
    }

    /// Refusing while StoreKit is undecided would turn a slow answer into a
    /// sales pitch shown to someone who already paid.
    func testImportIsAllowedWhileChecking() async {
        storage.data = Data([1, 2, 3, 4])
        let local = FakeLocalImportTarget()

        let ok = await viewModel.import(item: makeItem(), into: .internalMemory,
                                        using: local,
                                        entitlement: ProEntitlement(showsAdvertising: true,
                                                                    legacy: .notLegacy,
                                                                    purchase: .unknown))

        XCTAssertTrue(ok)
    }
}

/// Stands in for LocalBackupRepository's import side.
final class FakeLocalImportTarget: BackupImportTarget, @unchecked Sendable {
    struct Write: Equatable {
        let filename: String
        let comment: String
        let language: Int
        let data: Data
        let file: BackupFile
    }

    var imported: [Write] = []
    var existing: Set<String> = []
    var error: Error?

    func saveExists(filename: String, in file: BackupFile) throws -> Bool {
        existing.contains(filename)
    }

    func importRaw(filename: String, comment: String, language: Int,
                   saveDate: Date?, data: Data, into file: BackupFile) throws {
        if let error { throw error }
        imported.append(Write(filename: filename, comment: comment,
                              language: language, data: data, file: file))
    }
}
