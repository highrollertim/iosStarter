import SwiftUI

/// The search screen. Note the shape: the view is a pure function of
/// `viewModel.state` — every case of `LoadState` maps to exactly one branch,
/// and the compiler won't let us forget one.
struct SearchView: View {
    /// `@Bindable` bridges an `@Observable` object into bindings
    /// (`$viewModel.searchText`) — the successor to `@ObservedObject`.
    @Bindable var viewModel: SearchViewModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("RepoScout")
                .searchable(text: $viewModel.searchText, prompt: "Search GitHub repositories")
                // Type-safe navigation: pushing a value, not a view. The
                // destination for `Repo` values is declared once, here.
                .navigationDestination(for: Repo.self) { repo in
                    RepoDetailView(repo: repo)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            ContentUnavailableView(
                "Search GitHub",
                systemImage: "magnifyingglass",
                description: Text("Find repositories by name, topic, or language.")
            )
        case .loading:
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("search.loading")
        case .loaded(let repos) where repos.isEmpty:
            ContentUnavailableView.search(text: viewModel.searchText)
        case .loaded(let repos):
            List(repos) { repo in
                NavigationLink(value: repo) {
                    RepoRowView(repo: repo)
                }
                .accessibilityIdentifier("search.row.\(repo.fullName)")
            }
            .accessibilityIdentifier("search.list")
            .safeAreaInset(edge: .bottom) {
                if let refreshed = viewModel.lastRefreshedDescription {
                    Text(refreshed)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    viewModel.retry()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("search.retryButton")
            }
            .accessibilityIdentifier("search.errorView")
        }
    }
}

#if DEBUG
#Preview("Results") {
    SearchView(viewModel: SearchViewModel(client: MockGitHubClient()))
}

#Preview("Error") {
    SearchView(viewModel: SearchViewModel(client: MockGitHubClient(scenario: .searchError)))
}
#endif
