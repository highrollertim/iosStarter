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

        #expect(viewModel.state == .failed(message: GitHubClientError.rateLimited.errorDescription ?? ""))
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

    @Test("refreshed description reports whole seconds, and inflects for one")
    func refreshedDescription() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(SearchViewModel.refreshedDescription(from: base, now: base.addingTimeInterval(42)) == "Updated 42 seconds ago")
        // The singular comes from the catalog's plural variations, not from
        // any branch in the code — which is the point of testing it. If the
        // `one` variation is ever dropped, English silently regresses to
        // "Updated 1 seconds ago" and only this assertion notices.
        #expect(SearchViewModel.refreshedDescription(from: base, now: base.addingTimeInterval(1)) == "Updated 1 second ago")
        #expect(SearchViewModel.refreshedDescription(from: base, now: base) == "Updated 0 seconds ago")
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
            until: { viewModel.state == .failed(message: GitHubClientError.rateLimited.errorDescription ?? "") },
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
        #expect(viewModel.state == .failed(message: GitHubClientError.rateLimited.errorDescription ?? ""))

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
        #expect(viewModel.state == .failed(message: GitHubClientError.rateLimited.errorDescription ?? ""))

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

    @Test("a trailing space is not a new query")
    func trailingWhitespaceDoesNotRefire() async throws {
        // The dedup key and the request it stands for must be the same
        // string. Keying on the raw field text let "swift " past a key of
        // "swift" and fired a second, identical request — the user added a
        // space and paid for a whole round trip.
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy, debounceInterval: .milliseconds(50))

        viewModel.searchText = "swift"
        try await poll(until: { viewModel.state == .loaded(.fixture, isRefreshing: false) }, message: "first load")

        viewModel.searchText = "swift "
        try await Task.sleep(for: .milliseconds(300))
        #expect(await spy.queries == ["swift"])
    }
}
