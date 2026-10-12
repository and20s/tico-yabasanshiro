import Foundation

/// The product identifiers, which must match App Store Connect exactly.
///
/// The only place in the app where a product id is written down. A mismatch
/// here means Product.products(for:) returns nothing and the gate has no
/// offers to show.
enum ProProducts {
#if FREE_VERSION
    /// Lite keeps its historical identifier. The name says three months for
    /// historical reasons; the product is annual. The app is being retired
    /// and no App Store Connect work is planned for it.
    static let annual = "full_function_3mo"
    static let lifetime: String? = nil
#else
    static let annual = "pro.annual"
    static let lifetime: String? = "pro.lifetime"
#endif

    static var all: [String] { [annual, lifetime].compactMap { $0 } }
}
