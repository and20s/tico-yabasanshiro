import XCTest
@testable import YabaSnashiro

final class EmulatorSettingsStoreTests: XCTestCase {
    private var directory: URL!
    private var store: EmulatorSettingsStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        store = EmulatorSettingsStore(
            plistPath: directory.appendingPathComponent("settings.plist").path,
            defaults: UserDefaults(suiteName: "EmulatorSettingsStoreTests")!)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: "EmulatorSettingsStoreTests")
    }

    func testDefaultsMatchTheCore() {
        // These are the values GameViewController.loadSettings falls back to.
        XCTAssertEqual(store.cartridge, 0)
        XCTAssertEqual(store.renderingResolution, 0)
        XCTAssertFalse(store.showFPS)
        XCTAssertFalse(store.frameSkip)
        XCTAssertFalse(store.keepAspectRatio)
        XCTAssertFalse(store.rotateScreen)
        XCTAssertFalse(store.analogAsDPad)
    }

    func testWriteThenReadRoundTrip() {
        store.cartridge = 3
        store.renderingResolution = 2
        store.soundEngine = 0
        store.showFPS = true
        store.frameSkip = true
        store.keepAspectRatio = true
        store.rotateScreen = true
        store.analogAsDPad = true

        let reopened = EmulatorSettingsStore(
            plistPath: directory.appendingPathComponent("settings.plist").path,
            defaults: UserDefaults(suiteName: "EmulatorSettingsStoreTests")!)
        XCTAssertEqual(reopened.cartridge, 3)
        XCTAssertEqual(reopened.renderingResolution, 2)
        XCTAssertEqual(reopened.soundEngine, 0)
        XCTAssertTrue(reopened.showFPS)
        XCTAssertTrue(reopened.frameSkip)
        XCTAssertTrue(reopened.keepAspectRatio)
        XCTAssertTrue(reopened.rotateScreen)
        XCTAssertTrue(reopened.analogAsDPad)
    }

    /// The core reads these exact strings in GameViewController.loadSettings.
    /// If a key here drifts, the setting silently stops working -- which is
    /// what happened to sound quality, written as "sound quality" while the
    /// core read "sound engine".
    func testPlistKeysAreTheOnesTheCoreReads() throws {
        store.cartridge = 5
        store.renderingResolution = 1
        store.soundEngine = 1
        store.showFPS = true
        store.frameSkip = true
        store.keepAspectRatio = true
        store.rotateScreen = true
        store.analogAsDPad = true

        let path = directory.appendingPathComponent("settings.plist").path
        let plist = try XCTUnwrap(NSDictionary(contentsOfFile: path))

        XCTAssertEqual(plist["cartridge"] as? Int, 5)
        XCTAssertEqual(plist["rendering resolution"] as? Int, 1)
        XCTAssertEqual(plist["sound engine"] as? Int, 1)
        XCTAssertEqual(plist["show fps"] as? Bool, true)
        XCTAssertEqual(plist["frame skip"] as? Bool, true)
        XCTAssertEqual(plist["keep aspect rate"] as? Bool, true)
        XCTAssertEqual(plist["rotate screen"] as? Bool, true)
        XCTAssertEqual(plist["analog as dpad"] as? Bool, true)

        // The legacy screen wrote this key; the core never read it.
        XCTAssertNil(plist["sound quality"])
    }

    func testLandscapeLivesInUserDefaultsNotThePlist() throws {
        store.landscape = false
        let path = directory.appendingPathComponent("settings.plist").path
        let plist = NSDictionary(contentsOfFile: path)
        XCTAssertNil(plist?["landscape"])
        XCTAssertFalse(store.landscape)

        store.landscape = true
        XCTAssertTrue(store.landscape)
    }

    func testLandscapeDefaultsToTrue() {
        // GameViewController registers this default as true.
        XCTAssertTrue(store.landscape)
    }

    func testWritingOneSettingKeepsTheOthers() {
        store.cartridge = 4
        store.showFPS = true
        store.cartridge = 2
        XCTAssertTrue(store.showFPS, "writing cartridge must not clear show fps")
    }

    func testUnknownExistingKeysSurvive() throws {
        // The plist also holds keys this screen does not expose
        // (builtin bios, controller scale, analog mode). They must not be lost.
        let path = directory.appendingPathComponent("settings.plist").path
        try (["builtin bios": true, "controller scale": 0.8] as NSDictionary)
            .write(to: URL(fileURLWithPath: path))

        let store = EmulatorSettingsStore(
            plistPath: path,
            defaults: UserDefaults(suiteName: "EmulatorSettingsStoreTests")!)
        store.showFPS = true

        let plist = try XCTUnwrap(NSDictionary(contentsOfFile: path))
        XCTAssertEqual(plist["builtin bios"] as? Bool, true)
        XCTAssertEqual(plist["controller scale"] as? Double, 0.8)
    }
}
