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
/// closure `@MainActor` explicitly (below) is what inserts that *dynamic*
/// check — nothing here is verified at compile time, and the trap is the
/// point: a wrong scheduler fails loudly instead of quietly corrupting
/// main-actor state.
@Observable
final class SearchViewModel {

    private(set) var state: LoadState<[Repo]> = .idle
    private(set) var lastRefreshed: Date?
    /// The trimmed query behind the results currently in `state`, or `nil`
    /// when nothing has completed.
    ///
    /// Lives beside `state` rather than inside `LoadState` on purpose:
    /// `LoadState` is a generic lifecycle enum and knows nothing about
    /// searching. What needs it is the empty-results screen, whose title has
    /// to name the query that *produced* the empty set — `searchText` is the
    /// live field, still ahead of the debounce, so titling with it shows a
    /// query nobody has run yet.
    private(set) var lastCompletedQuery: String?
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
    /// The one in-flight search. `dispatch(_:)` is the only writer *of this
    /// variable*, which is what makes "cancel the previous search" a complete
    /// statement rather than a hope: there is no route to `search(matching:)`
    /// that leaves a task nobody holds. It says nothing about the task's
    /// lifetime — the task stored here may already have finished, and anyone
    /// holding the value `dispatch(_:)` returned can cancel it from any
    /// executor.
    private var searchTask: Task<Void, Never>?
    /// The trimmed query most recently dispatched. It is the pipeline's
    /// deduplication key; see the `filter` in `init` for why this replaced
    /// `removeDuplicates()`.
    ///
    /// Trimmed, and compared against a trimmed candidate, so the key and the
    /// request it stands for are the same string: keying on the raw text
    /// would let "swift " past a key of "swift" and fire a second identical
    /// request for a query the user only refined by a space.
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
            .filter { @MainActor [weak self] query in
                // Trimmed on both sides: `lastDispatchedQuery` holds the
                // trimmed text, so the candidate has to be trimmed too or a
                // trailing space reads as a different query.
                query.trimmingCharacters(in: .whitespacesAndNewlines) != self?.lastDispatchedQuery
            }
            .sink { @MainActor [weak self] query in
                self?.dispatch(query)
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

    /// The one way to start a search. Every route in — the debounce sink,
    /// `submitImmediately()`, `retry()`, pull-to-refresh — goes through here.
    ///
    /// Funnelling them is what makes the two invariants below true rather
    /// than merely usual:
    ///
    /// - **Every in-flight search *is* `searchTask`.** A caller that started
    ///   its own `Task` would be invisible to the cancellation on the next
    ///   line, and the "newest search wins" design rests on that cancellation.
    /// - **The dedup key always describes the search that is actually
    ///   running.** Recording it here, before the work begins, is what stops
    ///   a debounce emission already in flight from firing the same query a
    ///   second time when it lands.
    ///
    /// Returns the task so callers who need to wait — `.refreshable`, unit
    /// tests — can, without having to reach for `searchTask` themselves.
    @discardableResult
    func dispatch(_ query: String) -> Task<Void, Never> {
        lastDispatchedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        let task = Task { await self.search(matching: query) }
        searchTask = task
        return task
    }

    /// The single path from "query" to "state". Private: reaching it without
    /// going through `dispatch(_:)` would break both of that method's
    /// invariants.
    private func search(matching query: String) async {
        // Above the blank guard, not below it, and that ordering is the whole
        // point. A cancelled task has no business writing state — and the
        // blank path was the one place one could: `dispatch("")` immediately
        // followed by `dispatch("swift")` on the same main-actor turn schedules
        // the blank task, cancels it, then lets it run anyway, where it nil'd
        // the dedup key that the *live* "swift" search had just claimed. The
        // next identical keystroke then sailed through the `filter` and paid
        // for a duplicate round trip.
        guard !Task.isCancelled else { return }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .idle
            lastCompletedQuery = nil
            // Belt and braces for any future caller that reaches this method
            // without going through `dispatch(_:)`. It is not what makes
            // retyping a cleared field work: `dispatch(_:)` writes the key
            // before this runs, and a blank query trims to "", so clearing
            // the field and retyping the same text is already two different
            // keys as far as the `filter` is concerned.
            lastDispatchedQuery = nil
            return
        }

        // Stale-while-revalidate: if results are on screen, keep them there and
        // just flag the refresh — and "on screen" includes the results under a
        // failure banner. Retry from that banner re-enters here with state
        // `.failed(_, stale:)`; reading only `.loaded` would blank the exact
        // results the banner promised to preserve, and a second failure would
        // then drop them permanently.
        //
        // The promotion is gated on `trimmed == lastCompletedQuery`, because it
        // is only sound for *retrying the query those stale rows answer*.
        // Ungated, a brand-new query typed from a failure screen resurrected
        // the previous query's rows and showed them as its own — one search's
        // results labelled as another's, with a spinner claiming they were
        // being refreshed. Under rate limiting that compounds: every subsequent
        // failure carries the same ancient rows forward again, and the screen
        // drifts further from anything the user asked for. A new query with no
        // history of its own has nothing to keep, and the blank screen is the
        // correct answer for it.
        //
        // `staleResults` is produced *by* the branch that decides the state, so
        // "the failure restores exactly the rows this search was refining" is
        // structural rather than a claim about a later re-read of `state`. The
        // `catch` below runs after an `await`, and reading `state` there would
        // need an argument about who else could have written it meanwhile.
        let staleResults: [Repo]?
        if case .loaded(let existing, _) = state {
            state = .loaded(existing, isRefreshing: true)
            staleResults = existing
        } else if case .failed(_, let stale?) = state, !stale.isEmpty,
                  trimmed == lastCompletedQuery {
            state = .loaded(stale, isRefreshing: true)
            staleResults = stale
        } else {
            state = .loading
            staleResults = nil
        }

        do {
            let repos = try await client.searchRepositories(matching: trimmed)
            // INVARIANT, and it is about *turn atomicity*, not about who may
            // cancel. `Task.cancel()` is `nonisolated` — anyone on any
            // executor can call it, and this suite's own tests do — so the
            // reassuring version of this argument ("only main-actor code can
            // cancel us") is simply false.
            //
            // What holds: this `guard` and the three writes below are one
            // uninterrupted main-actor turn, with no suspension point between
            // them. A cancellation observed after the guard cannot un-write
            // them, and the only canceller in production is a newer
            // `dispatch(_:)`, which has already replaced `searchTask` and will
            // write its own result over ours. So the worst case is a state
            // that is briefly this search's and then immediately the newer
            // search's — never a torn mixture of the two.
            guard !Task.isCancelled else { return }
            state = .loaded(repos, isRefreshing: false)
            lastCompletedQuery = trimmed
            lastRefreshed = .now
        } catch {
            // One catch, and it asks the cancellation *flag*, never the error
            // *type*. A `CancellationError` is not proof that this task was
            // cancelled: `LiveGitHubClient` maps every `URLError(.cancelled)`
            // to one, and `URLSession` raises that for session invalidation
            // and other teardown too. Trusting the type meant an uncancelled
            // task could exit here leaving `.loading` on screen forever —
            // with the query still recorded as dispatched, so Retry never
            // rendered (it lives on `.failed`) and retyping was filtered out.
            //
            // Asking the flag instead covers both: a genuinely superseded
            // search returns silently through the guard, its successor owning
            // both the screen and the dedup key; anything else becomes a
            // `.failed` the user can actually act on.
            guard !Task.isCancelled else { return }
            // A failed query is repeatable — forget that we dispatched it so
            // the `filter` in `init` lets the identical text through again.
            lastDispatchedQuery = nil
            // Results already on screen survive the failure. Blanking them
            // would punish the user for a refinement that failed by throwing
            // away the last thing that worked.
            state = .failed(message: userFacingMessage(for: error), stale: staleResults)
        }
    }

    /// Dispatches `searchText` right now, bypassing the debounce.
    ///
    /// Bound to `.onSubmit(of: .search)`: once the user has pressed Return
    /// they have told us the query is finished, so making them wait out a
    /// 300ms debounce is pure latency. The debounce emission that is
    /// *already* in flight is dropped when it lands, because `dispatch(_:)`
    /// has recorded its query as the dedup key by then.
    func submitImmediately() {
        dispatch(searchText)
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
        // `max(0, ...)` does fire, and not only for a backwards wall clock.
        // The first `body` evaluation happens before `.onAppear` runs
        // `startTicker()`, so `now` is still whatever it was when this object
        // was built — after a long stop that is behind `lastRefreshed`, and
        // the interval is genuinely negative for that one frame. In steady
        // state the clamp is invisible for a different reason: `Int`
        // truncates toward zero, so sub-second lag lands on 0 anyway.
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

    #if DEBUG
    /// Places the view model directly in a given state, for previews.
    ///
    /// Every state below `.idle` is normally reachable only by running a
    /// search against a client that behaves the right way — which previews
    /// cannot do, because a `#Preview` renders once and does not wait out an
    /// async round trip. Without this seam the "Results" and "Error" previews
    /// both rendered the idle prompt: mislabelled, and dead as documentation.
    ///
    /// `#if DEBUG` because it is a testing affordance, not API: it is the one
    /// way to write `state` from outside, and shipping it would undo the
    /// `private(set)` that keeps `search(matching:)` the only writer.
    func setStateForPreviews(_ state: LoadState<[Repo]>, lastCompletedQuery: String? = nil) {
        self.state = state
        self.lastCompletedQuery = lastCompletedQuery
        if case .loaded = state {
            lastRefreshed = .now
        }
    }
    #endif

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
