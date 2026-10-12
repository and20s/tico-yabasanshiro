import Combine
import Foundation

/// Carries a shared-save id from a tapped link to the SwiftUI tree.
///
/// UIKit sees the link (AppDelegate) but the screen that shows it is deep in
/// SwiftUI, so the id waits here until MainTabView picks it up. A single
/// shared instance rather than an injected one because AppDelegate is created
/// by the system and has nowhere to receive a dependency from.
@MainActor
final class SharedBackupLinkRouter: ObservableObject {
    static let shared = SharedBackupLinkRouter()

    /// The id waiting to be shown; nil once the UI has taken it.
    @Published private(set) var pendingId: String?

    init() {}

    /// Records the id in a link, and reports whether it was one of ours so
    /// the caller knows not to fall through to its other handlers.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let id = BackupShareLink.id(from: url) else { return false }
        pendingId = id
        return true
    }

    /// Handles the `NSUserActivity` a Universal Link arrives as.
    @discardableResult
    func handle(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return false }
        return handle(url: url)
    }

    /// Called once the UI has presented it. Clearing here rather than in the
    /// view's onAppear means a second tap on the same link presents again.
    func clearPending() {
        pendingId = nil
    }
}
