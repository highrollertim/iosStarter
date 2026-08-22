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
    }

    @Test("queries are percent-encoded, not mangled")
    func queryEncoding() throws {
        let url = try #require(LiveGitHubClient.searchURL(matching: "swift ui kit"))
        #expect(url.absoluteString.contains("q=swift%20ui%20kit"))
    }
}
