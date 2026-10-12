import XCTest
@testable import YabaSnashiro

/// The link format is shared with Android and with the web, so these assert
/// the exact strings rather than a round trip through our own builder.
final class BackupShareLinkTests: XCTestCase {
    func testBuildsTheSameURLAndroidBuilds() {
        XCTAssertEqual(BackupShareLink.buildURL(id: "abc").absoluteString,
                       "https://www.yabasanshiro.com/backup/abc")
    }

    func testParsesBothTheHTTPSLinkAndTheCustomScheme() {
        XCTAssertEqual(BackupShareLink.id(from: "https://www.yabasanshiro.com/backup/abc"),
                       "abc")
        XCTAssertEqual(BackupShareLink.id(from: "yabasanshiro://backup/abc"), "abc")
    }

    /// Shared links get pasted with tracking parameters and fragments on them.
    func testIgnoresQueryFragmentAndTrailingSlash() {
        XCTAssertEqual(
            BackupShareLink.id(from: "https://www.yabasanshiro.com/backup/abc/?utm=x#top"),
            "abc")
        XCTAssertEqual(BackupShareLink.id(from: "yabasanshiro://backup/abc/"), "abc")
    }

    /// Scheme and host are case-insensitive, and a pasted link may carry
    /// either case.
    func testTheHostIsMatchedRegardlessOfCase() {
        XCTAssertEqual(BackupShareLink.id(from: "https://WWW.YabaSanshiro.com/backup/abc"),
                       "abc")
        XCTAssertEqual(BackupShareLink.id(from: "YabaSanshiro://backup/abc"), "abc")
    }

    /// The id addresses a document, so it is not folded with the host.
    func testTheIdKeepsItsCase() {
        XCTAssertEqual(BackupShareLink.id(from: "https://www.yabasanshiro.com/backup/AbC"),
                       "AbC")
    }

    func testRejectsAnythingThatIsNotABackupLink() {
        XCTAssertNil(BackupShareLink.id(from: "https://www.yabasanshiro.com/game/abc"))
        XCTAssertNil(BackupShareLink.id(from: "https://example.com/backup/abc"))
        XCTAssertNil(BackupShareLink.id(from: "yabasanshiro://discord/callback"))
        XCTAssertNil(BackupShareLink.id(from: "not a url"))
    }

    /// The id goes into a Storage path and a document lookup, so a crafted
    /// link must not be able to walk out of the collection.
    func testRejectsAMalformedId() {
        XCTAssertNil(BackupShareLink.id(from: "https://www.yabasanshiro.com/backup/"))
        XCTAssertNil(BackupShareLink.id(from: "yabasanshiro://backup/a b"))
        XCTAssertNil(BackupShareLink.id(from: "yabasanshiro://backup/"
                                        + String(repeating: "a", count: 129)))
    }

    /// Android strips punctuation because a hashtag cannot contain it, and
    /// keeps Japanese, which is letters as far as the check goes.
    func testHashtagsMatchAndroid() {
        XCTAssertEqual(BackupShareLink.hashtags(gameTitle: "NiGHTS into Dreams"),
                       "#yabasave #SegaSaturn #NiGHTSintoDreams")
        XCTAssertEqual(BackupShareLink.hashtags(gameTitle: "サクラ大戦"),
                       "#yabasave #SegaSaturn #サクラ大戦")
        XCTAssertEqual(BackupShareLink.hashtags(gameTitle: "  "),
                       "#yabasave #SegaSaturn")
    }
}
