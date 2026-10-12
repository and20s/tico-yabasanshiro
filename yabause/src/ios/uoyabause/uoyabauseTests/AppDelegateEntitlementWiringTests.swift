import XCTest
@testable import YabaSnashiro

/// The entitlement wiring lives in the app delegate, which no unit test
/// exercises: nothing constructs a UIApplication here, so both calls could be
/// deleted and the whole suite would stay green. It happened once already --
/// recheck() shipped with no caller at all -- so the calls are asserted
/// against the source, the same way TabStateOwnershipTests asserts ownership.
final class AppDelegateEntitlementWiringTests: XCTestCase {
    private func appDelegateSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // uoyabauseTests
            .deletingLastPathComponent()   // uoyabause (project dir)
            .appendingPathComponent("uoyabause")
        return try String(contentsOf: root.appendingPathComponent("AppDelegate.swift"),
                          encoding: .utf8)
    }

    /// The live code of one method, so a call cannot satisfy the assertion by
    /// sitting somewhere else in the file. Everything from the signature to
    /// the start of the next method declaration, with commented-out lines
    /// dropped: commenting a call out disables it exactly as deleting it
    /// does, and this test exists to catch that.
    private func body(of signature: String, in text: String) throws -> String {
        guard let start = text.range(of: signature) else {
            throw XCTSkip("AppDelegate no longer declares \(signature)")
        }
        let rest = text[start.upperBound...]
        let nextDeclaration = ["\n    func ", "\n    private func "]
            .compactMap { rest.range(of: $0)?.lowerBound }
            .min()
        let region = nextDeclaration.map { String(rest[..<$0]) } ?? String(rest)
        return region
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Without this call PurchaseManager.start() is never reached, so no
    /// Transaction.updates listener is installed: renewals, refunds and
    /// purchases made on another device go unobserved for the whole session,
    /// and neither entitlement source is ever read at launch.
    func testLaunchStartsTheEntitlementStore() throws {
        let text = try appDelegateSource()
        let launch = try body(of: "func application(_ application: UIApplication, didFinishLaunchingWithOptions",
                              in: text)
        XCTAssertTrue(launch.contains("ProEntitlementStore.shared.start()"),
                      "didFinishLaunchingWithOptions must call ProEntitlementStore.shared.start(): "
                      + "it is what installs the Transaction.updates listener, so without it "
                      + "renewals, refunds and cross-device purchases are never observed.")
    }

    /// Without this call a launch that failed its legacy read with nothing
    /// cached leaves the entitlement undecided, and undecided keeps every
    /// gate permissive -- for the rest of the session, because nothing else
    /// re-queries StoreKit until the app is relaunched.
    func testBecomingActiveRechecksTheEntitlement() throws {
        let text = try appDelegateSource()
        let active = try body(of: "func applicationDidBecomeActive", in: text)
        XCTAssertTrue(active.contains("ProEntitlementStore.shared.recheck()"),
                      "applicationDidBecomeActive must call ProEntitlementStore.shared.recheck(): "
                      + "a session whose legacy check failed at launch stays undecided, and "
                      + "undecided leaves every gate open until the app is relaunched.")
    }
}
