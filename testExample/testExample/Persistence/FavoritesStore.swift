import Foundation
import SwiftData

/// Thin repository over `ModelContext` for favorite mutations.
///
/// Views *read* favorites with `@Query` (live, animated updates for free) but
/// *write* through this type, so the write rules — dedup, save timing — live
/// in one unit-testable place instead of scattered across views.
struct FavoritesStore {
    let context: ModelContext

    /// `throws` rather than swallowing with `try?`. The previous version read
    /// `(try? existingFavorite(for: repo)) != nil`, which conflated two
    /// genuinely different answers: "the fetch succeeded and found nothing"
    /// and "the fetch itself failed". Both came back as `false`, so a broken
    /// store looked exactly like an unfavorited repo. Propagating lets the
    /// caller tell them apart — and it was worse than a lost distinction:
    /// `try?` on `throws -> FavoriteRepo?` flattens to `FavoriteRepo?`, so a
    /// *successful fetch returning nil* also produced `nil`, making the
    /// comparison right only by accident.
    func isFavorite(_ repo: Repo) throws -> Bool {
        try existingFavorite(for: repo) != nil
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

    /// Deletes many favorites with a single `save()`.
    ///
    /// The unit of work is the user's action, not the row: deleting three
    /// rows in one swipe of the Edit UI is one undoable thing that either
    /// happens or doesn't. Saving per row would also fan out one change
    /// notification per row, rebuilding every `@Query` that many times.
    func remove(_ favorites: some Sequence<FavoriteRepo>) throws {
        for favorite in favorites {
            context.delete(favorite)
        }
        try context.save()
    }

    /// Single-item convenience. Delegates so there is exactly one delete-and-
    /// save path to reason about.
    func remove(_ favorite: FavoriteRepo) throws {
        try remove(CollectionOfOne(favorite))
    }

    private func existingFavorite(for repo: Repo) throws -> FavoriteRepo? {
        // #Predicate can't reference `repo.id` directly — capture the value.
        let id = repo.id
        var descriptor = FetchDescriptor<FavoriteRepo>(predicate: #Predicate { $0.repoID == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
