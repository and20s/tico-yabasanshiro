import Foundation

/// Which set of saves the backup tab is showing.
///
/// The tab used to ask this with two controls: a Local/Cloud segmented picker
/// and, beside it, a menu choosing between the internal memory and whichever
/// cartridge is configured. They answer one question -- "which store am I
/// looking at?" -- so they are one selection here.
///
/// This is a projection over BackupTabState.section and
/// BackupListViewModel.selectedFile, which stay the underlying truth. Nothing
/// downstream of the picker had to learn about this type.
enum BackupSource: Hashable, Identifiable {
    /// One of the on-device backup memories.
    case local(BackupFile)
    /// The signed-in user's cloud saves.
    case cloud

    var id: String {
        switch self {
        case .local(let file): return "local.\(file.rawValue)"
        case .cloud: return "cloud"
        }
    }

    var displayName: String {
        switch self {
        case .local(let file): return file.displayName
        case .cloud: return String(localized: "Cloud", comment: "Backup source")
        }
    }

    var isCloud: Bool { self == .cloud }
}
