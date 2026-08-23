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

    var body: some View {
        NavigationStack {
            // Always the `List`, with the empty state as an *overlay* rather
            // than an `if/else` sibling. Swapping between two different view
            // types destroys the List and its rows' identity, so deleting the
            // last favorite popped the row out with no animation and the
            // empty state appeared with a jarring cut. Keeping one List for
            // the view's whole lifetime lets SwiftUI animate the final row
            // out while the overlay fades in.
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
            .overlay {
                if favorites.isEmpty {
                    ContentUnavailableView(
                        "No favorites yet",
                        systemImage: "star",
                        description: Text("Repositories you favorite will appear here.")
                    )
                    .accessibilityIdentifier("favorites.emptyView")
                }
            }
            .navigationTitle("Favorites")
            .toolbar {
                // Swipe-to-delete is a *gesture*, and a gesture is not an
                // affordance: it is invisible, and it is unreachable for
                // Switch Control and Voice Control users, who have no way to
                // express "swipe this row partway left". `EditButton` gives
                // the same operation a discoverable, focusable control.
                // (It also gives UI tests something to tap that doesn't
                // depend on synthesizing a swipe.)
                EditButton()
            }
            .navigationDestination(for: Repo.self) { repo in
                RepoDetailView(repo: repo)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        // One store call, therefore one `context.save()`. Saving once per
        // deleted row would emit a change notification per row — and `@Query`
        // would rebuild this list that many times — for what is, to the user,
        // a single action.
        let doomed = offsets.map { favorites[$0] }
        do {
            try FavoritesStore(context: modelContext).remove(doomed)
        } catch {
            Logger.favorites.error("Failed to remove favorites: \(error)")
        }
    }
}

#if DEBUG
#Preview {
    FavoritesView()
        .modelContainer(previewContainer)
}
#endif
