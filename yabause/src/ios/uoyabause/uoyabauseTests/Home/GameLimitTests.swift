import XCTest
@testable import YabaSnashiro

@MainActor
final class GameLimitTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for dir in temporaryDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        temporaryDirectories = []
    }

    private func lite(_ purchase: PurchaseStatus) -> ProEntitlement {
        ProEntitlement(showsAdvertising: true, legacy: .notLegacy, purchase: purchase)
    }

    func testLiteStopsAtThree() {
        let locked = lite(.none)
        XCTAssertFalse(GameRepository.isOverFreeLimit(count: 2, entitlement: locked))
        XCTAssertTrue(GameRepository.isOverFreeLimit(count: 3, entitlement: locked))
        XCTAssertTrue(GameRepository.isOverFreeLimit(count: 9, entitlement: locked))
    }

    /// The whole point of the purchase: the limit has to lift.
    func testAProPurchaseLiftsTheLimit() {
        XCTAssertFalse(GameRepository.isOverFreeLimit(count: 99,
                                                      entitlement: lite(.lifetime)))
    }

    func testAProUserHasNoLimit() {
        let paid = ProEntitlement(showsAdvertising: false, legacy: .legacyPaid, purchase: .none)
        XCTAssertFalse(GameRepository.isOverFreeLimit(count: 99, entitlement: paid))
    }

    /// Blocking an import while StoreKit is still answering would refuse a
    /// subscriber at the moment they open the app.
    func testCheckingDoesNotBlock() {
        XCTAssertFalse(GameRepository.isOverFreeLimit(count: 99,
                                                      entitlement: lite(.unknown)))
    }

    func testTheImporterOpensTheGateInsteadOfRefusingSilently() {
        let importer = GameImporter()
        XCTAssertFalse(importer.canAdd(currentCount: 3, entitlement: lite(.none)))
        XCTAssertNotNil(importer.gateReason)
        XCTAssertNotNil(importer.gateReason?.message,
                        "the sheet should say which limit was met")
    }

    func testTheImporterLetsAProUserThrough() {
        let importer = GameImporter()
        XCTAssertTrue(importer.canAdd(currentCount: 3, entitlement: lite(.lifetime)))
        XCTAssertNil(importer.gateReason)
    }

    // MARK: - Multi-select import

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        temporaryDirectories.append(dir)
        return dir
    }

    /// Picks `count` disc images out of a source directory, as the document
    /// browser would hand them over in one multi-select.
    private func pickedFiles(_ count: Int, in dir: URL) throws -> [URL] {
        try (0..<count).map { index in
            let url = dir.appendingPathComponent("disc\(index).bin")
            try Data(repeating: 0, count: 16).write(to: url)
            return url
        }
    }

    private func importedCount(in dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasSuffix(".bin") }.count ?? 0
    }

    private func runImport(files: Int, entitlement: ProEntitlement) async throws
        -> (importer: GameImporter, library: URL) {
        let source = try makeTempDir()
        let library = try makeTempDir()
        let urls = try pickedFiles(files, in: source)
        let repository = GameRepository(rootDirectory: library,
                                        cache: GameListCache(directory: library))
        let defaults = UserDefaults(suiteName: "GameLimitTests-\(UUID().uuidString)")!
        let viewModel = GameListViewModel(repository: repository, defaults: defaults)
        let importer = GameImporter()
        await importer.importFiles(.success(urls), into: viewModel,
                                   repository: repository, entitlement: entitlement)
        return (importer, library)
    }

    /// Three at once is exactly the allowance, so nothing is refused.
    func testLockedLiteKeepsThreeFilesPickedAtOnce() async throws {
        let run = try await runImport(files: 3, entitlement: lite(.none))
        XCTAssertEqual(importedCount(in: run.library), 3)
        XCTAssertNil(run.importer.gateReason)
    }

    /// The limit was checked once before the picker opened, when the library
    /// was empty, so without a per-file check all five would land.
    func testLockedLiteStopsAtThreeWhenFivePickedAtOnce() async throws {
        let run = try await runImport(files: 5, entitlement: lite(.none))
        XCTAssertEqual(importedCount(in: run.library), 3)
        XCTAssertNotNil(run.importer.gateReason,
                        "the gate should open when the selection runs past the limit")
    }

    func testAProUserKeepsEveryFilePickedAtOnce() async throws {
        let run = try await runImport(files: 5, entitlement: lite(.lifetime))
        XCTAssertEqual(importedCount(in: run.library), 5)
        XCTAssertNil(run.importer.gateReason)
    }
}
