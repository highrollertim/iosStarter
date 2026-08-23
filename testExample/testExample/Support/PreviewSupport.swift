import Foundation
import SwiftData
import SwiftUI

#if DEBUG
/// Supplies previews with an in-memory `ModelContainer`, pre-seeded with a
/// favorite so favorites previews aren't empty.
///
/// A `PreviewModifier` rather than a global container. Two things follow from
/// that. `makeSharedContext()` is built **once per preview process** and
/// shared by every preview that asks for it, so a file full of previews pays
/// for one store rather than one each. And it is `async throws`, so a
/// container that cannot be built surfaces as a preview-time error in the
/// canvas instead of a `fatalError` that takes the whole preview process down
/// with it — the failure mode a lazily-initialized global has no way to
/// express.
struct SampleData: PreviewModifier {
    static func makeSharedContext() async throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FavoriteRepo.self, configurations: configuration)
        if let repo = MockGitHubClient.fixtureRepos.first {
            container.mainContext.insert(FavoriteRepo(repo: repo))
        }
        return container
    }

    func body(content: Content, context: ModelContainer) -> some View {
        content.modelContainer(context)
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    /// Spelled as a trait so call sites read `#Preview(traits: .sampleData)`.
    @MainActor static var sampleData: Self { .modifier(SampleData()) }
}
#endif
