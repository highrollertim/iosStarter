import Foundation

/// Production `GitHubClient` backed by `URLSession` and `async/await`.
///
/// Note what is *not* here: no Combine. One-shot request/response work is
/// exactly what `async/await` is for. Combine appears in this codebase only
/// where values genuinely stream over time (see `SearchViewModel`).
nonisolated struct LiveGitHubClient: GitHubClient {
    /// A `var`, not a `let`, purely so the compiler-synthesized memberwise
    /// initializer exposes a `session:` parameter — that is the seam
    /// `LiveGitHubClientErrorMappingTests` uses to inject a session whose
    /// `protocolClasses` are stubbed. A `let` with a default value would
    /// still be memberwise-initializable, but spelling it `var` documents
    /// that substitution is an intended use, not an accident of synthesis.
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

    /// `@concurrent` is load-bearing, and it is the whole concurrency lesson
    /// of this file.
    ///
    /// This project builds with `SWIFT_APPROACHABLE_CONCURRENCY = YES`, which
    /// turns on `NonisolatedNonsendingByDefault` (SE-0461): a plain
    /// `nonisolated` *async* function runs on its **caller's** executor. The
    /// caller here is `SearchViewModel`, which is `@MainActor` by the
    /// project's default isolation — so without this attribute the `await`
    /// below, and more importantly the `JSONDecoder().decode` of a ~100KB
    /// search payload, would execute *on the main actor*. It would compile,
    /// pass tests, and drop frames.
    ///
    /// `@concurrent` opts this function back out to the global concurrent
    /// executor, so the request and the decode genuinely leave the caller's
    /// executor. The `async` keyword never moved work off the main thread by
    /// itself; under SE-0461 that is now explicit rather than folklore.
    @concurrent
    func searchRepositories(matching query: String) async throws -> [Repo] {
        guard let url = Self.searchURL(matching: query) else {
            throw GitHubClientError.invalidQuery
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        // `Accept` pins the v3 media type so GitHub's response shape can't
        // drift under us; `User-Agent` is *required* by the GitHub API —
        // requests without one are rejected outright.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RepoScout/1.0 (reference app)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports a cancelled task as URLError(.cancelled) — it never
            // throws `CancellationError` itself — so this is the only clause that can
            // observe cancellation here. Surface it as `CancellationError` so callers'
            // cancellation handling stays in one shape.
            throw CancellationError()
        } catch {
            throw GitHubClientError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubClientError.network
        }
        switch http.statusCode {
        case 200..<300:
            // Any 2xx is a success. Matching only 200 would have turned a
            // perfectly good 203 or 206 into `.server`.
            break
        case 400, 422:
            // GitHub answers a malformed or empty search query with 422
            // (and, occasionally, 400). Mapping these to `.invalidQuery` is
            // what makes that case reachable at all — before this, the only
            // producer of `.invalidQuery` was the `URLComponents` guard
            // above, which cannot realistically fail.
            throw GitHubClientError.invalidQuery
        case 403:
            // 403 is overloaded: it means "rate limited" (legacy secondary
            // limits) *and* "forbidden" (blocked repo, bad credentials, abuse
            // detection). Telling the user "give it a minute" when the real
            // answer is "this will never work" is worse than saying nothing,
            // so only claim rate limiting when GitHub's own headers say so.
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
                || http.value(forHTTPHeaderField: "Retry-After") != nil {
                throw GitHubClientError.rateLimited
            }
            throw GitHubClientError.server(statusCode: 403)
        case 429:
            // 429 is unambiguous — no header sniffing required.
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
