import SwiftUI
import UIKit

/// The system share sheet, for handing a published save's link somewhere.
///
/// UIActivityViewController rather than SwiftUI's ShareLink so the same body
/// works on the iOS 16 deployment target, and so the iPad popover has an
/// anchor to present from.
struct ShareLinkSheet: UIViewControllerRepresentable {
    let url: URL
    let title: String
    /// Appended to the message so shared saves can be searched together, as
    /// Android's share does. Empty omits the line.
    var hashtags: String = ""

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var text = String(format: String(localized: "%@ save data shared",
                                         comment: "Share link message"), title)
        if !hashtags.isEmpty {
            text += "\n\(hashtags)"
        }
        let controller = UIActivityViewController(
            activityItems: [text, url], applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}
