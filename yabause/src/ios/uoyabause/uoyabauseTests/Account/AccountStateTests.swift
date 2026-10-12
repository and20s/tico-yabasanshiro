import XCTest
@testable import YabaSnashiro

@MainActor
final class AccountStateTests: XCTestCase {
    func testSignedOutHasNoProfile() {
        let state = AccountState(provider: FakeAuthProvider(profile: nil))
        XCTAssertFalse(state.isSignedIn)
        XCTAssertNil(state.profile)
    }

    func testSignedInExposesTheProfile() {
        let profile = AccountProfile(userId: "u1", displayName: "Shinya",
                                     email: "a@example.com", photoURL: nil,
                                     providers: ["google.com"])
        let state = AccountState(provider: FakeAuthProvider(profile: profile))
        XCTAssertTrue(state.isSignedIn)
        XCTAssertEqual(state.profile?.displayName, "Shinya")
    }

    func testGoogleLinkedIsTrueOnlyForTheGoogleProvider() {
        let google = AccountProfile(userId: "u", displayName: nil, email: nil,
                                    photoURL: nil, providers: ["google.com"])
        let apple = AccountProfile(userId: "u", displayName: nil, email: nil,
                                   photoURL: nil, providers: ["apple.com"])
        XCTAssertTrue(AccountState(provider: FakeAuthProvider(profile: google)).isGoogleLinked)
        XCTAssertFalse(AccountState(provider: FakeAuthProvider(profile: apple)).isGoogleLinked)
    }

    func testProfileUpdatesWhenTheProviderReportsAChange() {
        let provider = FakeAuthProvider(profile: nil)
        let state = AccountState(provider: provider)
        XCTAssertFalse(state.isSignedIn)

        provider.emit(AccountProfile(userId: "u", displayName: "New", email: nil,
                                     photoURL: nil, providers: ["google.com"]))
        XCTAssertTrue(state.isSignedIn)
        XCTAssertEqual(state.profile?.displayName, "New")
    }

    func testSignOutClearsTheProfile() throws {
        let provider = FakeAuthProvider(
            profile: AccountProfile(userId: "u", displayName: nil, email: nil,
                                    photoURL: nil, providers: ["google.com"]))
        let state = AccountState(provider: provider)
        try state.signOut()
        XCTAssertFalse(state.isSignedIn)
    }
}

/// Stands in for Firebase Auth.
final class FakeAuthProvider: AccountAuthProviding {
    private var onChange: ((AccountProfile?) -> Void)?
    private var profile: AccountProfile?

    init(profile: AccountProfile?) { self.profile = profile }

    var currentProfile: AccountProfile? { profile }

    func observe(_ handler: @escaping (AccountProfile?) -> Void) {
        onChange = handler
    }

    func stopObserving() { onChange = nil }

    func signOut() throws { emit(nil) }

    func emit(_ profile: AccountProfile?) {
        self.profile = profile
        onChange?(profile)
    }
}
