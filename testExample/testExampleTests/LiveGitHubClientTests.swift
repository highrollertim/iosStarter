import Foundation
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

/// Exercises `LiveGitHubClient`'s response handling — status-code and
/// decoding failures becoming the right `GitHubClientError` case — via
/// `StubURLProtocol` (see `TestSupport.swift`) instead of hitting the real
/// GitHub API. `.serialized` because every test in this suite mutates the
/// same `StubURLProtocol.handler` static.
@Suite("LiveGitHubClient error mapping", .serialized)
struct LiveGitHubClientErrorMappingTests {

    /// One test case: the HTTP response `LiveGitHubClient` receives, and the
    /// typed error it should throw in response.
    struct Case: Sendable, CustomStringConvertible {
        let statusCode: Int
        let body: Data
        let expected: GitHubClientError

        var description: String { "HTTP \(statusCode) → \(expected)" }
    }

    static let cases: [Case] = [
        Case(statusCode: 403, body: Data(), expected: .rateLimited),
        Case(statusCode: 429, body: Data(), expected: .rateLimited),
        Case(statusCode: 500, body: Data(), expected: .server(statusCode: 500)),
        Case(statusCode: 200, body: Data("not valid json".utf8), expected: .decoding),
    ]

    private func makeStubbedClient() -> LiveGitHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LiveGitHubClient(session: URLSession(configuration: configuration))
    }

    @Test("HTTP responses map to the matching typed GitHubClientError", arguments: cases)
    func mapsResponseToTypedError(_ testCase: Case) async throws {
        StubURLProtocol.handler = { request in
            // `HTTPURLResponse.init` only fails for a malformed status line,
            // which a fixed integer status code never produces — force
            // unwrapping here (rather than `#require`, which assumes the
            // Swift Testing task context this closure runs outside of) is
            // safe and keeps the stub's plumbing out of the way.
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.github.com")!,
                statusCode: testCase.statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, testCase.body)
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeStubbedClient()
        // `GitHubClientError` is `Equatable`, so `#expect(throws:)` here
        // asserts the *exact* error case (and, for `.server`, the exact
        // status code) rather than merely "some error was thrown".
        await #expect(throws: testCase.expected) {
            try await client.searchRepositories(matching: "swift")
        }
    }
}
