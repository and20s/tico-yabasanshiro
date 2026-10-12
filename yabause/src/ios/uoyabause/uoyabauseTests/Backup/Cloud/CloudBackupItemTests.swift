import XCTest
@testable import YabaSnashiro

final class CloudBackupItemTests: XCTestCase {
    private let androidRecord: [String: Any] = [
        "filename": "SONICR_01", "comment": "STAGE 3", "language": 0,
        "saveDate": "2024/03/20 15:30:00", "dataSize": 1024, "blockSize": 5,
        "downloadUrl": "https://example.com/android.bin", "url": "",
        "uploadedAt": 1710948600000, "gameTitle": "Sonic R",
        "productNumber": "MK-81800", "screenshotUrl": "https://example.com/shot.png",
    ]

    private let legacyIOSRecord: [String: Any] = [
        "filename": "NIGHTS_01", "comment": "BOSS",
        "savedate": "2024/03/20 15:30:00", "datasize": 2048, "blocksize": 9,
        "url": "https://example.com/legacy.json",
    ]

    func testParsesAndroidRecord() throws {
        let item = try XCTUnwrap(CloudBackupItem(key: "abc", dictionary: androidRecord))
        XCTAssertEqual(item.key, "abc")
        XCTAssertEqual(item.filename, "SONICR_01")
        XCTAssertEqual(item.comment, "STAGE 3")
        XCTAssertEqual(item.dataSize, 1024)
        XCTAssertEqual(item.blockSize, 5)
        XCTAssertEqual(item.downloadURL, "https://example.com/android.bin")
        XCTAssertEqual(item.gameTitle, "Sonic R")
        XCTAssertEqual(item.productNumber, "MK-81800")
        XCTAssertEqual(item.screenshotURL, "https://example.com/shot.png")
        XCTAssertNotNil(item.saveDate)
    }

    func testParsesLegacyIOSRecord() throws {
        let item = try XCTUnwrap(CloudBackupItem(key: "-Nq7", dictionary: legacyIOSRecord))
        XCTAssertEqual(item.filename, "NIGHTS_01")
        XCTAssertEqual(item.dataSize, 2048)
        XCTAssertEqual(item.blockSize, 9)
        XCTAssertEqual(item.downloadURL, "https://example.com/legacy.json")
        XCTAssertNil(item.gameTitle)
        XCTAssertNil(item.screenshotURL)
        XCTAssertNotNil(item.saveDate)
    }

    func testRecordWithoutFilenameIsRejected() {
        XCTAssertNil(CloudBackupItem(key: "k", dictionary: ["comment": "x"]))
    }

    func testFirebaseNumbersArriveAsNSNumber() throws {
        // Firebase hands numbers back as NSNumber; a plain Int cast fails.
        let record: [String: Any] = ["filename": "A",
                                     "dataSize": NSNumber(value: 4096),
                                     "blockSize": NSNumber(value: 12)]
        let item = try XCTUnwrap(CloudBackupItem(key: "k", dictionary: record))
        XCTAssertEqual(item.dataSize, 4096)
        XCTAssertEqual(item.blockSize, 12)
    }

    func testSaveDateParsesBothSeparators() throws {
        let slashes = try XCTUnwrap(CloudBackupItem(
            key: "k", dictionary: ["filename": "A", "saveDate": "2024/03/20 15:30:00"]))
        let dashes = try XCTUnwrap(CloudBackupItem(
            key: "k", dictionary: ["filename": "A", "saveDate": "2024-03-20 15:30:00"]))
        XCTAssertEqual(slashes.saveDate, dashes.saveDate)
    }

    func testDictionaryForUploadCarriesBothKeyStyles() {
        let item = CloudBackupItem(
            key: "k", filename: "SONICR_01", comment: "STAGE 3", language: 0,
            saveDate: Date(timeIntervalSince1970: 894969000),
            dataSize: 1024, blockSize: 5,
            downloadURL: "https://example.com/x.bin",
            screenshotURL: "https://example.com/x.png",
            gameTitle: "Sonic R", productNumber: "MK-81800")

        let dictionary = item.dictionaryForUpload()

        XCTAssertEqual(dictionary["saveDate"] as? String, item.formattedSaveDate)
        XCTAssertEqual(dictionary["dataSize"] as? Int, 1024)
        XCTAssertEqual(dictionary["blockSize"] as? Int, 5)
        XCTAssertEqual(dictionary["downloadUrl"] as? String, "https://example.com/x.bin")
        XCTAssertEqual(dictionary["gameTitle"] as? String, "Sonic R")
        XCTAssertEqual(dictionary["screenshotUrl"] as? String, "https://example.com/x.png")

        // Legacy iOS aliases, so an older build still lists the record
        XCTAssertEqual(dictionary["savedate"] as? String, item.formattedSaveDate)
        XCTAssertEqual(dictionary["datasize"] as? Int, 1024)
        XCTAssertEqual(dictionary["blocksize"] as? Int, 5)

        // url stays empty exactly as Android leaves it, so an older build does
        // not try to download a payload it cannot read.
        XCTAssertEqual(dictionary["url"] as? String, "")
    }

    /// Android declares uploadedAt as a java.util.Date, which the Realtime
    /// Database mapper reads as a nested object. Writing a number there made
    /// getValue(CloudBackupMetadata) throw, and Android's per-record catch then
    /// dropped every save iOS uploaded. Omitting the key is what keeps iOS
    /// records visible on Android.
    func testUploadDictionaryOmitsUploadedAt() {
        let item = CloudBackupItem(
            key: "k", filename: "A", comment: "B", language: 0,
            saveDate: Date(timeIntervalSince1970: 894969000),
            dataSize: 10, blockSize: 2, downloadURL: "https://example.com/a")
        XCTAssertNil(item.dictionaryForUpload()["uploadedAt"])
    }

    func testUploadDictionaryRoundTripsBackIntoAnItem() throws {
        let original = CloudBackupItem(
            key: "k", filename: "A", comment: "B", language: 1,
            saveDate: Date(timeIntervalSince1970: 894969000),
            dataSize: 10, blockSize: 2, downloadURL: "https://example.com/a")
        let parsed = try XCTUnwrap(
            CloudBackupItem(key: "k", dictionary: original.dictionaryForUpload()))
        XCTAssertEqual(parsed.filename, original.filename)
        XCTAssertEqual(parsed.dataSize, original.dataSize)
        XCTAssertEqual(parsed.downloadURL, original.downloadURL)
        XCTAssertEqual(parsed.formattedSaveDate, original.formattedSaveDate)
    }
}
