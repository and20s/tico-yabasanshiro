import Foundation

/// Builds and parses the links that point at one shared save.
///
/// Ported from Android's `BackupShareLink`, string for string: the same link
/// has to open in either app, and the web pages that carry it are written
/// against this shape.
///
/// - https://www.yabasanshiro.com/backup/{id}  (Universal Link / App Link)
/// - yabasanshiro://backup/{id}                (custom scheme fallback)
enum BackupShareLink {
    private static let host = "www.yabasanshiro.com"
    private static let path = "backup"

    /// Attached to every shared-save post so they can be searched together.
    private static let fixedTags = "#yabasave #SegaSaturn"

    /// Ids are UUIDs. Anything else is refused before the id reaches a
    /// document lookup or a Storage path, so a crafted link cannot walk out
    /// of the collection it is supposed to address.
    private static let maxIdLength = 128

    static func buildURL(id: String) -> URL {
        URL(string: "https://\(host)/\(path)/\(id)")!
    }

    /// The backup id in an https or custom-scheme link, or nil if the string
    /// is not one of ours.
    static func id(from uri: String) -> String? {
        let withoutQuery = uri.prefix { $0 != "?" && $0 != "#" }
        let httpsPrefix = "https://\(host)/\(path)/"
        let schemePrefix = "yabasanshiro://\(path)/"

        // Scheme and host are case-insensitive, and a pasted link may carry
        // either case. The id itself is not folded: it addresses a document.
        let rest: Substring
        if let head = withoutQuery.prefixMatching(httpsPrefix) {
            rest = withoutQuery.dropFirst(head)
        } else if let head = withoutQuery.prefixMatching(schemePrefix) {
            rest = withoutQuery.dropFirst(head)
        } else {
            return nil
        }

        // A trailing slash is common in pasted links; anything after it is a
        // deeper path this app does not serve.
        let id = String(rest.drop(while: { $0 == "/" }).prefix { $0 != "/" })
        return isValid(id: id) ? id : nil
    }

    static func id(from url: URL) -> String? {
        id(from: url.absoluteString)
    }

    private static func isValid(id: String) -> Bool {
        guard !id.isEmpty, id.count <= maxIdLength else { return false }
        return id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }

    /// The hashtag line for a shared-save post.
    ///
    /// Punctuation and spaces are dropped because a hashtag cannot hold them;
    /// letters and digits stay, Japanese included. A blank title yields only
    /// the fixed tags.
    static func hashtags(gameTitle: String) -> String {
        let game = gameTitle.filter { $0.isLetter || $0.isNumber }
        return game.isEmpty ? fixedTags : "\(fixedTags) #\(game)"
    }
}

private extension Substring {
    /// The prefix's length when this starts with it, ignoring case; nil
    /// otherwise. Length rather than Bool so the caller can drop it.
    func prefixMatching(_ prefix: String) -> Int? {
        guard count >= prefix.count else { return nil }
        return self.prefix(prefix.count).lowercased() == prefix.lowercased()
            ? prefix.count : nil
    }
}
