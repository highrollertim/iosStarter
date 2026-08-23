import Foundation
import OSLog
import SwiftData

/// The composition root: the one place that decides which concrete
/// implementations the app runs with.
///
/// Everything downstream receives dependencies through initializers — no
/// singletons, no service locators. UI tests flip to deterministic doubles
/// purely via launch arguments, which is what makes them hermetic and
/// offline.
final class AppDependencies {
    let client: any GitHubClient
    let modelContainer: ModelContainer
    let searchViewModel: SearchViewModel

    init(processInfo: ProcessInfo = .processInfo) {
        // Both test affordances live inside `#if DEBUG`, and both must.
        // Launch arguments are not a trusted channel — a configuration
        // profile, an MDM-managed launch, or anyone who can drive the app on
        // a development device can set them — so a Release build that still
        // honoured `-UITestInMemoryStore` would throw away the user's entire
        // favorites database on request. A test hook that survives into
        // Release is a shipped defect, not a convenience.
        let inMemory: Bool
        #if DEBUG
        if processInfo.arguments.contains("-UITestMockNetwork") {
            let scenario = MockGitHubClient.Scenario(
                rawValue: processInfo.environment["UITEST_SCENARIO"] ?? ""
            ) ?? .success
            client = MockGitHubClient(scenario: scenario)
        } else {
            client = LiveGitHubClient()
        }
        inMemory = processInfo.arguments.contains("-UITestInMemoryStore")
        #else
        client = LiveGitHubClient()
        inMemory = false
        #endif

        modelContainer = Self.makeContainer(inMemory: inMemory)
        searchViewModel = SearchViewModel(client: client)
    }

    /// Builds the persistent container, degrading to an in-memory one rather
    /// than crashing.
    ///
    /// `fatalError` is the worst available response to the most likely cause:
    /// a schema-migration mismatch after an app update. The store on disk is
    /// from the previous version, the new build can't open it, and every
    /// launch dies in the same place — an unbreakable crash loop that no user
    /// can escape short of deleting the app, and that no crash reporter can
    /// distinguish from a hard bug.
    ///
    /// A degraded-but-running app beats a crash loop. Favorites are a
    /// convenience, not the product; a session with an empty favorites list
    /// still searches GitHub perfectly well, and the fault-level log entry
    /// means the real problem is still visible in diagnostics. (An app whose
    /// *data is the product* would make a different call here — it would
    /// surface a recovery UI rather than quietly starting fresh.)
    private static func makeContainer(inMemory: Bool) -> ModelContainer {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
            return try ModelContainer(for: FavoriteRepo.self, configurations: configuration)
        } catch {
            Logger.startup.fault(
                "Persistent ModelContainer unavailable, falling back to in-memory: \(error)"
            )
        }

        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(for: FavoriteRepo.self, configurations: configuration)
        } catch {
            // An in-memory container needs no disk, no migration and no
            // permissions; if this fails, the schema itself is malformed —
            // a programmer error that is present on every launch on every
            // device, and not something a running app can degrade around.
            fatalError("In-memory ModelContainer failed; the schema is invalid: \(error)")
        }
    }
}
