import Foundation

/// Who may use cloud backup, and how many slots they get.
///
/// A thin reading of ProEntitlement: cloud backup is one of the five things
/// the subscription unlocks, and this type adds only what is specific to the
/// cloud -- the slot count written to max_backup_count.
///
/// The values are stored rather than computed so a caller can hand one
/// around as a snapshot of the entitlement at a moment in time.
struct CloudBackupEntitlement {
    /// Slot count written to max_backup_count, matching the Android values.
    static let entitledSlotCount = ProEntitlement.cloudSlotCount

    let isEnabled: Bool

    /// True while StoreKit is still deciding. Callers should show a neutral
    /// "checking" state rather than claiming the feature is unavailable.
    let isCheckingEntitlement: Bool

    let slotCount: Int

    init(entitlement: ProEntitlement = ProEntitlement()) {
        self.isEnabled = entitlement.isUnlocked
        self.isCheckingEntitlement = entitlement.state == .checking
        self.slotCount = entitlement.isUnlocked ? Self.entitledSlotCount : 0
    }

    /// Pins the three values, for tests that need a state StoreKit would
    /// otherwise have to be stood up to produce.
    init(isEnabled: Bool, isCheckingEntitlement: Bool, slotCount: Int) {
        self.isEnabled = isEnabled
        self.isCheckingEntitlement = isCheckingEntitlement
        self.slotCount = slotCount
    }
}
