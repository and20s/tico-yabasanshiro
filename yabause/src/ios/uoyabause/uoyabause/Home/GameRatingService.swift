import Foundation
import FirebaseFirestore

/// Fetches the community average rating of a game from Firestore.
/// Ports the Android GameInfo.updateState() query:
/// games (product_number == X) -> games/{id}/summary/ratings.averageRating
final class GameRatingService {
    private let db = Firestore.firestore()

    /// Returns the average rating (0-5) or nil when unavailable.
    func fetchRating(productNumber: String) async -> Int? {
        guard !productNumber.isEmpty else { return nil }
        do {
            let documents = try await db.collection("games")
                .whereField("product_number", isEqualTo: productNumber)
                .getDocuments()
            guard let document = documents.documents.first else { return nil }
            let ratings = try await db.collection("games")
                .document(document.documentID)
                .collection("summary")
                .document("ratings")
                .getDocument()
            // Firestore decodes integer fields as Int64 (see LeaderBoardRepository.swift
            // "score" / "timestamp" fields), not Int, so read via Int64 and convert.
            if let average = ratings.get("averageRating") as? Int64 {
                return Int(average)
            }
            return ratings.get("averageRating") as? Int
        } catch {
            print("GameRatingService: fetch failed for \(productNumber): \(error)")
            return nil
        }
    }
}
