import XCTest
@testable import YabaSnashiro

private final class FakeAppTransaction: AppTransactionProviding {
    enum Outcome {
        case verified(AppTransactionInfo)
        case unverified
        case failure
    }

    struct TransientError: Error {}

    var outcome: Outcome
    private(set) var callCount = 0

    /// Answered in turn, one per call, so a test can make the provider fail
    /// twice and then succeed. Once exhausted, `outcome` answers forever.
    private var queued: [Outcome]

    init(_ outcome: Outcome) {
        self.outcome = outcome
        self.queued = []
    }

    init(sequence: [Outcome]) {
        self.outcome = sequence.last ?? .failure
        self.queued = sequence
    }

    func appTransaction() async throws -> AppTransactionInfo? {
        callCount += 1
        let answer = queued.isEmpty ? outcome : queued.removeFirst()
        switch answer {
        case .verified(let info): return info
        case .unverified: return nil
        case .failure: throw TransientError()
        }
    }
}

private final class FakeEvidence: LegacyEvidenceStoring {
    var stored: AppTransactionInfo?
    private(set) var saveCount = 0

    init(stored: AppTransactionInfo? = nil) { self.stored = stored }

    func load() -> AppTransactionInfo? { stored }

    func save(_ info: AppTransactionInfo) {
        stored = info
        saveCount += 1
    }
}

@MainActor
final class LegacyPurchaseTests: XCTestCase {
    private func paidEra(_ version: String = "61") -> AppTransactionInfo {
        AppTransactionInfo(originalAppVersion: version, isProduction: true)
    }

    private func freeEra(_ version: String = "100000") -> AppTransactionInfo {
        AppTransactionInfo(originalAppVersion: version, isProduction: true)
    }

    /// Case 1: the user bought the paid app and is updating into the free
    /// build.
    func testAProductionBuildFromThePaidEraIsLegacy() async {
        let subject = LegacyPurchase(provider: FakeAppTransaction(.verified(paidEra())),
                                     evidence: FakeEvidence())
        await subject.refresh()
        XCTAssertEqual(subject.status, .legacyPaid)
    }

    /// Case 2: deleted and reinstalled, so there is nothing cached. The
    /// entitlement has to come back from StoreKit alone.
    func testLegacyIsRecoveredWithNothingCached() async {
        let evidence = FakeEvidence(stored: nil)
        let subject = LegacyPurchase(provider: FakeAppTransaction(.verified(paidEra())),
                                     evidence: evidence)
        await subject.refresh()
        XCTAssertEqual(subject.status, .legacyPaid)
        XCTAssertEqual(evidence.saveCount, 1)
    }

    /// Case 3: first downloaded after the app went free.
    func testAProductionBuildFromTheFreeEraIsNotLegacy() async {
        let subject = LegacyPurchase(provider: FakeAppTransaction(.verified(freeEra())),
                                     evidence: FakeEvidence())
        await subject.refresh()
        XCTAssertEqual(subject.status, .notLegacy)
    }

    /// Case 7: a temporary failure must not revoke what Apple already
    /// confirmed.
    func testATransientFailureKeepsTheCachedEntitlement() async {
        let evidence = FakeEvidence(stored: paidEra())
        let subject = LegacyPurchase(provider: FakeAppTransaction(.failure),
                                     evidence: evidence,
                                     retryDelay: Self.testDelay)
        await subject.refresh()
        XCTAssertEqual(subject.status, .legacyPaid)
    }

    /// With nothing cached there is no answer yet -- which is not the same as
    /// "not entitled", and the gates treat it differently.
    func testATransientFailureWithNoCacheIsUndecided() async {
        let subject = LegacyPurchase(provider: FakeAppTransaction(.failure),
                                     evidence: FakeEvidence(),
                                     retryDelay: Self.testDelay)
        await subject.refresh()
        XCTAssertEqual(subject.status, .unknown)
    }

    // MARK: - Retrying a failure that has no cache to fall back on

    /// Short enough that three attempts cost the suite nothing.
    private static let testDelay: TimeInterval = 0.001

    /// Finding 1: settling on unknown after one failed call leaves every gate
    /// permissive for the whole session, because nothing else re-queries
    /// StoreKit. Two failures followed by a success must end in the success.
    func testAFailureWithNoCacheIsRetriedUntilAnAnswerLands() async {
        let provider = FakeAppTransaction(sequence: [.failure, .failure,
                                                     .verified(paidEra())])
        let subject = LegacyPurchase(provider: provider,
                                     evidence: FakeEvidence(),
                                     retryDelay: Self.testDelay)
        await subject.refresh()
        XCTAssertEqual(provider.callCount, 3, "the third attempt was never made")
        XCTAssertEqual(subject.status, .legacyPaid,
                       "the third attempt's answer is the one that lands")
    }

    /// The retry is bounded: a device that is simply offline must not spin.
    func testTheRetryGivesUpAfterThreeAttempts() async {
        let provider = FakeAppTransaction(.failure)
        let subject = LegacyPurchase(provider: provider,
                                     evidence: FakeEvidence(),
                                     retryDelay: Self.testDelay)
        await subject.refresh()
        XCTAssertEqual(provider.callCount, 3)
        XCTAssertEqual(subject.status, .unknown)
    }

    /// With cached evidence there is nothing to wait for: the answer is
    /// already known, so the failure resolves from the cache on the spot.
    func testAFailureWithCachedEvidenceIsNotRetried() async {
        let provider = FakeAppTransaction(.failure)
        let subject = LegacyPurchase(provider: provider,
                                     evidence: FakeEvidence(stored: paidEra()),
                                     retryDelay: Self.testDelay)
        await subject.refresh()
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(subject.status, .legacyPaid)
    }

    /// Case 8: an unverified transaction grants nothing and is never cached.
    func testAnUnverifiedTransactionGrantsNothing() async {
        let evidence = FakeEvidence()
        let subject = LegacyPurchase(provider: FakeAppTransaction(.unverified),
                                     evidence: evidence)
        await subject.refresh()
        XCTAssertEqual(subject.status, .notLegacy)
        XCTAssertEqual(evidence.saveCount, 0)
    }

    /// A device that changed Apple ID must not keep resolving from the old
    /// evidence, so a fresh verified answer always wins.
    func testAFreshAnswerOverwritesTheCache() async {
        let evidence = FakeEvidence(stored: paidEra())
        let subject = LegacyPurchase(provider: FakeAppTransaction(.verified(freeEra())),
                                     evidence: evidence)
        await subject.refresh()
        XCTAssertEqual(subject.status, .notLegacy)
        XCTAssertEqual(evidence.stored, freeEra())
    }

    /// The sandbox reports 1.0 for everyone. Believing it would make every
    /// TestFlight tester a legacy user and leave the free path untestable.
    func testANonProductionEnvironmentIsNotTrusted() async {
        let sandbox = AppTransactionInfo(originalAppVersion: "1.0", isProduction: false)
        let evidence = FakeEvidence()
        let subject = LegacyPurchase(provider: FakeAppTransaction(.verified(sandbox)),
                                     evidence: evidence)
        await subject.refresh()
        XCTAssertEqual(subject.status, .notLegacy)
        XCTAssertEqual(evidence.saveCount, 0,
                       "a sandbox answer must never be cached as evidence")
    }

    /// Finding 1: a persistent unverified answer (clock skew, corrupted
    /// receipt) must not cost a paying customer their entitlement for the
    /// session -- it falls back to the cache exactly like a transient
    /// failure.
    func testAnUnverifiedAnswerFallsBackToTheCachedEntitlement() async {
        let evidence = FakeEvidence(stored: paidEra())
        let subject = LegacyPurchase(provider: FakeAppTransaction(.unverified),
                                     evidence: evidence)
        await subject.refresh()
        XCTAssertEqual(subject.status, .legacyPaid)
        XCTAssertEqual(evidence.saveCount, 0)
    }

    /// Mirror of the above: an unverified answer with nothing cached grants
    /// nothing.
    func testAnUnverifiedAnswerWithNoCacheIsNotLegacy() async {
        let evidence = FakeEvidence()
        let subject = LegacyPurchase(provider: FakeAppTransaction(.unverified),
                                     evidence: evidence)
        await subject.refresh()
        XCTAssertEqual(subject.status, .notLegacy)
        XCTAssertEqual(evidence.saveCount, 0)
    }

    /// The decision "an unparseable version becomes notLegacy, never
    /// legacyPaid" lives in LegacyPurchase, not in the parser: it is the
    /// guard against granting Pro to a non-payer when the version string
    /// cannot be read.
    func testAnUnparseableVersionIsNotLegacy() async {
        let unparseable = AppTransactionInfo(originalAppVersion: "1.0b", isProduction: true)
        let subject = LegacyPurchase(provider: FakeAppTransaction(.verified(unparseable)),
                                     evidence: FakeEvidence())
        await subject.refresh()
        XCTAssertEqual(subject.status, .notLegacy)
    }

    /// The cache is what makes the entitlement survive a cold launch with no
    /// network, so it has to be read before anyone asks StoreKit.
    func testTheCachedAnswerIsAvailableBeforeAnyRefresh() {
        let provider = FakeAppTransaction(.failure)
        let subject = LegacyPurchase(provider: provider,
                                     evidence: FakeEvidence(stored: paidEra()))
        XCTAssertEqual(subject.status, .legacyPaid)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testWithNothingCachedTheStatusStartsUndecided() {
        let subject = LegacyPurchase(provider: FakeAppTransaction(.failure),
                                     evidence: FakeEvidence())
        XCTAssertEqual(subject.status, .unknown)
    }
}
