import Foundation

/// Why a save was reported.
///
/// A fixed list rather than free text: it needs no moderation of its own, it
/// is the same in every language, and it is what a reviewer can act on.
enum SharedBackupReportReason: String, CaseIterable, Identifiable {
    case inappropriate
    case spam
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inappropriate:
            return String(localized: "Inappropriate content",
                          comment: "Report reason")
        case .spam:
            return String(localized: "Spam or misleading",
                          comment: "Report reason")
        case .other:
            return String(localized: "Something else", comment: "Report reason")
        }
    }
}

/// One report, written to `shared_backup_reports/{autoId}`.
///
/// The owner is copied in rather than looked up later: by the time anyone
/// reads the report the save may already be gone, and a report that cannot
/// say who posted it is not actionable.
struct SharedBackupReport {
    let backupId: String
    let ownerId: String
    let reporterId: String
    let reason: SharedBackupReportReason

    func documentData(createdAt: Date) -> [String: Any] {
        [
            "backupId": backupId,
            "ownerId": ownerId,
            "reporterId": reporterId,
            "reason": reason.rawValue,
            "createdAt": createdAt,
        ]
    }
}
