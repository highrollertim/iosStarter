import SwiftData
import SwiftUI

@main
struct RepoScoutApp: App {
    /// Built once at launch; owns every long-lived dependency.
    private let dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            RootView(searchViewModel: dependencies.searchViewModel)
        }
        .modelContainer(dependencies.modelContainer)
    }
}
