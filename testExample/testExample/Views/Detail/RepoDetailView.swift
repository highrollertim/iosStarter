import OSLog
import SwiftData
import SwiftUI

/// Repository detail. Deliberately has **no view model**: there is no async
/// orchestration here — favorite state comes live from SwiftData via a
/// parameterized `@Query`, and the only action is a one-line store call.
/// A view model would be ceremony. (Contrast with `SearchView`, where the
/// pipeline earns one.)
struct RepoDetailView: View {
    let repo: Repo

    @Environment(\.modelContext) private var modelContext
    @Query private var matches: [FavoriteRepo]

    /// Counts *taps*, so haptic feedback can be triggered by the user's
    /// action rather than by an observed change in the store.
    @State private var toggleCount = 0

    init(repo: Repo) {
        self.repo = repo
        // A @Query built in init — filtered to this repo — so favorite state
        // updates live if it changes anywhere else in the app.
        let id = repo.id
        _matches = Query(filter: #Predicate<FavoriteRepo> { $0.repoID == id })
    }

    private var isFavorite: Bool {
        !matches.isEmpty
    }

    var body: some View {
        List {
            if let summary = repo.summary {
                Section("About") {
                    Text(summary)
                }
            }
            Section("Stats") {
                LabeledContent("Stars", value: repo.stargazersCount.formatted())
                LabeledContent("Forks", value: repo.forksCount.formatted())
                if let language = repo.language {
                    LabeledContent("Language", value: language)
                }
                LabeledContent("Owner", value: repo.ownerLogin)
            }
            // `webURL` is the model's answer to "is this link one we are
            // willing to open" — see `Repo.webURL`. No link, no section.
            if let url = repo.webURL {
                Section {
                    Link("View on GitHub", destination: url)
                        .accessibilityIdentifier("detail.githubLink")
                }
            }
        }
        .navigationTitle(repo.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // The title *is* the accessibility label — a separate
                // `.accessibilityLabel` would only be a second copy to keep
                // in sync. `.labelStyle(.iconOnly)` hides the text visually
                // without hiding it from assistive technology, which is
                // exactly the trade a bare `Image` gets wrong.
                //
                // The label is *stable* and the trait carries the state. A
                // label that flips to "Remove from Favorites" while
                // `.isSelected` is set makes VoiceOver read the contradiction
                // "Remove from Favorites, selected" — a name describing the
                // action next to a state describing the result. "Favorite,
                // selected" says one coherent thing. Say a control's name in
                // its label and its state in its traits, never both in the
                // label.
                Button("Favorite", systemImage: isFavorite ? "star.fill" : "star") {
                    toggleFavorite()
                }
                .labelStyle(.iconOnly)
                // Cross-fades star ↔ star.fill as one symbol changing state
                // rather than one view being replaced by another.
                .contentTransition(.symbolEffect(.replace))
                // Animating on the *value* rather than wrapping the call:
                // `toggleFavorite()` writes to SwiftData, and `isFavorite`
                // comes back through `@Query` on a later update — well
                // outside any `withAnimation` transaction the tap could open.
                .animation(.default, value: isFavorite)
                // Driven by the user's tap, not by an observed store read.
                // Triggering on `isFavorite` fired on *arrival* at an
                // already-favorited repo, because the `@Query` resolving from
                // false to true is a change like any other — a haptic for
                // something the user did not do. It also gave `.success` to
                // unfavoriting, which is a removal, not an achievement.
                .sensoryFeedback(trigger: toggleCount) { _, _ in
                    isFavorite ? .success : .impact(weight: .light)
                }
                // VoiceOver announces "selected" for a favorited repo, so the
                // state is audible and not only in the symbol.
                .accessibilityAddTraits(isFavorite ? [.isSelected] : [])
                .accessibilityIdentifier("detail.favoriteButton")
            }
        }
    }

    private func toggleFavorite() {
        toggleCount += 1
        do {
            try FavoritesStore(context: modelContext).toggle(repo)
        } catch {
            // A local-store write failing is exceptional; log rather than
            // interrupt. (A data-critical app would surface an alert here.)
            Logger.favorites.error("Failed to toggle favorite: \(error)")
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        RepoDetailView(repo: MockGitHubClient.fixtureRepos[0])
    }
    .modelContainer(previewContainer)
}
#endif
