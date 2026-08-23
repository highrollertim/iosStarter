import Foundation
import Synchronization
import Testing
@testable import testExample

@Suite("LiveGitHubClient request building")
struct LiveGitHubClientTests {

    @Test("search URL targets the GitHub search API with the query")
    func searchURLShape() throws {
        let url = try #require(LiveGitHubClient.searchURL(matching: "swift"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "api.github.com")
        #expect(components.path == "/search/repositories")
        #expect(components.queryItems?.contains(URLQueryItem(name: "q", value: "swift")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "per_page", value: "30")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "sort", value: "stars")) == true)
    }

    @Test("queries are percent-encoded, not mangled")
    func queryEncoding() throws {
        let url = try #require(LiveGitHubClient.searchURL(matching: "swift ui kit"))
        #expect(url.absoluteString.contains("q=swift%20ui%20kit"))
    }
}

/// Exercises `LiveGitHubClient`'s response handling — status codes, headers,
/// transport failures and decoding — via `StubURLProtocol` (see
/// `TestSupport.swift`) instead of hitting the real GitHub API.
///
/// `.serialized` because every test in this suite sets the same
/// `StubURLProtocol.handler`. Note that serialization is about *tests* not
/// overlapping; it is not what makes the handler itself thread-safe — see the
/// `Mutex` in `StubURLProtocol` for that, and why the old comment here was
/// wrong about it.
@Suite("LiveGitHubClient error mapping", .serialized)
struct LiveGitHubClientErrorMappingTests {

    /// One test case: the HTTP response `LiveGitHubClient` receives, and the
    /// typed error it should throw in response.
    struct Case: Sendable, CustomStringConvertible {
        let statusCode: Int
        var headers: [String: String] = [:]
        var body = Data()
        let expected: GitHubClientError
        /// Spelled out because "HTTP 403 → rateLimited" appears twice with
        /// different headers, and a test name that can't tell them apart is
        /// useless when one fails.
        let description: String
    }

    static let cases: [Case] = [
        Case(statusCode: 403, expected: .server(statusCode: 403),
             description: "403 with no rate-limit headers → server(403)"),
        Case(statusCode: 403, headers: ["x-ratelimit-remaining": "0"], expected: .rateLimited,
             description: "403 with x-ratelimit-remaining: 0 → rateLimited"),
        Case(statusCode: 403, headers: ["Retry-After": "60"], expected: .rateLimited,
             description: "403 with Retry-After → rateLimited"),
        Case(statusCode: 403, headers: ["x-ratelimit-remaining": "42"], expected: .server(statusCode: 403),
             description: "403 with quota remaining → server(403)"),
        Case(statusCode: 429, expected: .rateLimited,
             description: "429 → rateLimited"),
        Case(statusCode: 422, expected: .invalidQuery,
             description: "422 → invalidQuery"),
        Case(statusCode: 400, expected: .invalidQuery,
             description: "400 → invalidQuery"),
        Case(statusCode: 500, expected: .server(statusCode: 500),
             description: "500 → server(500)"),
        Case(statusCode: 200, body: Data("not valid json".utf8), expected: .decoding,
             description: "200 with a body that isn't JSON → decoding"),
    ]

    private static func response(
        for request: URLRequest,
        statusCode: Int,
        headers: [String: String]
    ) -> HTTPURLResponse {
        // `HTTPURLResponse.init` only fails for a malformed status line,
        // which a fixed integer status code never produces — force
        // unwrapping here (rather than `#require`, which assumes the
        // Swift Testing task context this closure runs outside of) is
        // safe and keeps the stub's plumbing out of the way.
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.github.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    @Test("HTTP responses map to the matching typed GitHubClientError", arguments: cases)
    func mapsResponseToTypedError(_ testCase: Case) async throws {
        try await withStubbedClient { request in
            (Self.response(for: request, statusCode: testCase.statusCode, headers: testCase.headers),
             testCase.body)
        } client: { client in
            // `GitHubClientError` is `Equatable`, so `#expect(throws:)` here
            // asserts the *exact* error case (and, for `.server`, the exact
            // status code) rather than merely "some error was thrown".
            await #expect(throws: testCase.expected) {
                try await client.searchRepositories(matching: "swift")
            }
        }
    }

    @Test("a transport failure becomes .network")
    func transportFailureBecomesNetwork() async throws {
        try await withStubbedClient { _ in
            throw URLError(.notConnectedToInternet)
        } client: { client in
            await #expect(throws: GitHubClientError.network) {
                try await client.searchRepositories(matching: "swift")
            }
        }
    }

    @Test("URLError(.cancelled) surfaces as CancellationError, not a GitHubClientError")
    func cancellationIsNotAClientError() async throws {
        // Asserted with do/catch rather than `#expect(throws:)` because the
        // claim is about the error's *type*: cancellation must escape the
        // typed-error vocabulary entirely so `SearchViewModel` can tell "the
        // user moved on" apart from "the request failed". Folding it into
        // `.network` would put a spurious error banner on screen every time
        // the debounce supersedes a request.
        try await withStubbedClient { _ in
            throw URLError(.cancelled)
        } client: { client in
            do {
                _ = try await client.searchRepositories(matching: "swift")
                Issue.record("Expected the cancelled request to throw")
            } catch is CancellationError {
                // Exactly right.
            } catch let error as GitHubClientError {
                Issue.record("Cancellation leaked into the typed error vocabulary as \(error)")
            } catch {
                Issue.record("Unexpected error type: \(type(of: error))")
            }
        }
    }

    @Test("a valid 200 round-trips into domain models")
    func successfulResponseMapsToRepos() async throws {
        try await withStubbedClient { request in
            (Self.response(for: request, statusCode: 200, headers: [:]),
             RepoDecodingTests.searchResponseJSON)
        } client: { client in
            let repos = try await client.searchRepositories(matching: "swift")
            #expect(repos.count == 2)
            #expect(repos.first?.fullName == "apple/swift")
            #expect(repos.first?.stargazersCount == 67000)
            #expect(repos.last?.language == nil)
        }
    }

    @Test("requests carry the headers GitHub requires")
    func requestCarriesRequiredHeaders() async throws {
        // GitHub rejects requests with no `User-Agent` outright, which is the
        // kind of failure that only shows up against the real API — so it is
        // asserted here, where the stub can see the outgoing request.
        let seen = Mutex<URLRequest?>(nil)
        try await withStubbedClient { request in
            seen.withLock { $0 = request }
            return (Self.response(for: request, statusCode: 200, headers: [:]),
                    RepoDecodingTests.searchResponseJSON)
        } client: { client in
            _ = try await client.searchRepositories(matching: "swift")
        }

        let request = try #require(seen.withLock { $0 })
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "RepoScout/1.0 (reference app)")
        #expect(request.timeoutInterval == 15)
    }
}
