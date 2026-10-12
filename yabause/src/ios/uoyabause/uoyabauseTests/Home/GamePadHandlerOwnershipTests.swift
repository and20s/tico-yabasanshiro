import XCTest
@testable import YabaSnashiro

/// Structural guards, not behavioural ones.
///
/// The lesson this file exists for: HomeTabNavigator had six green unit tests
/// while the feature it belongs to was broken, because the tests covered the
/// arithmetic and the defect was in ownership and routing. These assert the
/// properties the architecture depends on, which are the ones a future change
/// can silently break.
final class GamePadHandlerOwnershipTests: XCTestCase {
    /// Legacy UIKit screens that still install their own handlers. Every one
    /// of these lives inside the emulator, where HomeGamePadManager is
    /// deactivated and so has no event stream to route through; converting
    /// them means restructuring the emulator's input path, which is a
    /// different job. The list may shrink but must never grow.
    ///
    /// SignInHostingController left it in phase 2: it now installs nothing and
    /// its presenter owns B for it.
    private static let knownLegacyOwners: Set<String> = [
        "GameMainViewController.swift",
        "MenuViewController.swift",
        // The emulator's Saturn pad mapping. It writes valueChangedHandler,
        // a different property from the pressedChangedHandler the home UI
        // uses, so the two do not clear each other: benign only for as long
        // as the emulator ends the process instead of returning to the
        // library. Out of scope here; see the spec's phase notes.
        "GameViewController.swift",
        "LeaderBoardController.swift",
        "AchievementListViewController.swift",
    ]

    /// Legacy owners that are dismissable modals, so unlike the emulator host
    /// they cannot rely on the process ending to clean up after them.
    private static let dismissableLegacyOwners = [
        "LeaderBoardController.swift",
        "AchievementListViewController.swift",
    ]

    private static let soleModernOwner = "HomeGamePadManager.swift"

    /// The app sources, located from this file so the test needs no bundle
    /// resources. Skips rather than fails when run from a copy of the test
    /// bundle without the sources beside it.
    private func appSourceRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)      // .../uoyabauseTests/Home/<this>
            .deletingLastPathComponent()                 // .../uoyabauseTests/Home
            .deletingLastPathComponent()                 // .../uoyabauseTests
            .deletingLastPathComponent()                 // .../uoyabause (project dir)
            .appendingPathComponent("uoyabause")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("app sources are not available at \(root.path)")
        }
        return root
    }

    private func swiftFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The rule the whole design rests on: exactly one object installs
    /// GCController handlers in the home UI. Handlers are a single slot per
    /// button per controller, so a second installer silently kills the first
    /// (ios/CLAUDE.md CRITICAL).
    func testOnlyHomeGamePadManagerInstallsControllerHandlers() throws {
        let root = try appSourceRoot()
        var offenders: [String] = []
        for file in swiftFiles(under: root) {
            let name = file.lastPathComponent
            guard name != Self.soleModernOwner,
                  !Self.knownLegacyOwners.contains(name) else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if text.contains("pressedChangedHandler =")
                || text.contains("valueChangedHandler =") {
                offenders.append(name)
            }
        }
        XCTAssertEqual(offenders.sorted(), [],
                       "only \(Self.soleModernOwner) may install GCController handlers")
    }

    /// The legacy list is debt, so it has to stay visible. If a file on it
    /// stops installing handlers, remove it from the list rather than leaving
    /// a stale exemption that would hide a genuine new owner.
    func testTheLegacyOwnerListHasNoStaleEntries() throws {
        let root = try appSourceRoot()
        let files = swiftFiles(under: root)
        for name in Self.knownLegacyOwners {
            guard let file = files.first(where: { $0.lastPathComponent == name }) else {
                XCTFail("\(name) no longer exists; drop it from knownLegacyOwners")
                continue
            }
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(text.contains("ChangedHandler ="),
                          "\(name) no longer installs handlers; drop it from knownLegacyOwners")
        }
    }

    /// Screens declare focus scopes; they never import GameController. This
    /// is what makes the single-owner rule structural instead of a convention.
    func testNoSwiftUIViewImportsGameController() throws {
        let root = try appSourceRoot()
        var offenders: [String] = []
        for file in swiftFiles(under: root) where file.path.contains("/Views/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("import GameController") {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders.sorted(), [],
                       "SwiftUI screens must subscribe to HomeGamePadManager, not GCController")
    }

    /// A modal that installs handlers must release them again, and tell the
    /// screen underneath so it can reinstall its own. Clearing without the
    /// second half leaves the presenter silent, which is the same bug seen
    /// from the other side.
    func testDismissableLegacyOwnersReleaseTheirHandlers() throws {
        let root = try appSourceRoot()
        let files = swiftFiles(under: root)
        for name in Self.dismissableLegacyOwners {
            guard let file = files.first(where: { $0.lastPathComponent == name }) else {
                XCTFail("\(name) no longer exists")
                continue
            }
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(text.contains("pressedChangedHandler = nil"),
                          "\(name) installs handlers but never clears them")
            XCTAssertTrue(text.contains("viewWillDisappear"),
                          "\(name) must clear its handlers when it goes away")
            XCTAssertTrue(text.contains("legacyModalDidReleaseGamepad"),
                          "\(name) must tell its presenter to reinstall its handlers")
        }
    }

    /// The counterpart: something has to be listening, or the notification is
    /// a no-op and the presenter still goes silent.
    func testThePresenterReinstallsAfterAModalReleasesTheGamepad() throws {
        let root = try appSourceRoot()
        let host = root.appendingPathComponent("GameMainViewController.swift")
        let text = try String(contentsOf: host, encoding: .utf8)
        XCTAssertTrue(text.contains("name: .legacyModalDidReleaseGamepad"),
                      "GameMainViewController must observe legacyModalDidReleaseGamepad")
    }
}
