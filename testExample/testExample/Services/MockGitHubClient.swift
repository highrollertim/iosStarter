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
        /// to succeed immediately and no error to retry. Keying on the query
        /// makes the scenario independent of typing speed.
        case searchErrorOnce
    }

    let scenario: Scenario

    /// Queries that have already been failed once by `searchErrorOnce`. Only
    /// that scenario reads it, but it is the reason this type is an actor.
    private var failedQueries: Set<String> = []

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
        try await Task.sleep(for: .milliseconds(300))

        switch scenario {
        case .success:
            return Self.fixtureRepos
        case .searchError:
            throw GitHubClientError.rateLimited
        case .emptyResults:
            return []
        case .searchErrorOnce:
            // Recorded after the sleep, so a cancelled call never spends this
            // query's one failure on a request that no UI ever saw.
            if failedQueries.insert(query).inserted {
                throw GitHubClientError.rateLimited
            }
            return Self.fixtureRepos
        }
    }
}
#endif
