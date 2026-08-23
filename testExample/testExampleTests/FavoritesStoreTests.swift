import Foundation
import SwiftData
import Testing
@testable import testExample

/// SwiftData is fully testable without touching disk: an in-memory
/// `ModelContainer` per test gives hermetic, parallel-safe persistence tests.
@MainActor
@Suite("FavoritesStore")
struct FavoritesStoreTests {

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FavoriteRepo.self, configurations: configuration)
        return ModelContext(container)
    }

    private var sampleRepo: Repo {
        Repo(id: 99, fullName: "octo/sample", ownerLogin: "octo",
             summary: "Sample", stargazersCount: 10, forksCount: 2,
             language: "Swift", htmlURL: URL(string: "https://github.com/octo/sample")!)
    }

    private func repo(id: Int) -> Repo {
        Repo(id: id, fullName: "octo/sample-\(id)", ownerLogin: "octo",
             summary: nil, stargazersCount: id, forksCount: 0,
             language: nil, htmlURL: URL(string: "https://github.com/octo/sample-\(id)")!)
    }

    @Test("toggling an unknown repo favorites it")
    func toggleAdds() throws {
        let context = try makeContext()
        let store = FavoritesStore(context: context)

        try store.toggle(sampleRepo)

        // `try`, not `try?`: a fetch failure is a test failure, not a "no".
        // That distinction is the whole reason `isFavorite` throws now.
        #expect(try store.isFavorite(sampleRepo))
        #expect(try context.fetchCount(FetchDescriptor<FavoriteRepo>()) == 1)
    }

    @Test("toggling a favorited repo removes it")
    func toggleRemoves() throws {
        let context = try makeContext()
        let store = FavoritesStore(context: context)

        try store.toggle(sampleRepo)
        try store.toggle(sampleRepo)

        #expect(try !store.isFavorite(sampleRepo))
        #expect(try context.fetchCount(FetchDescriptor<FavoriteRepo>()) == 0)
    }

    @Test("favorites round-trip back into domain models")
    func favoriteRoundTrips() throws {
        let context = try makeContext()
        let store = FavoritesStore(context: context)
        let repo = sampleRepo

        try store.toggle(repo)
        let saved = try #require(try context.fetch(FetchDescriptor<FavoriteRepo>()).first)

        #expect(saved.asRepo == repo)
    }

    @Test("remove deletes the given favorite")
    func removeDeletes() throws {
        let context = try makeContext()
        let store = FavoritesStore(context: context)
        try store.toggle(sampleRepo)
        let saved = try #require(try context.fetch(FetchDescriptor<FavoriteRepo>()).first)

        try store.remove(saved)

        #expect(try context.fetchCount(FetchDescriptor<FavoriteRepo>()) == 0)
    }

    @Test("batch remove deletes every given favorite in one save")
    func batchRemoveDeletesAll() throws {
        let context = try makeContext()
        let store = FavoritesStore(context: context)
        for id in 1...4 {
            try store.toggle(repo(id: id))
        }
        let saved = try context.fetch(FetchDescriptor<FavoriteRepo>())
        #expect(saved.count == 4)

        // Three in one call — the shape `FavoritesView.delete(at:)` produces
        // when the user deletes a multi-row selection.
        try store.remove(saved.prefix(3))

        let remaining = try context.fetch(FetchDescriptor<FavoriteRepo>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.repoID == saved.last?.repoID)
        // `hasChanges` false confirms the single `save()` inside `remove`
        // actually committed all three deletions rather than leaving some
        // pending in the context.
        #expect(!context.hasChanges)
    }

    @Test("inserting two records with the same unique repoID collapses to one")
    func duplicateUniqueIDCollapses() throws {
        // Pins down what `@Attribute(.unique)` actually does here rather than
        // assuming it. The app never relies on this — `FavoritesStore`
        // fetches before it inserts (see `existingFavorite(for:)`) — but the
        // constraint is the safety net behind that logic, and a safety net
        // whose behaviour nobody has checked is just a comment.
        let context = try makeContext()
        context.insert(FavoriteRepo(repo: sampleRepo))
        context.insert(FavoriteRepo(repo: sampleRepo))
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<FavoriteRepo>()) == 1)
    }
}
