import Foundation

/// Abstraction over "something that can search GitHub".
///
/// The protocol is the seam that makes everything else testable: unit tests
/// substitute spies, previews and UI tests substitute `MockGitHubClient`,
/// production uses `LiveGitHubClient`. Callers never know the difference.
nonisolated protocol GitHubClient: Sendable {
    func searchRepositories(matching query: String) async throws -> [Repo]
}

/// Typed failures for the GitHub client.
///
/// A closed error enum (instead of rethrowing raw `URLError`/`DecodingError`)
/// means the UI layer switches over a small, stable set of cases — and the
/// user-facing copy lives here, once, via `LocalizedError`. Cancellation is
/// deliberately *not* one of these cases: a superseded request isn't a
/// failure, so conforming implementations (see `LiveGitHubClient`) let
/// `CancellationError` propagate unchanged instead of folding it into
/// `.network`.
///
/// What that buys is narrower than it looks, and the distinction is the whole
/// lesson of this file's error handling. The type is a **hint, not proof**: a
/// client may raise `CancellationError` for teardown that has nothing to do
/// with `Task` cancellation — `LiveGitHubClient` maps every
/// `URLError(.cancelled)` to one, and `URLSession` produces that code for an
/// invalidated session and other shutdowns as well. A caller that treats the
/// type as an answer will silently swallow real failures on live tasks.
/// Callers must ask `Task.isCancelled` instead; see `SearchViewModel`, whose
/// single `catch` does exactly that.
nonisolated enum GitHubClientError: Error, Equatable, LocalizedError {
    case invalidQuery
    case network
    case rateLimited
    case server(statusCode: Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            String(
                localized: "That search can't be sent. Try different text.",
                comment: "Error shown on the search screen when GitHub rejects the query text itself as malformed."
            )
        case .network:
            String(
                localized: "Couldn't reach GitHub. Check your connection and try again.",
                comment: "Error shown on the search screen when the request never reached GitHub — offline, DNS failure, timeout."
            )
        case .rateLimited:
            String(
                localized: "GitHub is rate-limiting searches right now. Give it a minute.",
                comment: "Error shown on the search screen when GitHub's API rate limit has been hit. Implies waiting will fix it."
            )
        case .server(let statusCode):
            String(
                localized: "GitHub had a problem (HTTP \(statusCode)). Try again shortly.",
                comment: "Error shown on the search screen for an unexpected server response. The number is an HTTP status code and must stay as digits."
            )
        case .decoding:
            String(
                localized: "GitHub sent a response this app couldn't read.",
                comment: "Error shown on the search screen when GitHub's reply arrived but could not be decoded."
            )
        }
    }
}
