import SwiftData
import SwiftUI

struct RootView: View {
    let searchViewModel: SearchViewModel

    var body: some View {
        TabView {
            // `role: .search` states what this tab *is*, and the system
            // decides what that means: it pins the tab to the trailing edge
            // of the tab bar and gives it the search-specific presentation
            // for the platform. It is a declaration of role, not a bundle of
            // appearance — the two behaviours below are separate opt-ins.
            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                SearchView(viewModel: searchViewModel)
            }
            // `.accessibilityIdentifier` on a `Tab` identifies the tab-bar
            // button that selects it, which is what UI tests need: a
            // locale-independent handle that does not break under
            // `-testLanguage de`.
            .accessibilityIdentifier("tab.search")
            Tab("Favorites", systemImage: "star.fill") {
                FavoritesView()
            }
            .accessibilityIdentifier("tab.favorites")
        }
        // Collapses the tab bar as the user scrolls into content and brings
        // it back on the way up. Opt-in, not implied by `role: .search`.
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

#if DEBUG
#Preview {
    RootView(searchViewModel: SearchViewModel(client: MockGitHubClient()))
        .modelContainer(previewContainer)
}
#endif
