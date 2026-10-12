import XCTest
@testable import YabaSnashiro

/// The shared-backup document is read and written by both apps, so these pin
/// the exact field names and shapes Android uses. A mismatch here does not
/// crash -- it silently hides or corrupts records, which is how SP3b's
/// interop bugs presented.
final class SharedBackupItemTests: XCTestCase {
    private func makeDocument() -> [String: Any] {
        [
            "ownerId": "uid-1",
            "ownerName": "Shinya",
            "ownerPhotoUrl": "https://example.com/a.png",
            "gameTitle": "NiGHTS INTO DREAMS",
            "productNumber": "GS-9046",
            "filename": "NIGHTS_01",
            "comment": "stage 3",
            "description": "all A ranks",
            "saveDate": "1996/07/05 12:34:56",
            "downloadUrl": "https://example.com/save?token=1",
            "sharedAt": Date(timeIntervalSince1970: 1_700_000_000),
            "downloadCount": 7,
            "isPublic": true,
            "ratings": ["average": 4.5, "count": 12],
            "dataSize": 2048,
            "blockSize": 4,
            "screenshotUrl": "https://example.com/shot.png",
        ]
    }

    func testReadsEveryFieldAndroidWrites() throws {
        let item = try XCTUnwrap(SharedBackupItem(id: "abc", data: makeDocument()))
        XCTAssertEqual(item.id, "abc")
        XCTAssertEqual(item.ownerId, "uid-1")
        XCTAssertEqual(item.ownerName, "Shinya")
        XCTAssertEqual(item.gameTitle, "NiGHTS INTO DREAMS")
        XCTAssertEqual(item.productNumber, "GS-9046")
        XCTAssertEqual(item.filename, "NIGHTS_01")
        XCTAssertEqual(item.description, "all A ranks")
        XCTAssertEqual(item.downloadURL, "https://example.com/save?token=1")
        XCTAssertEqual(item.downloadCount, 7)
        XCTAssertEqual(item.dataSize, 2048)
        XCTAssertEqual(item.blockSize, 4)
        XCTAssertEqual(item.screenshotURL, "https://example.com/shot.png")
    }

    /// The aggregate lives in a map *field* called `ratings`, which shares its
    /// name with a subcollection. Reading it as anything else loses the score.
    func testReadsTheRatingAggregateFromTheMapField() throws {
        let item = try XCTUnwrap(SharedBackupItem(id: "abc", data: makeDocument()))
        XCTAssertEqual(item.averageRating, 4.5, accuracy: 0.001)
        XCTAssertEqual(item.ratingCount, 12)
    }

    /// Android's reader defaults every field, so a partial document must still
    /// produce an item rather than vanishing from the list.
    func testTolerATesAMissingOptionalField() throws {
        var data = makeDocument()
        data["ownerPhotoUrl"] = NSNull()
        data["screenshotUrl"] = NSNull()
        data["ratings"] = ["average": 0.0, "count": 0]
        data.removeValue(forKey: "description")

        let item = try XCTUnwrap(SharedBackupItem(id: "abc", data: data))
        XCTAssertNil(item.ownerPhotoURL)
        XCTAssertNil(item.screenshotURL)
        XCTAssertEqual(item.description, "")
        XCTAssertEqual(item.ratingCount, 0)
    }

    /// Without a filename the save cannot be restored, and the Storage path
    /// cannot be built, so the record is not usable.
    func testRejectsADocumentWithNoFilename() {
        var data = makeDocument()
        data["filename"] = ""
        XCTAssertNil(SharedBackupItem(id: "abc", data: data))
    }

    /// saveDate is a string, not a Timestamp. It has to round-trip through the
    /// same formatter the personal cloud path already uses.
    func testParsesTheStringSaveDate() throws {
        let item = try XCTUnwrap(SharedBackupItem(id: "abc", data: makeDocument()))
        XCTAssertNotNil(item.saveDate)

        var dashed = makeDocument()
        dashed["saveDate"] = "1996-07-05 12:34:56"
        XCTAssertNotNil(try XCTUnwrap(SharedBackupItem(id: "b", data: dashed)).saveDate)
    }

    /// Publishing must emit exactly the keys Android reads back.
    func testWritesTheAndroidDocumentShape() throws {
        let item = try XCTUnwrap(SharedBackupItem(id: "abc", data: makeDocument()))
        let map = item.documentData()

        for key in ["ownerId", "ownerName", "ownerPhotoUrl", "gameTitle",
                    "productNumber", "filename", "comment", "description",
                    "saveDate", "downloadUrl", "sharedAt", "downloadCount",
                    "isPublic", "ratings", "dataSize", "blockSize",
                    "screenshotUrl"] {
            XCTAssertNotNil(map[key], "publish would omit \(key)")
        }
        XCTAssertEqual(map["isPublic"] as? Bool, true)
        XCTAssertTrue(map["saveDate"] is String, "saveDate must stay a string")
    }

    /// An absent photo or screenshot is written as an explicit null, not left
    /// out -- Android writes it that way and rules may assume the key exists.
    func testWritesExplicitNullsForAbsentOptionals() throws {
        var data = makeDocument()
        data["ownerPhotoUrl"] = NSNull()
        data["screenshotUrl"] = NSNull()
        let item = try XCTUnwrap(SharedBackupItem(id: "abc", data: data))
        let map = item.documentData()
        XCTAssertTrue(map["ownerPhotoUrl"] is NSNull)
        XCTAssertTrue(map["screenshotUrl"] is NSNull)
    }

    /// The Storage path embeds the Saturn filename verbatim, so both apps put
    /// the object in the same place.
    func testStoragePathsMatchAndroid() {
        XCTAssertEqual(SharedBackupItem.storagePath(id: "abc", filename: "NIGHTS_01"),
                       "shared_backups/abc/NIGHTS_01")
        XCTAssertEqual(SharedBackupItem.screenshotStoragePath(id: "abc"),
                       "shared_backups/abc/screenshot.png")
    }
}
