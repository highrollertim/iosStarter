import Foundation

#if DEBUG
/// Deterministic `GitHubClient` for previews and UI tests.
///
/// Lives in the app target (not the test bundle) because previews and
/// UI-test launches execute the real app binary. The `#if DEBUG` guard keeps
/// it out of release builds.
///
/// An `actor`, not a `struct`, because the interesting scenarios need to
/// *remember* things across calls — `searchErrorOnce` fails the first search
/// for each query and succeeds afterwards, which requires mutable state
/// reachable from whatever executor the caller happens to be on. An actor is
/// the default answer for that; a `struct` couldn't hold it at all and a
/// `final class` would need a lock and a `@unchecked Sendable` promise.
actor MockGitHubClient: GitHubClient {
    /// Scenario names arrive from UI tests via the `UITEST_SCENARIO`
    /// environment variable, hence `String` raw values. These strings are a
    /// contract with `XCUIApplication.launchedForUITest(scenario:)` — renaming
    /// a case silently reroutes a UI test to `.success`.
    enum Scenario: String, Sendable {
        case success
        case searchError
        /// A successful search that simply matched nothing — the path to
        /// `ContentUnavailableView.search`, which no error scenario reaches.
        case emptyResults
        /// Fails the first completed search *for each distinct query*, and
        /// succeeds on every one after it. Exists so a UI test can prove the
        /// Retry button actually *recovers*, not merely that it exists.
        ///
        /// Per query, not per client, because typing is a stream: searching
        /// "swift" produces debounce emissions for prefixes too, and a slow
        /// typist whose "s" completed before "swift" did would burn the one
        /// failure on a query the test never asserts about — leaving "swift"
        /// to succeed immediately and no error to retry.
        ///
        /// Precisely what per-query keying buys: a prefix can no longer
        /// *consume* the failure earmarked for the query under test. It does
        /// not stop a prefix from failing on its own account and putting a
        /// banner on screen before the query under test has run — that banner
        /// is real, and a test that asserts on the *absence* of an error has
        /// to reckon with it.
        case searchErrorOnce
        /// The mirror image of `searchErrorOnce`: for each distinct query, the
        /// first completed call **succeeds** and every later call for that
        /// same query fails.
        ///
        /// The state it exists to reach is the one no other scenario can — a
        /// failure with results still on screen — and then the retry *from*
        /// that state. Keyed per query for the same reason as above: a prefix
        /// emission that completes cannot spend the query-under-test's one
        /// success, so the flow does not depend on how fast the test types.
        /// Because every call after the first for a query fails, a retry
        /// always fails too — which makes "the rows and the banner both
        /// survive a retry" the assertion this scenario supports.
        case searchSucceedsThenFails
    }

    let scenario: Scenario

    /// Queries that have already been failed once by `searchErrorOnce`. Only
    /// that scenario reads it, but it is the reason this type is an actor.
    private var failedQueries: Set<String> = []

    /// Queries that have already been succeeded once by
    /// `searchSucceedsThenFails`. Same bookkeeping, opposite polarity.
    private var succeededQueries: Set<String> = []

    init(scenario: Scenario = .success) {
        self.scenario = scenario
    }

    /// Fixed results regardless of query — determinism beats realism in
    /// tests.
    static let fixtureRepos: [Repo] = [
        Repo(id: 1, fullName: "apple/swift", ownerLogin: "apple",
             summary: "The Swift Programming Language",
             stargazersCount: 67000, forksCount: 10000,
             language: "C++", htmlURL: URL(string: "https://github.com/apple/swift")!),
        Repo(id: 2, fullName: "swiftlang/swift-testing", ownerLogin: "swiftlang",
             summary: "A modern, expressive testing package for Swift",
             stargazersCount: 2000, forksCount: 300,
             language: "Swift", htmlURL: URL(string: "https://github.com/swiftlang/swift-testing")!),
        Repo(id: 3, fullName: "vapor/vapor", ownerLogin: "vapor",
             summary: "A server-side Swift HTTP web framework",
             stargazersCount: 25000, forksCount: 1500,
             language: "Swift", htmlURL: URL(string: "https://github.com/vapor/vapor")!),
    ]

    func searchRepositories(matching query: String) async throws -> [Repo] {
        // A short artificial delay keeps loading states visible and exercises
        // the async path. It is deliberately *before* the scenario switch:
        // `Task.sleep` throws on cancellation, so a superseded call (the
        // debounce sink cancels the previous task on every keystroke) exits
        // here and never records anything. Cancellation is not one of the
        // scenarios; it is the thing that happens instead of one.
        //
        // "Never records anything" is a claim about the window, not a
        // guarantee: this narrows it to a single actor hop. A cancellation
        // that lands after the sleep returns still spends this query's
        // outcome, because nothing between here and the `switch` looks at the
        // flag — and `SearchViewModel`'s `catch` swallows the resulting
        // failure, so nothing on screen says so either.
        try await Task.sleep(for: .milliseconds(300))

        switch scenario {
        case .success:
            return Self.fixtureRepos
        case .searchError:
            throw GitHubClientError.rateLimited
        case .emptyResults:
            return []
        case .searchErrorOnce:
            // Recorded after the sleep, so a call cancelled during it never
            // spends this query's one failure on a request no UI ever saw.
            if failedQueries.insert(query).inserted {
                throw GitHubClientError.rateLimited
            }
            return Self.fixtureRepos
        case .searchSucceedsThenFails:
            if succeededQueries.insert(query).inserted {
                return Self.fixtureRepos
            }
            throw GitHubClientError.rateLimited
        }
    }
}
#endif
