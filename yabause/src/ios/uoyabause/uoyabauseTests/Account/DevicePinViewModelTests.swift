import XCTest
@testable import YabaSnashiro

@MainActor
final class DevicePinViewModelTests: XCTestCase {
    private func makeViewModel(googleLinked: Bool = true,
                               signedIn: Bool = true,
                               token: String? = "google-token",
                               issue: @escaping (String) async throws -> String
                                 = { _ in "4821" },
                               revoke: @escaping (String) async -> Void = { _ in })
        -> DevicePinViewModel {
        let profile = signedIn
            ? AccountProfile(userId: "u", displayName: nil, email: nil, photoURL: nil,
                             providers: googleLinked ? ["google.com"] : ["apple.com"])
            : nil
        return DevicePinViewModel(
            accountState: AccountState(provider: FakeAuthProvider(profile: profile)),
            googleTokenProvider: { token },
            issuePin: issue,
            revokePin: revoke)
    }

    func testSignedOutReportsSignInRequired() {
        XCTAssertEqual(makeViewModel(signedIn: false).state, .signInRequired)
    }

    func testAppleOnlyAccountReportsGoogleRequired() {
        XCTAssertEqual(makeViewModel(googleLinked: false).state, .googleRequired)
    }

    func testGoogleAccountStartsIdle() {
        XCTAssertEqual(makeViewModel().state, .idle)
    }

    func testIssuingPublishesThePin() async {
        let viewModel = makeViewModel()
        await viewModel.issue()
        XCTAssertEqual(viewModel.state, .issued("4821"))
        XCTAssertNotNil(viewModel.expiresAt)
    }

    func testIssueFailureReportsAnError() async {
        struct Boom: Error {}
        let viewModel = makeViewModel(issue: { _ in throw Boom() })
        await viewModel.issue()
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testMissingGoogleTokenReportsAnError() async {
        let viewModel = makeViewModel(token: nil)
        await viewModel.issue()
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testDiscardRevokesAndClears() async {
        var revoked: [String] = []
        let viewModel = makeViewModel(issue: { _ in "1234" },
                                      revoke: { revoked.append($0) })
        await viewModel.issue()
        await viewModel.discard()
        XCTAssertEqual(revoked, ["1234"])
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testDiscardWithNoPinRevokesNothing() async {
        var revoked: [String] = []
        let viewModel = makeViewModel(revoke: { revoked.append($0) })
        await viewModel.discard()
        XCTAssertTrue(revoked.isEmpty)
    }

    func testRemainingSecondsCountsDown() async {
        let viewModel = makeViewModel()
        await viewModel.issue()
        XCTAssertGreaterThan(viewModel.remainingSeconds(at: Date()), 0)
        XCTAssertEqual(viewModel.remainingSeconds(at: Date().addingTimeInterval(9999)), 0)
    }
}
