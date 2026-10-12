import Foundation

/// The emulator settings, stored in Library/settings.plist because the core
/// reads that file directly when a game launches
/// (see GameViewController.loadSettings). The keys below must match the ones
/// it reads: a mismatch silently disables the setting, which is what happened
/// to sound quality before this type existed.
///
/// Changes take effect the next time a game starts, since loadSettings runs
/// once in viewDidLoad.
final class EmulatorSettingsStore {
    private let plistPath: String
    private let defaults: UserDefaults

    init(plistPath: String? = nil, defaults: UserDefaults = .standard) {
        self.plistPath = plistPath ?? Self.defaultPlistPath()
        self.defaults = defaults
        self.defaults.register(defaults: ["landscape": true])
    }

    // MARK: - Settings stored in the plist

    var cartridge: Int {
        get { int(forKey: "cartridge", default: 0) }
        set { set(newValue, forKey: "cartridge") }
    }

    var renderingResolution: Int {
        get { int(forKey: "rendering resolution", default: 0) }
        set { set(newValue, forKey: "rendering resolution") }
    }

    /// Defaults to 1 to match the bundled settings.plist, which
    /// GameViewController.getSettingFilePath copies into Library on first
    /// launch. The core's own fallback is 0, but it only applies when the key
    /// is missing, which cannot happen once that copy has run.
    var soundEngine: Int {
        get { int(forKey: "sound engine", default: 1) }
        set { set(newValue, forKey: "sound engine") }
    }

    var showFPS: Bool {
        get { bool(forKey: "show fps") }
        set { set(newValue, forKey: "show fps") }
    }

    var frameSkip: Bool {
        get { bool(forKey: "frame skip") }
        set { set(newValue, forKey: "frame skip") }
    }

    var keepAspectRatio: Bool {
        get { bool(forKey: "keep aspect rate") }
        set { set(newValue, forKey: "keep aspect rate") }
    }

    var rotateScreen: Bool {
        get { bool(forKey: "rotate screen") }
        set { set(newValue, forKey: "rotate screen") }
    }

    var analogAsDPad: Bool {
        get { bool(forKey: "analog as dpad") }
        set { set(newValue, forKey: "analog as dpad") }
    }

    // MARK: - Settings stored in UserDefaults

    /// The core reads this from UserDefaults, not the plist.
    var landscape: Bool {
        get { defaults.bool(forKey: "landscape") }
        set { defaults.set(newValue, forKey: "landscape") }
    }

    // MARK: - Plist access

    /// Reads the whole plist, so keys this screen does not expose
    /// (builtin bios, controller scale, analog mode) survive a write.
    private func load() -> [String: Any] {
        NSDictionary(contentsOfFile: plistPath) as? [String: Any] ?? [:]
    }

    private func int(forKey key: String, default fallback: Int) -> Int {
        (load()[key] as? NSNumber)?.intValue ?? fallback
    }

    private func bool(forKey key: String) -> Bool {
        (load()[key] as? NSNumber)?.boolValue ?? false
    }

    private func set(_ value: Any, forKey key: String) {
        var plist = load()
        plist[key] = value
        let directory = (plistPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: plistPath, atomically: true)
    }

    private static func defaultPlistPath() -> String {
        let library = NSSearchPathForDirectoriesInDomains(
            .libraryDirectory, .userDomainMask, true)[0]
        return (library as NSString).appendingPathComponent("settings.plist")
    }

    // MARK: - Shared access for the UIKit screens

    /// Path of the settings plist. Moved here from the deleted
    /// SettingsViewController, which the in-game menu still calls.
    static func settingsFilePath() -> String {
        defaultPlistPath()
    }

    /// The settings plist, seeding it from the bundled copy on first use so
    /// the defaults are not lost. Moved here from SettingsViewController.
    static func settingsPlist() -> NSMutableDictionary {
        let filePath = settingsFilePath()
        if !FileManager.default.fileExists(atPath: filePath),
           let bundleFilePath = Bundle.main.path(forResource: "settings",
                                                 ofType: "plist") {
            do {
                try FileManager.default.copyItem(atPath: bundleFilePath,
                                                 toPath: filePath)
            } catch {
                print("EmulatorSettingsStore: could not seed settings.plist: \(error)")
            }
        }
        return NSMutableDictionary(contentsOfFile: filePath) ?? NSMutableDictionary()
    }
}
