import Foundation
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
        #if DEBUG
        if processInfo.arguments.contains("-UITestMockNetwork") {
            let scenario = MockGitHubClient.Scenario(
                rawValue: processInfo.environment["UITEST_SCENARIO"] ?? ""
            ) ?? .success
            client = MockGitHubClient(scenario: scenario)
        } else {
            client = LiveGitHubClient()
        }
        #else
        client = LiveGitHubClient()
        #endif

        let inMemory = processInfo.arguments.contains("-UITestInMemoryStore")
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
            modelContainer = try ModelContainer(for: FavoriteRepo.self, configurations: configuration)
        } catch {
            // If the local store can't be created the app has no meaningful
            // degraded mode; fail loudly at launch rather than limping into
            // undefined behavior.
            fatalError("Failed to create ModelContainer: \(error)")
        }

        searchViewModel = SearchViewModel(client: client)
    }
}
