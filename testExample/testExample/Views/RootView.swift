import SwiftData
import SwiftUI

struct RootView: View {
    let searchViewModel: SearchViewModel

    var body: some View {
        TabView {
            // `role: .search` is one keyword that buys platform-correct
            // behaviour: the system pins the search tab to the trailing edge,
            // gives it the standard treatment in the iOS 26 tab bar (and the
            // sidebar/tab-bar adaptation on iPad), and wires up the standard
            // search keyboard shortcut. Hard-coding position and appearance
            // to imitate this is how apps end up feeling subtly wrong after
            // an OS update.
            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                SearchView(viewModel: searchViewModel)
            }
            Tab("Favorites", systemImage: "star.fill") {
                FavoritesView()
            }
        }
        // No `.accessibilityIdentifier` on the tabs: `Tab` is a builder for
        // tab *content*, not a `View`, so modifiers applied to it decorate
        // the screen inside the tab rather than the tab-bar button that
        // selects it. There is no API to identify that button, so
        // `FavoritesScreen.open()` queries it by its localized title — see
        // the note there.
    }
}

#if DEBUG
#Preview {
    RootView(searchViewModel: SearchViewModel(client: MockGitHubClient()))
        .modelContainer(previewContainer)
}
#endif
