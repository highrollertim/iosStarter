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
    /// `.unique` is a *store-level constraint*: it tells SwiftData that no
    /// two rows may share a `repoID`, and the store enforces that at save
    /// time. It is a safety net, not this app's deduplication strategy.
    ///
    /// The dedup the app actually relies on is the fetch-then-branch in
    /// `FavoritesStore.existingFavorite(for:)` — we look the repo up and
    /// decide to insert or delete *before* touching the context, so the
    /// constraint is never the thing standing between the user and a
    /// duplicate. That ordering matters: leaning on the constraint would mean
    /// leaning on whatever conflict resolution the store happens to perform,
    /// which is a persistence-layer implementation detail rather than a
    /// documented API guarantee. See `FavoritesStoreTests` for a test that
    /// pins down what a same-`repoID` insert actually does here, precisely
    /// because it is behaviour worth observing rather than assuming.
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
