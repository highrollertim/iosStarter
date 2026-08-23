import Combine
import Foundation
import Observation

/// Owns the search screen's state and its debounced search pipeline.
///
/// This is the app's only view model — the other screens have no async
/// orchestration, so they don't pay for one. `@Observable` (not
/// `ObservableObject`) is the 2026 baseline: views track exactly the
/// properties they read, no `objectWillChange`, no `@Published`.
///
/// **Isolation, precisely.** This type is `@MainActor` via the project's
/// default isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). That is
/// why the Combine sinks below *type-check* when they touch `state` — but it
/// is emphatically not why they are *safe*. Combine's `sink` takes an
/// ordinary synchronous closure and invokes it on whatever thread the
/// upstream delivers on; the compiler cannot see that thread. What makes
/// these sinks correct is `scheduler: DispatchQueue.main` on the debounce and
/// `on: .main` on the timer. Those two arguments are load-bearing: change
/// either one to a background queue or runloop and the code still compiles
/// clean, then traps at runtime on the main-actor precondition. Marking each
/// closure `@MainActor` explicitly (below) is how we make the compiler check
/// the assumption instead of merely inheriting it.
@Observable
final class SearchViewModel {

    private(set) var state: LoadState<[Repo]> = .idle
    private(set) var lastRefreshed: Date?
    /// Ticks once per second while `startTicker()` has been called, so
    /// "Updated Ns ago" stays current. Scoped, not free-running — see
    /// `startTicker()`/`stopTicker()`.
    private(set) var now: Date = .now

    /// Bound to the search field. Each keystroke feeds the Combine pipeline.
    var searchText: String = "" {
        didSet { querySubject.send(searchText) }
    }

    private let client: any GitHubClient
    private let querySubject = PassthroughSubject<String, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    /// The query most recently handed to `search(matching:)`, by *any* route —
    /// the debounce sink, `retry()`, or `submitImmediately()`. It is the
    /// pipeline's deduplication key; see the `filter` in `init` for why this
    /// replaced `removeDuplicates()`.
    private var lastDispatchedQuery: String?
    /// Owns the "updated N seconds ago" ticker's sink, separately from
    /// `cancellables`, so `stopTicker()` can tear down just this one
    /// publisher on demand instead of the fixed, init-time set below.
    private var tickerCancellable: AnyCancellable?

    /// `debounceInterval` is injectable so tests can shrink it from 300ms to
    /// 50ms — tune the constant without rewriting the tests.
    init(
        client: any GitHubClient,
        debounceInterval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(300)
    ) {
        self.client = client

        // WHY COMBINE HERE: keystrokes are a *stream of events over time*,
        // and debounce is exactly the stream algebra that is tedious to
        // hand-roll with Task.sleep and cancellation flags. For one-shot
        // async work we use async/await (see LiveGitHubClient); for event
        // streams, Combine still earns its keep.
        //
        // WHY `filter`, NOT `removeDuplicates()`: this is the more useful
        // lesson. `removeDuplicates()` dedups on the *input* — it drops any
        // value equal to the previous one, no matter what happened to the
        // work that value triggered. That is only sound when the operation is
        // deterministic, and a network search is not: the same text can fail
        // once and succeed the next time. With `removeDuplicates()`, a search
        // that failed became literally unrepeatable by typing — you had to
        // change the text and change it back. Deduping against
        // `lastDispatchedQuery` instead moves the decision to the *outcome*:
        // the value is cleared whenever a search fails, so re-submitting the
        // same text after a failure re-fires, while re-submitting it after a
        // success still doesn't. It also closes the other half of the bug —
        // `retry()` sets `lastDispatchedQuery` too, so a debounce emission
        // still in flight when the user taps Retry is filtered here instead
        // of racing a second identical request onto the wire.
        querySubject
            // load-bearing: `scheduler: DispatchQueue.main` is what actually
            // puts the `filter` and `sink` closures below on the main actor.
            // The `@MainActor` annotations on them are assertions about this
            // argument, not substitutes for it.
            .debounce(for: debounceInterval, scheduler: DispatchQueue.main)
            .filter { @MainActor [weak self] query in query != self?.lastDispatchedQuery }
            .sink { @MainActor [weak self] query in
                guard let self else { return }
                lastDispatchedQuery = query
                searchTask?.cancel()
                searchTask = Task { await self.search(matching: query) }
            }
            .store(in: &cancellables)
    }

    /// Starts the "updated N seconds ago" ticker: a second, tiny Combine
    /// example, deliberately *not* wired up in `init`.
    ///
    /// A `Timer.publish` subscription that starts in `init` would run for
    /// this object's entire lifetime — and this view model, once built by
    /// the composition root, lives for as long as the app does, not just
    /// while the search tab is on screen. An init-started timer would keep
    /// firing once a second on every other tab, invalidating this object's
    /// observable state (and therefore any view that reads it) every second
    /// for no reason. Instead, the view that actually needs the ticker
    /// starts it on `.onAppear` and stops it on `.onDisappear` (see
    /// `SearchView`), so the publisher's lifetime matches the lifetime of
    /// the UI that displays its output — the deliberate lesson here is
    /// publisher lifecycle management, not just "Combine can wrap a timer".
    ///
    /// Guards against double-starting: calling this while already ticking
    /// is a no-op rather than leaking a second subscription.
    func startTicker() {
        guard tickerCancellable == nil else { return }
        // Seed `now` before subscribing. `Timer.publish` does not emit
        // immediately — the first tick is a whole second away — and `now` has
        // been frozen since the last `stopTicker()`. Without this line,
        // leaving the tab for a minute and coming back displayed a stale
        // "Updated 0s ago" (or worse, a negative interval clamped to 0) for
        // one full second before the first tick corrected it.
        now = .now
        tickerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            // load-bearing: `on: .main` schedules the timer on the main
            // runloop, which is what makes the `@MainActor` sink below sound.
            .autoconnect()
            .sink { @MainActor [weak self] date in
                self?.now = date
            }
    }

    /// Stops the ticker and releases its subscription. Safe to call even if
    /// the ticker was never started.
    func stopTicker() {
        tickerCancellable?.cancel()
        tickerCancellable = nil
    }

    /// The single path from "query" to "state". Also called directly by the
    /// retry button and by unit tests — the debounce pipeline is just one
    /// caller among several.
    func search(matching query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .idle
            // Clearing the dedup key here means clearing the field and
            // retyping the same query searches again, rather than being
            // silently swallowed as a duplicate.
            lastDispatchedQuery = nil
            return
        }

        guard !Task.isCancelled else { return }

        // Stale-while-revalidate: if results are already on screen, keep them
        // there and just flag the refresh. Only a genuine first load blanks
        // the screen to a spinner. This is the state the naive four-case load
        // enum cannot express — see `LoadState`.
        if case .loaded(let existing, _) = state {
            state = .loaded(existing, isRefreshing: true)
        } else {
            state = .loading
        }

        do {
            let repos = try await client.searchRepositories(matching: trimmed)
            // INVARIANT: this check cannot go stale. `self` is `@MainActor`,
            // so the only code that can cancel `searchTask` runs on the main
            // actor, and there is no suspension point between this `guard`
            // and the writes below — the main actor cannot be re-entered in
            // between. A cancellation racing us therefore either lands before
            // the check (and we return) or after the writes (and the state is
            // already the newer search's problem, not ours). Without that
            // reasoning this would be a classic TOCTOU.
            guard !Task.isCancelled else { return }
            state = .loaded(repos, isRefreshing: false)
            lastRefreshed = .now
        } catch is CancellationError {
            // A newer search superseded this one; its results own the screen.
            // Deliberately does *not* clear `lastDispatchedQuery`: the newer
            // search already owns it.
        } catch {
            guard !Task.isCancelled else { return }
            // A failed query is repeatable — forget that we dispatched it so
            // the `filter` in `init` lets the identical text through again.
            lastDispatchedQuery = nil
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    /// Dispatches `searchText` right now, bypassing the debounce.
    ///
    /// Bound to `.onSubmit(of: .search)`: once the user has pressed Return
    /// they have told us the query is finished, so making them wait out a
    /// 300ms debounce is pure latency. Recording `lastDispatchedQuery` before
    /// dispatching is what stops the debounce emission that is *already* in
    /// flight from firing the same search a second time when it lands.
    func submitImmediately() {
        lastDispatchedQuery = searchText
        searchTask?.cancel()
        searchTask = Task { [searchText] in await self.search(matching: searchText) }
    }

    /// Re-runs the current query after a failure. Identical to a manual
    /// submit — including the debounce bypass and the dedup bookkeeping —
    /// so it delegates rather than duplicating the logic.
    func retry() {
        submitImmediately()
    }

    var lastRefreshedDescription: String? {
        Self.refreshedDescription(from: lastRefreshed, now: now)
    }

    /// Pure and static so the formatting logic is trivially unit-testable.
    nonisolated static func refreshedDescription(from lastRefreshed: Date?, now: Date) -> String? {
        guard let lastRefreshed else { return nil }
        // `max(0, ...)` is belt and braces. Since `startTicker()` seeds `now`
        // it should never fire, but a clamped 0 beats "Updated -1s ago" if
        // the wall clock ever moves backwards under us.
        let seconds = max(0, Int(now.timeIntervalSince(lastRefreshed)))
        // Spelled out ("42 seconds") rather than abbreviated ("42s") because
        // this string has plural variations in the catalog, and a language
        // that inflects the *noun* needs a noun to inflect. English gets away
        // with "42s" for every count; German, Russian and Arabic do not, and
        // an abbreviation gives their translators nothing to work with.
        return String(
            localized: "Updated \(seconds) seconds ago",
            comment: "Footer under the search results list, showing how long ago the results arrived. Has plural variations."
        )
    }

    private func userFacingMessage(for error: any Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return String(
            localized: "Something went wrong. Please try again.",
            comment: "Fallback error message shown on the search screen when a failure carries no more specific description."
        )
    }
}
