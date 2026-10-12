import Foundation

/// Per-category push notification switches.
/// The UserDefaults keys and FCM topic names match what MessagingManager
/// already uses, so a user's existing choices survive the SwiftUI rewrite.
final class NotificationSettingsStore {
    enum Category: String, CaseIterable, Identifiable {
        case achievements
        case leaderboards
        case gameUpdates = "game_updates"
        case systemNotifications = "system_notifications"
        case promotions

        var id: String { rawValue }

        var topic: String { "yabasanshiro_\(rawValue)" }

        var defaultsKey: String { "notification_\(rawValue)_enabled" }

        /// Categories on by default, matching the legacy screen.
        var isOnByDefault: Bool {
            self == .gameUpdates || self == .systemNotifications
        }

        var title: String {
            switch self {
            case .achievements:
                return String(localized: "Achievements",
                              comment: "Notification category")
            case .leaderboards:
                return String(localized: "Leaderboards",
                              comment: "Notification category")
            case .gameUpdates:
                return String(localized: "Game Updates",
                              comment: "Notification category")
            case .systemNotifications:
                return String(localized: "System Notifications",
                              comment: "Notification category")
            case .promotions:
                return String(localized: "Promotions",
                              comment: "Notification category")
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var registration: [String: Any] = [:]
        for category in Category.allCases {
            registration[category.defaultsKey] = category.isOnByDefault
        }
        defaults.register(defaults: registration)
    }

    func isEnabled(_ category: Category) -> Bool {
        defaults.bool(forKey: category.defaultsKey)
    }

    func setEnabled(_ enabled: Bool, for category: Category) {
        defaults.set(enabled, forKey: category.defaultsKey)
    }
}
