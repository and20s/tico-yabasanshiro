import XCTest
import UIKit
@testable import YabaSnashiro

final class BackupScreenshotStoreTests: XCTestCase {
    private var directory: URL!
    private var store: BackupScreenshotStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        store = BackupScreenshotStore(rootDirectory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    func testSaveThenPathExists() throws {
        store.save(makeImage(), fileKey: "memory", filename: "SAVE01")
        let path = store.path(fileKey: "memory", filename: "SAVE01")
        XCTAssertNotNil(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path!))
    }

    func testPathIsNilWhenMissing() {
        XCTAssertNil(store.path(fileKey: "memory", filename: "NOPE"))
    }

    func testPathsAreScopedByFileKey() {
        store.save(makeImage(), fileKey: "memory", filename: "SAVE01")
        XCTAssertNil(store.path(fileKey: "backup4", filename: "SAVE01"))
    }

    func testDeleteRemovesTheFile() {
        store.save(makeImage(), fileKey: "memory", filename: "SAVE01")
        store.delete(fileKey: "memory", filename: "SAVE01")
        XCTAssertNil(store.path(fileKey: "memory", filename: "SAVE01"))
    }

    func testSavingEncodedBytesStoresThemVerbatim() throws {
        let data = makeImage().pngData()!
        store.save(pngData: data, fileKey: "memory", filename: "SAVE01")

        let path = try XCTUnwrap(store.path(fileKey: "memory", filename: "SAVE01"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
    }

    /// The store is keyed by backup file, so a save copied to another file
    /// needs its image copied with it or the copy lands without one.
    func testCopyPlacesTheImageUnderTheDestinationFile() throws {
        store.save(makeImage(), fileKey: "memory", filename: "SAVE01")

        store.copy(fileKey: "memory", filename: "SAVE01", toFileKey: "backup4")

        let source = try XCTUnwrap(store.path(fileKey: "memory", filename: "SAVE01"))
        let destination = try XCTUnwrap(store.path(fileKey: "backup4", filename: "SAVE01"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)),
                       try Data(contentsOf: URL(fileURLWithPath: source)))
    }

    /// Saves written before screenshots existed have none, and copying one of
    /// those is an ordinary case rather than a failure.
    func testCopyOfAMissingImageLeavesTheDestinationEmpty() {
        store.copy(fileKey: "memory", filename: "NOPE", toFileKey: "backup4")
        XCTAssertNil(store.path(fileKey: "backup4", filename: "NOPE"))
    }
}
