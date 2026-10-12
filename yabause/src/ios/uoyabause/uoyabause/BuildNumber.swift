import Foundation

/// Reads CFBundleVersion strings as numbers.
///
/// The app decides who bought the paid app by comparing the build the user
/// first downloaded against the build that went free. Comparing those as text
/// would be wrong -- "9" sorts after "100000" -- so every comparison here goes
/// through integer components.
enum BuildNumber {
    /// The CFBundleVersion of the first release that ships free with
    /// subscriptions. Every build from here on must be at or above it.
    /// Kept in step with the Fastfile, which parses this line.
    static let freeBusinessModelStartBuild = 100000

    /// Whether the version predates the free business model.
    ///
    /// Nil when the string cannot be read as a CFBundleVersion. A nil must
    /// never be treated as "older": that would hand the legacy entitlement to
    /// anything the parser did not understand.
    static func isBeforeFreeBusinessModel(_ version: String) -> Bool? {
        guard let left = components(of: version) else { return nil }
        let right = [freeBusinessModelStartBuild]
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs < rhs }
        }
        return false
    }

    /// CFBundleVersion is dot separated digits. Anything else is rejected
    /// rather than coerced.
    private static func components(of version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            result.append(value)
        }
        return result
    }
}
