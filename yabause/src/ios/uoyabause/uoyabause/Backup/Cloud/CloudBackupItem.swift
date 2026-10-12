import Foundation

/// One save record under user-posts/{uid}/backup/{key} in the Realtime Database.
///
/// Two record shapes exist in the wild: Android writes camelCase keys
/// (filename, saveDate, dataSize, blockSize, downloadUrl, ...) while older iOS
/// builds wrote lowercase ones (savedate, datasize, blocksize, url). Reading
/// accepts both; writing emits the Android shape plus the legacy aliases, so
/// an older iOS build still lists what this app uploads.
struct CloudBackupItem: Identifiable, Equatable {
    let key: String
    let filename: String
    let comment: String
    let language: Int
    let saveDate: Date?
    let dataSize: Int
    let blockSize: Int
    let downloadURL: String
    let screenshotURL: String?
    let gameTitle: String?
    let productNumber: String?

    var id: String { key }

    init(key: String, filename: String, comment: String, language: Int,
         saveDate: Date?, dataSize: Int, blockSize: Int, downloadURL: String,
         screenshotURL: String? = nil, gameTitle: String? = nil,
         productNumber: String? = nil) {
        self.key = key
        self.filename = filename
        self.comment = comment
        self.language = language
        self.saveDate = saveDate
        self.dataSize = dataSize
        self.blockSize = blockSize
        self.downloadURL = downloadURL
        self.screenshotURL = screenshotURL
        self.gameTitle = gameTitle
        self.productNumber = productNumber
    }

    /// Builds an item from a Realtime Database snapshot value.
    /// Returns nil when the record carries no filename, which is the one field
    /// every shape has and without which the record cannot be restored.
    init?(key: String, dictionary: [String: Any]) {
        guard let filename = Self.string(dictionary["filename"]), !filename.isEmpty
        else { return nil }

        self.key = key
        self.filename = filename
        self.comment = Self.string(dictionary["comment"]) ?? ""
        self.language = Self.int(dictionary["language"]) ?? 0
        self.saveDate = Self.date(
            from: Self.string(dictionary["saveDate"])
                ?? Self.string(dictionary["savedate"]))
        self.dataSize = Self.int(dictionary["dataSize"])
            ?? Self.int(dictionary["datasize"]) ?? 0
        self.blockSize = Self.int(dictionary["blockSize"])
            ?? Self.int(dictionary["blocksize"]) ?? 0

        let downloadUrl = Self.nonEmpty(dictionary["downloadUrl"])
        self.downloadURL = downloadUrl ?? Self.nonEmpty(dictionary["url"]) ?? ""
        self.screenshotURL = Self.nonEmpty(dictionary["screenshotUrl"])
        self.gameTitle = Self.nonEmpty(dictionary["gameTitle"])
        self.productNumber = Self.nonEmpty(dictionary["productNumber"])
    }

    /// The record to write back, in the Android shape plus the legacy iOS
    /// aliases. url stays empty exactly as Android leaves it, so an older iOS
    /// build lists the record without trying to download a payload it cannot
    /// parse.
    ///
    /// uploadedAt is deliberately absent. Android declares it as a
    /// java.util.Date, and the Realtime Database mapper serializes a Date as a
    /// nested object rather than a number -- writing epoch millis there made
    /// getValue(CloudBackupMetadata) throw, so Android silently dropped every
    /// record iOS uploaded. Nothing on either platform reads the field.
    func dictionaryForUpload() -> [String: Any] {
        var dictionary: [String: Any] = [
            "filename": filename,
            "comment": comment,
            "language": language,
            "saveDate": formattedSaveDate,
            "dataSize": dataSize,
            "blockSize": blockSize,
            "downloadUrl": downloadURL,
            "url": "",
            // Legacy iOS aliases
            "savedate": formattedSaveDate,
            "datasize": dataSize,
            "blocksize": blockSize,
        ]
        if let screenshotURL, !screenshotURL.isEmpty {
            dictionary["screenshotUrl"] = screenshotURL
        }
        if let gameTitle, !gameTitle.isEmpty {
            dictionary["gameTitle"] = gameTitle
        }
        if let productNumber, !productNumber.isEmpty {
            dictionary["productNumber"] = productNumber
        }
        return dictionary
    }

    /// The save date in the format both apps write, empty when unknown.
    var formattedSaveDate: String {
        guard let saveDate else { return "" }
        return Self.uploadFormatter.string(from: saveDate)
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

    // MARK: - Value helpers

    private static let uploadFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    private static let dashFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// Firebase hands numbers back as NSNumber, so a plain Int cast fails.
    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// A string value, treating an empty one as absent.
    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Both separators appear in stored records.
    private static func date(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return uploadFormatter.date(from: text) ?? dashFormatter.date(from: text)
    }
}
