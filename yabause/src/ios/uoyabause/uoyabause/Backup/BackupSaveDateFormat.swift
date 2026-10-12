import Foundation

/// How a save's date is written into, and read back out of, a backup record.
///
/// Both the personal cloud path and the shared-backup path store this as a
/// **string**, not a Firebase timestamp, so the two have to agree on the
/// format or a save published from one screen shows no date on the other.
/// Reading accepts both separators because both appear in stored records.
enum BackupSaveDateFormat {
    private static let slashed: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    private static let dashed: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func date(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return slashed.date(from: text) ?? dashed.date(from: text)
    }

    /// The form this app writes. Android reads whatever string it is given.
    static func string(from date: Date) -> String {
        slashed.string(from: date)
    }
}
