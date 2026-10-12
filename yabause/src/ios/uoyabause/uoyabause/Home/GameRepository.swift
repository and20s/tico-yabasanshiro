import Foundation

enum GameRepositoryError: Error {
    case unsupportedFileType
    case copyFailed(underlying: Error)
    case accessDenied
}

/// Scans a directory tree for Saturn disc images and maintains the
/// persistent game list. Extracted from the legacy FileSelectController /
/// MainScreenController so it can be unit tested and shared by SwiftUI.
final class GameRepository {
    /// File extensions accepted by the document picker import.
    static let importableExtensions: Set<String> =
        ["bin", "cue", "chd", "ccd", "img", "mds", "mdf"]

    private let rootDirectory: URL
    private let cache: GameListCache

    init(rootDirectory: URL? = nil, cache: GameListCache = GameListCache()) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.cache = cache
    }

    // MARK: - Scan

    /// Returns the last scan result immediately (may be stale).
    func cachedItems() -> [GameItem] { cache.load() }

    /// Rescans the directory tree. Cached online metadata is merged onto
    /// freshly scanned entries, and the result is persisted.
    func rescan() -> [GameItem] {
        let cachedByPath = Dictionary(
            cache.load().map { ($0.filePath, $0) },
            uniquingKeysWith: { first, _ in first })

        let now = Date()
        var items: [GameItem] = []
        for path in allFilesRecursively(at: rootDirectory.path) {
            guard let gameInfo = scanFile(at: path) else { continue }
            let cached = cachedByPath[path]
            var item = GameItem(gameInfo: gameInfo).merging(cached: cached)
            if item.addedAt == nil {
                // Already known but from a cache written before arrival times
                // existed: every such entry gets the same one, and
                // FreeGameSlots orders them by path. Stamping them with `now`
                // instead would rank them by the order the disk was walked in,
                // which is not stable across launches. A file the cache has
                // never seen is new, so it arrives now and cannot take a free
                // slot from a game that was already there.
                item.addedAt = cached == nil ? now : .distantPast
            }
            items.append(item)
        }
        cache.save(items)
        return items
    }

    /// Persist updated items (e.g. after rating / RA progress fetch).
    func persist(_ items: [GameItem]) {
        cache.save(items)
    }

    private func scanFile(at path: String) -> GameInfo? {
        do {
            if path.hasSuffix(".chd") {
                if let buf = getGameinfoFromChd(path) {
                    let data = Data(bytes: buf, count: 256)
                    return getGameInfoFromBuf(filePath: path, header: data)
                }
                return nil
            }
            if path.hasSuffix(".cue") { return try genGameInfoFromCUE(filePath: path) }
            if path.hasSuffix(".ccd") { return try genGameInfoFromCCD(filePath: path) }
            if path.hasSuffix(".mds") { return try genGameInfoFromMDS(filePath: path) }
        } catch {
            // Broken image: skip this file, keep scanning (spec 7.1)
            print("GameRepository: skipping \(path): \(error)")
        }
        return nil
    }

    private func allFilesRecursively(at path: String) -> [String] {
        let manager = FileManager.default
        var results: [String] = []
        guard let contents = try? manager.contentsOfDirectory(atPath: path) else { return results }
        for item in contents {
            let fullPath = (path as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard manager.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                results.append(contentsOf: allFilesRecursively(at: fullPath))
            } else {
                results.append(fullPath)
            }
        }
        return results
    }

    // MARK: - Import (from document picker)

    /// Copies a picked file into the library root, replacing any existing
    /// file of the same name. Handles security-scoped URLs.
    func importFile(from url: URL) throws {
        let ext = url.pathExtension.lowercased()
        guard GameRepository.importableExtensions.contains(ext) else {
            throw GameRepositoryError.unsupportedFileType
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let destination = rootDirectory.appendingPathComponent(url.lastPathComponent)
        guard destination != url else { return }
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: url, to: destination)
        } catch {
            throw GameRepositoryError.copyFailed(underlying: error)
        }
    }

    // MARK: - Delete

    /// Deletes the game file and its referenced data files, then rescans.
    func delete(item: GameItem) {
        let manager = FileManager.default
        let url = URL(fileURLWithPath: item.filePath)
        for target in referencedFiles(of: url) + [url] {
            try? manager.removeItem(at: target)
        }
        _ = rescan()
    }

    /// Data files referenced by a descriptor file (cue/ccd/mds).
    private func referencedFiles(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        switch url.pathExtension.lowercased() {
        case "cue":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            var files: [URL] = []
            for line in text.split(separator: "\n") {
                if let range = line.range(of: "FILE \"(.*)\"", options: .regularExpression) {
                    let name = String(line[range])
                        .replacingOccurrences(of: "FILE \"", with: "")
                        .replacingOccurrences(of: "\"", with: "")
                    files.append(dir.appendingPathComponent(name))
                }
            }
            return files
        case "ccd":
            return [url.deletingPathExtension().appendingPathExtension("img"),
                    url.deletingPathExtension().appendingPathExtension("sub")]
        case "mds":
            return [url.deletingPathExtension().appendingPathExtension("mdf")]
        default:
            return []
        }
    }

    // MARK: - Lite version limit

    /// True when the free version game-count limit is exceeded.
    ///
    /// Runtime rather than #if: the limit is one of the things a subscription
    /// lifts, and a compile-time check cannot be told about a purchase.
    static func isOverFreeLimit(count: Int,
                                entitlement: ProEntitlement = ProEntitlement()) -> Bool {
        guard !entitlement.allowsAction else { return false }
        return count >= ProEntitlement.freeGameLimit
    }
}
