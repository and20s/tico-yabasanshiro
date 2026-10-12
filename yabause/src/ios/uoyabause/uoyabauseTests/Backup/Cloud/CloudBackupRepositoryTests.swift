import XCTest
@testable import YabaSnashiro

/// In-memory stand-ins for the Realtime Database and Cloud Storage.
final class FakeCloudDatabase: CloudDatabase {
    var records: [String: [String: Any]] = [:]
    var maxBackupCount: Int?
    var writtenMaxCount: Int?
    var removedKeys: [String] = []
    var updatedKeys: [String] = []
    var shouldFail = false

    func loadRecords(userId: String) async throws -> [String: [String: Any]] {
        if shouldFail { throw CloudBackupError.network }
        return records
    }
    func loadMaxBackupCount(userId: String) async throws -> Int? {
        if shouldFail { throw CloudBackupError.network }
        return maxBackupCount
    }
    func writeMaxBackupCount(_ count: Int, userId: String) async throws {
        writtenMaxCount = count
    }
    func updateRecord(_ values: [String: Any], key: String, userId: String) async throws {
        if shouldFail { throw CloudBackupError.network }
        updatedKeys.append(key)
        records[key] = (records[key] ?? [:]).merging(values) { _, new in new }
    }
    func removeRecord(key: String, userId: String) async throws {
        if shouldFail { throw CloudBackupError.network }
        removedKeys.append(key)
        records.removeValue(forKey: key)
    }
}

final class FakeCloudStorage: CloudStorage {
    var objects: [String: Data] = [:]
    var uploadedPaths: [String] = []
    var removedPaths: [String] = []
    var downloadURLs: [String: String] = [:]

    func upload(_ data: Data, path: String) async throws -> String {
        uploadedPaths.append(path)
        objects[path] = data
        let url = downloadURLs[path] ?? "https://example.com/\(path)"
        downloadURLs[path] = url
        return url
    }
    func download(url: String, maxBytes: Int) async throws -> Data {
        guard let path = downloadURLs.first(where: { $0.value == url })?.key,
              let data = objects[path] else { throw CloudBackupError.network }
        guard data.count <= maxBytes else { throw CloudBackupError.tooLarge }
        return data
    }
    func remove(path: String) async throws {
        removedPaths.append(path)
        objects.removeValue(forKey: path)
    }
}

final class CloudBackupRepositoryTests: XCTestCase {
    private var database: FakeCloudDatabase!
    private var storage: FakeCloudStorage!
    private var repository: CloudBackupRepository!

    override func setUpWithError() throws {
        database = FakeCloudDatabase()
        storage = FakeCloudStorage()
        repository = CloudBackupRepository(database: database, storage: storage)
    }

    func testItemsParsesBothRecordShapes() async throws {
        database.records = [
            "android": ["filename": "A", "saveDate": "2024/03/20 15:30:00",
                        "dataSize": 100, "blockSize": 2,
                        "downloadUrl": "https://example.com/a", "url": ""],
            "legacy": ["filename": "B", "savedate": "2024/03/20 15:30:00",
                       "datasize": 200, "blocksize": 4,
                       "url": "https://example.com/b"],
        ]
        let items = try await repository.items(userId: "u")
        XCTAssertEqual(Set(items.map(\.filename)), ["A", "B"])
        XCTAssertEqual(items.first { $0.filename == "A" }?.dataSize, 100)
        XCTAssertEqual(items.first { $0.filename == "B" }?.dataSize, 200)
    }

    func testItemsSkipsRecordsWithoutFilename() async throws {
        database.records = ["broken": ["comment": "no filename"]]
        let items = try await repository.items(userId: "u")
        XCTAssertTrue(items.isEmpty)
    }

    func testItemsPropagatesNetworkFailure() async {
        database.shouldFail = true
        do {
            _ = try await repository.items(userId: "u")
            XCTFail("expected a failure")
        } catch {
            // expected
        }
    }

    func testSlotUsageReadsTheConfiguredMaximum() async throws {
        database.maxBackupCount = 256
        database.records = ["a": ["filename": "A"], "b": ["filename": "B"]]
        let usage = try await repository.slotUsage(userId: "u")
        XCTAssertEqual(usage.used, 2)
        XCTAssertEqual(usage.total, 256)
    }

    func testSlotUsageTreatsAMissingMaximumAsZero() async throws {
        database.maxBackupCount = nil
        let usage = try await repository.slotUsage(userId: "u")
        XCTAssertEqual(usage.total, 0)
    }

    func testSlotUsageIsFullWhenUsedReachesTotal() async throws {
        database.maxBackupCount = 1
        database.records = ["a": ["filename": "A"]]
        let usage = try await repository.slotUsage(userId: "u")
        XCTAssertTrue(usage.isFull)
    }

    /// The count must match the list, and Android's count, which both skip
    /// records that do not parse. Counting raw children made iOS report one
    /// more than Android for the same account.
    func testSlotUsageCountsOnlyRecordsThatParse() async throws {
        database.maxBackupCount = 256
        database.records = [
            "good": ["filename": "A"],
            "broken": ["comment": "no filename"],
        ]
        let usage = try await repository.slotUsage(userId: "u")
        let items = try await repository.items(userId: "u")
        XCTAssertEqual(usage.used, 1)
        XCTAssertEqual(usage.used, items.count, "the count must match the list")
    }

    func testEnsureSlotCountWritesTheEntitledValue() async throws {
        try await repository.ensureSlotCount(256, userId: "u")
        XCTAssertEqual(database.writtenMaxCount, 256)
    }

    private func makeLocalSave() -> BackupSave {
        var raw = YSBupSave()
        withUnsafeMutableBytes(of: &raw.filename) { buffer in
            for (index, byte) in Array("SONICR_01".utf8).prefix(11).enumerated() {
                buffer[index] = byte
            }
        }
        withUnsafeMutableBytes(of: &raw.comment) { buffer in
            for (index, byte) in Array("STAGE3".utf8).prefix(10).enumerated() {
                buffer[index] = byte
            }
        }
        raw.year = 18; raw.month = 5; raw.day = 12
        raw.hour = 9; raw.minute = 30
        raw.datasize = 1024; raw.blocksize = 5
        return BackupSave(raw: raw, file: .internalMemory)
    }

    func testUploadWritesRawBytesAndTheAndroidRecord() async throws {
        let payload = Data(repeating: 0x7F, count: 1024)
        let key = try await repository.upload(save: makeLocalSave(), data: payload,
                                              screenshot: nil, userId: "u")

        XCTAssertEqual(storage.uploadedPaths, ["u/backups/\(key)"])
        XCTAssertEqual(storage.objects["u/backups/\(key)"], payload)

        let record = try XCTUnwrap(database.records[key])
        XCTAssertEqual(record["filename"] as? String, "SONICR_01")
        XCTAssertEqual(record["dataSize"] as? Int, 1024)
        XCTAssertNotNil(record["downloadUrl"] as? String)
        XCTAssertEqual(record["url"] as? String, "")
        XCTAssertEqual(record["datasize"] as? Int, 1024)   // legacy alias
    }

    func testUploadStoresTheScreenshotSeparately() async throws {
        let shot = Data(repeating: 0x11, count: 32)
        let key = try await repository.upload(save: makeLocalSave(),
                                              data: Data(repeating: 0, count: 8),
                                              screenshot: shot, userId: "u")
        XCTAssertTrue(storage.uploadedPaths.contains("u/backups/\(key)_screenshot.png"))
        XCTAssertNotNil(try XCTUnwrap(database.records[key])["screenshotUrl"] as? String)
    }

    func testUploadUsesUpdateChildValuesSoAndroidFieldsSurvive() async throws {
        let key = try await repository.upload(save: makeLocalSave(),
                                              data: Data(repeating: 0, count: 8),
                                              screenshot: nil, userId: "u")
        XCTAssertEqual(database.updatedKeys, [key])
    }

    func testUploadKeysAreUUIDsLikeAndroid() async throws {
        let key = try await repository.upload(save: makeLocalSave(),
                                              data: Data(repeating: 0, count: 8),
                                              screenshot: nil, userId: "u")
        XCTAssertNotNil(UUID(uuidString: key))
    }

    func testDownloadUnwrapsALegacyEnvelope() async throws {
        let payload = [UInt8](repeating: 0x42, count: 16)
        let content = Data(payload).base64EncodedString()
        let envelope = Data("""
        {"header":{"filename":"eA=="},"data":{"size":16,"content":"\(content)"}}
        """.utf8)
        storage.objects["u/backups/k"] = envelope
        storage.downloadURLs["u/backups/k"] = "https://example.com/legacy"

        let item = try XCTUnwrap(CloudBackupItem(
            key: "k", dictionary: ["filename": "A", "url": "https://example.com/legacy"]))
        let downloaded = try await repository.download(item: item)
        XCTAssertEqual(Array(downloaded), payload)
    }

    func testDownloadPassesRawAndroidBytesThrough() async throws {
        let payload = Data([0x01, 0x02, 0x03])
        storage.objects["u/backups/k"] = payload
        storage.downloadURLs["u/backups/k"] = "https://example.com/android"

        let item = try XCTUnwrap(CloudBackupItem(
            key: "k", dictionary: ["filename": "A",
                                   "downloadUrl": "https://example.com/android"]))
        let downloaded = try await repository.download(item: item)
        XCTAssertEqual(downloaded, payload)
    }

    func testDownloadWithoutAUrlThrows() async {
        let item = CloudBackupItem(key: "k", filename: "A", comment: "", language: 0,
                                   saveDate: nil, dataSize: 0, blockSize: 0,
                                   downloadURL: "")
        do {
            _ = try await repository.download(item: item)
            XCTFail("expected a failure")
        } catch {
            // expected
        }
    }

    func testDeleteRemovesTheRecordAndBothStorageObjects() async throws {
        let key = try await repository.upload(save: makeLocalSave(),
                                              data: Data(repeating: 0, count: 8),
                                              screenshot: Data([0x01]), userId: "u")
        try await repository.delete(key: key, userId: "u")

        XCTAssertEqual(database.removedKeys, [key])
        // The old iOS build deleted only the record and leaked the blob.
        XCTAssertTrue(storage.removedPaths.contains("u/backups/\(key)"))
        XCTAssertTrue(storage.removedPaths.contains("u/backups/\(key)_screenshot.png"))
    }

    func testStoragePathsMatchTheAndroidLayout() {
        XCTAssertEqual(CloudBackupRepository.storagePath(userId: "u", key: "k"),
                       "u/backups/k")
        XCTAssertEqual(CloudBackupRepository.screenshotPath(userId: "u", key: "k"),
                       "u/backups/k_screenshot.png")
    }
}
