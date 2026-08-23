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
            // `htmlURL` is decoded straight from a network payload, so its
            // scheme is whatever the server said — `Link` would happily hand
            // a `javascript:` or custom-scheme URL to `openURL`. Render the
            // link only for schemes we actually meant to support.
            if isWebLink {
                Section {
                    Link("View on GitHub", destination: repo.htmlURL)
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
                Button(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "star.fill" : "star"
                ) {
                    withAnimation { toggleFavorite() }
                }
                .labelStyle(.iconOnly)
                // Cross-fades star ↔ star.fill as one symbol changing state
                // rather than one view being replaced by another.
                .contentTransition(.symbolEffect(.replace))
                .sensoryFeedback(.success, trigger: isFavorite)
                // VoiceOver announces "selected" for a favorited repo, so the
                // state is audible and not only in the changed label.
                .accessibilityAddTraits(isFavorite ? [.isSelected] : [])
                .accessibilityIdentifier("detail.favoriteButton")
            }
        }
    }

    private var isWebLink: Bool {
        repo.htmlURL.scheme == "https" || repo.htmlURL.scheme == "http"
    }

    private func toggleFavorite() {
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
