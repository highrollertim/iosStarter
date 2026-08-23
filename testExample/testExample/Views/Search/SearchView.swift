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
            .safeAreaInset(edge: .bottom) {
                LastRefreshedFooter(viewModel: viewModel, isRefreshing: isRefreshing)
            }
            // The ticker that drives `lastRefreshedDescription` only runs
            // while this list is on screen: start it when the results
            // appear, stop it when they leave. See
            // `SearchViewModel.startTicker()` for why an init-started timer
            // on this app-lifetime view model would be wrong.
            .onAppear { viewModel.startTicker() }
            .onDisappear { viewModel.stopTicker() }
        case .failed(let message):
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
                    // On the *description*, not on the ContentUnavailableView:
                    // a container-level identifier here gets re-parented onto
                    // every child the view merges, which is what was clobbering
                    // "search.retryButton" below. Identifying the one leaf that
                    // is genuinely the error message gives UI tests something
                    // locale-independent to assert on — the previous query
                    // matched the literal English "Something went wrong", and
                    // stopped matching the moment the app grew a second
                    // language.
                    .accessibilityIdentifier("search.errorView")
            } actions: {
                Button("Retry") {
                    viewModel.retry()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("search.retryButton")
            }
            // No container-level accessibility identifier here: ContentUnavailableView
            // re-parents a container identifier onto its merged children, which was
            // clobbering "search.retryButton" on the Retry button below. The error
            // state is identified honestly instead — by its visible text — in the UI
            // tests (see SearchScreen.errorView).
        }
    }
}

/// The "Updated Ns ago" status bar under the results list.
///
/// **This being its own `View` struct is the entire point of the file's
/// second lesson.** `@Observable` tracks reads *per `body` evaluation*: every
/// observable property read while a `body` runs is registered as a dependency
/// of that `body`. `lastRefreshedDescription` reads `viewModel.now`, which the
/// ticker rewrites once a second. Inline this text back into `SearchView` —
/// even inside the `safeAreaInset` builder — and that read is attributed to
/// `SearchView.body`, so the whole screen (`NavigationStack`, `searchable`,
/// the entire `List`) is invalidated every second forever. Pulled out into a
/// leaf, the once-a-second dependency belongs to a view whose body is two
/// `Text`s. Confine time-driven invalidation to the smallest view that
/// actually displays the time.
private struct LastRefreshedFooter: View {
    let viewModel: SearchViewModel
    let isRefreshing: Bool

    var body: some View {
        if let refreshed = viewModel.lastRefreshedDescription {
            HStack(spacing: 6) {
                if isRefreshing {
                    // Stale-while-revalidate made visible: the list below is
                    // still the previous query's results, and this says so
                    // without yanking them off screen.
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(refreshed)
                    // The digits change every second; without a monospaced
                    // figure face the text jitters as glyph widths change.
                    .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(.bar)
            // Ambient status, not content. A VoiceOver element whose label
            // changes once a second is actively hostile: it interrupts the
            // user mid-sentence and makes the results list hard to escape.
            // The information is decorative here; the list is the content.
            .accessibilityHidden(true)
        }
    }
}

#if DEBUG
#Preview("Results") {
    SearchView(viewModel: SearchViewModel(client: MockGitHubClient()))
        // Without a container the preview traps the moment you tap a row:
        // `RepoDetailView`'s `@Query` has no `modelContext` to resolve
        // against. Previews of any view that can *navigate* to SwiftData
        // need the environment the navigation destination expects.
        .modelContainer(previewContainer)
}

#Preview("Error") {
    SearchView(viewModel: SearchViewModel(client: MockGitHubClient(scenario: .searchError)))
        .modelContainer(previewContainer)
}
#endif
