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

/// Gates calls by query key, and can be armed before a call arrives
/// (`open(_:)` called first) or release one already in flight (`open(_:)`
/// called after). Lets a test run two overlapping searches and control
/// precisely which one resolves first — the shape needed to prove a
/// superseded, still in-flight search cannot clobber a newer search's
/// result once it's finally released.
actor KeyedGatedGitHubClient: GitHubClient {
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var preOpened: Set<String> = []
    private let repos: [String: [Repo]]

    init(repos: [String: [Repo]]) {
        self.repos = repos
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        if preOpened.remove(query) == nil {
            await withCheckedContinuation { continuations[query] = $0 }
        }
        return repos[query] ?? []
    }

    /// Resumes the call for `query` if it's already suspended; otherwise
    /// arms it to resolve immediately the moment it arrives.
    func open(_ query: String) {
        if let continuation = continuations.removeValue(forKey: query) {
            continuation.resume()
        } else {
            preOpened.insert(query)
        }
    }

    /// True once `searchRepositories(matching: query)` has suspended
    /// waiting for `open(_:)` — lets a test wait for a call to be truly
    /// in flight before proceeding, deterministically.
    func isPending(_ query: String) -> Bool {
        continuations[query] != nil
    }
}

/// A `URLProtocol` that answers every request with a canned response instead
/// of touching the network.
///
/// The technique: register this class on a dedicated `URLSessionConfiguration`
/// (not `.shared`), point `LiveGitHubClient(session:)` at the resulting
/// session, and set `handler` before each call. `URLSession` hands every
/// request for that session to `canInit`/`startLoading` on this type instead
/// of a real socket, so tests exercise `LiveGitHubClient`'s actual response
/// and error handling — status codes, malformed bodies — with no real HTTP
/// traffic and no flakiness from an actual network.
///
/// `handler` is `nonisolated(unsafe)` because `URLProtocol`'s loading
/// callbacks aren't `Sendable`-checked, and it's fine here: the suites that
/// use it are `.serialized` (see `LiveGitHubClientErrorMappingTests`), so
/// only one test is ever touching `handler` at a time.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No in-flight work to cancel — `startLoading()` above is synchronous.
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

/// Same semantics as the synchronous overload above, for conditions that
/// must themselves suspend (e.g. querying an actor). Kept as a distinct
/// overload — rather than making the sync one `async` everywhere — so
/// existing synchronous call sites stay exactly as simple as they were.
@MainActor
func poll(
    until condition: () async -> Bool,
    timeout: Duration = .seconds(2),
    message: @autoclosure () -> String = "condition"
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(message())")
}
