import SwiftUI

/// One community save in the shared list.
///
/// Mirrors CloudSaveRow, plus the two things only a shared save has: who
/// published it and how it has been received.
struct SharedSaveRow: View {
    let item: SharedBackupItem

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
                Text(item.gameTitle.isEmpty ? item.filename : item.gameTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.themeOnSurface)
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.caption)
                        .foregroundStyle(Color.themeOnSurfaceVariant)
                        .lineLimit(2)
                } else if !item.comment.isEmpty {
                    Text(item.comment)
                        .font(.caption)
                        .foregroundStyle(Color.themeOnSurfaceVariant)
                }
                ownerLine
                statsLine
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    @ViewBuilder
    private var screenshot: some View {
        if let text = item.screenshotURL, let url = URL(string: text) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.themeSurfaceContainerHighest
            }
        } else {
            Color.themeSurfaceContainerHighest
        }
    }

    private var ownerLine: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.circle")
                .font(.caption2)
                .accessibilityHidden(true)
            Text(item.ownerName)
                .font(.caption2)
            if !formattedDate.isEmpty {
                Text("\u{00B7} \(formattedDate)")
                    .font(.caption2)
            }
        }
        .foregroundStyle(Color.themeOnSurfaceVariant)
    }

    private var statsLine: some View {
        HStack(spacing: 8) {
            if item.ratingCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.themeRating)
                    Text(String(format: "%.1f (%d)",
                                item.averageRating, item.ratingCount))
                        .font(.caption2)
                }
            }
            HStack(spacing: 2) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 9))
                    .accessibilityHidden(true)
                Text("\(item.downloadCount)")
                    .font(.caption2)
            }
            Text("\(item.blockSize) "
                 + String(localized: "blocks", comment: "Backup block count unit"))
                .font(.caption2)
        }
        .foregroundStyle(Color.themeOnSurfaceVariant)
    }
}
