import SwiftData
import SwiftUI

/// The search screen.
///
/// The shape, stated honestly, because the obvious description of it would be
/// wrong. `content` has **two** forms, not one branch per `LoadState` case:
///
/// 1. Rows worth reading — a non-empty `.loaded`, or a `.failed` that kept
///    non-empty stale results — render as **one** `List`. Both states share
///    that single view identity; see `displayedRows`.
/// 2. Everything else is a four-arm `switch`: idle, loading, loaded-but-empty,
///    and failed-with-nothing-to-keep.
///
/// The `where` clauses in `displayedRows` are **not** compiler-verified. A
/// `switch` whose arms are all guarded is not exhaustive, so it is the
/// unguarded `default` that makes it compile — the compiler cannot tell us
/// that the two guarded arms describe the states they claim to. What catches a
/// mistake there is the test suite, not the build.
///
/// And the screen is not a pure function of `state` alone: two places read
/// state that lives *beside* the enum. The empty branch and `.refreshable`
/// read `lastCompletedQuery`, and the footer reads `lastRefreshed`/`now`.
/// That is the deliberate trade behind keeping `LoadState` a generic lifecycle
/// enum that knows nothing about searching (see `SearchViewModel`): the price
/// is that a reader has to look in two places to know what this screen shows.
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

    /// The rows the screen is showing, or `nil` when it is showing something
    /// other than rows.
    ///
    /// Two states carry results worth reading: a non-empty `.loaded`, and a
    /// `.failed` that kept non-empty stale results under its banner. Naming
    /// them together here is what lets `content` build **one** `List` for
    /// both.
    private var displayedRows: [Repo]? {
        switch viewModel.state {
        case .loaded(let repos, _) where !repos.isEmpty: repos
        case .failed(_, let stale?) where !stale.isEmpty: stale
        default: nil
        }
    }

    /// True only while a `.loaded` state is revalidating. The failure states
    /// are never "refreshing": the banner, not the spinner, is what they have
    /// to say.
    private var isRefreshing: Bool {
        if case .loaded(_, let refreshing) = viewModel.state { refreshing } else { false }
    }

    @ViewBuilder
    private var content: some View {
        if let rows = displayedRows {
            // **One `List`, for both states that have rows** — the same lesson
            // `FavoritesView` spells out for its empty state, in the other
            // direction. There it is one `List` for its whole lifetime with the
            // empty state as an overlay; here it is one `List` across
            // `.loaded` ↔ `.failed(_, stale:)`. A `List` built in one `switch`
            // arm and an identical `List` built in another are two *different*
            // views to SwiftUI, so crossing between them destroys and rebuilds:
            // scroll position resets, rows cut instead of animating, and every
            // modifier attached below restarts — which is how the failure state
            // used to lose `.refreshable`, lose the timestamp footer, and stop
            // and restart the ticker on every failure. Hoisting the list out of
            // the `switch` makes the transition an *update* of one view rather
            // than a swap between two.
            List(rows) { repo in
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
            //
            // It re-runs the query these rows *belong to*, not the live field:
            // pulling mid-debounce would otherwise search half-typed text, and
            // pulling on a cleared field would collapse the list to idle.
            .refreshable {
                await viewModel.dispatch(viewModel.lastCompletedQuery ?? viewModel.searchText).value
            }
            // `safeAreaBar`, not `safeAreaInset`: the bar variant supplies the
            // system bar background and scroll-edge treatment itself, so the
            // leaf below carries no `.background(.bar)` and no width-stretching
            // frame of its own.
            .safeAreaBar(edge: .bottom) { bottomBar }
            // The ticker that drives `lastRefreshedDescription` only runs
            // while this list is on screen: start it when the results
            // appear, stop it when they leave. Its lifetime is the list's, so
            // a failure that keeps its rows no longer stops and restarts it.
            // See `SearchViewModel.startTicker()` for why an init-started
            // timer on this app-lifetime view model would be wrong.
            .onAppear { viewModel.startTicker() }
            .onDisappear { viewModel.stopTicker() }
            // A failure that keeps its rows is, visually, a bar appearing under
            // a screen that is otherwise unchanged — and to VoiceOver it is
            // nothing at all: focus does not move, no element the user is on
            // has changed, so nothing is spoken. The full-screen failure branch
            // needs no announcement for the opposite reason: replacing the
            // content relocates focus, which the system speaks by itself.
            .onChange(of: viewModel.state) { previous, current in
                guard case .failed(let message, let stale?) = current, !stale.isEmpty else { return }
                // Only on the way *in*. Retrying from the banner and failing
                // again lands on `.failed` from `.loaded`, which is a new
                // failure and worth saying; `.failed` → `.failed` is not.
                if case .failed = previous { return }
                AccessibilityNotification.Announcement(message).post()
            }
        } else {
            switch viewModel.state {
            case .idle:
                ContentUnavailableView(
                    "Search GitHub",
                    systemImage: "magnifyingglass",
                    description: Text("Find repositories by name, topic, or language.")
                )
            case .loading:
                // Only a load with nothing to keep blanks the screen. A
                // refinement of an existing result set keeps its list and flags
                // itself in the footer instead — see `LoadState` and
                // `SearchViewModel.search(matching:)`.
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("search.loading")
            case .loaded(_, let isRefreshing):
                // Reached only with an empty result set: the non-empty case
                // took the list path above.
                //
                // The title has to name the query that *produced* this empty
                // set. `searchText` is the live field — still ahead of the
                // debounce, and the user may already be typing the next query —
                // so titling with it announces "No Results for …" about a
                // search nobody has run.
                //
                // It is not the fallback either, and the old `?? searchText`
                // overstated its own necessity: every writer of `.loaded`
                // records `lastCompletedQuery` in the same main-actor turn (see
                // `SearchViewModel.search(matching:)`), so a `.loaded` with no
                // recorded query is unreachable in production — only the
                // `#if DEBUG` preview seam can build one. Naming no query at
                // all is the honest answer for that case, and the untitled
                // system view is exactly it.
                Group {
                    if let query = viewModel.lastCompletedQuery {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ContentUnavailableView.search
                    }
                }
                // `isRefreshing` is real here too: refining from an empty set is
                // exactly when the user most needs to see that something is
                // happening, and this branch has no list and no footer to say so.
                .overlay(alignment: .bottom) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .padding()
                            .accessibilityIdentifier("search.emptyRefreshing")
                            // Ambient status, like the footer's spinner: the
                            // content here is the "no results" message, and an
                            // unlabelled progress element beside it is noise.
                            .accessibilityHidden(true)
                    }
                }
            case .failed(let message, _):
                // Nothing to keep: a load with no results behind it failed, or
                // the last thing that succeeded had no results to preserve.
                // Same two identifiers as the banner below — only one of the
                // two ever renders, so UI tests find exactly one of each
                // either way.
                ContentUnavailableView {
                    Label("Something went wrong", systemImage: "exclamationmark.triangle")
                } description: {
                    // The identifier goes on the description `Text`, never on
                    // the `ContentUnavailableView`: a container-level
                    // identifier is re-parented onto every child the view
                    // merges, clobbering "search.retryButton" below.
                    // Identifying the one leaf that is genuinely the error
                    // message also gives UI tests something locale-independent
                    // to match, which the literal English "Something went
                    // wrong" was not.
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

    /// The bar under the list.
    ///
    /// Under a failure it is the banner **and** the timestamp, stacked, not
    /// the banner alone. "Updated N seconds ago" matters most precisely when
    /// the rows above it are stale: it is the only thing on screen that says
    /// how old the results the user is still reading actually are, and the
    /// failure is the moment that stops being a detail.
    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if case .failed(let message, _) = viewModel.state {
                ErrorBanner(message: message) { viewModel.retry() }
            }
            LastRefreshedFooter(viewModel: viewModel, isRefreshing: isRefreshing)
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
/// once-a-second dependency belongs to a view whose body is a spinner and a
/// `Text`.
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
