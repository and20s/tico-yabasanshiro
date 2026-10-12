import SwiftUI
import Kingfisher

/// One game card in the library list. Mirrors the Android item_game_card:
/// box art / title / product number + release date / rating stars /
/// RA progress bar.
struct GameCardView: View {
    let item: GameItem
    let isFocused: Bool
    /// Outside the free version's allowance: shown dimmed with a lock, and
    /// choosing it opens the pro gate rather than the detail.
    var isLocked: Bool = false

    @Environment(\.isControllerConnected) private var isControllerConnected

    private var formattedReleaseDate: String { item.formattedReleaseDate }

    /// Touch users are shown no selection at all, so the card only reacts
    /// while a controller is attached.
    private var showsFocus: Bool { isFocused && isControllerConnected }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            KFImage(item.imageUrl.flatMap(URL.init(string:)))
                .placeholder {
                    Image("missing").resizable().scaledToFit()
                }
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                Text("\(item.productNumber) / \(formattedReleaseDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.rating > 0 {
                    HStack(spacing: 1) {
                        ForEach(0..<5, id: \.self) { index in
                            Image(systemName: index < item.rating ? "star.fill" : "star")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.themeRating)
                        }
                    }
                }
                if item.raTotal > 0 {
                    ProgressView(value: Double(item.raUnlocked),
                                 total: Double(item.raTotal))
                        .tint(Color.themeRating)
                        .padding(.top, 2)
                    Text("\(Image(systemName: "trophy.fill")) \(item.raUnlocked)/\(item.raTotal)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        // Dimmed rather than hidden: the card says the game is there and the
        // lock says why it will not start, which is what the gate then offers
        // to fix.
        .opacity(isLocked ? 0.55 : 1)
        .padding(10)
        .controllerFocusRing(isFocused, base: Color.themeSurfaceContainerHigh)
        .scaleEffect(showsFocus ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: showsFocus)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isLocked ? [.isButton] : [])
        .accessibilityHint(isLocked
                           ? String(localized: "Locked in the free version",
                                    comment: "Accessibility hint on a locked game card")
                           : "")
    }
}
