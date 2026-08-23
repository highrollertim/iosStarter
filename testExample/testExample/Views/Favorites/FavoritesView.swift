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
            // than an `if/else` sibling. Swapping between two view types
            // destroys the List and its rows' identity, and a view with no
            // identity cannot animate: the last row would cut rather than
            // slide out. One List for the view's whole lifetime lets SwiftUI
            // animate the final row away while the overlay fades in.
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
                    // The overlay is informational; it must never intercept a
                    // tap aimed at a row that is still animating out beneath it.
                    .allowsHitTesting(false)
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
                // depend on synthesizing a swipe.) Hidden while the list is
                // empty: an enabled Edit button over nothing to edit is a
                // control with no possible effect.
                if !favorites.isEmpty {
                    EditButton()
                }
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
#Preview(traits: .sampleData) {
    FavoritesView()
}
#endif
