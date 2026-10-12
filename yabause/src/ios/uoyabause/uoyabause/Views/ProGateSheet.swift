import StoreKit
import SwiftUI

/// Why the gate opened. The message is shown in the sheet, in the same slot
/// Android calls tv_additional_message, so the user is told which restriction
/// they just met rather than being shown a bare pitch.
struct ProGateReason: Identifiable {
    let id = UUID()
    let message: String?

    init(_ message: String? = nil) {
        self.message = message
    }
}

/// One purchasable row in the gate, built from what StoreKit returned.
///
/// The gate draws whatever it is handed, so the full app can offer two
/// products and Lite one without either needing its own screen.
struct ProOffer: Identifiable {
    enum Kind { case annual, lifetime }

    let id: String
    let product: Product
    let kind: Kind
}

/// Loads the products, runs purchase and restore.
@MainActor
final class ProGateModel: ObservableObject {
    @Published private(set) var offers: [ProOffer] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isPurchasing = false
    /// Where this user stands, as the gate draws it.
    ///
    /// Checking is a third value rather than "not Pro yet" on purpose. A
    /// customer who bought the paid app is `.checking` for the second or two
    /// before AppTransaction answers, and treating that as not-entitled shows
    /// them the offers -- which is how someone gets walked all the way
    /// through buying what they already own.
    @Published private(set) var standing: Standing = .checking
    @Published var errorMessage: String?

    enum Standing: Equatable {
        case checking
        case entitled
        case notEntitled
    }

    /// Kept as a convenience for the flows that dismiss once Pro is in hand.
    var isPro: Bool { standing == .entitled }

    /// Row order, which the focus scope mirrors. Built from the offers the
    /// store returned rather than fixed, so one screen serves both builds.
    enum Row: Hashable {
        case offer(String)
        case buyFullVersion
        case restore
        case cancel
    }

    /// The focus list, which has to name exactly what the sheet draws, in the
    /// same order, in every state. Once Pro is confirmed the offers are
    /// replaced by a badge, and while the answer is still outstanding they are
    /// replaced by the progress overlay -- either way Cancel is alone, and the
    /// list has to follow or Down would walk onto buttons that are not there.
    ///
    /// A free function of the three inputs, so the invariant is testable
    /// without standing up the view.
    nonisolated static func rows(standing: Standing, offerIDs: [String],
                                 isLite: Bool) -> [Row] {
        switch standing {
        case .checking, .entitled:
            return [.cancel]
        case .notEntitled:
            break
        }
        var built = offerIDs.map { Row.offer($0) }
        // The second offer only makes sense in Lite, where the full app is a
        // different product the user can go and buy.
        if isLite { built.append(.buyFullVersion) }
        built.append(contentsOf: [.restore, .cancel])
        return built
    }

    /// The button text for an offer. Static and nonisolated so it can be
    /// tested synchronously without standing up StoreKit.
    nonisolated static func title(for kind: ProOffer.Kind, price: String?) -> String {
        guard let price else {
            switch kind {
            case .annual:
                return String(localized: "Subscribe", comment: "Subscribe button")
            case .lifetime:
                return String(localized: "Buy Lifetime Pro",
                              comment: "Lifetime purchase button")
            }
        }
        switch kind {
        case .annual:
            return String(format: String(localized: "Subscribe (%@/year)",
                                         comment: "Subscribe button with price"),
                          price)
        case .lifetime:
            return String(format: String(localized: "Buy Lifetime Pro (%@)",
                                         comment: "Lifetime button with price"),
                          price)
        }
    }

    func load() async {
        isLoading = true
        await PurchaseManager.shared.requestProducts()
        await PurchaseManager.shared.refresh()
        let byID = Dictionary(uniqueKeysWithValues:
            PurchaseManager.shared.products.map { ($0.id, $0) })
        // Annual first, lifetime second: the cheaper commitment leads, and
        // the order is fixed so the focus ring does not move between launches.
        var built: [ProOffer] = []
        if let product = byID[ProProducts.annual] {
            built.append(ProOffer(id: product.id, product: product, kind: .annual))
        }
        if let lifetimeID = ProProducts.lifetime, let product = byID[lifetimeID] {
            built.append(ProOffer(id: product.id, product: product, kind: .lifetime))
        }
        offers = built
        standing = currentStanding()
        isLoading = false
    }

    /// Follows the observed store. The sheet hands over every entitlement the
    /// store publishes while it is open, so a legacy answer that lands a
    /// moment after the sheet opened replaces the offers with the badge
    /// instead of leaving a paying customer on the sales layout.
    func apply(_ entitlement: ProEntitlement) {
        standing = Self.standing(for: entitlement)
    }

    private static func standing(for entitlement: ProEntitlement) -> Standing {
        switch entitlement.state {
        case .unlocked: return .entitled
        case .locked: return .notEntitled
        case .checking: return .checking
        }
    }

    /// The whole answer, not just the in-app purchases.
    ///
    /// The in-app purchases alone say nothing about the legacy paid app, so
    /// asking PurchaseManager would show the paywall to a customer who bought
    /// the app back when it cost money -- the people this migration exists to
    /// protect.
    ///
    /// The store is refreshed rather than a private ProEntitlement being
    /// constructed, for two reasons. Its refresh() is synchronous: it rebuilds
    /// the entitlement from both sources as they stand at this instant, so
    /// there is no @Published hop to be a snapshot behind, which a plain read
    /// of the store right after an awaited refresh would be. And it leaves the
    /// store holding that same answer, so the badge -- which observes the
    /// store -- cannot disagree with this flag.
    private func currentStanding() -> Standing {
        ProEntitlementStore.shared.refresh()
        return Self.standing(for: ProEntitlementStore.shared.entitlement)
    }

    func purchase(_ offer: ProOffer) async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            _ = try await PurchaseManager.shared.purchase(offer.product)
            standing = currentStanding()
        } catch {
            errorMessage = String(localized: "Could not complete the purchase.",
                                  comment: "Purchase error")
            print("ProGateModel: purchase failed: \(error)")
        }
    }

    func restore() async {
        isPurchasing = true
        defer { isPurchasing = false }
        await PurchaseManager.shared.restorePurchases()
        standing = currentStanding()
    }
}

/// The one place the app asks for money. Mirrors Android's dialog_pro_gate:
/// the same hero image, the same five features, subscribe and buy-the-full-app
/// side by side.
///
/// Two things Android does not have are required here. A restore control,
/// because Apple requires one. The price, the period and links to the terms
/// and the privacy policy, because guideline 3.1.2 requires them on the
/// screen that sells a subscription.
struct ProGateSheet: View {
    let reason: ProGateReason
    /// The coordinator this sheet pushes its scope onto. Nil from the
    /// UIKit presentation in GameViewController, which parks the pad
    /// through didPresentModal instead.
    var focus: ControllerFocusCoordinator?
    var onChange: () -> Void = {}

    @StateObject private var model = ProGateModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isControllerConnected) private var isControllerConnected
    /// Observed, not read through the singleton: the badge names which of the
    /// three routes granted Pro, and reading the store without observing it
    /// would draw a stale frame -- a lifetime buyer briefly labelled Pro
    /// Annual -- and would never update if the entitlement changed while the
    /// sheet stayed open.
    @ObservedObject private var entitlementStore = ProEntitlementStore.shared
    /// Modal: nothing behind this sheet may move while money is being
    /// asked for (behaviour table section 0.1).
    @StateObject private var scope =
        ActionListFocusModel(scopeName: "proGate", isModal: true)

    private typealias Row = ProGateModel.Row

    /// The rows actually drawn, in the order they are drawn.
    private var rows: [Row] {
        ProGateModel.rows(standing: model.standing,
                          offerIDs: model.offers.map(\.id),
                          isLite: ProEntitlement.buildIsLite)
    }

    private func isFocused(_ row: Row) -> Bool {
        guard let index = rows.firstIndex(of: row) else { return false }
        return scope.focused == index
    }

    private static let features = [
        String(localized: "Unlimited games (free: 3 games max)", comment: "Pro feature"),
        String(localized: "Cloud backup (up to 256 saves)", comment: "Pro feature"),
        String(localized: "Action Replay / Cloud cheats", comment: "Pro feature"),
        String(localized: "Shared backup import and rating", comment: "Pro feature"),
        String(localized: "No advertisements", comment: "Pro feature"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                if let message = reason.message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Color.themePrimary)
                        .multilineTextAlignment(.center)
                }
                featureList
                buttons
                legal
            }
            .padding(24)
        }
        .accessibilityIdentifier("proGate")
        .background(hero)
        .overlay {
            // The table asks that A during work in flight not simply do
            // nothing: the work has to be visible while it blocks the rows.
            // Loading counts -- the store is being asked for the product, and
            // until it answers there is no purchase to start.
            if model.isPurchasing || model.isLoading
                || model.standing == .checking {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .background(Color.themeSurfaceContainerHigh,
                                in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .controllerFocusScope(scope, in: focus)
        .task { await model.load() }
        .onAppear { configureScope() }
        .onChange(of: model.standing) { _ in declareRows() }
        // The decision follows the store rather than the snapshot load() took:
        // a legacy answer that arrives while the sheet is open has to replace
        // the offers, or a customer who already paid is walked through buying
        // what they own.
        .onChange(of: entitlementStore.entitlement) { model.apply($0) }
        .onChange(of: model.offers.map(\.id)) { _ in declareRows() }
        .onChange(of: isControllerConnected) {
            scope.applyInitialFocus(controllerConnected: $0)
        }
        .alert(String(localized: "Error", comment: "Error alert title"),
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Full-bleed art under a scrim, the way the Android dialog draws it.
    private var hero: some View {
        Image("pro_hero")
            .resizable()
            .scaledToFill()
            .overlay(Color.black.opacity(0.53))
            .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(String(localized: "Unlock YabaSanshiro", comment: "Pro gate title"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(String(localized: "Get the full experience with these premium features",
                        comment: "Pro gate subtitle"))
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.features, id: \.self) { text in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.themePrimary)
                    Text(text).font(.footnote).foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.standing {
        case .checking:
            // Nothing here: the progress overlay is what a user sees while
            // StoreKit decides. Drawing the offers under it would put the
            // sales pitch in front of a customer who has already paid.
            EmptyView()
        case .entitled:
            switch entitlementStore.entitlement.source {
            case .legacyPaid:
                VStack(spacing: 4) {
                    Label(String(localized: "Lifetime Pro", comment: "Lifetime pro badge"),
                          systemImage: "checkmark.seal.fill")
                        .font(.headline).foregroundStyle(.green)
                    Text(String(localized: "Thank you for purchasing Yaba Sanshiro 2.",
                                comment: "Thanks shown to a legacy paid user"))
                        .font(.caption).foregroundStyle(.white)
                }
            case .lifetime:
                Label(String(localized: "Lifetime Pro", comment: "Lifetime pro badge"),
                      systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.green)
            case .annual:
                Label(String(localized: "Pro Annual", comment: "Annual pro badge"),
                      systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.green)
            case .none:
                // Entitled but the source has not been read back yet. Neutral
                // on purpose: naming the annual plan here would tell a legacy
                // or lifetime owner they are on a yearly subscription.
                Label(String(localized: "Pro", comment: "Pro card title"),
                      systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.green)
            }
        case .notEntitled:
            emptyOffers

            ForEach(model.offers) { offer in
                offerRow(offer)
            }

            if ProEntitlement.buildIsLite {
                Button(String(localized: "Buy the full version",
                              comment: "Second offer in the pro gate")) {
                    openFullVersion()
                }
                .buttonStyle(.bordered)
                .controllerFocusRing(isFocused(.buyFullVersion), cornerRadius: 8)
            }

            Button(String(localized: "Restore Purchases",
                          comment: "Restore purchases button")) {
                startRestore()
            }
            .disabled(model.isPurchasing)
            .controllerFocusRing(isFocused(.restore), cornerRadius: 8)
        }

        // Drawn in every state, and last in every state, so the focus list
        // above matches what is on screen wherever the entitlement stands.
        Button(String(localized: "Cancel", comment: "Cancel")) { dismiss() }
            .foregroundStyle(.white)
            .controllerFocusRing(isFocused(.cancel), cornerRadius: 8)
    }

    /// One offer, drawn from whatever the store returned. The annual offer
    /// leads with the prominent style; the lifetime one carries the sentence
    /// that says it does not renew.
    @ViewBuilder
    private func offerRow(_ offer: ProOffer) -> some View {
        VStack(spacing: 2) {
            offerButton(offer)
            if offer.kind == .lifetime {
                Text(String(localized: "Pay once. Keep Pro forever.",
                            comment: "Lifetime offer explanation"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    /// The two button styles are different types, so the choice has to be a
    /// branch between two views rather than a value inside one call.
    @ViewBuilder
    private func offerButton(_ offer: ProOffer) -> some View {
        let title = ProGateModel.title(for: offer.kind,
                                       price: offer.product.displayPrice)
        let isBusy = model.isLoading || model.isPurchasing
        if offer.kind == .annual {
            Button(title) { startPurchase(offer) }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Color.themeOnPrimary)
                .disabled(isBusy)
                .controllerFocusRing(isFocused(.offer(offer.id)), cornerRadius: 8)
        } else {
            Button(title) { startPurchase(offer) }
                .buttonStyle(.bordered)
                .foregroundStyle(Color.themePrimary)
                .disabled(isBusy)
                .controllerFocusRing(isFocused(.offer(offer.id)), cornerRadius: 8)
        }
    }

    // MARK: - Controller focus

    private func configureScope() {
        // Blocks A, not the ring: the framework does not gate move(by:), so
        // Up and Down keep walking the list while this is true. What it
        // guarantees is that A does not fire a row's action -- it goes to
        // onConfirm instead, which is what lets A answer the error alert
        // rather than reaching the button behind it. Work in flight blocks
        // for the same reason, and the overlay above shows it is happening.
        scope.isBlocked = {
            model.isPurchasing || model.isLoading || model.errorMessage != nil
        }
        scope.onConfirm = {
            guard model.errorMessage != nil else { return false }
            model.errorMessage = nil
            return true
        }
        // B is never a no-op (behaviour table section 0): it takes the alert
        // down if one is up, and otherwise closes the gate.
        scope.onClose = {
            if model.errorMessage != nil {
                model.errorMessage = nil
                return true
            }
            dismiss()
            return true
        }
        declareRows()
    }

    private func declareRows() {
        scope.setActions(rows.map { row in
            switch row {
            case .offer(let id):
                return {
                    guard let offer = model.offers.first(where: { $0.id == id }) else { return }
                    startPurchase(offer)
                }
            case .buyFullVersion: return { openFullVersion() }
            case .restore: return { startRestore() }
            case .cancel: return { dismiss() }
            }
        })
        scope.applyInitialFocus(controllerConnected: isControllerConnected)
    }

    // MARK: - Actions

    private func startPurchase(_ offer: ProOffer) {
        Task {
            await model.purchase(offer)
            onChange()
            if model.isPro { dismiss() }
        }
    }

    private func openFullVersion() {
        guard let url = ProEntitlement.fullAppURL else { return }
        UIApplication.shared.open(url)
    }

    private func startRestore() {
        Task {
            await model.restore()
            onChange()
            if model.isPro { dismiss() }
        }
    }

    /// Shown when the store returned nothing, which is the live state while a
    /// product is not yet approved, or the device is offline. The table
    /// (section 0) does not allow a focused row to answer nothing.
    @ViewBuilder
    private var emptyOffers: some View {
        if !model.isLoading && model.offers.isEmpty {
            Text(String(localized: "Purchases are not available right now. Please try again later.",
                        comment: "No products returned by the store"))
                .font(.footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
    }

    private var annualOffer: ProOffer? {
        model.offers.first { $0.kind == .annual }
    }

    /// Guideline 3.1.2: the length, the price and both links have to be on
    /// the screen that sells the subscription. Which is the whole condition --
    /// when the badge is up nothing is on sale here, so the terms of a sale
    /// have no place under it. The links stay either way: they are true of the
    /// app rather than of an offer, and this sheet is where the app puts them.
    private var legal: some View {
        VStack(spacing: 6) {
            switch model.standing {
            case .checking:
                // Nothing is on sale while the answer is outstanding, and
                // nothing is confirmed either, so neither sentence is true.
                EmptyView()
            case .entitled:
                entitledTerms
            case .notEntitled:
                offerTerms
            }
            HStack(spacing: 16) {
                Link(String(localized: "Terms of Use", comment: "Terms link"),
                     destination: ProGateSheet.termsURL)
                Link(String(localized: "Privacy Policy", comment: "Privacy link"),
                     destination: ProGateSheet.privacyURL)
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.8))
        .multilineTextAlignment(.center)
    }

    /// What an already-entitled user is told. Only the annual subscriber has
    /// anything renewing, and for them the sentence is both true and the one
    /// place the app says where to cancel, so they keep it. A lifetime or
    /// legacy owner owes nothing and must never read that their Pro renews.
    ///
    /// No price for anyone: an existing subscriber may be grandfathered onto a
    /// tier the store no longer quotes, so today's price is not their price.
    @ViewBuilder
    private var entitledTerms: some View {
        if entitlementStore.entitlement.source == .annual {
            Text(String(localized: "Auto-renewing annual subscription. Cancel any time in Settings.",
                        comment: "Subscription terms"))
        }
    }

    /// What a user being sold to is told, per offer actually on sale.
    @ViewBuilder
    private var offerTerms: some View {
        // The storefront's own localized price, never a hardcoded amount:
        // the price differs per country. Price and renewal sentence stand
        // or fall together on the annual offer actually being on sale:
        // with only the lifetime product returned, or nothing at all,
        // there is no subscription on this screen to describe, and saying
        // one auto-renews would be false.
        if let price = annualOffer?.product.displayPrice {
            Text(String(format: String(localized: "%@ per year",
                                       comment: "Subscription price and period"),
                        price))
            Text(String(localized: "Auto-renewing annual subscription. Cancel any time in Settings.",
                        comment: "Subscription terms"))
        }
        if model.offers.contains(where: { $0.kind == .lifetime }) {
            Text(String(localized: "Lifetime Pro is a one-time purchase and does not renew.",
                        comment: "Lifetime terms"))
        }
    }

    static let termsURL = URL(string: "https://www.yabasanshiro.com/terms-of-use")!
    static let privacyURL = URL(string: "https://www.yabasanshiro.com/privacy")!
}

extension View {
    /// Opens the pro gate for a reason. Every gate in the app goes through
    /// here, so there is one screen asking for money rather than three.
    ///
    /// `focus` is what stops the D-pad driving the screen underneath while
    /// the sheet is up; it defaults to nil for presentations that have no
    /// coordinator to hand.
    func proGate(item: Binding<ProGateReason?>,
                 focus: ControllerFocusCoordinator? = nil,
                 onChange: @escaping () -> Void = {}) -> some View {
        modifier(ProGateModifier(item: item, focus: focus, onChange: onChange))
    }
}

/// A modifier rather than a bare `sheet` so the controller-connected flag can
/// be read here and handed to the sheet: a presentation is its own hosting
/// context, and the rest of the app passes the value across the same seam.
private struct ProGateModifier: ViewModifier {
    @Binding var item: ProGateReason?
    let focus: ControllerFocusCoordinator?
    let onChange: () -> Void

    @Environment(\.isControllerConnected) private var isControllerConnected

    func body(content: Content) -> some View {
        content.sheet(item: $item) { reason in
            ProGateSheet(reason: reason, focus: focus, onChange: onChange)
                .environment(\.isControllerConnected, isControllerConnected)
        }
    }
}
