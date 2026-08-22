import Foundation

#if DEBUG
/// Deterministic `GitHubClient` for previews and UI tests.
///
/// Lives in the app target (not the test bundle) because previews and
/// UI-test launches execute the real app binary. The `#if DEBUG` guard keeps
/// it out of release builds.
nonisolated struct MockGitHubClient: GitHubClient {
    /// Scenario names arrive from UI tests via the `UITEST_SCENARIO`
    /// environment variable, hence `String` raw values.
    enum Scenario: String, Sendable {
        case success
        case searchError
    }

    var scenario: Scenario = .success

    /// Fixed results regardless of query — determinism beats realism in
    /// tests. A short artificial delay keeps loading states visible and
    /// exercises the async path.
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
        try await Task.sleep(for: .milliseconds(300))
        switch scenario {
        case .success:
            return Self.fixtureRepos
        case .searchError:
            throw GitHubClientError.rateLimited
        }
    }
}
#endif
