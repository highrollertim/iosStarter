import Foundation
import Testing
@testable import testExample

/// `@MainActor` because `SearchViewModel` is main-actor-isolated (the app
/// target uses default MainActor isolation; this test target does not).
@MainActor
@Suite("SearchViewModel state transitions")
struct SearchViewModelTests {

    @Test("successful search moves loading → loaded")
    func successMovesThroughLoadingToLoaded() async throws {
        let gate = GatedGitHubClient(repos: .fixture)
        let viewModel = SearchViewModel(client: gate)
        #expect(viewModel.state == .idle)

        let search = Task { await viewModel.search(matching: "swift") }
        try await poll(until: { viewModel.state == .loading }, message: "state == .loading")
        await gate.open()
        await search.value

        #expect(viewModel.state == .loaded(.fixture))
        #expect(viewModel.lastRefreshed != nil)
    }

    @Test("failed search surfaces the error's user-facing message")
    func failureSurfacesMessage() async {
        let spy = SpyGitHubClient(result: .failure(.rateLimited))
        let viewModel = SearchViewModel(client: spy)

        await viewModel.search(matching: "swift")

        #expect(viewModel.state == .failed(message: GitHubClientError.rateLimited.errorDescription ?? ""))
    }

    @Test("blank queries reset to idle without hitting the network", arguments: ["", "   ", "\n"])
    func blankQueriesResetToIdle(query: String) async {
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy)

        await viewModel.search(matching: query)

        #expect(viewModel.state == .idle)
        #expect(await spy.queries.isEmpty)
    }

    @Test("a cancelled search cannot clobber a newer search's result")
    func supersededSearchCannotClobberNewerResult() async throws {
        let staleResult: [Repo] = [
            Repo(id: 2, fullName: "stale/repo", ownerLogin: "stale", summary: nil,
                 stargazersCount: 0, forksCount: 0, language: nil,
                 htmlURL: URL(string: "https://github.com/stale/repo")!)
        ]
        let freshResult: [Repo] = .fixture
        let client = KeyedGatedGitHubClient(repos: ["first": staleResult, "second": freshResult])
        let viewModel = SearchViewModel(client: client)

        // Drives cancellation the way the production debounce sink does
        // (`searchTask?.cancel()` followed by starting a Task for the
        // latest query — see `SearchViewModel.init`'s `querySubject` sink).
        // Exercised directly here, rather than through Combine's
        // time-based debounce, so the test is deterministic.
        let firstSearch = Task { await viewModel.search(matching: "first") }
        try await poll(until: { await client.isPending("first") }, message: "\"first\" request in flight")
        firstSearch.cancel()

        // Arm "second" to resolve the instant its call arrives, then run it
        // to completion — this is the search that should win.
        await client.open("second")
        let secondSearch = Task { await viewModel.search(matching: "second") }
        await secondSearch.value

        #expect(viewModel.state == .loaded(freshResult))

        // Only now release the stale, already-cancelled first request.
        // `search(matching:)`'s `Task.isCancelled` guard (checked right
        // after the `try await` succeeds) must discard this late arrival
        // rather than let it clobber the newer state.
        await client.open("first")
        await firstSearch.value

        #expect(viewModel.state == .loaded(freshResult))
    }

    @Test("refreshed description reports whole seconds")
    func refreshedDescription() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(SearchViewModel.refreshedDescription(from: base, now: base.addingTimeInterval(42)) == "Updated 42s ago")
        #expect(SearchViewModel.refreshedDescription(from: nil, now: base) == nil)
    }
}
