import XCTest
@testable import YabaSnashiro

final class BackupCartridgeSettingTests: XCTestCase {
    private var settingsPath: String!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupCartridgeSettingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        settingsPath = directory.appendingPathComponent("settings.plist").path
    }

    override func tearDownWithError() throws {
        let directory = (settingsPath as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func write(_ dictionary: [String: Any]) {
        XCTAssertTrue((dictionary as NSDictionary).write(toFile: settingsPath,
                                                         atomically: true))
    }

    func testBackupRamCartridgeValuesMapToTheMatchingFile() {
        let expected: [Int: BackupFile] = [
            2: .cartridge4Mbit,
            3: .cartridge8Mbit,
            4: .cartridge16Mbit,
            5: .cartridge32Mbit
        ]
        for (value, file) in expected {
            write(["cartridge": value])
            let setting = BackupCartridgeSetting(settingsPath: settingsPath)
            XCTAssertEqual(setting.configuredCartridge(), file,
                           "cartridge value \(value)")
        }
    }

    func testNoCartridgeReturnsNil() {
        write(["cartridge": 0])
        XCTAssertNil(BackupCartridgeSetting(settingsPath: settingsPath)
            .configuredCartridge())
    }

    func testDramCartridgesReturnNil() {
        for value in [6, 7] {
            write(["cartridge": value])
            XCTAssertNil(BackupCartridgeSetting(settingsPath: settingsPath)
                .configuredCartridge(), "cartridge value \(value)")
        }
    }

    func testMissingSettingsFileReturnsNil() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsPath))
        XCTAssertNil(BackupCartridgeSetting(settingsPath: settingsPath)
            .configuredCartridge())
    }

    func testSettingsWithoutTheCartridgeKeyReturnsNil() {
        write(["sound": 1])
        XCTAssertNil(BackupCartridgeSetting(settingsPath: settingsPath)
            .configuredCartridge())
    }
}
