import Foundation
import SwiftData

/// SwiftData record for a favorited repository.
///
/// Deliberately a *separate type* from `Repo`: persistence schema and domain
/// model evolve on different clocks (schema migrations vs API changes), so
/// they shouldn't be the same type even when the fields rhyme. `asRepo` and
/// `init(repo:)` are the two conversion seams.
@Model
final class FavoriteRepo {
    /// `.unique` makes SwiftData upsert on conflict — favoriting the same
    /// repo twice can never create duplicates.
    @Attribute(.unique) var repoID: Int
    var fullName: String
    var ownerLogin: String
    var summary: String?
    var stargazersCount: Int
    var forksCount: Int
    var language: String?
    var htmlURL: URL
    var savedAt: Date

    init(repo: Repo, savedAt: Date = .now) {
        self.repoID = repo.id
        self.fullName = repo.fullName
        self.ownerLogin = repo.ownerLogin
        self.summary = repo.summary
        self.stargazersCount = repo.stargazersCount
        self.forksCount = repo.forksCount
        self.language = repo.language
        self.htmlURL = repo.htmlURL
        self.savedAt = savedAt
    }
}

extension FavoriteRepo {
    var asRepo: Repo {
        Repo(
            id: repoID,
            fullName: fullName,
            ownerLogin: ownerLogin,
            summary: summary,
            stargazersCount: stargazersCount,
            forksCount: forksCount,
            language: language,
            htmlURL: htmlURL
        )
    }
}
