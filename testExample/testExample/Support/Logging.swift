import Foundation
import OSLog

/// Shared `Logger` instances, declared once.
///
/// Two views were each constructing their own `Logger` with the same
/// subsystem and category, and one of them hard-coded the bundle identifier
/// as a string literal — which silently stops matching the app the moment the
/// bundle ID changes. Hoisting them here gives one definition per category
/// and one place to get the subsystem right.
extension Logger {
    /// Everything touching the favorites store: toggles, deletes, and the
    /// failures thereof.
    static let favorites = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoScout",
        category: "favorites"
    )

    /// Composition-root and launch-time concerns — currently just the
    /// persistent-store fallback in `AppDependencies`.
    static let startup = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoScout",
        category: "startup"
    )
}
