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

    private static let logger = Logger(subsystem: "work.timmaher.testExample", category: "favorites")

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
            Section {
                Link("View on GitHub", destination: repo.htmlURL)
                    .accessibilityIdentifier("detail.githubLink")
            }
        }
        .navigationTitle(repo.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityIdentifier("detail.favoriteButton")
            }
        }
    }

    private func toggleFavorite() {
        do {
            try FavoritesStore(context: modelContext).toggle(repo)
        } catch {
            // A local-store write failing is exceptional; log rather than
            // interrupt. (A data-critical app would surface an alert here.)
            Self.logger.error("Failed to toggle favorite: \(error)")
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
