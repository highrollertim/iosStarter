import Foundation
import Testing
@testable import testExample

/// Records queries and returns a canned result.
///
/// An actor, not a class-with-a-lock: test doubles are a natural place to
/// demonstrate that actors are the default answer for mutable shared state.
actor SpyGitHubClient: GitHubClient {
    private(set) var queries: [String] = []
    private let result: Result<[Repo], GitHubClientError>

    init(result: Result<[Repo], GitHubClientError>) {
        self.result = result
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        queries.append(query)
        return try result.get()
    }
}

/// Suspends every request until the test calls `open()`, letting tests
/// observe in-flight (`.loading`) state deterministically — no sleeps.
actor GatedGitHubClient: GitHubClient {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private let repos: [Repo]

    init(repos: [Repo]) {
        self.repos = repos
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        await withCheckedContinuation { continuations.append($0) }
        return repos
    }

    func open() {
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

extension [Repo] {
    static let fixture: [Repo] = [
        Repo(id: 1, fullName: "apple/swift", ownerLogin: "apple",
             summary: "The Swift Programming Language",
             stargazersCount: 67000, forksCount: 10000,
             language: "C++", htmlURL: URL(string: "https://github.com/apple/swift")!)
    ]
}

/// Polls a main-actor condition until it holds or the timeout elapses.
/// Records a test failure on timeout so callers read linearly.
@MainActor
func poll(
    until condition: () -> Bool,
    timeout: Duration = .seconds(2),
    message: @autoclosure () -> String = "condition"
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(message())")
}
