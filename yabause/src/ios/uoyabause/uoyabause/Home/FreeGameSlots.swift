import Foundation

/// Which games the free version may play.
///
/// The limit used to be enforced only where games are imported, so anything
/// copied into the app's Documents folder from the Finder was playable no
/// matter how much of it there was. The rule lives here instead: a plain
/// function over the library that the games tab, the launcher and the in-game
/// disc picker all call, so a game that shows as locked cannot be started
/// through another route.
///
/// The free slots are the first `ProEntitlement.freeGameLimit` games *by
/// arrival*, never by the order they happen to be shown in. Sorting or
/// searching the list therefore cannot hand the slots to another three games,
/// and the games someone has been playing keep working when a fourth file
/// appears.
enum FreeGameSlots {
    /// The paths a locked build may launch, or nil when there is no limit.
    ///
    /// nil rather than "all of them": callers read it as "no limit at all", so
    /// a library that grew after this was computed cannot come out half
    /// locked. Pro (and StoreKit's undecided state, as everywhere else) is nil.
    static func unlockedPaths(items: [GameItem],
                              entitlement: ProEntitlement = ProEntitlement()) -> Set<String>? {
        guard !entitlement.allowsAction else { return nil }
        let ordered = items.sorted(by: arrivedEarlier)
        return Set(ordered.prefix(ProEntitlement.freeGameLimit).map(\.filePath))
    }

    /// Whether this game is out of the free allowance.
    ///
    /// A path the set does not name is locked, which also covers a file the
    /// library has not scanned yet: unknown means not allowed, so a launch
    /// route that skips the list cannot slip past the limit.
    static func isLocked(filePath: String, unlocked: Set<String>?) -> Bool {
        guard let unlocked = unlocked else { return false }
        return !unlocked.contains(filePath)
    }

    /// The same answer for callers that hold no library, read from the same
    /// cache the games tab publishes (it is written on every rescan).
    static func isLocked(filePath: String,
                         cache: GameListCache = GameListCache(),
                         entitlement: ProEntitlement = ProEntitlement()) -> Bool {
        isLocked(filePath: filePath,
                 unlocked: unlockedPaths(items: cache.load(), entitlement: entitlement))
    }

    /// Library order: when a game entered the library, then its path.
    ///
    /// The path is not only a tie-break for entries imported in the same
    /// second. Cache written before `addedAt` existed carries none at all, and
    /// ordering those by path is what makes the migrated answer the same on
    /// every launch instead of following the order the disk was walked in.
    static func arrivedEarlier(_ lhs: GameItem, _ rhs: GameItem) -> Bool {
        let left = lhs.addedAt ?? .distantPast
        let right = rhs.addedAt ?? .distantPast
        if left != right { return left < right }
        return lhs.filePath < rhs.filePath
    }
}
