import Foundation
import SwiftData

#if DEBUG
/// Shared in-memory container for previews, pre-seeded with a favorite so
/// favorites UI previews aren't empty.
@MainActor
let previewContainer: ModelContainer = {
    do {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FavoriteRepo.self, configurations: configuration)
        if let repo = MockGitHubClient.fixtureRepos.first {
            container.mainContext.insert(FavoriteRepo(repo: repo))
        }
        return container
    } catch {
        fatalError("Failed to create preview ModelContainer: \(error)")
    }
}()
#endif
