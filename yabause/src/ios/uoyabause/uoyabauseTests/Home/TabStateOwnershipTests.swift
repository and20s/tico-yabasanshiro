import XCTest
@testable import YabaSnashiro

/// At regular width the sidebar rebuilds the detail column on every tab
/// change. Anything a tab view owns with `@StateObject` dies with that
/// rebuild, so the tabs take their state from MainTabView instead.
///
/// These assert the ownership rather than the rendering: a view test cannot
/// see who holds a reference, but the source can.
final class TabStateOwnershipTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Home
            .deletingLastPathComponent()   // uoyabauseTests
            .deletingLastPathComponent()   // uoyabause (project dir)
            .appendingPathComponent("uoyabause")
        return try String(contentsOf: root.appendingPathComponent(path),
                          encoding: .utf8)
    }

    /// The tab views must not create their own long-lived state.
    func testTabViewsDoNotOwnTheirState() throws {
        let paths = [
            "Backup/Views/BackupTabView.swift",
            "Settings/Views/SettingsTabView.swift",
            "Account/Views/AccountTabView.swift",
            "Home/Views/GamesTabView.swift",
        ]
        for path in paths {
            let text = try source(path)
            for line in text.split(separator: "\n") where line.contains("@StateObject") {
                // A focus scope is per-presentation and is meant to be
                // rebuilt with the view; everything else must come from
                // outside so it survives a sidebar rebuild.
                XCTAssertTrue(line.contains("FocusModel"),
                              "\(path) still owns state: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// MainTabView is where that state lives instead.
    func testMainTabViewOwnsEveryTabsState() throws {
        let text = try source("Home/Views/MainTabView.swift")
        for owned in ["GameListViewModel", "GamesTabState",
                      "BackupListViewModel", "CloudBackupViewModel",
                      "BackupTabState", "SettingsTabModel",
                      "AccountState", "AccountViewModel", "DevicePinViewModel"] {
            XCTAssertTrue(text.contains("@StateObject private var")
                          && text.contains(owned),
                          "MainTabView does not own \(owned)")
        }
    }

    /// The backup list must not re-read the backup memory on every appearance,
    /// or holding the view model across tab changes buys nothing.
    func testTheBackupListLoadsOnlyOnce() async {
        let viewModel = await BackupListViewModel()
        await viewModel.loadInitial()
        let first = await viewModel.loadGenerationForTesting
        await viewModel.loadInitial()
        let second = await viewModel.loadGenerationForTesting
        XCTAssertEqual(first, second,
                       "loadInitial reloaded on a second call")
    }

    /// Every `.task` that loads on appearance must go through a guarded
    /// entry point. The cloud half was missed the first time round, and it is
    /// the one that costs a network round trip.
    func testAppearanceLoadsAreGuarded() throws {
        let paths = [
            "Backup/Views/BackupTabView.swift",
            "Backup/Views/CloudBackupSection.swift",
            "Home/Views/GamesTabView.swift",
        ]
        for path in paths {
            for line in try source(path).split(separator: "\n")
            where line.contains(".task") && line.contains("load") {
                XCTAssertTrue(line.contains("loadInitial"),
                              "\(path) reloads on every appearance: "
                              + line.trimmingCharacters(in: .whitespaces))
            }
        }
    }
}
