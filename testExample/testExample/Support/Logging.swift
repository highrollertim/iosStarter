import Foundation
import OSLog

/// Shared `Logger` instances, declared once.
///
/// One definition per category, and one place that derives the subsystem from
/// the bundle identifier — a literal spelled at each call site silently stops
/// matching the app the moment that identifier changes.
/// `nonisolated` on both: this project sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a bare `static let` in an
/// extension is main-actor-isolated and unreachable from anywhere else.
/// `Logger` is `Sendable` and safe to use from any executor — and the
/// failures most worth logging happen off the main actor, inside
/// `nonisolated` and `@concurrent` code where the network lives. A logger you
/// have to hop to the main actor to reach is a logger that changes the timing
/// of the thing it is observing.
extension Logger {
    /// Everything touching the favorites store: toggles, deletes, and the
    /// failures thereof.
    nonisolated static let favorites = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoScout",
        category: "favorites"
    )

    /// The network layer's failures: the two `catch` clauses in
    /// `LiveGitHubClient.searchRepositories(matching:)`.
    ///
    /// This is the category the paragraph above is about — it is logged from
    /// a `@concurrent` function, off the main actor, which is exactly why
    /// these are `nonisolated`. It also makes the rogue-`CancellationError`
    /// story diagnosable in the field: the cancelled clause logs at `debug`
    /// (a superseded search is routine, not a defect), so a build that is
    /// silently mapping session teardown onto cancellation shows up as a
    /// stream of cancellations nobody asked for.
    nonisolated static let network = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoScout",
        category: "network"
    )

    /// Composition-root and launch-time concerns — currently just the
    /// persistent-store fallback in `AppDependencies`.
    nonisolated static let startup = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoScout",
        category: "startup"
    )
}
