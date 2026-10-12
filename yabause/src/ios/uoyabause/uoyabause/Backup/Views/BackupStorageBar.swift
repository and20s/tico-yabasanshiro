import SwiftUI

/// Used/free blocks of the selected backup file.
/// Mirrors the Android layout_storage_status.
struct BackupStorageBar: View {
    let status: BackupStorageStatus

    private var usedFraction: Double {
        guard status.totalBlock > 0 else { return 0 }
        return Double(status.usedBlock) / Double(status.totalBlock)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: usedFraction)
                .tint(Color.themePrimary)
            Text("\(status.usedBlock)/\(status.totalBlock) "
                 + String(localized: "blocks", comment: "Backup block count unit"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
