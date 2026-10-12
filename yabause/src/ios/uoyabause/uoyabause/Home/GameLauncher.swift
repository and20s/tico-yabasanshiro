import SwiftUI
import UIKit

/// Presents the legacy UIKit emulator screen from SwiftUI.
/// The game exits via exit(0) (existing behavior), so no dismiss path
/// back to the tab UI is required.
enum GameLauncher {
    /// Instantiates GameMainViewController from the storyboard and
    /// presents it full screen over the given view controller.
    @MainActor
    static func launch(filePath: String, productNumber: String,
                       from presenter: UIViewController) {
        // Last line of defence for the free version's three-game limit. Every
        // route into the emulator passes through here, including any added
        // later that forgets to ask, so a file dropped into the Documents
        // folder from the Finder cannot be played by finding another way in.
        guard !FreeGameSlots.isLocked(filePath: filePath) else {
            presentGate(from: presenter)
            return
        }
        // The standalone backup session owns emulator globals; hand them back
        // before the emulator starts (see BackupSession).
        BackupSession.shared.closeIfOpen()

        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        guard let vc = storyboard.instantiateViewController(
            withIdentifier: "GameMainViewController") as? GameMainViewController else {
            assertionFailure("GameMainViewController not found in storyboard")
            return
        }
        // The emulator installs its own global GCController handlers.
        // Tell the home UI to drop ours first (ios/CLAUDE.md CRITICAL).
        NotificationCenter.default.post(
            name: HomeGamePadManager.shouldYieldNotification, object: nil)
        vc.selectedFile = filePath
        vc.productNumber = productNumber
        vc.modalPresentationStyle = .fullScreen
        presenter.present(vc, animated: true)
    }

    /// The same pro gate the rest of the app opens, presented over UIKit.
    @MainActor
    private static func presentGate(from presenter: UIViewController) {
        let sheet = ProGateSheet(
            reason: ProGateReason(
                String(localized: "The free version holds three games. A subscription removes the limit.",
                       comment: "Reason the pro gate opened from the game limit"))) {
            ProEntitlementStore.shared.refresh()
        }
        presenter.present(UIHostingController(rootView: sheet), animated: true)
    }

    /// Topmost view controller usable as a presenter from SwiftUI.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
