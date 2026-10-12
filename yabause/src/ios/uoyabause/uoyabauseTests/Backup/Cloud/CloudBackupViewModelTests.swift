import XCTest
@testable import YabaSnashiro

/// Stands in for Firebase Auth so the view model can be tested signed in and out.
struct FakeCloudAuth: CloudAuth {
    var userId: String?
}

@MainActor
final class CloudBackupViewModelTests: XCTestCase {
    private var database: FakeCloudDatabase!
    private var storage: FakeCloudStorage!
    private var screenshots: BackupScreenshotStore!
    private var metadata: BackupMetadataStore!
    private var screenshotDirectory: URL!

    private static let defaultsSuite = "CloudBackupViewModelTests"

    override func setUpWithError() throws {
        database = FakeCloudDatabase()
        storage = FakeCloudStorage()
        screenshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        screenshots = BackupScreenshotStore(rootDirectory: screenshotDirectory)
        let defaults = UserDefaults(suiteName: Self.defaultsSuite)!
        defaults.removePersistentDomain(forName: Self.defaultsSuite)
        metadata = BackupMetadataStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: screenshotDirectory)
        UserDefaults(suiteName: Self.defaultsSuite)?
            .removePersistentDomain(forName: Self.defaultsSuite)
    }

    private func makeViewModel(userId: String? = "u",
                               entitled: Bool = true,
                               checking: Bool = false) -> CloudBackupViewModel {
        CloudBackupViewModel(
            repository: CloudBackupRepository(database: database, storage: storage),
            auth: FakeCloudAuth(userId: userId),
            isEntitled: entitled,
            isCheckingEntitlement: checking,
            entitledSlotCount: 256)
    }

    func testUndecidedEntitlementDoesNotPromptForUpgrade() async {
        // A Lite subscriber must not be sold cloud backup while StoreKit is
        // still deciding whether they already have it.
        let viewModel = makeViewModel(entitled: false, checking: true)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .checkingEntitlement)
    }

    /// The view model is built at app-root, before StoreKit answers, so the
    /// entitlement it saw at construction is always "checking" on Lite. It
    /// has to read the entitlement again on every load, or a subscriber who
    /// pays is left staring at the spinner for the whole session.
    func testEntitlementIsReReadOnEachLoad() async {
        var entitlement = CloudBackupEntitlement(isEnabled: false,
                                                 isCheckingEntitlement: true,
                                                 slotCount: 0)
        let viewModel = CloudBackupViewModel(
            repository: CloudBackupRepository(database: database, storage: storage),
            auth: FakeCloudAuth(userId: "u"),
            entitlement: { entitlement })

        await viewModel.load()
        XCTAssertEqual(viewModel.state, .checkingEntitlement)

        entitlement = CloudBackupEntitlement(isEnabled: true,
                                             isCheckingEntitlement: false,
                                             slotCount: 256)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .empty)
        XCTAssertTrue(viewModel.isEntitled)
        XCTAssertFalse(viewModel.isCheckingEntitlement)
    }

    /// A legacy paid customer opens Backup -> Cloud in the second before
    /// AppTransaction answers. The first load bails to `.checkingEntitlement`,
    /// and if that counted as "loaded once" the section would spin until the
    /// app was relaunched.
    func testAnUndecidedEntitlementDoesNotLatchTheInitialLoad() async {
        var entitlement = CloudBackupEntitlement(isEnabled: false,
                                                 isCheckingEntitlement: true,
                                                 slotCount: 0)
        let viewModel = CloudBackupViewModel(
            repository: CloudBackupRepository(database: database, storage: storage),
            auth: FakeCloudAuth(userId: "u"),
            entitlement: { entitlement })

        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.state, .checkingEntitlement)

        entitlement = CloudBackupEntitlement(isEnabled: true,
                                             isCheckingEntitlement: false,
                                             slotCount: 256)
        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.state, .empty)
    }

    /// The latch still has to hold once a real answer arrived, or every
    /// sidebar switch would hit the network again.
    func testADecidedInitialLoadStillRunsOnlyOnce() async {
        var entitlement = CloudBackupEntitlement(isEnabled: true,
                                                 isCheckingEntitlement: false,
                                                 slotCount: 256)
        let viewModel = CloudBackupViewModel(
            repository: CloudBackupRepository(database: database, storage: storage),
            auth: FakeCloudAuth(userId: "u"),
            entitlement: { entitlement })

        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.state, .empty)

        entitlement = CloudBackupEntitlement(isEnabled: false,
                                             isCheckingEntitlement: true,
                                             slotCount: 0)
        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.state, .empty)
    }

    /// The view model can only re-run the load if something asks it to, and
    /// the only event that can is the entitlement resolving.
    func testTheCloudSectionReloadsWhenTheEntitlementResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Cloud
            .deletingLastPathComponent()   // Backup
            .deletingLastPathComponent()   // uoyabauseTests
            .deletingLastPathComponent()   // project dir
            .appendingPathComponent("uoyabause/Backup/Views/CloudBackupSection.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("@ObservedObject private var entitlementStore"),
                      "the cloud section no longer observes the entitlement store")
        XCTAssertTrue(source.contains(".onChange(of: entitlementStore.entitlement)"),
                      "the cloud section no longer reacts to the entitlement resolving")
    }

    /// The local detail sheet reads `isEntitled` without the cloud section
    /// ever having been on screen, so no load() has run. Held as a snapshot
    /// it would still be the app-root value -- "checking", so not entitled --
    /// and a subscriber would find no upload button and nothing to tap.
    func testEntitlementIsFreshWithoutALoad() {
        var entitlement = CloudBackupEntitlement(isEnabled: false,
                                                 isCheckingEntitlement: true,
                                                 slotCount: 0)
        let viewModel = CloudBackupViewModel(
            repository: CloudBackupRepository(database: database, storage: storage),
            auth: FakeCloudAuth(userId: "u"),
            entitlement: { entitlement })
        XCTAssertFalse(viewModel.isEntitled)
        XCTAssertTrue(viewModel.isCheckingEntitlement)

        entitlement = CloudBackupEntitlement(isEnabled: true,
                                             isCheckingEntitlement: false,
                                             slotCount: 256)
        XCTAssertTrue(viewModel.isEntitled)
        XCTAssertFalse(viewModel.isCheckingEntitlement)
    }

    func testSignedOutReportsAuthRequired() async {
        let viewModel = makeViewModel(userId: nil)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .signInRequired)
    }

    func testUnentitledReportsUpgradeRequired() async {
        let viewModel = makeViewModel(entitled: false)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .upgradeRequired)
    }

    func testUnentitledIsCheckedBeforeSignIn() async {
        // A Lite user who is signed out should be told to upgrade, not to sign in.
        let viewModel = makeViewModel(userId: nil, entitled: false)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .upgradeRequired)
    }

    func testLoadedWithNoRecordsReportsEmpty() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .empty)
    }

    func testLoadedRecordsArePublished() async {
        database.records = [
            "a": ["filename": "AAA", "saveDate": "2024/03/20 15:30:00",
                  "dataSize": 100, "downloadUrl": "https://example.com/a"],
            "b": ["filename": "BBB", "saveDate": "2024/03/21 15:30:00",
                  "dataSize": 200, "downloadUrl": "https://example.com/b"],
        ]
        let viewModel = makeViewModel()
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.displayItems.count, 2)
    }

    func testLoadWritesTheEntitledSlotCount() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        XCTAssertEqual(database.writtenMaxCount, 256)
    }

    func testNetworkFailureReportsFailed() async {
        database.shouldFail = true
        let viewModel = makeViewModel()
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .failed)
    }

    func testSortByNameAscending() async {
        database.records = [
            "a": ["filename": "BBB", "saveDate": "2024/03/20 15:30:00"],
            "b": ["filename": "AAA", "saveDate": "2024/03/21 15:30:00"],
        ]
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.sortMode = .nameAscending
        XCTAssertEqual(viewModel.displayItems.map(\.filename), ["AAA", "BBB"])
    }

    func testSortByDateDescendingIsTheDefault() async {
        database.records = [
            "a": ["filename": "OLD", "saveDate": "2024/03/20 15:30:00"],
            "b": ["filename": "NEW", "saveDate": "2024/03/21 15:30:00"],
        ]
        let viewModel = makeViewModel()
        await viewModel.load()
        XCTAssertEqual(viewModel.sortMode, .dateDescending)
        XCTAssertEqual(viewModel.displayItems.map(\.filename), ["NEW", "OLD"])
    }

    func testSearchFiltersByNameCommentAndGameTitle() async {
        database.records = [
            "a": ["filename": "AAA", "comment": "SONIC", "gameTitle": "Sonic R"],
            "b": ["filename": "BBB", "comment": "NIGHTS", "gameTitle": "NiGHTS"],
        ]
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.searchText = "sonic"
        XCTAssertEqual(viewModel.displayItems.map(\.filename), ["AAA"])
        viewModel.searchText = "bbb"
        XCTAssertEqual(viewModel.displayItems.map(\.filename), ["BBB"])
        viewModel.searchText = ""
        XCTAssertEqual(viewModel.displayItems.count, 2)
    }

    func testDeleteRemovesTheItem() async {
        database.records = ["a": ["filename": "AAA",
                                  "downloadUrl": "https://example.com/a"]]
        let viewModel = makeViewModel()
        await viewModel.load()
        await viewModel.delete(key: "a")
        XCTAssertTrue(viewModel.displayItems.isEmpty)
        XCTAssertEqual(database.removedKeys, ["a"])
    }

    func testSlotUsageIsPublished() async {
        database.maxBackupCount = 256
        database.records = ["a": ["filename": "AAA"]]
        let viewModel = makeViewModel()
        await viewModel.load()
        XCTAssertEqual(viewModel.slotUsage?.used, 1)
        XCTAssertEqual(viewModel.slotUsage?.total, 256)
    }

    // MARK: - Restore

    private func makeCloudItem(screenshotURL: String? = "https://example.com/shot")
        -> CloudBackupItem {
        CloudBackupItem(key: "k", filename: "NIGHTS_01", comment: "stage 3",
                        language: 0, saveDate: nil, dataSize: 3, blockSize: 1,
                        downloadURL: "https://example.com/save",
                        screenshotURL: screenshotURL,
                        gameTitle: "NiGHTS", productNumber: "GS-9046")
    }

    private func seedCloudObjects(screenshot: Data? = Data([9, 9, 9])) {
        storage.objects["save"] = Data([1, 2, 3])
        storage.downloadURLs["save"] = "https://example.com/save"
        if let screenshot {
            storage.objects["shot"] = screenshot
            storage.downloadURLs["shot"] = "https://example.com/shot"
        }
    }

    /// The screenshot and the game are held in local side stores keyed by file
    /// and name, not inside the save, so a restore that writes only the bytes
    /// lands with neither.
    func testRestoreCarriesTheScreenshotAndGameIntoTheLocalStores() async throws {
        seedCloudObjects()
        let viewModel = makeViewModel()

        let ok = await viewModel.restore(item: makeCloudItem(), into: .internalMemory,
                                         using: FakeLocalImportTarget(),
                                         screenshots: screenshots, metadata: metadata)

        XCTAssertTrue(ok)
        let path = try XCTUnwrap(screenshots.path(fileKey: "memory", filename: "NIGHTS_01"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([9, 9, 9]))
        XCTAssertEqual(metadata.lookup(fileKey: "memory", filename: "NIGHTS_01")?.gameTitle,
                       "NiGHTS")
    }

    /// Saves uploaded before screenshots existed carry none, and those restore
    /// like any other.
    func testRestoreWithoutAScreenshotStillSucceeds() async {
        seedCloudObjects(screenshot: nil)
        let viewModel = makeViewModel()

        let ok = await viewModel.restore(item: makeCloudItem(screenshotURL: nil),
                                         into: .internalMemory,
                                         using: FakeLocalImportTarget(),
                                         screenshots: screenshots, metadata: metadata)

        XCTAssertTrue(ok)
        XCTAssertNil(screenshots.path(fileKey: "memory", filename: "NIGHTS_01"))
    }

    /// The image is decoration: an unreachable one must not cost the user the
    /// save they asked to restore.
    func testAnUnreachableScreenshotDoesNotFailTheRestore() async {
        seedCloudObjects(screenshot: nil)
        let viewModel = makeViewModel()

        let ok = await viewModel.restore(item: makeCloudItem(), into: .internalMemory,
                                         using: FakeLocalImportTarget(),
                                         screenshots: screenshots, metadata: metadata)

        XCTAssertTrue(ok)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(screenshots.path(fileKey: "memory", filename: "NIGHTS_01"))
    }
}
