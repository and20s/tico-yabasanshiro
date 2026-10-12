import Foundation

enum CloudBackupPayloadError: Error {
    case empty
    case corruptEnvelope
}

/// Turns whatever is stored in Cloud Storage into raw save bytes.
///
/// Android stores the raw bytes. Older iOS builds stored a JSON envelope with
/// the bytes base64 encoded inside, so both shapes exist in the bucket.
enum CloudBackupPayload {
    static func saveBytes(from data: Data) throws -> Data {
        guard !data.isEmpty else { throw CloudBackupPayloadError.empty }

        guard let envelope = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              envelope["header"] != nil else {
            // Not our envelope: Android wrote the bytes directly.
            return data
        }

        guard let payload = envelope["data"] as? [String: Any],
              let content = payload["content"] as? String,
              let bytes = Data(base64Encoded: content), !bytes.isEmpty else {
            throw CloudBackupPayloadError.corruptEnvelope
        }
        return bytes
    }
}
