import Foundation
import Testing
@testable import testExample

/// Decoding tests use inline fixtures so the expected JSON shape is visible
/// right next to the assertions — no hunting through resource bundles.
@Suite("GitHub search response decoding")
struct RepoDecodingTests {

    /// A trimmed but structurally faithful GitHub `/search/repositories` payload.
    static let searchResponseJSON = Data("""
    {
      "total_count": 2,
      "incomplete_results": false,
      "items": [
        {
          "id": 44838949,
          "full_name": "apple/swift",
          "owner": { "login": "apple", "id": 10639145 },
          "description": "The Swift Programming Language",
          "stargazers_count": 67000,
          "forks_count": 10000,
          "language": "C++",
          "html_url": "https://github.com/apple/swift"
        },
        {
          "id": 792063708,
          "full_name": "swiftlang/swift-testing",
          "owner": { "login": "swiftlang", "id": 42816656 },
          "description": null,
          "stargazers_count": 2000,
          "forks_count": 300,
          "language": null,
          "html_url": "https://github.com/swiftlang/swift-testing"
        }
      ]
    }
    """.utf8)

    @Test("decodes a realistic payload into domain models")
    func decodesRealisticPayload() throws {
        let response = try JSONDecoder().decode(GitHubSearchResponse.self, from: Self.searchResponseJSON)
        let repos = response.items.map(Repo.init(dto:))

        #expect(repos.count == 2)
        let first = try #require(repos.first)
        #expect(first.id == 44838949)
        #expect(first.fullName == "apple/swift")
        #expect(first.ownerLogin == "apple")
        #expect(first.summary == "The Swift Programming Language")
        #expect(first.stargazersCount == 67000)
        #expect(first.forksCount == 10000)
        #expect(first.language == "C++")
        #expect(first.htmlURL == URL(string: "https://github.com/apple/swift"))
    }

    @Test("optional fields decode as nil when the API sends null")
    func optionalFieldsDecodeAsNil() throws {
        let response = try JSONDecoder().decode(GitHubSearchResponse.self, from: Self.searchResponseJSON)
        let second = try #require(response.items.last.map(Repo.init(dto:)))
        #expect(second.summary == nil)
        #expect(second.language == nil)
    }

    /// Parameterized test: several malformed payloads, one test body.
    @Test("malformed payloads throw", arguments: [
        #"{ "items": [ { "full_name": "a/b" } ] }"#,        // missing required fields
        #"{ "total_count": 1 }"#,                            // missing items array
        #"not json at all"#,
    ])
    func malformedPayloadsThrow(fixture: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GitHubSearchResponse.self, from: Data(fixture.utf8))
        }
    }
}
