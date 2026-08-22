import Combine
import Foundation
import Observation

/// Owns the search screen's state and its debounced search pipeline.
///
/// This is the app's only view model — the other screens have no async
/// orchestration, so they don't pay for one. `@Observable` (not
/// `ObservableObject`) is the 2026 baseline: views track exactly the
/// properties they read, no `objectWillChange`, no `@Published`.
///
/// Main-actor-isolated via the project's default isolation, which is why the
/// Combine sinks below can touch state without hopping.
@Observable
final class SearchViewModel {

    private(set) var state: LoadState<[Repo]> = .idle
    private(set) var lastRefreshed: Date?
    /// Ticks once per second (see the Timer pipeline) so "Updated Ns ago"
    /// stays current without the view owning a timer.
    private(set) var now: Date = .now

    /// Bound to the search field. Each keystroke feeds the Combine pipeline.
    var searchText: String = "" {
        didSet { querySubject.send(searchText) }
    }

    private let client: any GitHubClient
    private let querySubject = PassthroughSubject<String, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?

    /// `debounceInterval` is injectable so tests can shrink it from 300ms to
    /// 50ms — tune the constant without rewriting the tests.
    init(
        client: any GitHubClient,
        debounceInterval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(300)
    ) {
        self.client = client

        // WHY COMBINE HERE: keystrokes are a *stream of events over time*,
        // and debounce/removeDuplicates are exactly the stream algebra that
        // is tedious to hand-roll with Task.sleep and cancellation flags.
        // For one-shot async work we use async/await (see LiveGitHubClient);
        // for event streams, Combine still earns its keep.
        querySubject
            .debounce(for: debounceInterval, scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in
                guard let self else { return }
                searchTask?.cancel()
                searchTask = Task { await self.search(matching: query) }
            }
            .store(in: &cancellables)

        // A second, tiny Combine example: a timer is also a stream. Note the
        // lifecycle management — sinks live in `cancellables`, which the
        // deinit of this object tears down automatically.
        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.now = date
            }
            .store(in: &cancellables)
    }

    /// The single path from "query" to "state". Also called directly by the
    /// retry button and by unit tests — the debounce pipeline is just one
    /// caller among several.
    func search(matching query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .idle
            return
        }

        state = .loading
        do {
            let repos = try await client.searchRepositories(matching: trimmed)
            guard !Task.isCancelled else { return }
            state = .loaded(repos)
            lastRefreshed = .now
        } catch is CancellationError {
            // A newer search superseded this one; its results own the screen.
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(message: userFacingMessage(for: error))
        }
    }

    func retry() {
        searchTask?.cancel()
        searchTask = Task { await search(matching: searchText) }
    }

    var lastRefreshedDescription: String? {
        Self.refreshedDescription(from: lastRefreshed, now: now)
    }

    /// Pure and static so the formatting logic is trivially unit-testable.
    nonisolated static func refreshedDescription(from lastRefreshed: Date?, now: Date) -> String? {
        guard let lastRefreshed else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(lastRefreshed)))
        return String(localized: "Updated \(seconds)s ago")
    }

    private func userFacingMessage(for error: any Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return String(localized: "Something went wrong. Please try again.")
    }
}
