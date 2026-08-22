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

    @Test("toggling an unknown repo favorites it")
    func toggleAdds() throws {
        let context = try makeContext()
        let store = FavoritesStore(context: context)

        try store.toggle(sampleRepo)

        #expect(store.isFavorite(sampleRepo))
        #expect(try context.fetchCount(FetchDescriptor<FavoriteRepo>()) == 1)
    }

    @Test("toggling a favorited repo removes it")
    func toggleRemoves() throws {
        let context = try makeContext()
        let store = FavoritesStore(context: context)

        try store.toggle(sampleRepo)
        try store.toggle(sampleRepo)

        #expect(!store.isFavorite(sampleRepo))
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
}
