import Foundation
import Testing
@testable import testExample

/// `@MainActor` because `SearchViewModel` is main-actor-isolated (the app
/// target uses default MainActor isolation; this test target does not).
@MainActor
@Suite("SearchViewModel state transitions")
struct SearchViewModelTests {

    /// A debounce long enough that the Combine pipeline provably cannot fire
    /// during a test. Used by the tests that drive `dispatch`/`retry` directly
    /// and only set `searchText` so `retry()` has something to re-run —
    /// without it, `searchText`'s `didSet` would race a second, unwanted
    /// request into the assertions.
    private static let neverFires: DispatchQueue.SchedulerTimeType.Stride = .seconds(30)

    // `dispatch(_:)` rather than the private `search(matching:)`: it is the
    // only route into a search in production, and it hands back the `Task` it
    // stored, so `await …value` makes these tests deterministic without a
    // sleep. Driving the real funnel also means the dedup bookkeeping under
    // test is the bookkeeping the app performs.

    @Test("successful search moves loading → loaded")
    func successMovesThroughLoadingToLoaded() async throws {
        let gate = GatedGitHubClient(repos: .fixture)
        let viewModel = SearchViewModel(client: gate)
        #expect(viewModel.state == .idle)

        let search = viewModel.dispatch("swift")
        try await poll(until: { viewModel.state == .loading }, message: "state == .loading")
        await gate.open()
        await search.value

        #expect(viewModel.state == .loaded(.fixture, isRefreshing: false))
        #expect(viewModel.lastRefreshed != nil)
    }

    @Test("failed search surfaces the error's user-facing message")
    func failureSurfacesMessage() async {
        let spy = SpyGitHubClient(result: .failure(.rateLimited))
        let viewModel = SearchViewModel(client: spy)

        await viewModel.dispatch("swift").value

        #expect(viewModel.state == .failed(message: GitHubClientError.rateLimited.errorDescription ?? "", stale: nil))
    }

    @Test("blank queries reset to idle without hitting the network", arguments: ["", "   ", "\n"])
    func blankQueriesResetToIdle(query: String) async {
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy)

        await viewModel.dispatch(query).value

        #expect(viewModel.state == .idle)
        #expect(await spy.queries.isEmpty)
    }

    @Test("refining a loaded search keeps the stale results on screen")
    func refiningKeepsStaleResultsVisible() async throws {
        let staleResult: [Repo] = [
            Repo(id: 2, fullName: "stale/repo", ownerLogin: "stale", summary: nil,
                 stargazersCount: 0, forksCount: 0, language: nil,
                 htmlURL: URL(string: "https://github.com/stale/repo")!)
        ]
        let client = KeyedGatedGitHubClient(repos: ["swif": staleResult, "swift": .fixture])
        let viewModel = SearchViewModel(client: client)

        await client.open("swif")
        await viewModel.dispatch("swif").value
        #expect(viewModel.state == .loaded(staleResult, isRefreshing: false))

        // The refinement is in flight. This is the state a four-case
        // `LoadState` cannot express: the previous query's rows are still the
        // right thing to show, and blanking them to a spinner on every
        // keystroke is the bug `isRefreshing` exists to prevent.
        let refinement = viewModel.dispatch("swift")
        try await poll(until: { await client.isPending("swift") }, message: "refinement in flight")
        #expect(viewModel.state == .loaded(staleResult, isRefreshing: true))

        await client.open("swift")
        await refinement.value
        #expect(viewModel.state == .loaded(.fixture, isRefreshing: false))
    }

    @Test("an empty refinement reports the query that produced it")
    func emptyRefinementRecordsItsQuery() async throws {
        // The state hole this closes: results on screen, the user refines,
        // and the refinement matches nothing. The empty screen has to say
        // "No Results for <the refining query>" — and it cannot ask
        // `searchText`, which is the live, un-debounced field.
        let client = KeyedGatedGitHubClient(repos: ["swift": .fixture, "swiftzzz": []])
        let viewModel = SearchViewModel(client: client, debounceInterval: Self.neverFires)

        await client.open("swift")
        await viewModel.dispatch("swift").value
        #expect(viewModel.state == .loaded(.fixture, isRefreshing: false))
        #expect(viewModel.lastCompletedQuery == "swift")

        await client.open("swiftzzz")
        await viewModel.dispatch("  swiftzzz  ").value

        #expect(viewModel.state == .loaded([], isRefreshing: false))
        // Trimmed, because that is the query that was actually sent.
        #expect(viewModel.lastCompletedQuery == "swiftzzz")
    }

    @Test("a failed refinement keeps the results it was refining")
    func failedRefinementKeepsStaleResults() async throws {
        // Blanking the screen on a failed refinement throws away the last
        // thing that worked. The failure is real and gets said out loud —
        // but over the results, not instead of them.
        let client = ScriptedGitHubClient(
            script: [.success(.fixture), .failure(.rateLimited)]
        )
        let viewModel = SearchViewModel(client: client, debounceInterval: Self.neverFires)

        await viewModel.dispatch("swift").value
        #expect(viewModel.state == .loaded(.fixture, isRefreshing: false))

        await viewModel.dispatch("swiftui").value
        #expect(viewModel.state == .failed(
            message: GitHubClientError.rateLimited.errorDescription ?? "",
            stale: .fixture
        ))
    }

    @Test("retrying the query the stale rows answer keeps them on screen throughout")
    func retryFromFailureBannerPreservesStaleResults() async throws {
        // The banner's Retry re-enters `search` with state `.failed(_, stale:)`,
        // and the promotion has to read that shape too: reading only `.loaded`
        // would blank the results the banner promised to preserve, and a second
        // failure would then drop them permanently.
        //
        // The *middle* of the retry is the part worth pinning, and it is
        // invisible to a test that only inspects terminal states — which is
        // what the previous version of this test did. Gating the client is
        // what makes the in-flight moment observable: while the retry is
        // suspended, the rows must be back on screen and flagged refreshing,
        // not replaced by a spinner.
        let client = KeyedGatedGitHubClient(scripts: [
            "swift": [.success(.fixture), .failure(.rateLimited), .failure(.network)]
        ])
        let viewModel = SearchViewModel(client: client, debounceInterval: Self.neverFires)

        await client.open("swift")
        await viewModel.dispatch("swift").value
        #expect(viewModel.state == .loaded(.fixture, isRefreshing: false))
        #expect(viewModel.lastCompletedQuery == "swift")

        // A refresh of that same query fails. The rows it was refreshing stay,
        // under a banner.
        await client.open("swift")
        await viewModel.dispatch("swift").value
        #expect(viewModel.state == .failed(
            message: GitHubClientError.rateLimited.errorDescription ?? "",
            stale: .fixture
        ))

        // The user taps Retry. `retry()` delegates to `dispatch(searchText)`;
        // dispatching directly is the same funnel with an awaitable task,
        // minus the field bookkeeping this test never set up.
        let retry = viewModel.dispatch("swift")
        try await poll(until: { await client.isPending("swift") }, message: "the retry to be in flight")
        #expect(viewModel.state == .loaded(.fixture, isRefreshing: true))

        // And a second failure still carries the same results forward.
        await client.open("swift")
        await retry.value
        #expect(viewModel.state == .failed(
            message: GitHubClientError.network.errorDescription ?? "",
            stale: .fixture
        ))
    }

    @Test("retrying a failed refinement keeps the rows the banner is sitting on")
    func retryingAFailedRefinementKeepsTheRowsUnderTheBanner() async throws {
        // The `lastFailedQuery` half of the gate, and the case the feature was
        // built for. A refinement fails, so the banner is about "swiftui" while
        // the rows underneath it are "swift"'s. The banner's Retry re-runs
        // *its own* query — `retry()` submits `searchText` — so a gate that
        // only recognised `lastCompletedQuery` sent this tap to `.loading` and
        // blanked the rows the banner had just promised to keep.
        //
        // The in-flight moment is the whole assertion: terminal states cannot
        // tell a promotion from a fresh load that happened to fail with the
        // same stale array attached.
        let client = KeyedGatedGitHubClient(
            repos: ["swift": .fixture],
            scripts: ["swiftui": [.failure(.rateLimited), .failure(.network)]]
        )
        let viewModel = SearchViewModel(client: client, debounceInterval: Self.neverFires)

        await client.open("swift")
        await viewModel.dispatch("swift").value
        #expect(viewModel.state == .loaded(.fixture, isRefreshing: false))

        await client.open("swiftui")
        await viewModel.dispatch("swiftui").value
        #expect(viewModel.state == .failed(
            message: GitHubClientError.rateLimited.errorDescription ?? "",
            stale: .fixture
        ))
        // The two keys have genuinely parted company here, which is what makes
        // this test cover a disjunct the same-query one cannot.
        #expect(viewModel.lastCompletedQuery == "swift")
        #expect(viewModel.lastFailedQuery == "swiftui")

        let retry = viewModel.dispatch("swiftui")
        try await poll(until: { await client.isPending("swiftui") }, message: "the banner's retry to be in flight")
        #expect(viewModel.state == .loaded(.fixture, isRefreshing: true))

        await client.open("swiftui")
        await retry.value
        #expect(viewModel.state == .failed(
            message: GitHubClientError.network.errorDescription ?? "",
            stale: .fixture
        ))
    }

    @Test("refreshing after a failed refinement keeps the rows it re-runs")
    func refreshAfterAFailedRefinementKeepsTheLoadedQuerysRows() async throws {
        // The `lastCompletedQuery` half, isolated. `.refreshable` dispatches
        // `lastCompletedQuery`, so a pull from this screen re-runs "swift" —
        // which is neither the live field nor the query the banner is about,
        // and is exactly the query the rows on screen answer.
        //
        // Deleting the *other* disjunct leaves this passing and the test above
        // failing, and vice versa: two arms, two witnesses.
        let client = KeyedGatedGitHubClient(
            repos: ["swift": .fixture],
            scripts: ["swiftui": [.failure(.rateLimited)]]
        )
        let viewModel = SearchViewModel(client: client, debounceInterval: Self.neverFires)

        await client.open("swift")
        await viewModel.dispatch("swift").value
        await client.open("swiftui")
        await viewModel.dispatch("swiftui").value
        #expect(viewModel.state == .failed(
            message: GitHubClientError.rateLimited.errorDescription ?? "",
            stale: .fixture
        ))

        let refresh = viewModel.dispatch("swift")
        try await poll(until: { await client.isPending("swift") }, message: "the refresh to be in flight")
        #expect(viewModel.state == .loaded(.fixture, isRefreshing: true))

        await client.open("swift")
        await refresh.value
        #expect(viewModel.state == .loaded(.fixture, isRefreshing: false))
        // A success clears the banner's query along with the banner.
        #expect(viewModel.lastFailedQuery == nil)
    }

    @Test("a new query typed from a failure does not resurrect the old query's rows")
    func newQueryFromAFailureStartsBlank() async throws {
        // The half of the gate that is not negotiable. Ungated, the promotion
        // fired for any query dispatched from a failure — so typing something
        // new showed the previous search's results as the new query's own, with
        // a spinner claiming they were being refreshed. A query with no history
        // has nothing to keep, and a blank screen is the correct answer for it.
        //
        // "New" here means new to *both* keys: the search that succeeded was
        // "swift" and the one that failed was "swift" too, so "swiftui" matches
        // neither `lastCompletedQuery` nor `lastFailedQuery` and the gate has to
        // reject it on both counts. Delete the gate entirely and this test
        // fails; that is what it is for.
        let staleResult: [Repo] = [
            Repo(id: 2, fullName: "stale/repo", ownerLogin: "stale", summary: nil,
                 stargazersCount: 0, forksCount: 0, language: nil,
                 htmlURL: URL(string: "https://github.com/stale/repo")!)
        ]
        let client = KeyedGatedGitHubClient(scripts: [
            "swift": [.success(staleResult), .failure(.rateLimited)],
            "swiftui": [.failure(.network)],
        ])
        let viewModel = SearchViewModel(client: client, debounceInterval: Self.neverFires)

        await client.open("swift")
        await viewModel.dispatch("swift").value
        await client.open("swift")
        await viewModel.dispatch("swift").value
        #expect(viewModel.state == .failed(
            message: GitHubClientError.rateLimited.errorDescription ?? "",
            stale: staleResult
        ))

        let fresh = viewModel.dispatch("swiftui")
        try await poll(until: { await client.isPending("swiftui") }, message: "the new query to be in flight")
        #expect(viewModel.state == .loading)

        await client.open("swiftui")
        await fresh.value
        // Nothing to keep, so nothing is kept: the new query's failure is a
        // first-load failure, and gets the full-screen presentation.
        #expect(viewModel.state == .failed(
            message: GitHubClientError.network.errorDescription ?? "",
            stale: nil
        ))
    }

    @Test("a failure that kept no rows blanks to loading on retry")
    func retryFromAFailureWithEmptyStaleResultsBlanksToLoading() async throws {
        // The other guard on the promotion. A search can succeed with zero
        // results and then fail on refresh, which leaves `.failed(_, stale: [])`
        // — a failure whose "preserved results" are an empty array. Promoting
        // that puts a zero-row list and a refresh spinner on screen in place of
        // the message the user needs.
        let client = KeyedGatedGitHubClient(scripts: [
            "zzzz": [.success([]), .failure(.rateLimited), .success(.fixture)]
        ])
        let viewModel = SearchViewModel(client: client, debounceInterval: Self.neverFires)

        await client.open("zzzz")
        await viewModel.dispatch("zzzz").value
        #expect(viewModel.state == .loaded([], isRefreshing: false))

        await client.open("zzzz")
        await viewModel.dispatch("zzzz").value
        #expect(viewModel.state == .failed(
            message: GitHubClientError.rateLimited.errorDescription ?? "",
            stale: []
        ))

        let retry = viewModel.dispatch("zzzz")
        try await poll(until: { await client.isPending("zzzz") }, message: "the retry to be in flight")
        #expect(viewModel.state == .loading)

        await client.open("zzzz")
        await retry.value
        #expect(viewModel.state == .loaded(.fixture, isRefreshing: false))
    }

    @Test("a cancelled blank search cannot release a live search's dedup key")
    func cancelledBlankSearchLeavesTheLiveKeyAlone() async throws {
        // The interleaving, which is one main-actor turn:
        //
        //   dispatch("")      → key = "",      task A created (not yet running)
        //   dispatch("swift") → key = "swift", task A cancelled, task B created
        //   … turn ends, A runs, then B runs …
        //
        // Task A is cancelled before its body has executed a single line. With
        // the cancellation guard *below* the blank-query guard, A ran the blank
        // path anyway and set `lastDispatchedQuery = nil` — releasing the key
        // that B, still in flight, had just claimed. The user then retyped the
        // same text and paid for a duplicate round trip, because the `filter`
        // in `init` had nothing left to compare against.
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy, debounceInterval: .milliseconds(50))

        let blank = viewModel.dispatch("")
        let live = viewModel.dispatch("swift")
        await blank.value
        await live.value

        #expect(viewModel.state == .loaded(.fixture, isRefreshing: false))

        // `lastDispatchedQuery` is private, so the key is asserted the way the
        // user experiences it: re-submitting the identical text after a
        // *success* must not reach the client again.
        viewModel.searchText = "swift"
        try await Task.sleep(for: .milliseconds(300))
        #expect(await spy.queries == ["swift"])
    }

    @Test("a first-load failure has nothing to keep")
    func firstLoadFailureCarriesNoStaleResults() async throws {
        // The other half of the same rule, and what selects the full-screen
        // error presentation in `SearchView`.
        let spy = SpyGitHubClient(result: .failure(.network))
        let viewModel = SearchViewModel(client: spy, debounceInterval: Self.neverFires)

        await viewModel.dispatch("swift").value

        #expect(viewModel.state == .failed(
            message: GitHubClientError.network.errorDescription ?? "",
            stale: nil
        ))
    }

    @Test("a cancelled search cannot clobber a newer search's result")
    func supersededSearchCannotClobberNewerResult() async throws {
        let staleResult: [Repo] = [
            Repo(id: 2, fullName: "stale/repo", ownerLogin: "stale", summary: nil,
                 stargazersCount: 0, forksCount: 0, language: nil,
                 htmlURL: URL(string: "https://github.com/stale/repo")!)
        ]
        let freshResult: [Repo] = .fixture
        let client = KeyedGatedGitHubClient(repos: ["first": staleResult, "second": freshResult])
        let viewModel = SearchViewModel(client: client)

        // The production funnel, not a hand-rolled imitation of it: the
        // second `dispatch` is what cancels the first search, exactly as the
        // debounce sink's next emission would. Driven through `dispatch`
        // rather than Combine's time-based debounce only so the ordering is
        // deterministic.
        let firstSearch = viewModel.dispatch("first")
        try await poll(until: { await client.isPending("first") }, message: "\"first\" request in flight")

        // Arm "second" to resolve the instant its call arrives, then run it
        // to completion — this is the search that should win.
        await client.open("second")
        let secondSearch = viewModel.dispatch("second")
        await secondSearch.value

        #expect(viewModel.state == .loaded(freshResult, isRefreshing: false))

        // `KeyedGatedGitHubClient` honours cancellation (it wraps its
        // continuation in a `withTaskCancellationHandler`), so the cancelled
        // first call throws rather than parking forever. What keeps that
        // throw off the screen is the `guard !Task.isCancelled` in the catch
        // — the property this test pins is "a superseded search cannot
        // clobber the newer one", and the cancellation *flag* is what
        // delivers it. Mutation testing makes the distinction concrete: the
        // error's type is never consulted, so this assertion holds equally
        // whether the client throws `CancellationError` or something else
        // entirely. The complementary guard, for clients that ignore
        // cancellation and return a late success, is covered by
        // `lateResultFromCancelledTaskIsDiscarded` below.
        await client.open("first")
        await firstSearch.value

        #expect(viewModel.state == .loaded(freshResult, isRefreshing: false))
    }

    @Test("a CancellationError on an uncancelled task fails visibly, not silently")
    func rogueCancellationErrorSurfacesAsFailure() async throws {
        // `LiveGitHubClient` maps every `URLError(.cancelled)` to
        // `CancellationError`, and `URLSession` produces that code for
        // teardown that has nothing to do with `Task` cancellation. Keying
        // off the error's *type* therefore swallowed a real failure on a
        // perfectly live task: the screen kept `.loading` forever, with no
        // Retry (it renders only on `.failed`) and the query still recorded
        // as dispatched, so retyping it was filtered out too.
        let client = RogueCancellationGitHubClient(failures: 1)
        let viewModel = SearchViewModel(client: client, debounceInterval: .milliseconds(50))

        viewModel.searchText = "swift"
        try await poll(
            until: { if case .failed = viewModel.state { true } else { false } },
            message: "the rogue CancellationError to surface as .failed"
        )

        // `lastDispatchedQuery` is private, so it is asserted the way the user
        // experiences it: retyping the identical text has to reach the client
        // a second time. If the key were still pinned, the `filter` in `init`
        // would drop this and the state would never advance.
        viewModel.searchText = "swift"
        try await poll(
            until: { viewModel.state == .loaded(.fixture, isRefreshing: false) },
            message: "the identical query to run again after the failure"
        )
        #expect(await client.queries == ["swift", "swift"])
    }

    @Test("a client that ignores cancellation still can't clobber state")
    func lateResultFromCancelledTaskIsDiscarded() async throws {
        let staleResult: [Repo] = [
            Repo(id: 3, fullName: "late/repo", ownerLogin: "late", summary: nil,
                 stargazersCount: 0, forksCount: 0, language: nil,
                 htmlURL: URL(string: "https://github.com/late/repo")!)
        ]
        let client = UncancellableGatedGitHubClient(repos: staleResult)
        let viewModel = SearchViewModel(client: client)

        let search = viewModel.dispatch("late")
        try await poll(until: { await client.isPending }, message: "request in flight")
        #expect(viewModel.state == .loading)

        // Cancel, then let the client succeed anyway — exactly what a
        // third-party client that never checks `Task.isCancelled` does.
        search.cancel()
        await client.open()
        await search.value

        // The post-`await` guard in `search(matching:)` is the only thing
        // between that late success and the screen. State must not have
        // advanced to `.loaded`.
        #expect(viewModel.state == .loading)
    }

    @Test("startTicker() seeds `now` immediately, then advances it; stopTicker() stops updates")
    func tickerSeedsStartsAndStops() async throws {
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy)
        let nowAtInit = viewModel.now

        // Let the clock move on while the ticker is *not* running, the way it
        // does while the user is on another tab.
        try await Task.sleep(for: .milliseconds(50))
        let beforeStart = Date.now
        viewModel.startTicker()

        // Asserted synchronously, before any tick can have happened:
        // `Timer.publish(every: 1, ...)` doesn't emit for a whole second, so
        // the only thing that can have moved `now` is the seed in
        // `startTicker()`. Without it the footer showed a stale
        // "Updated 0s ago" for that whole second after returning to the tab.
        #expect(viewModel.now >= beforeStart)
        #expect(viewModel.now > nowAtInit)

        let seeded = viewModel.now
        // `Timer.publish(every: 1, ...)` ticks on wall-clock seconds, so give
        // it a few seconds of headroom rather than racing the first tick.
        try await poll(until: { viewModel.now != seeded }, timeout: .seconds(4), message: "now to advance after the seed")

        viewModel.stopTicker()
        let stoppedNow = viewModel.now
        // Bounded negative check, same spirit as the rest of the suite: this
        // can't prove the ticker never fires again, only that it produces no
        // further update within this window, which is as much as a
        // deterministic test can honestly claim about "stopped".
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(viewModel.now == stoppedNow)
    }

    @Test("startTicker() while already ticking does nothing at all")
    func doubleStartTickerIsANoOp() {
        // What the guard in `startTicker()` protects, precisely.
        //
        // It is *not* a leaked subscription, and the previous version of this
        // test could not have failed: `tickerCancellable` is an
        // `AnyCancellable`, and assigning a second one over it releases the
        // first, whose `deinit` cancels it. Even with the guard deleted there
        // is only ever one live timer, so "stop once and watch `now` keep
        // advancing" describes something that cannot happen.
        //
        // What the guard actually prevents is the *re-seed*: the second call
        // would rewrite `now` and restart the timer's phase, so a view that
        // sends `.onAppear` twice (a tab switched away and back inside one
        // second, a re-parented view) would move the clock the footer reads
        // for no reason. Asserting on the seed is fast, deterministic, and
        // fails the moment the guard goes.
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy)

        viewModel.startTicker()
        let seeded = viewModel.now
        viewModel.startTicker()

        #expect(viewModel.now == seeded)
        viewModel.stopTicker()
    }

    @Test("stopTicker() on a view model that never started is harmless")
    func stopTickerWithoutStartDoesNotCrash() {
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy)
        let before = viewModel.now

        // The view lifecycle can produce this: `.onDisappear` fires for a
        // screen whose `.onAppear` never ran.
        viewModel.stopTicker()
        viewModel.stopTicker()

        #expect(viewModel.now == before)
    }

    @Test("refreshed description reports whole seconds, and inflects for one")
    func refreshedDescription() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        // This suite runs twice — `testExample.xctestplan` has an English
        // configuration and a German one — and this is the one test whose
        // output is a *localized* string, so it is the one test that has to
        // know which run it is in. That is not an inconvenience to work
        // around: a plural rule is exactly the kind of thing that is correct
        // in the development language and wrong everywhere else, and only a
        // run in the other language can catch it.
        let expected: (fortyTwo: String, one: String, zero: String) =
            Locale.current.language.languageCode?.identifier == "de"
            ? ("Vor 42 Sekunden aktualisiert", "Vor 1 Sekunde aktualisiert", "Vor 0 Sekunden aktualisiert")
            : ("Updated 42 seconds ago", "Updated 1 second ago", "Updated 0 seconds ago")

        #expect(SearchViewModel.refreshedDescription(from: base, now: base.addingTimeInterval(42)) == expected.fortyTwo)
        // The singular comes from the catalog's plural variations, not from
        // any branch in the code — which is the point of testing it. If the
        // `one` variation is ever dropped, the language silently regresses to
        // "Updated 1 seconds ago" / "Vor 1 Sekunden aktualisiert" and only
        // this assertion notices.
        #expect(SearchViewModel.refreshedDescription(from: base, now: base.addingTimeInterval(1)) == expected.one)
        #expect(SearchViewModel.refreshedDescription(from: base, now: base) == expected.zero)
        #expect(SearchViewModel.refreshedDescription(from: nil, now: base) == nil)
    }

    @Test("rapid typing coalesces into a single request for the final text")
    func rapidTypingCoalesces() async throws {
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy, debounceInterval: .milliseconds(50))

        viewModel.searchText = "s"
        viewModel.searchText = "sw"
        viewModel.searchText = "swift"

        try await poll(until: { viewModel.state == .loaded(.fixture, isRefreshing: false) }, message: "state == .loaded")
        #expect(await spy.queries == ["swift"])
    }

    @Test("after a success, re-submitting the same text does not re-search")
    func unchangedTextDoesNotResearchAfterSuccess() async throws {
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy, debounceInterval: .milliseconds(50))

        viewModel.searchText = "swift"
        try await poll(until: { viewModel.state == .loaded(.fixture, isRefreshing: false) }, message: "first load")

        // Re-assigning the same value still fires `searchText`'s `didSet`, so
        // the pipeline genuinely sees a second "swift". It is the
        // `lastDispatchedQuery` filter — not `removeDuplicates()`, which is
        // gone — that drops it.
        viewModel.searchText = "swift"
        // Give the pipeline time to (wrongly) fire again before asserting.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await spy.queries == ["swift"])
    }

    @Test("after a failure, re-submitting the same text does re-search")
    func sameTextResearchesAfterFailure() async throws {
        // The bug `removeDuplicates()` shipped: a search that failed was
        // literally unrepeatable by typing. The user had to change the text
        // and change it back to get another attempt at the identical query.
        let client = ScriptedGitHubClient(
            script: [.failure(.rateLimited), .success(.fixture)]
        )
        let viewModel = SearchViewModel(client: client, debounceInterval: .milliseconds(50))

        viewModel.searchText = "swift"
        try await poll(
            until: { viewModel.state == .failed(message: GitHubClientError.rateLimited.errorDescription ?? "", stale: nil) },
            message: "first attempt to fail"
        )

        viewModel.searchText = "swift"
        try await poll(
            until: { viewModel.state == .loaded(.fixture, isRefreshing: false) },
            message: "the identical query to run again"
        )
        #expect(await client.queries == ["swift", "swift"])
    }

    @Test("retry() re-runs the failed query and can recover")
    func retryRecoversFromFailure() async throws {
        let client = ScriptedGitHubClient(
            script: [.failure(.rateLimited), .success(.fixture)]
        )
        let viewModel = SearchViewModel(client: client, debounceInterval: Self.neverFires)
        viewModel.searchText = "swift"

        await viewModel.dispatch("swift").value
        #expect(viewModel.state == .failed(message: GitHubClientError.rateLimited.errorDescription ?? "", stale: nil))

        viewModel.retry()
        try await poll(
            until: { viewModel.state == .loaded(.fixture, isRefreshing: false) },
            message: "retry to succeed"
        )
        #expect(await client.queries == ["swift", "swift"])
    }

    @Test("retry() with a cleared search field returns to idle")
    func retryAfterClearingGoesIdle() async throws {
        // Documents a real edge: the error view stays on screen while the
        // user empties the search field, so Retry can be tapped with nothing
        // to search for. The right answer is the idle prompt, not a request
        // for the empty string.
        let client = ScriptedGitHubClient(script: [.failure(.rateLimited)])
        let viewModel = SearchViewModel(client: client, debounceInterval: Self.neverFires)
        viewModel.searchText = "swift"

        await viewModel.dispatch("swift").value
        #expect(viewModel.state == .failed(message: GitHubClientError.rateLimited.errorDescription ?? "", stale: nil))

        viewModel.searchText = ""
        viewModel.retry()

        try await poll(until: { viewModel.state == .idle }, message: "state == .idle")
        #expect(await client.queries == ["swift"])
    }

    @Test("submitImmediately() bypasses the debounce and de-dupes the pending emission")
    func submitImmediatelyBypassesDebounce() async throws {
        let spy = SpyGitHubClient(result: .success(.fixture))
        // Long enough that the pipeline's own emission lands well after the
        // manual submit, which is the race `submitImmediately()` has to win.
        let viewModel = SearchViewModel(client: spy, debounceInterval: .milliseconds(200))

        viewModel.searchText = "swift"
        viewModel.submitImmediately()

        try await poll(
            until: { viewModel.state == .loaded(.fixture, isRefreshing: false) },
            message: "the immediate submit to land"
        )
        // The debounce emission for "swift" is still pending here; wait it
        // out and confirm the filter dropped it instead of firing a second
        // identical request.
        try await Task.sleep(for: .milliseconds(400))
        #expect(await spy.queries == ["swift"])
    }

    @Test("retry() suppresses the debounce emission that follows it")
    func retryDedupesTheFollowingEmission() async throws {
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy, debounceInterval: .milliseconds(50))

        viewModel.searchText = "swift"
        try await poll(until: { viewModel.state == .loaded(.fixture, isRefreshing: false) }, message: "first load")

        // Retry, then an identical keystroke inside the debounce window — the
        // shape a user produces by tapping Retry and touching the field. Retry
        // goes through `dispatch(_:)`, which writes the key before the request
        // leaves, so the emission that lands 50ms later is filtered rather
        // than racing a duplicate request onto the wire.
        viewModel.retry()
        viewModel.searchText = "swift"

        try await Task.sleep(for: .milliseconds(300))
        #expect(await spy.queries == ["swift", "swift"])
    }

    @Test("a trailing space is not a new query, in either direction")
    func trailingWhitespaceDoesNotRefire() async throws {
        // The dedup key and the request it stands for must be the same
        // string. Keying on the raw field text let "swift " past a key of
        // "swift" and fired a second, identical request — the user added a
        // space and paid for a whole round trip.
        //
        // Both directions, because they pin *different* trims and a test that
        // only walks one of them passes with the other deleted. Padding after
        // a bare query exercises the `filter`'s trim of the candidate; the
        // reverse — a padded query first, then the bare one — exercises
        // `dispatch(_:)`'s trim of the key it stores.
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy, debounceInterval: .milliseconds(50))

        viewModel.searchText = "swift"
        try await poll(until: { viewModel.state == .loaded(.fixture, isRefreshing: false) }, message: "first load")

        viewModel.searchText = "swift "
        try await Task.sleep(for: .milliseconds(300))
        #expect(await spy.queries == ["swift"])
    }

    @Test("a query typed with padding first is not re-fired once the padding goes")
    func leadingPaddedQueryDoesNotRefireWhenTrimmed() async throws {
        // The direction the test above cannot cover. The key recorded for
        // "swift " has to be the trimmed "swift", or removing the space reads
        // as a different query and re-runs a search whose results are already
        // on screen. Note what the client receives, too: `search(matching:)`
        // sends the trimmed text, so the request and the key describe the same
        // string end to end.
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy, debounceInterval: .milliseconds(50))

        viewModel.searchText = "swift "
        try await poll(until: { viewModel.state == .loaded(.fixture, isRefreshing: false) }, message: "first load")
        #expect(await spy.queries == ["swift"])

        viewModel.searchText = "swift"
        try await Task.sleep(for: .milliseconds(300))
        #expect(await spy.queries == ["swift"])
    }
}
