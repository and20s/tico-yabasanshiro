import Foundation

/// The posters this user has chosen not to see.
///
/// Kept on the device rather than in Firestore: hiding someone is this
/// reader's preference, not a claim about them, and it must work signed out
/// and take effect immediately. Reporting is the separate action that tells
/// us about a save (see SharedBackupReport).
///
/// App Review expects both -- report the content, block the person -- for a
/// screen that lists what other users uploaded (Guideline 1.2).
struct SharedBackupBlockList {
    private static let key = "backup_share.blocked_owner_ids"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var blockedIds: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    var count: Int { blockedIds.count }

    func isBlocked(_ ownerId: String) -> Bool {
        !ownerId.isEmpty && blockedIds.contains(ownerId)
    }

    func block(_ ownerId: String) {
        guard !ownerId.isEmpty else { return }
        var ids = blockedIds
        ids.insert(ownerId)
        write(ids)
    }

    /// All at once, since the only way back is the "unhide" row: there is no
    /// per-person list to pick from, and building one would mean showing the
    /// names of people the user asked not to see.
    func unblockAll() {
        defaults.removeObject(forKey: Self.key)
    }

    private func write(_ ids: Set<String>) {
        defaults.set(Array(ids).sorted(), forKey: Self.key)
    }
}
