import SwiftData
import SwiftUI

struct RootView: View {
    let searchViewModel: SearchViewModel

    var body: some View {
        TabView {
            Tab("Search", systemImage: "magnifyingglass") {
                SearchView(viewModel: searchViewModel)
            }
            Tab("Favorites", systemImage: "star.fill") {
                FavoritesView()
            }
        }
    }
}

#if DEBUG
#Preview {
    RootView(searchViewModel: SearchViewModel(client: MockGitHubClient()))
        .modelContainer(previewContainer)
}
#endif
