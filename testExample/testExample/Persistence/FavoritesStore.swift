import Foundation
import SwiftData

/// Thin repository over `ModelContext` for favorite mutations.
///
/// Views *read* favorites with `@Query` (live, animated updates for free) but
/// *write* through this type, so the write rules — dedup, save timing — live
/// in one unit-testable place instead of scattered across views.
struct FavoritesStore {
    let context: ModelContext

    func isFavorite(_ repo: Repo) -> Bool {
        ((try? existingFavorite(for: repo)) ?? nil) != nil
    }

    /// Favorite if absent, unfavorite if present.
    func toggle(_ repo: Repo) throws {
        if let existing = try existingFavorite(for: repo) {
            context.delete(existing)
        } else {
            context.insert(FavoriteRepo(repo: repo))
        }
        try context.save()
    }

    func remove(_ favorite: FavoriteRepo) throws {
        context.delete(favorite)
        try context.save()
    }

    private func existingFavorite(for repo: Repo) throws -> FavoriteRepo? {
        // #Predicate can't reference `repo.id` directly — capture the value.
        let id = repo.id
        var descriptor = FetchDescriptor<FavoriteRepo>(predicate: #Predicate { $0.repoID == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
