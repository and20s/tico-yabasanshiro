import XCTest
@testable import YabaSnashiro

@MainActor
private final class FakeDiscordStore: DiscordLinkStoring {
    var linked = false
    var lookupError: Error?
    private(set) var unlinkedUserIds: [String] = []

    func isLinked(userId: String) async throws -> Bool {
        if let error = lookupError { throw error }
        return linked
    }

    func unlink(userId: String) async throws {
        unlinkedUserIds.append(userId)
        linked = false
    }
}

@MainActor
private final class FakeRetroStatus: RetroAchievementsStatusProviding {
    var isLoggedIn = false
    var username: String?

    func signOut() {
        isLoggedIn = false
        username = nil
    }
}

@MainActor
private final class FakeProStatus: ProStatusProviding {
    var state: ProEntitlement.State
    var hasActiveSubscription = false
    var renewal: SubscriptionRenewal = .unknown
    private(set) var restoreCount = 0

    init(_ state: ProEntitlement.State) { self.state = state }

    func currentState() async -> ProEntitlement.State { state }

    func currentRenewal() async -> SubscriptionRenewal { renewal }

    func restore() async { restoreCount += 1 }
}

@MainActor
private final class FakeDeleter: AccountDeleting {
    var error: Error?
    private(set) var methods: [AccountReauthentication] = []

    func deleteAccount(reauthenticatingWith method: AccountReauthentication) async throws {
        methods.append(method)
        if let error = error { throw error }
    }
}

private struct FakeError: Error {}

@MainActor
final class AccountViewModelTests: XCTestCase {
    private var discord: FakeDiscordStore!
    private var retro: FakeRetroStatus!
    private var pro: FakeProStatus!
    private var deleter: FakeDeleter!

    override func setUp() {
        super.setUp()
        discord = FakeDiscordStore()
        retro = FakeRetroStatus()
        pro = FakeProStatus(.locked)
        deleter = FakeDeleter()
    }

    private func makeViewModel(providers: [String] = ["google.com"],
                               pro: ProEntitlement.State = .locked,
                               hasActiveSubscription: Bool = false)
    -> (AccountViewModel, AccountState) {
        let profile = AccountProfile(userId: "u1", displayName: "Tester",
                                     email: "t@example.com", photoURL: nil,
                                     providers: providers)
        let auth = FakeAuthProvider(profile: profile)
        let state = AccountState(provider: auth)
        self.pro.state = pro
        self.pro.hasActiveSubscription = hasActiveSubscription
        let viewModel = AccountViewModel(accountState: state,
                                         discordStore: discord,
                                         retroStatus: retro,
                                         proStatus: self.pro,
                                         deleter: deleter)
        return (viewModel, state)
    }

    // MARK: - Discord

    func testDiscordStartsUndecided() {
        let (viewModel, _) = makeViewModel()
        XCTAssertEqual(viewModel.discord, .checking)
    }

    func testRefreshReportsLinkedDiscord() async {
        discord.linked = true
        let (viewModel, _) = makeViewModel()
        await viewModel.refresh()
        XCTAssertEqual(viewModel.discord, .linked(nil))
    }

    func testDiscordLookupFailureReportsNotLinked() async {
        discord.lookupError = FakeError()
        let (viewModel, _) = makeViewModel()
        await viewModel.refresh()
        XCTAssertEqual(viewModel.discord, .notLinked)
    }

    func testUnlinkDiscordDeletesTheDocument() async {
        discord.linked = true
        let (viewModel, _) = makeViewModel()
        await viewModel.unlinkDiscord()
        XCTAssertEqual(discord.unlinkedUserIds, ["u1"])
        XCTAssertEqual(viewModel.discord, .notLinked)
    }

    // MARK: - RetroAchievements

    func testRetroAchievementsReportsUsername() async {
        retro.isLoggedIn = true
        retro.username = "player"
        let (viewModel, _) = makeViewModel()
        await viewModel.refresh()
        XCTAssertEqual(viewModel.retroAchievements, .linked("player"))
    }

    func testDisconnectRetroAchievements() async {
        retro.isLoggedIn = true
        retro.username = "player"
        let (viewModel, _) = makeViewModel()
        await viewModel.refresh()
        viewModel.disconnectRetroAchievements()
        XCTAssertEqual(viewModel.retroAchievements, .notLinked)
    }

    // MARK: - Subscription

    func testSubscriptionStartsUndecided() {
        let (viewModel, _) = makeViewModel()
        XCTAssertTrue(viewModel.isCheckingPro)
        XCTAssertFalse(viewModel.isPro)
    }

    func testSubscribedIsReported() async {
        let (viewModel, _) = makeViewModel(pro: .unlocked(.annual))
        await viewModel.refresh()
        XCTAssertTrue(viewModel.isPro)
        XCTAssertFalse(viewModel.isCheckingPro)
    }

    /// A legacy paid user is Pro without any subscription, and the card must
    /// say so rather than offering to sell them something they already have.
    func testALegacyPaidUserIsProWithoutASubscription() async {
        let (viewModel, _) = makeViewModel(pro: .unlocked(.legacyPaid))
        await viewModel.refreshSubscription()
        XCTAssertTrue(viewModel.isPro)
        XCTAssertFalse(viewModel.isCheckingPro)
        XCTAssertEqual(viewModel.pro, .unlocked(.legacyPaid))
    }

    /// Never claim the entitlement is missing while StoreKit is deciding.
    func testCheckingIsNotTheSameAsNotPro() async {
        let (viewModel, _) = makeViewModel(pro: .checking)
        await viewModel.refreshSubscription()
        XCTAssertFalse(viewModel.isPro)
        XCTAssertTrue(viewModel.isCheckingPro)
    }

    /// Buying a subscription is possible in the moments before the legacy
    /// status resolves, and that user must still be able to cancel it.
    func testALegacyUserWithASubscriptionIsOfferedTheManageDoor() async {
        let (viewModel, _) = makeViewModel(pro: .unlocked(.legacyPaid),
                                           hasActiveSubscription: true)
        await viewModel.refreshSubscription()
        // Still thanked as a legacy buyer, not told their Pro renews yearly.
        XCTAssertEqual(viewModel.pro, .unlocked(.legacyPaid))
        XCTAssertTrue(viewModel.canManageSubscription)
    }

    func testALegacyUserWithoutASubscriptionHasNothingToManage() async {
        let (viewModel, _) = makeViewModel(pro: .unlocked(.legacyPaid))
        await viewModel.refreshSubscription()
        XCTAssertFalse(viewModel.canManageSubscription)
    }

    func testASubscriberIsAlwaysOfferedTheManageDoor() async {
        let (viewModel, _) = makeViewModel(pro: .unlocked(.annual))
        await viewModel.refreshSubscription()
        XCTAssertTrue(viewModel.canManageSubscription)
    }

    /// A live subscription that is still set to renew keeps the renewal line.
    func testARenewingSubscriberIsToldItRenews() async {
        pro.renewal = .willRenew
        let (viewModel, _) = makeViewModel(pro: .unlocked(.annual),
                                           hasActiveSubscription: true)
        await viewModel.refreshSubscription()
        XCTAssertEqual(viewModel.subscriptionRenewal, .willRenew)
    }

    /// A subscriber who cancelled keeps Pro to the end of the period they
    /// paid for, and must be told when it runs out -- not that it renews.
    func testACancelledSubscriberIsToldWhenItRunsOut() async {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        pro.renewal = .expires(expiry)
        let (viewModel, _) = makeViewModel(pro: .unlocked(.annual),
                                           hasActiveSubscription: true)
        await viewModel.refreshSubscription()
        XCTAssertEqual(viewModel.subscriptionRenewal, .expires(expiry))
        // Still entitled: cancelled is not lapsed.
        XCTAssertTrue(viewModel.isPro)
        XCTAssertTrue(viewModel.canManageSubscription)
    }

    /// Before StoreKit answers there is no date to show, and the card must
    /// not invent one.
    func testAnUnknownRenewalStaysUnknown() async {
        let (viewModel, _) = makeViewModel(pro: .unlocked(.annual))
        await viewModel.refreshSubscription()
        XCTAssertEqual(viewModel.subscriptionRenewal, .unknown)
    }

    func testRestoreRechecksTheStatus() async {
        let (viewModel, _) = makeViewModel(pro: .locked)
        // The restore is what makes them Pro, so the recheck after it is the
        // only thing that can move the view model off .locked.
        pro.state = .unlocked(.lifetime)
        await viewModel.restorePurchases()
        XCTAssertEqual(pro.restoreCount, 1)
        XCTAssertTrue(viewModel.isPro)
    }

    // MARK: - Deletion

    func testGoogleAccountReauthenticatesWithGoogle() async {
        let (viewModel, _) = makeViewModel(providers: ["google.com"])
        viewModel.askToDeleteAccount()
        XCTAssertEqual(viewModel.deletion, .confirming)
        await viewModel.confirmDeletion()
        XCTAssertEqual(deleter.methods, [.google])
        XCTAssertEqual(viewModel.deletion, .deleted)
    }

    func testPasswordAccountAsksForThePassword() async {
        let (viewModel, _) = makeViewModel(providers: ["password"])
        await viewModel.confirmDeletion()
        XCTAssertEqual(viewModel.deletion, .passwordRequired)
        XCTAssertTrue(deleter.methods.isEmpty)

        await viewModel.deleteAccount(reauthenticatingWith: .password("hunter2"))
        XCTAssertEqual(deleter.methods, [.password("hunter2")])
        XCTAssertEqual(viewModel.deletion, .deleted)
    }

    func testAppleOnlyAccountIsAskedToSignInAgain() async {
        let (viewModel, _) = makeViewModel(providers: ["apple.com"])
        await viewModel.confirmDeletion()
        XCTAssertEqual(viewModel.deletion, .reauthenticationUnsupported)
        XCTAssertTrue(deleter.methods.isEmpty)
    }

    func testFailedDeletionReturnsToIdleWithAnError() async {
        deleter.error = FakeError()
        let (viewModel, _) = makeViewModel()
        await viewModel.confirmDeletion()
        XCTAssertEqual(viewModel.deletion, .idle)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    // MARK: - Sign out

    func testSignOutGoesThroughAccountState() {
        let (viewModel, state) = makeViewModel()
        viewModel.signOut()
        XCTAssertFalse(state.isSignedIn)
    }
}

/// The nonce must differ per request and reach Apple only as a hash.
final class AppleSignInNonceTests: XCTestCase {
    func testNonceIsRandomPerCall() {
        let first = SignInViewModel.randomNonceString()
        let second = SignInViewModel.randomNonceString()
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, second)
    }

    func testSha256MatchesKnownVector() {
        XCTAssertEqual(SignInViewModel.sha256("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
