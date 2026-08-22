import OSLog
import SwiftData
import SwiftUI

/// Favorites tab. Reads live via `@Query` — inserts and deletes made
/// anywhere in the app appear here, animated, with zero wiring. Writes go
/// through `FavoritesStore` so the rules stay in one tested place.
struct FavoritesView: View {
    @Query(sort: \FavoriteRepo.savedAt, order: .reverse)
    private var favorites: [FavoriteRepo]

    @Environment(\.modelContext) private var modelContext

    private static let logger = Logger(subsystem: "work.timmaher.testExample", category: "favorites")

    var body: some View {
        NavigationStack {
            Group {
                if favorites.isEmpty {
                    ContentUnavailableView(
                        "No favorites yet",
                        systemImage: "star",
                        description: Text("Repositories you favorite will appear here.")
                    )
                    .accessibilityIdentifier("favorites.emptyView")
                } else {
                    List {
                        ForEach(favorites) { favorite in
                            NavigationLink(value: favorite.asRepo) {
                                RepoRowView(repo: favorite.asRepo)
                            }
                            .accessibilityIdentifier("favorites.row.\(favorite.fullName)")
                        }
                        .onDelete(perform: delete)
                    }
                    .accessibilityIdentifier("favorites.list")
                }
            }
            .navigationTitle("Favorites")
            .navigationDestination(for: Repo.self) { repo in
                RepoDetailView(repo: repo)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let store = FavoritesStore(context: modelContext)
        for index in offsets {
            do {
                try store.remove(favorites[index])
            } catch {
                Self.logger.error("Failed to remove favorite: \(error)")
            }
        }
    }
}

#if DEBUG
#Preview {
    FavoritesView()
        .modelContainer(previewContainer)
}
#endif
