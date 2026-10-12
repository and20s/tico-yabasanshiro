import XCTest
@testable import YabaSnashiro

final class BuildNumberTests: XCTestCase {
    func testTheBoundaryIsTheNumberTheFirstFreeReleaseShips() {
        XCTAssertEqual(BuildNumber.freeBusinessModelStartBuild, 100000)
    }

    /// Every build the paid app ever shipped was a plain integer below 100.
    func testEveryShippedPaidBuildIsBeforeTheBoundary() {
        for version in ["1", "2", "3", "48", "57", "61", "70"] {
            XCTAssertEqual(BuildNumber.isBeforeFreeBusinessModel(version), true,
                           "\(version) should count as a paid-era build")
        }
    }

    /// What the sandbox reports. It is below the boundary numerically, which
    /// is why the caller must look at the environment before trusting it.
    func testTheSandboxValueIsBeforeTheBoundary() {
        XCTAssertEqual(BuildNumber.isBeforeFreeBusinessModel("1.0"), true)
    }

    func testTheBoundaryItselfIsNotBefore() {
        XCTAssertEqual(BuildNumber.isBeforeFreeBusinessModel("100000"), false)
    }

    func testBuildsAfterTheBoundaryAreNotBefore() {
        for version in ["100001", "100002", "999999"] {
            XCTAssertEqual(BuildNumber.isBeforeFreeBusinessModel(version), false)
        }
    }

    /// A dotted build number is compared component by component, not as text.
    /// "9" is greater than "1" as a number but smaller as a string.
    func testDottedVersionsCompareNumerically() {
        XCTAssertEqual(BuildNumber.isBeforeFreeBusinessModel("1.2.3"), true)
        XCTAssertEqual(BuildNumber.isBeforeFreeBusinessModel("100000.1"), false)
        XCTAssertEqual(BuildNumber.isBeforeFreeBusinessModel("99999.9.9"), true)
    }

    /// Anything that is not a CFBundleVersion must not be read as "older",
    /// which would hand out the legacy entitlement on garbage input.
    func testUnreadableVersionsAreUndecided() {
        for version in ["", "1.0b", "1..0", "abc", "-1", "1.0.0.0.x"] {
            XCTAssertNil(BuildNumber.isBeforeFreeBusinessModel(version),
                         "\(version) should be undecidable")
        }
    }
}
