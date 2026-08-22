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
/// `.network`, so callers can tell "cancelled" apart from "actually failed".
nonisolated enum GitHubClientError: Error, Equatable, LocalizedError {
    case invalidQuery
    case network
    case rateLimited
    case server(statusCode: Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            String(localized: "That search can't be sent. Try different text.")
        case .network:
            String(localized: "Couldn't reach GitHub. Check your connection and try again.")
        case .rateLimited:
            String(localized: "GitHub is rate-limiting searches right now. Give it a minute.")
        case .server(let statusCode):
            String(localized: "GitHub had a problem (HTTP \(statusCode)). Try again shortly.")
        case .decoding:
            String(localized: "GitHub sent a response this app couldn't read.")
        }
    }
}
