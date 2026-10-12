import SwiftUI

/// Issues a PIN another device can use to sign in as this user.
/// Only Google accounts can issue one: the PIN carries a Google token.
struct CrossDeviceSyncCard: View {
    @ObservedObject var viewModel: DevicePinViewModel
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "Cross-Device Sync", comment: "Sync card title"),
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeSurfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onReceive(ticker) { now = $0 }
        .onDisappear {
            // Android leaves issued PINs alive until the server expires them.
            Task { await viewModel.discard() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .signInRequired:
            Text(String(localized: "Sign in to sync with another device.",
                        comment: "Sync needs sign in"))
                .font(.subheadline).foregroundStyle(.secondary)
        case .googleRequired:
            Text(String(localized: "This feature is available when you sign in with Google.",
                        comment: "Sync needs a Google account"))
                .font(.subheadline).foregroundStyle(.secondary)
        case .idle:
            Text(String(localized: "Create a PIN, then enter it on the other device to sign in there.",
                        comment: "Sync instructions"))
                .font(.subheadline).foregroundStyle(.secondary)
            Button(String(localized: "Create PIN", comment: "Issue a sync PIN")) {
                Task { await viewModel.issue() }
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Color.themeOnPrimary)
        case .issuing:
            ProgressView()
        case .issued(let pin):
            Text(pin)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
            Text(remainingText)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Button(String(localized: "New PIN", comment: "Issue another sync PIN")) {
                Task {
                    await viewModel.discard()
                    await viewModel.issue()
                }
            }
        }
    }

    private var remainingText: String {
        let seconds = viewModel.remainingSeconds(at: now)
        return String(format: "%@ %d:%02d",
                      String(localized: "Expires in", comment: "PIN countdown"),
                      seconds / 60, seconds % 60)
    }
}
