import XCTest
@testable import YabaSnashiro

@MainActor
final class SharedBackupPublishTests: XCTestCase {
    private var database: FakeSharedBackupDatabase!
    private var storage: FakeSharedStorage!
    private var publisher: SharedBackupPublisher!

    override func setUp() {
        super.setUp()
        database = FakeSharedBackupDatabase()
        storage = FakeSharedStorage()
        publisher = SharedBackupPublisher(
            repository: SharedBackupRepository(database: database, storage: storage),
            identity: { SharedBackupPublisher.Publisher(
                userId: "uid-1", name: "Shinya", photoURL: nil) })
    }

    /// BackupSave is built from the native struct, so this fills one the way
    /// BackupSaveTests does rather than inventing a second initialiser.
    private func makeSave(filename: String = "NIGHTS_01") -> BackupSave {
        var raw = YSBupSave()
        withUnsafeMutableBytes(of: &raw.filename) { buffer in
            for (index, byte) in Array(filename.utf8).prefix(11).enumerated() {
                buffer[index] = byte
            }
        }
        withUnsafeMutableBytes(of: &raw.comment) { buffer in
            for (index, byte) in Array("stage 3".utf8).prefix(10).enumerated() {
                buffer[index] = byte
            }
        }
        raw.year = 96
        raw.month = 7
        raw.day = 5
        raw.hour = 12
        raw.minute = 34
        raw.datasize = 2048
        raw.blocksize = 4
        return BackupSave(raw: raw, file: .internalMemory)
    }

    private func makeDetails(title: String = "NiGHTS") -> SharedBackupDetails {
        SharedBackupDetails(gameTitle: title, productNumber: "GS-9046",
                            description: "all A ranks")
    }

    /// The whole point: bytes to Storage, then a document Android can read.
    func testPublishUploadsTheSaveThenWritesTheDocument() async throws {
        let id = try await publisher.publish(save: makeSave(), data: Data([1, 2, 3]),
                                             screenshot: nil,
                                             details: makeDetails())

        XCTAssertEqual(storage.uploaded.map(\.path),
                       ["shared_backups/\(id)/NIGHTS_01"])
        let written = try XCTUnwrap(database.stored[id])
        XCTAssertEqual(written.filename, "NIGHTS_01")
        XCTAssertEqual(written.gameTitle, "NiGHTS")
        XCTAssertEqual(written.ownerId, "uid-1")
        XCTAssertEqual(written.ownerName, "Shinya")
        XCTAssertTrue(written.isPublic)
    }

    /// A screenshot goes to the fixed name Android reads back.
    func testAScreenshotIsUploadedAlongside() async throws {
        let id = try await publisher.publish(save: makeSave(), data: Data([1]),
                                             screenshot: Data([9, 9]),
                                             details: makeDetails())
        XCTAssertEqual(storage.uploaded.map(\.path).sorted(), [
            "shared_backups/\(id)/NIGHTS_01",
            "shared_backups/\(id)/screenshot.png",
        ].sorted())
        XCTAssertNotNil(database.stored[id]?.screenshotURL)
    }

    /// A save with no screenshot still publishes; the field is an explicit
    /// null, which is what Android writes.
    func testPublishingWithoutAScreenshotStillWritesTheDocument() async throws {
        let id = try await publisher.publish(save: makeSave(), data: Data([1]),
                                             screenshot: nil,
                                             details: makeDetails())
        XCTAssertNil(database.stored[id]?.screenshotURL)
        XCTAssertTrue(database.stored[id]?.documentData()["screenshotUrl"] is NSNull)
    }

    /// Android requires a title, and a blank one makes the record unfindable.
    func testABlankTitleIsRejectedBeforeAnythingIsUploaded() async {
        do {
            _ = try await publisher.publish(save: makeSave(), data: Data([1]),
                                            screenshot: nil,
                                            details: makeDetails(title: "  "))
            XCTFail("published with no title")
        } catch {
            XCTAssertTrue(storage.uploaded.isEmpty, "uploaded before validating")
            XCTAssertTrue(database.stored.isEmpty)
        }
    }

    /// Publishing is an identity-bearing act; without a signed-in user there
    /// is no owner to record and no way to delete it later.
    func testPublishingRequiresASignedInUser() async {
        publisher = SharedBackupPublisher(
            repository: SharedBackupRepository(database: database, storage: storage),
            identity: { nil })
        do {
            _ = try await publisher.publish(save: makeSave(), data: Data([1]),
                                            screenshot: nil, details: makeDetails())
            XCTFail("published while signed out")
        } catch {
            XCTAssertTrue(storage.uploaded.isEmpty)
        }
    }

    /// Android leaves the blob behind when the document write fails. Clean it
    /// up so a failed publish does not bill for an object nobody can reach.
    func testAFailedDocumentWriteRemovesTheUploadedObjects() async {
        database.writeFails = true
        do {
            _ = try await publisher.publish(save: makeSave(), data: Data([1]),
                                            screenshot: Data([9]),
                                            details: makeDetails())
            XCTFail("reported success after the document write failed")
        } catch {
            XCTAssertEqual(storage.removed.count, 2,
                           "the orphaned save and screenshot were not cleaned up")
        }
    }

    /// The share link both apps build.
    func testTheShareLinkMatchesAndroid() {
        XCTAssertEqual(SharedBackupPublisher.shareURL(id: "abc").absoluteString,
                       "https://www.yabasanshiro.com/backup/abc")
    }
}
