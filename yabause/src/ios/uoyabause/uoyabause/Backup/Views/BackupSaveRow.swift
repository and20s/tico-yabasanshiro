import SwiftUI

/// One save in the backup list: screenshot, name, comment, game and size.
struct BackupSaveRow: View {
    let save: BackupSave

    private var formattedDate: String {
        guard let date = save.saveDate else { return "" }
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
                Text(save.filename)
                    .font(.subheadline.weight(.semibold))
                if !save.comment.isEmpty {
                    Text(save.comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let title = save.gameTitle, !title.isEmpty {
                    Text("\(title) \u{00B7} \(formattedDate)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !formattedDate.isEmpty {
                    Text(formattedDate)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(save.displaySize) \u{00B7} \(save.blockSize) "
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
        if let path = save.screenshotPath,
           let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.themeSurfaceContainerHigh
                Image(systemName: "externaldrive")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
