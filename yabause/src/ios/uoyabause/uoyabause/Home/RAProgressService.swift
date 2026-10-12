import Foundation

/// Fetches RetroAchievements progress for library games without launching
/// them. Ports the Android RetroAchievementsManager web API access:
/// - resolveGame:          dorequest.php r=achievementsets (gameId + total)
/// - fetchAllUserProgress: dorequest.php r=allprogress c=39 (unlock counts)
///
/// The native bridge functions (YabauseRA_GenerateGameHash /
/// YabauseRA_GetUserApiToken) come from YabaInterface.h through the
/// Objective-C bridging header.
final class RAProgressService {
    private static let endpoint = URL(string: "https://retroachievements.org/dorequest.php")!
    private static let userAgent = "YabaSanshiro/1.20"

    private let session: URLSession
    private let hashGenerator: (String) -> String?

    init(session: URLSession = .shared,
         hashGenerator: @escaping (String) -> String? = RAProgressService.nativeHash) {
        self.session = session
        self.hashGenerator = hashGenerator
    }

    // MARK: - Credentials

    /// Session token from the native rc_client, or nil when not logged in.
    static func currentToken() -> String? {
        guard let cString = YabauseRA_GetUserApiToken() else { return nil }
        let token = String(cString: cString)
        return token.isEmpty ? nil : token
    }

    /// Generate the RA hash via the native bridge (blocking; call off-main).
    static func nativeHash(for path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 33)
        let ok = path.withCString { cPath in
            YabauseRA_GenerateGameHash(cPath, &buffer, 33)
        }
        guard ok == 1 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Web API

    /// Resolve RA game id and total achievement count from a game hash.
    func resolveGame(hash: String, username: String, token: String) async
        -> (gameId: Int, total: Int)? {
        guard hash.count == 32, hash.range(of: "^[a-fA-F0-9]{32}$",
                                           options: .regularExpression) != nil else {
            return nil
        }
        guard let json = await post(body: "r=achievementsets&u=\(username)&t=\(token)&m=\(hash)"),
              json["Success"] as? Bool == true,
              let gameId = json["GameId"] as? Int, gameId > 0 else {
            return nil
        }
        var total = 0
        if let sets = json["Sets"] as? [[String: Any]] {
            for set in sets {
                total += (set["Achievements"] as? [Any])?.count ?? 0
            }
        }
        return (gameId, total)
    }

    /// Unlock counts for all Saturn games of the user (console id 39).
    func fetchAllUserProgress(username: String, token: String) async
        -> [Int: (unlocked: Int, hardcore: Int)]? {
        guard let json = await post(body: "r=allprogress&u=\(username)&t=\(token)&c=39"),
              json["Success"] as? Bool == true,
              let response = json["Response"] as? [String: [String: Any]] else {
            return nil
        }
        var map: [Int: (unlocked: Int, hardcore: Int)] = [:]
        for (key, value) in response {
            guard let gameId = Int(key) else { continue }
            map[gameId] = (value["Unlocked"] as? Int ?? 0,
                           value["UnlockedHardcore"] as? Int ?? 0)
        }
        return map
    }

    // MARK: - Orchestration

    /// Fill RA progress for all items that have no cached data yet, then
    /// apply the user's unlock counts. Games not in the RA database are
    /// marked raNotSupported so they are not retried every launch.
    func updateProgress(items: [GameItem], username: String, token: String) async -> [GameItem] {
        var updated = items
        for index in updated.indices {
            var item = updated[index]
            guard !item.raNotSupported else { continue }
            if item.raHash == nil {
                item.raHash = hashGenerator(item.filePath)
            }
            guard let hash = item.raHash else {
                item.raNotSupported = true
                updated[index] = item
                continue
            }
            if item.raGameId == 0 {
                if let resolved = await resolveGame(hash: hash, username: username, token: token) {
                    item.raGameId = resolved.gameId
                    item.raTotal = resolved.total
                } else {
                    item.raNotSupported = true
                }
            }
            updated[index] = item
        }

        if let progress = await fetchAllUserProgress(username: username, token: token) {
            for index in updated.indices where updated[index].raGameId > 0 {
                if let entry = progress[updated[index].raGameId] {
                    updated[index].raUnlocked = entry.unlocked
                    updated[index].raUnlockedHardcore = entry.hardcore
                }
            }
        }
        return updated
    }

    // MARK: - Transport

    private func post(body: String) async -> [String: Any]? {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            print("RAProgressService: request failed: \(error)")
            return nil
        }
    }
}
