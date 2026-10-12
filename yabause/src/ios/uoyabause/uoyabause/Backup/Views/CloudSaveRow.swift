import SwiftUI

/// One cloud save in the backup list: screenshot, name, comment, game and size.
/// Mirrors BackupSaveRow, but the screenshot comes from a URL instead of disk.
struct CloudSaveRow: View {
    let item: CloudBackupItem

    private var formattedDate: String {
        guard let date = item.saveDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            screenshot
                .frame(width: 64, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.subheadline.weight(.semibold))
                if !item.comment.isEmpty {
                    Text(item.comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let title = item.gameTitle, !title.isEmpty {
                    Text("\(title) \u{00B7} \(formattedDate)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !formattedDate.isEmpty {
                    Text(formattedDate)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(item.displaySize) \u{00B7} \(item.blockSize) "
                     + String(localized: "blocks", comment: "Backup block count unit"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var screenshot: some View {
        if let text = item.screenshotURL, let url = URL(string: text) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.themeSurfaceContainerHigh
            Image(systemName: "icloud")
                .foregroundStyle(.secondary)
        }
    }
}
