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
                Text("Favorites coming in Task 9") // TODO(Task 9)
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
