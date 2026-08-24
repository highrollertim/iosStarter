> **Archived — point-in-time planning artifact from the initial build
> (2026-08-22).** Superseded by the code and `ARCHITECTURE.md`. Code
> listings herein predate later fix waves and **MUST NOT** be used as
> reference — in particular the init-started ticker shown here was later
> identified as a bug. Kept only as a record of how the app was planned.
> The plan was also written *for an agentic executor*, so its tool-plumbing
> instructions (the "REQUIRED SUB-SKILL" note below, the checkbox task
> syntax) are part of the archived artifact rather than guidance to a human
> reader of this repository.

# RepoScout Reference App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the empty `testExample` Xcode template into RepoScout, a GitHub-repo-search app that models 2026 iOS best practices: `@Observable` MVVM, protocol DI, an honest Combine/async-await mix, SwiftData, Swift Testing, and BDD-style XCUITests.

**Architecture:** `@Observable` view model for search only; protocol-based `GitHubClient` (live/mock); SwiftData favorites behind a thin `FavoritesStore`; composition root in the App type selects live vs mock via launch arguments so UI tests are hermetic.

**Tech Stack:** Swift 6 language mode, SwiftUI, Combine (debounce + timer only), SwiftData, Swift Testing (`import Testing`), XCUITest with `XCTContext.runActivity`.

## Global Constraints

- Xcode project, targets, schemes, and bundle IDs stay named `testExample`. The app is branded **RepoScout** in UI copy and `INFOPLIST_KEY_CFBundleDisplayName`.
- Deployment target: iOS 26.2. Xcode 26.2. Simulator for all test runs: `iPhone 17 Pro`.
- Swift 6 language mode (`SWIFT_VERSION = 6.0`) with the template's existing `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`. The app target defaults to `MainActor`; model/service types opt out with `nonisolated`. The two test targets do NOT have default MainActor isolation — annotate test suites `@MainActor` where they touch view models or SwiftData.
- Zero third-party dependencies. Zero SPM packages.
- The project uses `PBXFileSystemSynchronizedRootGroup`: any file created under `testExample/testExample/`, `testExample/testExampleTests/`, or `testExample/testExampleUITests/` automatically joins that target. Never edit `project.pbxproj` to add files.
- All shell commands run from `/Volumes/Dock/Code/testExample/testExample` unless noted. Git commands may run from the repo root `/Volumes/Dock/Code/testExample`.
- Unit test command (used throughout; first run is slow — allow up to 10 minutes):
  `xcodebuild test -project testExample.xcodeproj -scheme testExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:testExampleTests 2>&1 | tail -30`
- Build-only command:
  `xcodebuild build -project testExample.xcodeproj -scheme testExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20`
- UI test command:
  `xcodebuild test -project testExample.xcodeproj -scheme testExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:testExampleUITests 2>&1 | tail -30`
- Every substantive type/method gets `///` doc comments explaining *why* the pattern is used, written for an audience of new-to-iOS through returning-senior developers. Comments below are part of the deliverable — do not strip them.
- Commit at the end of every task with the message given in the task. All commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Project settings — Swift 6 mode + RepoScout display name

**Files:**
- Modify: `testExample/testExample.xcodeproj/project.pbxproj` (settings values only, via `perl` one-liners)

**Interfaces:**
- Produces: a project that compiles in Swift 6 language mode; later tasks rely on default-MainActor isolation in the app target and its absence in test targets.

- [ ] **Step 1: Bump Swift language mode to 6 in all six build-configuration blocks**

Run from `/Volumes/Dock/Code/testExample/testExample`:

```bash
perl -pi -e 's/SWIFT_VERSION = 5\.0;/SWIFT_VERSION = 6.0;/g' testExample.xcodeproj/project.pbxproj
grep -c 'SWIFT_VERSION = 6.0;' testExample.xcodeproj/project.pbxproj
```

Expected: `6`

- [ ] **Step 2: Add the RepoScout display name to the two app-target configurations**

`INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents` appears only in the app target's two config blocks, so it is a safe insertion anchor:

```bash
perl -pi -e 's/(INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;)/$1\n\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = RepoScout;/' testExample.xcodeproj/project.pbxproj
grep -c 'INFOPLIST_KEY_CFBundleDisplayName = RepoScout;' testExample.xcodeproj/project.pbxproj
```

Expected: `2`

- [ ] **Step 3: Verify the project still builds**

Run the build-only command from Global Constraints.
Expected: `** BUILD SUCCEEDED **` in the tail output.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A testExample/testExample.xcodeproj/project.pbxproj && git commit -m "chore: adopt Swift 6 language mode and RepoScout display name"
```

---

### Task 2: Domain model and DTO decoding (TDD)

**Files:**
- Create: `testExample/testExample/Models/Repo.swift`
- Create: `testExample/testExample/Models/GitHubSearchResponse.swift`
- Create: `testExample/testExampleTests/RepoDecodingTests.swift`
- Delete: `testExample/testExampleTests/testExampleTests.swift` (template stub)

**Interfaces:**
- Produces:
  - `Repo` — `nonisolated struct Repo: Identifiable, Hashable, Sendable` with `let id: Int`, `fullName: String`, `ownerLogin: String`, `summary: String?`, `stargazersCount: Int`, `forksCount: Int`, `language: String?`, `htmlURL: URL`, and memberwise init.
  - `GitHubSearchResponse` — `nonisolated struct GitHubSearchResponse: Decodable, Sendable` with `let items: [RepoDTO]`.
  - `RepoDTO` — `nonisolated struct` mirroring GitHub's JSON, plus `Repo.init(dto: RepoDTO)`.

- [ ] **Step 1: Write the failing decoding tests**

Delete the template stub first: `rm testExample/testExampleTests/testExampleTests.swift`

Create `testExample/testExampleTests/RepoDecodingTests.swift`:

```swift
import Foundation
import Testing
@testable import testExample

/// Decoding tests use inline fixtures so the expected JSON shape is visible
/// right next to the assertions — no hunting through resource bundles.
@Suite("GitHub search response decoding")
struct RepoDecodingTests {

    /// A trimmed but structurally faithful GitHub `/search/repositories` payload.
    static let searchResponseJSON = Data("""
    {
      "total_count": 2,
      "incomplete_results": false,
      "items": [
        {
          "id": 44838949,
          "full_name": "apple/swift",
          "owner": { "login": "apple", "id": 10639145 },
          "description": "The Swift Programming Language",
          "stargazers_count": 67000,
          "forks_count": 10000,
          "language": "C++",
          "html_url": "https://github.com/apple/swift"
        },
        {
          "id": 792063708,
          "full_name": "swiftlang/swift-testing",
          "owner": { "login": "swiftlang", "id": 42816656 },
          "description": null,
          "stargazers_count": 2000,
          "forks_count": 300,
          "language": null,
          "html_url": "https://github.com/swiftlang/swift-testing"
        }
      ]
    }
    """.utf8)

    @Test("decodes a realistic payload into domain models")
    func decodesRealisticPayload() throws {
        let response = try JSONDecoder().decode(GitHubSearchResponse.self, from: Self.searchResponseJSON)
        let repos = response.items.map(Repo.init(dto:))

        #expect(repos.count == 2)
        let first = try #require(repos.first)
        #expect(first.id == 44838949)
        #expect(first.fullName == "apple/swift")
        #expect(first.ownerLogin == "apple")
        #expect(first.summary == "The Swift Programming Language")
        #expect(first.stargazersCount == 67000)
        #expect(first.forksCount == 10000)
        #expect(first.language == "C++")
        #expect(first.htmlURL == URL(string: "https://github.com/apple/swift"))
    }

    @Test("optional fields decode as nil when the API sends null")
    func optionalFieldsDecodeAsNil() throws {
        let response = try JSONDecoder().decode(GitHubSearchResponse.self, from: Self.searchResponseJSON)
        let second = try #require(response.items.last.map(Repo.init(dto:)))
        #expect(second.summary == nil)
        #expect(second.language == nil)
    }

    /// Parameterized test: several malformed payloads, one test body.
    @Test("malformed payloads throw", arguments: [
        #"{ "items": [ { "full_name": "a/b" } ] }"#,        // missing required fields
        #"{ "total_count": 1 }"#,                            // missing items array
        #"not json at all"#,
    ])
    func malformedPayloadsThrow(fixture: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GitHubSearchResponse.self, from: Data(fixture.utf8))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile (types don't exist)**

Run the unit test command. Expected: build failure mentioning `GitHubSearchResponse`/`Repo` not found.

- [ ] **Step 3: Implement the models**

Create `testExample/testExample/Models/Repo.swift`:

```swift
import Foundation

/// The app's domain model for a repository.
///
/// Deliberately separate from the network DTO (`RepoDTO`): the API's shape is
/// GitHub's decision, this type's shape is ours. When the API changes, only
/// the DTO and its mapping move.
///
/// `nonisolated`: this project uses Xcode's default-`MainActor` isolation, so
/// types that must cross concurrency boundaries (decoded on a background
/// URLSession task, displayed on the main actor) opt out explicitly.
/// `Sendable` is trivially satisfied because this is an immutable value type.
nonisolated struct Repo: Identifiable, Hashable, Sendable {
    let id: Int
    let fullName: String
    let ownerLogin: String
    /// GitHub calls this `description`; renamed to avoid colliding with
    /// `CustomStringConvertible.description` conventions.
    let summary: String?
    let stargazersCount: Int
    let forksCount: Int
    let language: String?
    let htmlURL: URL
}
```

Create `testExample/testExample/Models/GitHubSearchResponse.swift`:

```swift
import Foundation

/// Data-transfer objects mirroring GitHub's `/search/repositories` JSON.
///
/// Explicit `CodingKeys` (rather than a global `convertFromSnakeCase`
/// strategy) keep the mapping greppable: search for `full_name` and you land
/// here.
nonisolated struct GitHubSearchResponse: Decodable, Sendable {
    let items: [RepoDTO]
}

nonisolated struct RepoDTO: Decodable, Sendable {
    struct Owner: Decodable, Sendable {
        let login: String
    }

    let id: Int
    let fullName: String
    let owner: Owner
    let description: String?
    let stargazersCount: Int
    let forksCount: Int
    let language: String?
    let htmlUrl: URL

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case owner
        case description
        case stargazersCount = "stargazers_count"
        case forksCount = "forks_count"
        case language
        case htmlUrl = "html_url"
    }
}

extension Repo {
    /// The single seam where API shape becomes domain shape.
    init(dto: RepoDTO) {
        self.init(
            id: dto.id,
            fullName: dto.fullName,
            ownerLogin: dto.owner.login,
            summary: dto.description,
            stargazersCount: dto.stargazersCount,
            forksCount: dto.forksCount,
            language: dto.language,
            htmlURL: dto.htmlUrl
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the unit test command. Expected: `** TEST SUCCEEDED **`, all `RepoDecodingTests` passing.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "feat: add Repo domain model and GitHub DTO decoding"
```

---

### Task 3: GitHubClient protocol, errors, live + mock clients (TDD)

**Files:**
- Create: `testExample/testExample/Services/GitHubClient.swift`
- Create: `testExample/testExample/Services/LiveGitHubClient.swift`
- Create: `testExample/testExample/Services/MockGitHubClient.swift`
- Test: `testExample/testExampleTests/LiveGitHubClientTests.swift`

**Interfaces:**
- Consumes: `Repo`, `GitHubSearchResponse`, `RepoDTO` from Task 2.
- Produces:
  - `nonisolated protocol GitHubClient: Sendable { func searchRepositories(matching query: String) async throws -> [Repo] }`
  - `nonisolated enum GitHubClientError: Error, Equatable, LocalizedError` with cases `.invalidQuery`, `.network`, `.rateLimited`, `.server(statusCode: Int)`, `.decoding`.
  - `LiveGitHubClient` with `static func searchURL(matching query: String) -> URL?`.
  - `MockGitHubClient` (DEBUG only) with `enum Scenario: String, Sendable { case success, searchError }`, `init(scenario: Scenario = .success)`, and `static let fixtureRepos: [Repo]` containing exactly three repos whose `fullName`s are `"apple/swift"`, `"swiftlang/swift-testing"`, `"vapor/vapor"`.

- [ ] **Step 1: Write the failing URL-building tests**

Create `testExample/testExampleTests/LiveGitHubClientTests.swift`:

```swift
import Foundation
import Testing
@testable import testExample

@Suite("LiveGitHubClient request building")
struct LiveGitHubClientTests {

    @Test("search URL targets the GitHub search API with the query")
    func searchURLShape() throws {
        let url = try #require(LiveGitHubClient.searchURL(matching: "swift"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "api.github.com")
        #expect(components.path == "/search/repositories")
        #expect(components.queryItems?.contains(URLQueryItem(name: "q", value: "swift")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "per_page", value: "30")) == true)
    }

    @Test("queries are percent-encoded, not mangled")
    func queryEncoding() throws {
        let url = try #require(LiveGitHubClient.searchURL(matching: "swift ui kit"))
        #expect(url.absoluteString.contains("q=swift%20ui%20kit"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run the unit test command. Expected: build failure, `LiveGitHubClient` not found.

- [ ] **Step 3: Implement protocol, error, live client, mock client**

Create `testExample/testExample/Services/GitHubClient.swift`:

```swift
import Foundation

/// Abstraction over "something that can search GitHub".
///
/// The protocol is the seam that makes everything else testable: unit tests
/// substitute spies, previews and UI tests substitute `MockGitHubClient`,
/// production uses `LiveGitHubClient`. Callers never know the difference.
nonisolated protocol GitHubClient: Sendable {
    func searchRepositories(matching query: String) async throws -> [Repo]
}

/// Typed failures for the GitHub client.
///
/// A closed error enum (instead of rethrowing raw `URLError`/`DecodingError`)
/// means the UI layer switches over a small, stable set of cases — and the
/// user-facing copy lives here, once, via `LocalizedError`.
nonisolated enum GitHubClientError: Error, Equatable, LocalizedError {
    case invalidQuery
    case network
    case rateLimited
    case server(statusCode: Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            String(localized: "That search can't be sent. Try different text.")
        case .network:
            String(localized: "Couldn't reach GitHub. Check your connection and try again.")
        case .rateLimited:
            String(localized: "GitHub is rate-limiting searches right now. Give it a minute.")
        case .server(let statusCode):
            String(localized: "GitHub had a problem (HTTP \(statusCode)). Try again shortly.")
        case .decoding:
            String(localized: "GitHub sent a response this app couldn't read.")
        }
    }
}
```

Create `testExample/testExample/Services/LiveGitHubClient.swift`:

```swift
import Foundation

/// Production `GitHubClient` backed by `URLSession` and `async/await`.
///
/// Note what is *not* here: no Combine. One-shot request/response work is
/// exactly what `async/await` is for. Combine appears in this codebase only
/// where values genuinely stream over time (see `SearchViewModel`).
nonisolated struct LiveGitHubClient: GitHubClient {
    var session: URLSession = .shared

    /// Static and pure so URL construction is unit-testable without any
    /// networking.
    static func searchURL(matching query: String) -> URL? {
        var components = URLComponents(string: "https://api.github.com/search/repositories")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "per_page", value: "30"),
        ]
        return components?.url
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        guard let url = Self.searchURL(matching: query) else {
            throw GitHubClientError.invalidQuery
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw GitHubClientError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubClientError.network
        }
        switch http.statusCode {
        case 200:
            break
        case 403, 429:
            // GitHub signals rate limiting with 403 (legacy) and 429.
            throw GitHubClientError.rateLimited
        default:
            throw GitHubClientError.server(statusCode: http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(GitHubSearchResponse.self, from: data)
            return decoded.items.map(Repo.init(dto:))
        } catch {
            throw GitHubClientError.decoding
        }
    }
}
```

Create `testExample/testExample/Services/MockGitHubClient.swift`:

```swift
import Foundation

#if DEBUG
/// Deterministic `GitHubClient` for previews and UI tests.
///
/// Lives in the app target (not the test bundle) because previews and
/// UI-test launches execute the real app binary. The `#if DEBUG` guard keeps
/// it out of release builds.
nonisolated struct MockGitHubClient: GitHubClient {
    /// Scenario names arrive from UI tests via the `UITEST_SCENARIO`
    /// environment variable, hence `String` raw values.
    enum Scenario: String, Sendable {
        case success
        case searchError
    }

    var scenario: Scenario = .success

    /// Fixed results regardless of query — determinism beats realism in
    /// tests. A short artificial delay keeps loading states visible and
    /// exercises the async path.
    static let fixtureRepos: [Repo] = [
        Repo(id: 1, fullName: "apple/swift", ownerLogin: "apple",
             summary: "The Swift Programming Language",
             stargazersCount: 67000, forksCount: 10000,
             language: "C++", htmlURL: URL(string: "https://github.com/apple/swift")!),
        Repo(id: 2, fullName: "swiftlang/swift-testing", ownerLogin: "swiftlang",
             summary: "A modern, expressive testing package for Swift",
             stargazersCount: 2000, forksCount: 300,
             language: "Swift", htmlURL: URL(string: "https://github.com/swiftlang/swift-testing")!),
        Repo(id: 3, fullName: "vapor/vapor", ownerLogin: "vapor",
             summary: "A server-side Swift HTTP web framework",
             stargazersCount: 25000, forksCount: 1500,
             language: "Swift", htmlURL: URL(string: "https://github.com/vapor/vapor")!),
    ]

    func searchRepositories(matching query: String) async throws -> [Repo] {
        try await Task.sleep(for: .milliseconds(300))
        switch scenario {
        case .success:
            return Self.fixtureRepos
        case .searchError:
            throw GitHubClientError.rateLimited
        }
    }
}
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Run the unit test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "feat: add GitHubClient protocol with live and mock implementations"
```

---

### Task 4: LoadState + SearchViewModel core (TDD)

**Files:**
- Create: `testExample/testExample/Support/LoadState.swift`
- Create: `testExample/testExample/ViewModels/SearchViewModel.swift`
- Test: `testExample/testExampleTests/SearchViewModelTests.swift`
- Test helper: `testExample/testExampleTests/TestSupport.swift`

**Interfaces:**
- Consumes: `GitHubClient`, `GitHubClientError`, `Repo`.
- Produces:
  - `nonisolated enum LoadState<Value: Sendable & Equatable>: Equatable, Sendable` — cases `.idle`, `.loading`, `.loaded(Value)`, `.failed(message: String)`.
  - `@Observable final class SearchViewModel` (MainActor via default isolation) with:
    - `init(client: any GitHubClient, debounceInterval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(300))`
    - `var searchText: String` (settable), `private(set) var state: LoadState<[Repo]>`, `private(set) var lastRefreshed: Date?`, `private(set) var now: Date`
    - `func search(matching query: String) async`, `func retry()`
    - `var lastRefreshedDescription: String?` and `static func refreshedDescription(from lastRefreshed: Date?, now: Date) -> String?`
  - Test target: `SpyGitHubClient` and `GatedGitHubClient` actors, `[Repo].fixture`, `poll(until:)` helper (all in `TestSupport.swift`, reused by later tasks).

- [ ] **Step 1: Write test support + failing state-transition tests**

Create `testExample/testExampleTests/TestSupport.swift`:

```swift
import Foundation
import Testing
@testable import testExample

/// Records queries and returns a canned result.
///
/// An actor, not a class-with-a-lock: test doubles are a natural place to
/// demonstrate that actors are the default answer for mutable shared state.
actor SpyGitHubClient: GitHubClient {
    private(set) var queries: [String] = []
    private let result: Result<[Repo], GitHubClientError>

    init(result: Result<[Repo], GitHubClientError>) {
        self.result = result
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        queries.append(query)
        return try result.get()
    }
}

/// Suspends every request until the test calls `open()`, letting tests
/// observe in-flight (`.loading`) state deterministically — no sleeps.
actor GatedGitHubClient: GitHubClient {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private let repos: [Repo]

    init(repos: [Repo]) {
        self.repos = repos
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        await withCheckedContinuation { continuations.append($0) }
        return repos
    }

    func open() {
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

extension [Repo] {
    static let fixture: [Repo] = [
        Repo(id: 1, fullName: "apple/swift", ownerLogin: "apple",
             summary: "The Swift Programming Language",
             stargazersCount: 67000, forksCount: 10000,
             language: "C++", htmlURL: URL(string: "https://github.com/apple/swift")!)
    ]
}

/// Polls a main-actor condition until it holds or the timeout elapses.
/// Records a test failure on timeout so callers read linearly.
@MainActor
func poll(
    until condition: () -> Bool,
    timeout: Duration = .seconds(2),
    message: @autoclosure () -> String = "condition"
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(message())")
}
```

Create `testExample/testExampleTests/SearchViewModelTests.swift`:

```swift
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

    @Test("refreshed description reports whole seconds")
    func refreshedDescription() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(SearchViewModel.refreshedDescription(from: base, now: base.addingTimeInterval(42)) == "Updated 42s ago")
        #expect(SearchViewModel.refreshedDescription(from: nil, now: base) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run the unit test command. Expected: build failure, `SearchViewModel`/`LoadState` not found.

- [ ] **Step 3: Implement LoadState and SearchViewModel**

Create `testExample/testExample/Support/LoadState.swift`:

```swift
/// The lifecycle of any asynchronously loaded value, as a closed enum.
///
/// This is the headline pattern of the codebase: instead of juggling
/// `isLoading: Bool` + `items: [Repo]` + `error: Error?` (eight combinations,
/// most of them nonsense), one enum makes illegal states unrepresentable.
/// The UI layer `switch`es over it and the compiler guarantees every state
/// has a screen.
///
/// `failed` carries a display-ready message rather than the `Error` itself:
/// errors aren't `Equatable`, and by the time state reaches the view the only
/// question left is "what do we tell the user?".
nonisolated enum LoadState<Value: Sendable & Equatable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(message: String)
}
```

Create `testExample/testExample/ViewModels/SearchViewModel.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run the unit test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "feat: add LoadState and SearchViewModel with Combine search pipeline"
```

---

### Task 5: Debounce behavior test (TDD — behavior lock-in)

**Files:**
- Modify: `testExample/testExampleTests/SearchViewModelTests.swift` (append tests)

**Interfaces:**
- Consumes: `SearchViewModel`, `SpyGitHubClient`, `poll(until:)` from Task 4.

- [ ] **Step 1: Add the debounce tests**

Append inside `SearchViewModelTests`:

```swift
    @Test("rapid typing coalesces into a single request for the final text")
    func rapidTypingCoalesces() async throws {
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy, debounceInterval: .milliseconds(50))

        viewModel.searchText = "s"
        viewModel.searchText = "sw"
        viewModel.searchText = "swift"

        try await poll(until: { viewModel.state == .loaded(.fixture) }, message: "state == .loaded")
        #expect(await spy.queries == ["swift"])
    }

    @Test("unchanged text does not re-search (removeDuplicates)")
    func unchangedTextDoesNotResearch() async throws {
        let spy = SpyGitHubClient(result: .success(.fixture))
        let viewModel = SearchViewModel(client: spy, debounceInterval: .milliseconds(50))

        viewModel.searchText = "swift"
        try await poll(until: { viewModel.state == .loaded(.fixture) }, message: "first load")

        viewModel.searchText = "swift"
        // Give the pipeline time to (wrongly) fire again before asserting.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await spy.queries == ["swift"])
    }
```

- [ ] **Step 2: Run tests to verify they pass**

Run the unit test command. Expected: `** TEST SUCCEEDED **`. (The implementation from Task 4 should already satisfy these; they exist to lock the behavior in. If either fails, fix `SearchViewModel`, not the test.)

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "test: lock in debounce and duplicate-suppression behavior"
```

---

### Task 6: SwiftData FavoriteRepo + FavoritesStore (TDD)

**Files:**
- Create: `testExample/testExample/Persistence/FavoriteRepo.swift`
- Create: `testExample/testExample/Persistence/FavoritesStore.swift`
- Test: `testExample/testExampleTests/FavoritesStoreTests.swift`

**Interfaces:**
- Consumes: `Repo`.
- Produces:
  - `@Model final class FavoriteRepo` with `repoID: Int` (`@Attribute(.unique)`), `fullName`, `ownerLogin`, `summary: String?`, `stargazersCount: Int`, `forksCount: Int`, `language: String?`, `htmlURL: URL`, `savedAt: Date`; `init(repo: Repo, savedAt: Date = .now)`; `var asRepo: Repo`.
  - `struct FavoritesStore` with `init(context: ModelContext)`, `func isFavorite(_ repo: Repo) -> Bool`, `func toggle(_ repo: Repo) throws`, `func remove(_ favorite: FavoriteRepo) throws`.

- [ ] **Step 1: Write the failing store tests**

Create `testExample/testExampleTests/FavoritesStoreTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import testExample

/// SwiftData is fully testable without touching disk: an in-memory
/// `ModelContainer` per test gives hermetic, parallel-safe persistence tests.
@MainActor
@Suite("FavoritesStore")
struct FavoritesStoreTests {

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FavoriteRepo.self, configurations: configuration)
        return ModelContext(container)
    }

    private var sampleRepo: Repo {
        Repo(id: 99, fullName: "octo/sample", ownerLogin: "octo",
             summary: "Sample", stargazersCount: 10, forksCount: 2,
             language: "Swift", htmlURL: URL(string: "https://github.com/octo/sample")!)
    }

    @Test("toggling an unknown repo favorites it")
    func toggleAdds() throws {
        let context = try makeContext()
        let store = FavoritesStore(context: context)

        try store.toggle(sampleRepo)

        #expect(store.isFavorite(sampleRepo))
        #expect(try context.fetchCount(FetchDescriptor<FavoriteRepo>()) == 1)
    }

    @Test("toggling a favorited repo removes it")
    func toggleRemoves() throws {
        let context = try makeContext()
        let store = FavoritesStore(context: context)

        try store.toggle(sampleRepo)
        try store.toggle(sampleRepo)

        #expect(!store.isFavorite(sampleRepo))
        #expect(try context.fetchCount(FetchDescriptor<FavoriteRepo>()) == 0)
    }

    @Test("favorites round-trip back into domain models")
    func favoriteRoundTrips() throws {
        let context = try makeContext()
        let store = FavoritesStore(context: context)
        let repo = sampleRepo

        try store.toggle(repo)
        let saved = try #require(try context.fetch(FetchDescriptor<FavoriteRepo>()).first)

        #expect(saved.asRepo == repo)
    }

    @Test("remove deletes the given favorite")
    func removeDeletes() throws {
        let context = try makeContext()
        let store = FavoritesStore(context: context)
        try store.toggle(sampleRepo)
        let saved = try #require(try context.fetch(FetchDescriptor<FavoriteRepo>()).first)

        try store.remove(saved)

        #expect(try context.fetchCount(FetchDescriptor<FavoriteRepo>()) == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run the unit test command. Expected: build failure, `FavoriteRepo`/`FavoritesStore` not found.

- [ ] **Step 3: Implement the model and store**

Create `testExample/testExample/Persistence/FavoriteRepo.swift`:

```swift
import Foundation
import SwiftData

/// SwiftData record for a favorited repository.
///
/// Deliberately a *separate type* from `Repo`: persistence schema and domain
/// model evolve on different clocks (schema migrations vs API changes), so
/// they shouldn't be the same type even when the fields rhyme. `asRepo` and
/// `init(repo:)` are the two conversion seams.
@Model
final class FavoriteRepo {
    /// `.unique` makes SwiftData upsert on conflict — favoriting the same
    /// repo twice can never create duplicates.
    @Attribute(.unique) var repoID: Int
    var fullName: String
    var ownerLogin: String
    var summary: String?
    var stargazersCount: Int
    var forksCount: Int
    var language: String?
    var htmlURL: URL
    var savedAt: Date

    init(repo: Repo, savedAt: Date = .now) {
        self.repoID = repo.id
        self.fullName = repo.fullName
        self.ownerLogin = repo.ownerLogin
        self.summary = repo.summary
        self.stargazersCount = repo.stargazersCount
        self.forksCount = repo.forksCount
        self.language = repo.language
        self.htmlURL = repo.htmlURL
        self.savedAt = savedAt
    }
}

extension FavoriteRepo {
    var asRepo: Repo {
        Repo(
            id: repoID,
            fullName: fullName,
            ownerLogin: ownerLogin,
            summary: summary,
            stargazersCount: stargazersCount,
            forksCount: forksCount,
            language: language,
            htmlURL: htmlURL
        )
    }
}
```

Create `testExample/testExample/Persistence/FavoritesStore.swift`:

```swift
import Foundation
import SwiftData

/// Thin repository over `ModelContext` for favorite mutations.
///
/// Views *read* favorites with `@Query` (live, animated updates for free) but
/// *write* through this type, so the write rules — dedup, save timing — live
/// in one unit-testable place instead of scattered across views.
struct FavoritesStore {
    let context: ModelContext

    func isFavorite(_ repo: Repo) -> Bool {
        ((try? existingFavorite(for: repo)) ?? nil) != nil
    }

    /// Favorite if absent, unfavorite if present.
    func toggle(_ repo: Repo) throws {
        if let existing = try existingFavorite(for: repo) {
            context.delete(existing)
        } else {
            context.insert(FavoriteRepo(repo: repo))
        }
        try context.save()
    }

    func remove(_ favorite: FavoriteRepo) throws {
        context.delete(favorite)
        try context.save()
    }

    private func existingFavorite(for repo: Repo) throws -> FavoriteRepo? {
        // #Predicate can't reference `repo.id` directly — capture the value.
        let id = repo.id
        var descriptor = FetchDescriptor<FavoriteRepo>(predicate: #Predicate { $0.repoID == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the unit test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "feat: add SwiftData FavoriteRepo model and FavoritesStore"
```

---

### Task 7: Composition root, RootView, SearchView

**Files:**
- Create: `testExample/testExample/Support/AppDependencies.swift`
- Create: `testExample/testExample/Views/RootView.swift`
- Create: `testExample/testExample/Views/Search/SearchView.swift`
- Create: `testExample/testExample/Views/Search/RepoRowView.swift`
- Create: `testExample/testExample/Support/PreviewSupport.swift`
- Modify: `testExample/testExample/testExampleApp.swift` → rename to `RepoScoutApp.swift`
- Delete: `testExample/testExample/ContentView.swift`

**Interfaces:**
- Consumes: `SearchViewModel`, `GitHubClient`, `LiveGitHubClient`, `MockGitHubClient`, `FavoriteRepo`, `LoadState`, `Repo`.
- Produces:
  - `AppDependencies` — `final class` with `let client: any GitHubClient`, `let modelContainer: ModelContainer`, `let searchViewModel: SearchViewModel`, `init(processInfo: ProcessInfo = .processInfo)`. Honors launch args `-UITestMockNetwork`, `-UITestInMemoryStore`, env `UITEST_SCENARIO`.
  - `RootView(searchViewModel:)` — TabView with Search and Favorites tabs. **Note:** until Task 9 exists, the Favorites tab shows a placeholder `Text` — this task creates it with `FavoritesPlaceholderView` replaced in Task 9. To avoid churn, this task creates a minimal real `FavoritesView` file in Task 9 only; here, use `Text("Favorites coming in Task 9")` inline and mark it with `// TODO(Task 9)` — this is the one permitted TODO, removed by Task 9.
  - `SearchView(viewModel:)`, `RepoRowView(repo:)`.
  - Accessibility identifiers produced here (UI tests depend on these exact strings): `search.loading`, `search.list`, `search.row.<fullName>`, `search.errorView`, `search.retryButton`.
  - `previewContainer: ModelContainer` (DEBUG-only, in-memory, seeded).

- [ ] **Step 1: Create AppDependencies**

Create `testExample/testExample/Support/AppDependencies.swift`:

```swift
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
```

- [ ] **Step 2: Replace the App entry point**

```bash
git mv testExample/testExample/testExampleApp.swift testExample/testExample/RepoScoutApp.swift
rm testExample/testExample/ContentView.swift
```

Write `testExample/testExample/RepoScoutApp.swift`:

```swift
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
```

- [ ] **Step 3: Create RootView, SearchView, RepoRowView, preview support**

Create `testExample/testExample/Views/RootView.swift`:

```swift
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
```

Create `testExample/testExample/Views/Search/SearchView.swift`:

```swift
import SwiftUI

/// The search screen. Note the shape: the view is a pure function of
/// `viewModel.state` — every case of `LoadState` maps to exactly one branch,
/// and the compiler won't let us forget one.
struct SearchView: View {
    /// `@Bindable` bridges an `@Observable` object into bindings
    /// (`$viewModel.searchText`) — the successor to `@ObservedObject`.
    @Bindable var viewModel: SearchViewModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("RepoScout")
                .searchable(text: $viewModel.searchText, prompt: "Search GitHub repositories")
                // Type-safe navigation: pushing a value, not a view. The
                // destination for `Repo` values is declared once, here.
                .navigationDestination(for: Repo.self) { repo in
                    RepoDetailView(repo: repo)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            ContentUnavailableView(
                "Search GitHub",
                systemImage: "magnifyingglass",
                description: Text("Find repositories by name, topic, or language.")
            )
        case .loading:
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("search.loading")
        case .loaded(let repos) where repos.isEmpty:
            ContentUnavailableView.search(text: viewModel.searchText)
        case .loaded(let repos):
            List(repos) { repo in
                NavigationLink(value: repo) {
                    RepoRowView(repo: repo)
                }
                .accessibilityIdentifier("search.row.\(repo.fullName)")
            }
            .accessibilityIdentifier("search.list")
            .safeAreaInset(edge: .bottom) {
                if let refreshed = viewModel.lastRefreshedDescription {
                    Text(refreshed)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    viewModel.retry()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("search.retryButton")
            }
            .accessibilityIdentifier("search.errorView")
        }
    }
}

#if DEBUG
#Preview("Results") {
    SearchView(viewModel: SearchViewModel(client: MockGitHubClient()))
}

#Preview("Error") {
    SearchView(viewModel: SearchViewModel(client: MockGitHubClient(scenario: .searchError)))
}
#endif
```

**Note:** `RepoDetailView` does not exist until Task 8. To keep this task independently buildable, create a minimal stub file `testExample/testExample/Views/Detail/RepoDetailView.swift` now — Task 8 replaces its body entirely:

```swift
import SwiftUI

struct RepoDetailView: View {
    let repo: Repo

    var body: some View {
        Text(repo.fullName) // Replaced with the real detail screen in Task 8.
    }
}
```

Create `testExample/testExample/Views/Search/RepoRowView.swift`:

```swift
import SwiftUI

/// One search result row. Small, stateless, preview-driven — the default
/// shape for leaf views.
struct RepoRowView: View {
    let repo: Repo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(repo.fullName)
                .font(.headline)
            if let summary = repo.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Label("\(repo.stargazersCount)", systemImage: "star")
                if let language = repo.language {
                    Label(language, systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        // Merge the row into one accessibility element with a sentence-shaped
        // label, instead of making VoiceOver users step through four fragments.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [repo.fullName, "\(repo.stargazersCount) stars"]
        if let language = repo.language { parts.append("written in \(language)") }
        if let summary = repo.summary { parts.append(summary) }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    List(MockGitHubClient.fixtureRepos) { repo in
        RepoRowView(repo: repo)
    }
}
#endif
```

Create `testExample/testExample/Support/PreviewSupport.swift`:

```swift
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
```

- [ ] **Step 4: Build and verify**

Run the build-only command. Expected: `** BUILD SUCCEEDED **`.
Then run the unit test command to confirm nothing regressed. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "feat: add composition root, RootView, and search screen"
```

---

### Task 8: RepoDetailView

**Files:**
- Modify: `testExample/testExample/Views/Detail/RepoDetailView.swift` (replace the Task 7 stub)

**Interfaces:**
- Consumes: `Repo`, `FavoriteRepo`, `FavoritesStore`.
- Produces: full detail screen. Accessibility identifiers UI tests depend on: `detail.favoriteButton`.

- [ ] **Step 1: Implement the detail screen**

Replace `testExample/testExample/Views/Detail/RepoDetailView.swift` with:

```swift
import OSLog
import SwiftData
import SwiftUI

/// Repository detail. Deliberately has **no view model**: there is no async
/// orchestration here — favorite state comes live from SwiftData via a
/// parameterized `@Query`, and the only action is a one-line store call.
/// A view model would be ceremony. (Contrast with `SearchView`, where the
/// pipeline earns one.)
struct RepoDetailView: View {
    let repo: Repo

    @Environment(\.modelContext) private var modelContext
    @Query private var matches: [FavoriteRepo]

    private static let logger = Logger(subsystem: "work.timmaher.testExample", category: "favorites")

    init(repo: Repo) {
        self.repo = repo
        // A @Query built in init — filtered to this repo — so favorite state
        // updates live if it changes anywhere else in the app.
        let id = repo.id
        _matches = Query(filter: #Predicate<FavoriteRepo> { $0.repoID == id })
    }

    private var isFavorite: Bool {
        !matches.isEmpty
    }

    var body: some View {
        List {
            if let summary = repo.summary {
                Section("About") {
                    Text(summary)
                }
            }
            Section("Stats") {
                LabeledContent("Stars", value: repo.stargazersCount.formatted())
                LabeledContent("Forks", value: repo.forksCount.formatted())
                if let language = repo.language {
                    LabeledContent("Language", value: language)
                }
                LabeledContent("Owner", value: repo.ownerLogin)
            }
            Section {
                Link("View on GitHub", destination: repo.htmlURL)
                    .accessibilityIdentifier("detail.githubLink")
            }
        }
        .navigationTitle(repo.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityIdentifier("detail.favoriteButton")
            }
        }
    }

    private func toggleFavorite() {
        do {
            try FavoritesStore(context: modelContext).toggle(repo)
        } catch {
            // A local-store write failing is exceptional; log rather than
            // interrupt. (A data-critical app would surface an alert here.)
            Self.logger.error("Failed to toggle favorite: \(error)")
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        RepoDetailView(repo: MockGitHubClient.fixtureRepos[0])
    }
    .modelContainer(previewContainer)
}
#endif
```

- [ ] **Step 2: Build and run unit tests**

Run the build-only command, then the unit test command. Expected: both succeed.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "feat: add repository detail screen with live favorite state"
```

---

### Task 9: FavoritesView

**Files:**
- Create: `testExample/testExample/Views/Favorites/FavoritesView.swift`
- Modify: `testExample/testExample/Views/RootView.swift` (replace the placeholder)

**Interfaces:**
- Consumes: `FavoriteRepo`, `FavoritesStore`, `RepoRowView`, `RepoDetailView`.
- Produces: favorites tab. Accessibility identifiers UI tests depend on: `favorites.list`, `favorites.row.<fullName>`, `favorites.emptyView`.

- [ ] **Step 1: Implement FavoritesView**

Create `testExample/testExample/Views/Favorites/FavoritesView.swift`:

```swift
import OSLog
import SwiftData
import SwiftUI

/// Favorites tab. Reads live via `@Query` — inserts and deletes made
/// anywhere in the app appear here, animated, with zero wiring. Writes go
/// through `FavoritesStore` so the rules stay in one tested place.
struct FavoritesView: View {
    @Query(sort: \FavoriteRepo.savedAt, order: .reverse)
    private var favorites: [FavoriteRepo]

    @Environment(\.modelContext) private var modelContext

    private static let logger = Logger(subsystem: "work.timmaher.testExample", category: "favorites")

    var body: some View {
        NavigationStack {
            Group {
                if favorites.isEmpty {
                    ContentUnavailableView(
                        "No favorites yet",
                        systemImage: "star",
                        description: Text("Repositories you favorite will appear here.")
                    )
                    .accessibilityIdentifier("favorites.emptyView")
                } else {
                    List {
                        ForEach(favorites) { favorite in
                            NavigationLink(value: favorite.asRepo) {
                                RepoRowView(repo: favorite.asRepo)
                            }
                            .accessibilityIdentifier("favorites.row.\(favorite.fullName)")
                        }
                        .onDelete(perform: delete)
                    }
                    .accessibilityIdentifier("favorites.list")
                }
            }
            .navigationTitle("Favorites")
            .navigationDestination(for: Repo.self) { repo in
                RepoDetailView(repo: repo)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let store = FavoritesStore(context: modelContext)
        for index in offsets {
            do {
                try store.remove(favorites[index])
            } catch {
                Self.logger.error("Failed to remove favorite: \(error)")
            }
        }
    }
}

#if DEBUG
#Preview {
    FavoritesView()
        .modelContainer(previewContainer)
}
#endif
```

- [ ] **Step 2: Replace the RootView placeholder**

In `testExample/testExample/Views/RootView.swift` replace:

```swift
            Tab("Favorites", systemImage: "star.fill") {
                Text("Favorites coming in Task 9") // TODO(Task 9)
            }
```

with:

```swift
            Tab("Favorites", systemImage: "star.fill") {
                FavoritesView()
            }
```

- [ ] **Step 3: Build and run unit tests**

Run the build-only command, then the unit test command. Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "feat: add favorites tab backed by SwiftData @Query"
```

---

### Task 10: String Catalog

**Files:**
- Create: `testExample/testExample/Localizable.xcstrings`

**Interfaces:**
- Consumes: the user-facing string literals from Tasks 3–9.

- [ ] **Step 1: Create the String Catalog**

Create `testExample/testExample/Localizable.xcstrings`. String Catalogs are JSON; entries with an empty body use the key as the English source text. Xcode's build step auto-syncs this file with literals found in code — the manual entries below seed it and document the workflow:

```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "Search GitHub" : {},
    "Find repositories by name, topic, or language." : {},
    "Search GitHub repositories" : {},
    "Searching…" : {},
    "Something went wrong" : {},
    "Retry" : {},
    "RepoScout" : {},
    "Search" : {},
    "Favorites" : {},
    "No favorites yet" : {},
    "Repositories you favorite will appear here." : {},
    "About" : {},
    "Stats" : {},
    "Stars" : {},
    "Forks" : {},
    "Language" : {},
    "Owner" : {},
    "View on GitHub" : {},
    "Add to favorites" : {},
    "Remove from favorites" : {}
  },
  "version" : "1.0"
}
```

- [ ] **Step 2: Build to let Xcode validate/sync the catalog**

Run the build-only command. Expected: `** BUILD SUCCEEDED **`. If the build appends discovered strings (e.g. the error copy from `GitHubClientError`) to the catalog, keep those changes — that's the tool working as designed.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "feat: add String Catalog for localization"
```

---

### Task 11: UI test infrastructure + search happy path

**Files:**
- Create: `testExample/testExampleUITests/Support/BDD.swift`
- Create: `testExample/testExampleUITests/Support/XCUIApplication+Launch.swift`
- Create: `testExample/testExampleUITests/Screens/SearchScreen.swift`
- Create: `testExample/testExampleUITests/Screens/RepoDetailScreen.swift`
- Create: `testExample/testExampleUITests/Screens/FavoritesScreen.swift`
- Create: `testExample/testExampleUITests/SearchFlowUITests.swift`
- Delete: `testExample/testExampleUITests/testExampleUITests.swift` (template stub)

**Interfaces:**
- Consumes: accessibility identifiers from Tasks 7–9 (`search.*`, `detail.*`, `favorites.*`); launch arguments handled by `AppDependencies` (`-UITestMockNetwork`, `-UITestInMemoryStore`, env `UITEST_SCENARIO`); mock fixture names (`apple/swift` etc.).
- Produces:
  - `Given/When/Then/And` free functions wrapping `XCTContext.runActivity`.
  - `XCUIApplication.launchedForUITest(scenario:)`.
  - Screen objects: `SearchScreen`, `RepoDetailScreen`, `FavoritesScreen` — all `struct X { let app: XCUIApplication }` with the members shown below (Task 12 uses them).

- [ ] **Step 1: Delete the template stub and create BDD helpers**

```bash
rm testExample/testExampleUITests/testExampleUITests.swift
```

Create `testExample/testExampleUITests/Support/BDD.swift`:

```swift
import XCTest

/// BDD-style structuring for XCUITests.
///
/// Each step wraps `XCTContext.runActivity`, so the Xcode test report and
/// `xcresult` bundle read as living Gherkin:
///
///     ▸ Given the app has launched to the Search tab
///     ▸ When I search for "swift"
///     ▸ Then I see the apple/swift repository
///
/// No framework, no .feature files — activities are the standard-library way
/// to get scenario-shaped reports.
func Given(_ description: String, _ body: () throws -> Void) rethrows {
    try XCTContext.runActivity(named: "Given \(description)") { _ in try body() }
}

func When(_ description: String, _ body: () throws -> Void) rethrows {
    try XCTContext.runActivity(named: "When \(description)") { _ in try body() }
}

func Then(_ description: String, _ body: () throws -> Void) rethrows {
    try XCTContext.runActivity(named: "Then \(description)") { _ in try body() }
}

func And(_ description: String, _ body: () throws -> Void) rethrows {
    try XCTContext.runActivity(named: "And \(description)") { _ in try body() }
}
```

- [ ] **Step 2: Create the launch helper and screen objects**

Create `testExample/testExampleUITests/Support/XCUIApplication+Launch.swift`:

```swift
import XCTest

extension XCUIApplication {
    /// Launches the app hermetically: mock network, in-memory store.
    /// `scenario` maps to `MockGitHubClient.Scenario` raw values in the app.
    static func launchedForUITest(scenario: String = "success") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockNetwork", "-UITestInMemoryStore"]
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        app.launch()
        return app
    }
}
```

Create `testExample/testExampleUITests/Screens/SearchScreen.swift`:

```swift
import XCTest

/// Screen object for the Search tab.
///
/// Tests never touch raw queries — they speak in user intentions
/// (`search(for:)`) and observable facts (`row(for:)`). When the UI changes,
/// this file changes; the scenarios don't.
struct SearchScreen {
    let app: XCUIApplication

    var searchField: XCUIElement {
        app.searchFields.firstMatch
    }

    var errorView: XCUIElement {
        app.descendants(matching: .any)["search.errorView"].firstMatch
    }

    var retryButton: XCUIElement {
        app.buttons["search.retryButton"]
    }

    func search(for query: String) {
        searchField.tap()
        searchField.typeText(query)
    }

    func row(for fullName: String) -> XCUIElement {
        app.descendants(matching: .any)["search.row.\(fullName)"].firstMatch
    }

    func openDetail(for fullName: String) {
        row(for: fullName).tap()
    }
}
```

Create `testExample/testExampleUITests/Screens/RepoDetailScreen.swift`:

```swift
import XCTest

struct RepoDetailScreen {
    let app: XCUIApplication

    var favoriteButton: XCUIElement {
        app.buttons["detail.favoriteButton"]
    }

    func toggleFavorite() {
        favoriteButton.tap()
    }

    func goBack() {
        app.navigationBars.buttons.firstMatch.tap()
    }
}
```

Create `testExample/testExampleUITests/Screens/FavoritesScreen.swift`:

```swift
import XCTest

struct FavoritesScreen {
    let app: XCUIApplication

    var emptyView: XCUIElement {
        app.descendants(matching: .any)["favorites.emptyView"].firstMatch
    }

    func open() {
        app.tabBars.buttons["Favorites"].tap()
    }

    func row(for fullName: String) -> XCUIElement {
        app.descendants(matching: .any)["favorites.row.\(fullName)"].firstMatch
    }

    func openDetail(for fullName: String) {
        row(for: fullName).tap()
    }
}
```

- [ ] **Step 3: Write the search happy-path scenario**

Create `testExample/testExampleUITests/SearchFlowUITests.swift`:

```swift
import XCTest

final class SearchFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSearchingShowsResults() {
        let app = XCUIApplication.launchedForUITest()
        let search = SearchScreen(app: app)

        Given("the app has launched to the Search tab") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
        }

        When("I search for \"swift\"") {
            search.search(for: "swift")
        }

        Then("I see the apple/swift repository in the results") {
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 5))
        }
    }
}
```

- [ ] **Step 4: Run the UI test**

Run: `xcodebuild test -project testExample.xcodeproj -scheme testExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:testExampleUITests/SearchFlowUITests 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`. If the row query fails, inspect the element tree by adding `print(app.debugDescription)` temporarily — the identifier may land on a `button` or `cell` element type; the `descendants(matching: .any)` query is designed to be resilient to that, so first check the identifier string itself.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "test: add BDD UI-test infrastructure and search happy-path scenario"
```

---

### Task 12: Remaining UI scenarios + launch test cleanup

**Files:**
- Modify: `testExample/testExampleUITests/SearchFlowUITests.swift` (add error scenario)
- Create: `testExample/testExampleUITests/FavoritesFlowUITests.swift`
- Modify: `testExample/testExampleUITests/testExampleUITestsLaunchTests.swift`

**Interfaces:**
- Consumes: everything from Task 11.

- [ ] **Step 1: Add the error scenario**

Append to `SearchFlowUITests`:

```swift
    func testSearchFailureShowsRetryableError() {
        let app = XCUIApplication.launchedForUITest(scenario: "searchError")
        let search = SearchScreen(app: app)

        Given("the app has launched with GitHub rate-limiting searches") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
        }

        When("I search for \"swift\"") {
            search.search(for: "swift")
        }

        Then("I see an error state instead of results") {
            XCTAssertTrue(search.errorView.waitForExistence(timeout: 5))
        }

        And("the error offers a retry action") {
            XCTAssertTrue(search.retryButton.exists)
        }
    }
```

- [ ] **Step 2: Add the favorites round-trip scenario**

Create `testExample/testExampleUITests/FavoritesFlowUITests.swift`:

```swift
import XCTest

final class FavoritesFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFavoritingARepoRoundTrip() {
        let app = XCUIApplication.launchedForUITest()
        let search = SearchScreen(app: app)
        let detail = RepoDetailScreen(app: app)
        let favorites = FavoritesScreen(app: app)

        Given("I have searched for \"swift\" and opened apple/swift") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
            search.search(for: "swift")
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 5))
            search.openDetail(for: "apple/swift")
            XCTAssertTrue(detail.favoriteButton.waitForExistence(timeout: 5))
        }

        When("I favorite the repository") {
            detail.toggleFavorite()
        }

        Then("it appears in the Favorites tab") {
            favorites.open()
            XCTAssertTrue(favorites.row(for: "apple/swift").waitForExistence(timeout: 5))
        }

        When("I unfavorite it from its detail screen") {
            favorites.openDetail(for: "apple/swift")
            XCTAssertTrue(detail.favoriteButton.waitForExistence(timeout: 5))
            detail.toggleFavorite()
            detail.goBack()
        }

        Then("the Favorites tab shows its empty state") {
            XCTAssertTrue(favorites.emptyView.waitForExistence(timeout: 5))
        }
    }
}
```

- [ ] **Step 3: Clean up the template launch test**

Replace the contents of `testExample/testExampleUITests/testExampleUITestsLaunchTests.swift` with:

```swift
import XCTest

/// Smoke test: the app launches at all, on every UI-appearance configuration
/// the suite runs under, and we keep a screenshot in the result bundle.
final class LaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockNetwork", "-UITestInMemoryStore"]
        app.launch()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
```

- [ ] **Step 4: Run the full UI test suite**

Run the UI test command from Global Constraints.
Expected: `** TEST SUCCEEDED **` — all scenarios green.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "test: add error and favorites BDD scenarios, clean up launch test"
```

---

### Task 13: README, ARCHITECTURE, final verification

**Files:**
- Create: `README.md` (repo root)
- Create: `ARCHITECTURE.md` (repo root)

**Interfaces:**
- Consumes: the finished codebase.

- [ ] **Step 1: Write README.md**

At `/Volumes/Dock/Code/testExample/README.md` — cover, in this order, in real prose (not bullet soup): what RepoScout is (a reference app for 2026 iOS practice, built as a GitHub repo search/favorites browser); requirements (Xcode 26.2+); how to run (open `testExample/testExample.xcodeproj`, run the `testExample` scheme); how to run tests, quoting both xcodebuild commands from Global Constraints; a "what to look at" table mapping each practice to its file (LoadState → `Support/LoadState.swift`, Combine debounce → `ViewModels/SearchViewModel.swift`, protocol DI → `Services/GitHubClient.swift` + `Support/AppDependencies.swift`, SwiftData → `Persistence/`, Swift Testing → `testExampleTests/`, BDD UI tests → `testExampleUITests/`); and a note that the project name remains `testExample` deliberately while the product is RepoScout.

- [ ] **Step 2: Write ARCHITECTURE.md**

At `/Volumes/Dock/Code/testExample/ARCHITECTURE.md` — a guided tour with three explicit reading paths addressed to the three audiences:

1. **"New to iOS"** — start at `RepoScoutApp.swift`, follow a keystroke: searchable field → `SearchViewModel.searchText` → Combine debounce → `GitHubClient` → `LoadState` → `SearchView`'s switch. Explain each hop in one short paragraph.
2. **"I've written some SwiftUI"** — the decisions worth stealing: `LoadState` enum vs boolean soup; view model only where it earns its keep (search yes, detail/favorites no); DTO vs domain model split; constructor injection from a composition root; `@Query` for reads + store for writes.
3. **"I shipped ObjC/UIKit, then went into management"** — a translation table: view controller → View + (sometimes) view model; delegate/KVO → `@Observable` tracking; NSFetchedResultsController → `@Query`; Core Data stack → `ModelContainer`; NotificationCenter/timers → Combine publishers; GCD → async/await + actors; XCTest+OCMock → Swift Testing + protocol doubles.

Also include the honest Combine section: where it survives in 2026 (event streams: debounced input, timers), where it doesn't (one-shot requests → async/await), and why this app draws the line where it does.

- [ ] **Step 3: Final full verification**

```bash
cd /Volumes/Dock/Code/testExample/testExample
xcodebuild test -project testExample.xcodeproj -scheme testExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **` — full unit + UI suite green.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/Dock/Code/testExample && git add -A && git commit -m "docs: add README and ARCHITECTURE guided tour"
```
