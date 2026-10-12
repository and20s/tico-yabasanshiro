import Foundation

enum DevicePinError: Error {
    case notConfigured
    case network
    case malformedResponse
}

/// Issues and revokes the PIN that lets another device sign in as this user.
///
/// The PIN is minted by an AWS Lambda, not by this app. What it carries is the
/// user's Google OAuth ID token: the other device fetches it and signs in with
/// GoogleAuthProvider. That is why only Google-provider accounts can issue a
/// PIN -- an Apple-only account has no Google token to hand over.
final class DevicePinService {
    struct Endpoints {
        let issueURL: URL
        let issueApiKey: String
        let revokeURL: URL
        let revokeApiKey: String

        /// Reads the endpoints from secrets.plist, which is not in git.
        static func fromSecrets() -> Endpoints? {
            guard let path = Bundle.main.path(forResource: "secrets", ofType: "plist"),
                  let dictionary = NSDictionary(contentsOfFile: path) as? [String: Any],
                  let issue = dictionary["pinIssueUrl"] as? String,
                  let issueURL = URL(string: issue),
                  let issueKey = dictionary["pinIssueApiKey"] as? String,
                  let revoke = dictionary["pinRevokeUrl"] as? String,
                  let revokeURL = URL(string: revoke),
                  let revokeKey = dictionary["pinRevokeApiKey"] as? String else {
                return nil
            }
            return Endpoints(issueURL: issueURL, issueApiKey: issueKey,
                             revokeURL: revokeURL, revokeApiKey: revokeKey)
        }
    }

    private let session: URLSession
    private let endpoints: Endpoints?

    init(session: URLSession = .shared,
         endpoints: Endpoints? = Endpoints.fromSecrets()) {
        self.session = session
        self.endpoints = endpoints
    }

    var isConfigured: Bool { endpoints != nil }

    /// Uploads the Google OAuth ID token and returns the PIN the server minted.
    func issuePin(googleIDToken: String) async throws -> String {
        guard let endpoints = endpoints else { throw DevicePinError.notConfigured }
        let data = try await post(url: endpoints.issueURL,
                                  apiKey: endpoints.issueApiKey,
                                  body: ["token": googleIDToken])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pin = json["pinin"] as? String, !pin.isEmpty else {
            throw DevicePinError.malformedResponse
        }
        return pin
    }

    /// Consumes the PIN so it can no longer be redeemed. The endpoint is the
    /// same one the other device uses, so revoking is just redeeming it here.
    func revokePin(_ pin: String) async throws {
        guard let endpoints = endpoints else { throw DevicePinError.notConfigured }
        // The response body is the raw token, which we discard.
        _ = try await post(url: endpoints.revokeURL,
                           apiKey: endpoints.revokeApiKey,
                           body: ["key": pin])
    }

    /// Revoking is best effort: leaving a stale PIN alive is bad, but failing
    /// to revoke is not worth an error in front of the user.
    func revokePinIgnoringErrors(_ pin: String) async {
        try? await revokePin(pin)
    }

    private func post(url: URL, apiKey: String, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DevicePinError.network
        }
        return data
    }
}
