import SwiftData
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
                // The opt-in for the iOS 26 minimized search presentation:
                // the search field collapses toward the tab bar as the user
                // scrolls into results and expands again on interaction.
                // `role: .search` on the Tab does not turn this on by itself.
                .searchToolbarBehavior(.minimize)
                // Repository names are case-sensitive-ish identifiers, not
                // prose: auto-capitalizing "swift" to "Swift" and
                // autocorrecting "vapor" to "vapour" are both actively wrong
                // here, and both are on by default.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // Pressing Return means "I'm done typing" — honour it
                // immediately instead of making the user wait out the
                // debounce they've already finished outrunning.
                .onSubmit(of: .search) { viewModel.submitImmediately() }
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
            // Only a *first* load blanks the screen. A refinement of an
            // existing result set keeps its list and flags itself in the
            // footer instead — see `.loaded` below and `LoadState`.
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("search.loading")
        case .loaded(let repos, let isRefreshing) where repos.isEmpty:
            // The title has to name the query that *produced* this empty set.
            // `searchText` is the live field — still ahead of the debounce, and
            // the user may already be typing the next query — so titling with
            // it announces "No Results for …" about a search nobody has run.
            // `lastCompletedQuery` is that query; `searchText` is the fallback
            // for the case where nothing has completed yet.
            ContentUnavailableView.search(
                text: viewModel.lastCompletedQuery ?? viewModel.searchText
            )
            // `isRefreshing` is real here too: refining from an empty set is
            // exactly when the user most needs to see that something is
            // happening, and this branch has no list and no footer to say so.
            .overlay(alignment: .bottom) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .padding()
                        .accessibilityIdentifier("search.emptyRefreshing")
                }
            }
        case .loaded(let repos, let isRefreshing):
            List(repos) { repo in
                NavigationLink(value: repo) {
                    RepoRowView(repo: repo)
                }
                .accessibilityIdentifier("search.row.\(repo.fullName)")
            }
            .accessibilityIdentifier("search.list")
            // Stale-while-revalidate with no way to ask for a revalidation is
            // half a design: results can go quietly out of date and the only
            // cure is editing the query. `dispatch(_:)` is what makes this
            // safe to expose — the pull cancels any in-flight search and
            // becomes the one that owns the screen.
            .refreshable { await viewModel.dispatch(viewModel.searchText).value }
            // `safeAreaBar`, not `safeAreaInset`: the bar variant supplies the
            // system bar background and scroll-edge treatment itself, so the
            // leaf below carries no `.background(.bar)` and no width-stretching
            // frame of its own.
            .safeAreaBar(edge: .bottom) {
                LastRefreshedFooter(viewModel: viewModel, isRefreshing: isRefreshing)
            }
            // The ticker that drives `lastRefreshedDescription` only runs
            // while this list is on screen: start it when the results
            // appear, stop it when they leave. See
            // `SearchViewModel.startTicker()` for why an init-started timer
            // on this app-lifetime view model would be wrong.
            .onAppear { viewModel.startTicker() }
            .onDisappear { viewModel.stopTicker() }
        case .failed(let message, let stale?) where !stale.isEmpty:
            // A refinement failed with results still on screen. Those results
            // are the best thing anyone has, so the failure gets a bar rather
            // than the whole window. Same two identifiers as the full-screen
            // branch below — only one of the two ever renders, so UI tests
            // find exactly one of each either way.
            List(stale) { repo in
                NavigationLink(value: repo) {
                    RepoRowView(repo: repo)
                }
                .accessibilityIdentifier("search.row.\(repo.fullName)")
            }
            .accessibilityIdentifier("search.list")
            .safeAreaBar(edge: .bottom) {
                ErrorBanner(message: message) { viewModel.retry() }
            }
        case .failed(let message, _):
            // Nothing to keep: a first load failed, or the last thing that
            // succeeded had no results to preserve.
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                // The identifier goes on the description `Text`, never on the
                // `ContentUnavailableView`: a container-level identifier is
                // re-parented onto every child the view merges, clobbering
                // "search.retryButton" below. Identifying the one leaf that is
                // genuinely the error message also gives UI tests something
                // locale-independent to match, which the literal English
                // "Something went wrong" was not.
                Text(message)
                    .accessibilityIdentifier("search.errorView")
            } actions: {
                Button("Retry") {
                    viewModel.retry()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("search.retryButton")
            }
        }
    }
}

/// The compact failure presentation: a bar under results that are still
/// worth reading.
///
/// Carries the same identifiers as the full-screen error state, because it is
/// the same two things — the message and the way out — at a different size.
private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.footnote)
                .accessibilityIdentifier("search.errorView")
            Spacer(minLength: 0)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("search.retryButton")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// The "Updated Ns ago" status bar under the results list.
///
/// **This being its own `View` struct is the entire point of the file's
/// second lesson.** `@Observable` tracks reads *per `body` evaluation*: every
/// observable property read while a `body` runs is registered as a dependency
/// of that `body`. `lastRefreshedDescription` reads `viewModel.now`, which the
/// ticker rewrites once a second. Inline this text back into `SearchView` —
/// even inside the `safeAreaBar` builder — and that read is attributed to
/// `SearchView.body`, so `SearchView.body` is re-evaluated every second
/// forever. (Re-evaluated, not re-rendered: SwiftUI's structural diffing
/// elides the rows that did not change. The cost is the evaluation, and it is
/// still a cost worth not paying once a second.) Pulled out into a leaf, the
/// once-a-second dependency belongs to a view whose body is two `Text`s.
///
/// The insulation is one-directional, and worth being precise about: it keeps
/// the ticker's invalidation *inside* this leaf, but it does not exempt the
/// leaf from the parent's. Anything that re-evaluates `SearchView.body` —
/// `state` changing, `searchText` changing — re-evaluates this too. That
/// direction is harmless; the once-a-second one is the one that compounds.
private struct LastRefreshedFooter: View {
    let viewModel: SearchViewModel
    let isRefreshing: Bool

    var body: some View {
        // The `HStack` is outside the `if let`, so the spinner does not
        // depend on there being a timestamp to show. Gating "a request is in
        // flight" on "a previous request has finished" was accidental
        // coupling: the two facts are unrelated, and the first refresh after
        // a cold start had both a spinner to show and no timestamp yet.
        HStack(spacing: 6) {
            if isRefreshing {
                // Stale-while-revalidate made visible: the list below is
                // still the previous query's results, and this says so
                // without yanking them off screen.
                ProgressView()
                    .controlSize(.mini)
            }
            if let refreshed = viewModel.lastRefreshedDescription {
                Text(refreshed)
                    // The digits change every second; without a monospaced
                    // figure face the text jitters as glyph widths change.
                    .monospacedDigit()
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        // Ambient status, not content. A VoiceOver element whose label
        // changes once a second is actively hostile: it interrupts the
        // user mid-sentence and makes the results list hard to escape.
        // The information is decorative here; the list is the content.
        .accessibilityHidden(true)
    }
}

#if DEBUG
/// Builds a view model already in `state`, because a `#Preview` renders once
/// and cannot wait out a search — a preview handed a mock client shows the
/// idle prompt and nothing else. See `setStateForPreviews`.
@MainActor
private func previewViewModel(
    _ state: LoadState<[Repo]>,
    lastCompletedQuery: String? = nil
) -> SearchViewModel {
    let viewModel = SearchViewModel(client: MockGitHubClient())
    viewModel.setStateForPreviews(state, lastCompletedQuery: lastCompletedQuery)
    return viewModel
}

// `traits: .sampleData` supplies the model container. Without one the preview
// traps the moment you tap a row: `RepoDetailView`'s `@Query` has no
// `modelContext` to resolve against. Any preview of a view that can
// *navigate* to SwiftData needs the environment its destination expects.

#Preview("Results", traits: .sampleData) {
    SearchView(viewModel: previewViewModel(
        .loaded(MockGitHubClient.fixtureRepos, isRefreshing: false)
    ))
}

#Preview("Refreshing", traits: .sampleData) {
    SearchView(viewModel: previewViewModel(
        .loaded(MockGitHubClient.fixtureRepos, isRefreshing: true)
    ))
}

#Preview("Empty", traits: .sampleData) {
    SearchView(viewModel: previewViewModel(
        .loaded([], isRefreshing: false),
        lastCompletedQuery: "zzzz"
    ))
}

#Preview("Error (first load)", traits: .sampleData) {
    SearchView(viewModel: previewViewModel(
        .failed(message: "GitHub is rate-limiting searches right now. Give it a minute.", stale: nil)
    ))
}

#Preview("Error (stale kept)", traits: .sampleData) {
    SearchView(viewModel: previewViewModel(
        .failed(
            message: "GitHub is rate-limiting searches right now. Give it a minute.",
            stale: MockGitHubClient.fixtureRepos
        )
    ))
}
#endif
