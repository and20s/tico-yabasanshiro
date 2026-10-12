import SwiftUI
import UIKit

/// Hosts the existing UIKit pad editor. It is a direct-manipulation screen
/// with its own gesture handling, so it stays UIKit for now.
struct PadSettingsBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PadSettingsViewController {
        let configuration = PadConfiguration.load() ?? .default
        return PadSettingsViewController(configuration: configuration) { newConfig in
            // Same as the legacy settings screen: tell any active
            // YabausePadView that the layout changed.
            NotificationCenter.default.post(
                name: NSNotification.Name("PadConfigurationChanged"),
                object: nil,
                userInfo: ["configuration": newConfig]
            )
        }
    }

    func updateUIViewController(_ vc: PadSettingsViewController, context: Context) {}
}
