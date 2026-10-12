import UIKit
import SwiftUI
import FirebaseAuth

/// Presents the SwiftUI SignInView from UIKit, for the one place that still
/// pushes a modal sign-in screen: the in-game menu. (The cloud backup section
/// and the account tab embed `SignInView` directly.)
///
/// Replaces the legacy LoginViewController and keeps its contract:
/// completionHandler runs when the screen goes away, with true when a user is
/// signed in by then.
///
/// It installs no GCController handlers of its own. It used to set
/// `buttonB.pressedChangedHandler` and nil it again in `viewWillDisappear`
/// without restoring the presenter's, which is exactly the failure
/// ios/CLAUDE.md's CRITICAL section describes: handlers are one slot per
/// button per controller, so clearing one screen's silently kills the screen
/// underneath. B-to-dismiss now comes from the presenter, which owns the
/// controller for the whole in-game context
/// (`GameMainViewController.enableModalGamepadSupport(for:)`) and restores its
/// own handlers afterwards.
final class SignInHostingController: UIHostingController<SignInView> {

    /// Called when the screen is dismissed; true when sign-in succeeded.
    var completionHandler: ((Bool) -> Void)?

    private var authHandle: AuthStateDidChangeListenerHandle?
    private var didReportCompletion = false

    init() {
        super.init(rootView: SignInView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Sign In", comment: "Sign in heading")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "Close", comment: "Close Dialoig"),
            style: .plain, target: self, action: #selector(closeTapped))

        // Dismiss as soon as Firebase reports a signed-in user, which is what
        // the caller is waiting for.
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard user != nil else { return }
            self?.dismissSelf()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        reportCompletion()
    }

    @objc private func closeTapped() {
        dismissSelf()
    }

    private func dismissSelf() {
        // presentingViewController is nil once the dismissal is under way.
        guard presentingViewController != nil else { return }
        dismiss(animated: true)
    }

    private func reportCompletion() {
        guard !didReportCompletion else { return }
        didReportCompletion = true
        completionHandler?(Auth.auth().currentUser != nil)
    }

    deinit {
        if let handle = authHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }
}
