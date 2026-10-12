import Foundation

/// One Saturn save entry, built from the C YSBupSave struct.
/// Game title, product number and screenshot are filled in separately from
/// the metadata and screenshot stores, since the save itself does not carry
/// them (see BackupMetadataStore / BackupScreenshotStore).
struct BackupSave: Identifiable, Equatable {
    let filename: String
    let comment: String
    let language: Int
    let saveDate: Date?
    let dataSize: Int
    let blockSize: Int
    let file: BackupFile

    var gameTitle: String?
    var productNumber: String?
    var screenshotPath: String?

    var id: String { "\(file.fileKey)/\(filename)" }

    init(raw: YSBupSave, file: BackupFile) {
        self.filename = Self.decodeFixedString(of: raw.filename)
        self.comment = Self.decodeFixedString(of: raw.comment)
        self.language = Int(raw.language)
        self.dataSize = Int(raw.datasize)
        self.blockSize = Int(raw.blocksize)
        self.file = file
        self.saveDate = Self.decodeDate(raw: raw)
    }

    /// Saturn strings are fixed-size, NUL padded, and encoded in Shift-JIS.
    /// CP932 is used because the existing backup list code decodes with it.
    private static func decodeFixedString<T>(of tuple: T) -> String {
        var value = tuple
        let bytes: [UInt8] = withUnsafeBytes(of: &value) { buffer in
            Array(buffer.prefix(while: { $0 != 0 }))
        }
        let data = Data(bytes)
        return (String(data: data, encoding: .windowsCP932)
                ?? String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespaces)
    }

    /// The core stores the year as an offset from 1980.
    private static func decodeDate(raw: YSBupSave) -> Date? {
        guard raw.month >= 1, raw.month <= 12, raw.day >= 1, raw.day <= 31 else {
            return nil
        }
        var components = DateComponents()
        components.year = 1980 + Int(raw.year)
        components.month = Int(raw.month)
        components.day = Int(raw.day)
        components.hour = Int(raw.hour)
        components.minute = Int(raw.minute)
        return Calendar.current.date(from: components)
    }

    var displaySize: String {
        if dataSize < 1024 {
            return "\(dataSize) B"
        }
        if dataSize < 1024 * 1024 {
            return "\(dataSize / 1024) KB"
        }
        return "\(dataSize / (1024 * 1024)) MB"
    }
}
