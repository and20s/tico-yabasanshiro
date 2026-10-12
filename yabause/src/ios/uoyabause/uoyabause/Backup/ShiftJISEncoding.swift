import Foundation

extension String.Encoding {
    /// CP932 (Microsoft's Shift-JIS superset), the encoding the Saturn uses
    /// for save names and comments.
    static let windowsCP932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
}
