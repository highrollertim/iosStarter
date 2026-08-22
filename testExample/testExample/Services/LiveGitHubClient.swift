import Foundation

/// Production `GitHubClient` backed by `URLSession` and `async/await`.
///
/// Note what is *not* here: no Combine. One-shot request/response work is
/// exactly what `async/await` is for. Combine appears in this codebase only
/// where values genuinely stream over time (see `SearchViewModel`).
nonisolated struct LiveGitHubClient: GitHubClient {
    var session: URLSession = .shared

    /// Static and pure so URL construction is unit-testable without any
    /// networking.
    static func searchURL(matching query: String) -> URL? {
        var components = URLComponents(string: "https://api.github.com/search/repositories")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "per_page", value: "30"),
        ]
        return components?.url
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        guard let url = Self.searchURL(matching: query) else {
            throw GitHubClientError.invalidQuery
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw GitHubClientError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubClientError.network
        }
        switch http.statusCode {
        case 200:
            break
        case 403, 429:
            // GitHub signals rate limiting with 403 (legacy) and 429.
            throw GitHubClientError.rateLimited
        default:
            throw GitHubClientError.server(statusCode: http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(GitHubSearchResponse.self, from: data)
            return decoded.items.map(Repo.init(dto:))
        } catch {
            throw GitHubClientError.decoding
        }
    }
}
