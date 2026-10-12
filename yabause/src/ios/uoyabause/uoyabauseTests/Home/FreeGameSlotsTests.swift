import XCTest
@testable import YabaSnashiro

/// The free version plays the first three games that entered the library.
/// Which three is decided here, away from any view: the games tab, the
/// launcher and the in-game disc picker all ask this one type, so a game that
/// is locked in the list cannot be launchable from somewhere else.
final class FreeGameSlotsTests: XCTestCase {
    private func lite(_ purchase: PurchaseStatus) -> ProEntitlement {
        ProEntitlement(showsAdvertising: true, legacy: .notLegacy, purchase: purchase)
    }

    /// A library entry with an explicit arrival time, which is what decides
    /// the free slots.
    private func item(_ name: String, added: TimeInterval) -> GameItem {
        var item = GameItem(gameInfo: GameInfo())
        item.filePath = "/games/\(name).chd"
        item.displayName = name
        item.addedAt = Date(timeIntervalSince1970: added)
        return item
    }

    /// Five games, added in the order A, B, C, D, E.
    private var library: [GameItem] {
        [item("A", added: 10), item("B", added: 20), item("C", added: 30),
         item("D", added: 40), item("E", added: 50)]
    }

    private func unlocked(_ items: [GameItem],
                          _ entitlement: ProEntitlement) -> Set<String>? {
        FreeGameSlots.unlockedPaths(items: items, entitlement: entitlement)
    }

    // MARK: - Who is unlocked

    func testAShortLibraryIsFullyPlayable() {
        let three = Array(library.prefix(3))
        XCTAssertEqual(unlocked(three, lite(.none)), Set(three.map(\.filePath)))
    }

    func testOnlyTheFirstThreeArrivalsArePlayable() {
        XCTAssertEqual(unlocked(library, lite(.none)),
                       Set(["/games/A.chd", "/games/B.chd", "/games/C.chd"]))
    }

    /// nil rather than "every path": the callers read it as "no limit at all",
    /// so a library that grows after this was computed cannot be half-locked.
    func testAProUserHasNoLockedGames() {
        XCTAssertNil(unlocked(library, lite(.lifetime)))
        XCTAssertNil(unlocked(library, ProEntitlement(showsAdvertising: false,
                                                      legacy: .legacyPaid,
                                                      purchase: .none)))
    }

    /// Same reasoning as the import gate: locking a subscriber's library for
    /// the second before StoreKit answers is the worse mistake.
    func testCheckingLocksNothing() {
        XCTAssertNil(unlocked(library, lite(.unknown)))
    }

    // MARK: - Stability

    /// The point of keying on arrival: sorting the list must not hand the free
    /// slots to whichever three games happen to be on top.
    func testTheSlotsDoNotFollowThePresentationOrder() {
        let byName = library.sorted { $0.displayName > $1.displayName }
        let byPath = library.shuffled()
        XCTAssertEqual(unlocked(byName, lite(.none)), unlocked(library, lite(.none)))
        XCTAssertEqual(unlocked(byPath, lite(.none)), unlocked(library, lite(.none)))
    }

    /// A filtered list is a view of the library, not the library: computing
    /// the slots from search results would unlock the fourth game as soon as
    /// the first three were typed away.
    func testSearchResultsDoNotUnlockAnything() {
        let onlyDAndE = library.filter { $0.displayName == "D" || $0.displayName == "E" }
        let slots = unlocked(library, lite(.none))
        XCTAssertFalse(FreeGameSlots.isLocked(filePath: "/games/A.chd", unlocked: slots))
        for item in onlyDAndE {
            XCTAssertTrue(FreeGameSlots.isLocked(filePath: item.filePath, unlocked: slots))
        }
    }

    /// Cache written before this feature has no arrival time at all. Those
    /// entries are ordered by path so the answer is the same on every launch.
    func testMigratedEntriesFallBackToPathOrder() {
        var items = library.map { item -> GameItem in
            var copy = item
            copy.addedAt = nil
            return copy
        }
        items.shuffle()
        XCTAssertEqual(unlocked(items, lite(.none)),
                       Set(["/games/A.chd", "/games/B.chd", "/games/C.chd"]))
    }

    /// A game imported after the migration arrives later than every migrated
    /// entry, so it cannot push an existing game out of a free slot.
    func testANewImportDoesNotStealASlotFromMigratedEntries() {
        var migrated = Array(library.prefix(3)).map { item -> GameItem in
            var copy = item
            copy.addedAt = .distantPast
            return copy
        }
        migrated.append(item("Z", added: 60))
        XCTAssertEqual(unlocked(migrated, lite(.none)),
                       Set(["/games/A.chd", "/games/B.chd", "/games/C.chd"]))
    }

    // MARK: - isLocked

    func testAPathOutsideTheLibraryIsLocked() {
        let slots = unlocked(library, lite(.none))
        XCTAssertTrue(FreeGameSlots.isLocked(filePath: "/games/unknown.chd",
                                             unlocked: slots),
                      "a path the library never scanned must not be launchable")
    }

    func testNothingIsLockedWithoutALimit() {
        XCTAssertFalse(FreeGameSlots.isLocked(filePath: "/games/unknown.chd",
                                              unlocked: nil))
    }
}
