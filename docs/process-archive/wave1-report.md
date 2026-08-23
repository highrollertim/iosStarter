> **Archived — point-in-time remediation record (Wave 1, 2026-08-22).**
> Superseded by the code and `ARCHITECTURE.md`. Line numbers, code
> listings and "current state" claims herein describe the tree as it
> stood at the end of that wave and **MUST NOT** be used as reference —
> later waves changed several of the files described here. Kept only as a
> record of what was fixed and why.

# Wave 1 remediation report

Branch: `feature/audit-remediation`
Toolchain: Apple Swift 6.2.3 (swiftlang-6.2.3.3.21), Xcode 17C52, iOS 26.2 SDK
Build settings confirmed in `project.pbxproj`: `SWIFT_VERSION = 6.0`,
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`
(the UI-test target's compile line shows the resulting
`-enable-upcoming-feature NonisolatedNonsendingByDefault`, i.e. SE-0461 is live).

## Commits

| Hash | Subject |
|---|---|
| `1dc5aad` | fix: concurrency truth, shipped defects, and UX/accessibility gaps |
| `887ab27` | test: fix test-support defects and cover the Wave 1 behaviour changes |
| `4c7cc86` | test: add UI coverage for the new states, and an accessibility audit |

`project.pbxproj` was **not** modified. `xcodebuild` re-sorts two
`INFOPLIST_KEY_*` lines in it on every run; that reordering was reverted before
each commit and the file is byte-identical to its pre-Wave-1 state.

## Test results

Both suites green on iPhone 17 Pro.

Unit — `-only-testing:testExampleTests` (`** TEST SUCCEEDED **`), tail:

```
Test case 'FavoritesStoreTests/duplicateUniqueIDCollapses()' passed (0.000 seconds)
Test case 'SearchViewModelTests/supersededSearchCannotClobberNewerResult()' passed (0.000 seconds)
Test case 'LiveGitHubClientErrorMappingTests/mapsResponseToTypedError(_:)' passed (0.000 seconds)   [x9 cases]
Test case 'SearchViewModelTests/refiningKeepsStaleResultsVisible()' passed (0.000 seconds)
Test case 'LiveGitHubClientErrorMappingTests/transportFailureBecomesNetwork()' passed (0.000 seconds)
Test case 'LiveGitHubClientErrorMappingTests/cancellationIsNotAClientError()' passed (0.000 seconds)
Test case 'LiveGitHubClientErrorMappingTests/successfulResponseMapsToRepos()' passed (0.000 seconds)
Test case 'LiveGitHubClientErrorMappingTests/requestCarriesRequiredHeaders()' passed (0.000 seconds)
Test case 'SearchViewModelTests/rapidTypingCoalesces()' passed (0.000 seconds)
Test case 'SearchViewModelTests/sameTextResearchesAfterFailure()' passed (0.000 seconds)
Test case 'SearchViewModelTests/unchangedTextDoesNotResearchAfterSuccess()' passed (1.000 seconds)
Test case 'SearchViewModelTests/submitImmediatelyBypassesDebounce()' passed (1.000 seconds)
Test case 'SearchViewModelTests/tickerSeedsStartsAndStops()' passed (3.000 seconds)
```

UI — `-only-testing:testExampleUITests` (`** TEST SUCCEEDED **`, 281s), tail:

```
Test case 'FavoritesFlowUITests.testDeletingAFavoriteViaEditButton()' passed (24.890 seconds)
Test case 'FavoritesFlowUITests.testFavoritingARepoRoundTrip()' passed (25.176 seconds)
Test case 'SearchFlowUITests.testRetryRecoversFromATransientFailure()' passed (11.083 seconds)
Test case 'SearchFlowUITests.testSearchFailureShowsRetryableError()' passed (9.850 seconds)
Test case 'SearchFlowUITests.testSearchingShowsResults()' passed (11.822 seconds)
Test case 'SearchFlowUITests.testSearchWithNoMatchesShowsTheNoResultsState()' passed (9.492 seconds)
Test case 'AccessibilityAuditUITests.testSearchResultsAndFavoritesPassTheAccessibilityAudit()' passed (20.019 seconds)
Test case 'AccessibilityAuditUITests.testSearchResultsSurviveTheLargestDynamicTypeSize()' passed (12.430 seconds)
Test case 'LaunchTests.testLaunch()' passed [x4 UI configurations]
Test case 'LaunchTests.testLaunchPerformance()' passed [x4 UI configurations]
```

---

## A. Concurrency truth (SE-0461)

**A1 — `@concurrent`. Done as specified; no fallback needed.**
`LiveGitHubClient.swift:45`. `@concurrent func searchRepositories(matching:)`
compiles clean in this configuration (Swift 6 language mode, approachable
concurrency on) and satisfies the plain `nonisolated async` protocol
requirement in `GitHubClient` without complaint. No `Task.detached` or private
helper was needed. Doc comment at `LiveGitHubClient.swift:29-44` explains why
the attribute is load-bearing: without it the request *and* the ~100KB
`JSONDecoder().decode` run on the caller's executor, which is the `@MainActor`
`SearchViewModel`.

*Note vs the work order:* the order says "the toolchain is 6.3". The installed
toolchain is 6.2.3. `@concurrent` exists in 6.2, so this made no difference.

**A2 — `Repo` doc comment.** `Models/Repo.swift:9-27`. The false claim
("decoded on a background URLSession task") is gone. Replaced with the three
actual reasons for `nonisolated`: reachability from the `nonisolated`
`GitHubClient` protocol, satisfying `LoadState<Value: Sendable>` non-vacuously,
and a genuine executor crossing *because* the client is now `@concurrent` —
explicitly noting that a plain `nonisolated async` client would have crossed
nothing.

**A3 — `SearchViewModel` isolation comment.** `ViewModels/SearchViewModel.swift:11-24`.
Now states that default isolation is why the sinks *type-check*, and that what
makes them *safe* is `scheduler: DispatchQueue.main` / `on: .main` — "change
either one to a background queue or runloop and the code still compiles clean,
then traps at runtime on the main-actor precondition."

**A4 — Explicit closure annotations.** `SearchViewModel.swift:88-97`. Both the
`filter` and the `sink` closures are `{ @MainActor [weak self] ... }`, and the
ticker's sink at `SearchViewModel.swift:130-132` likewise. `// load-bearing:`
comments sit on the `debounce(scheduler:)` argument (`:85-88`) and the
`Timer.publish(on:)` argument (`:127-128`). These compiled without diagnostics.

**A5 — Cancellation guard invariant + early guard.** `SearchViewModel.swift:160`
carries the early `guard !Task.isCancelled else { return }`, placed above the
new state-transition block per the work order's parenthetical. The post-`await`
guard's invariant is documented at `SearchViewModel.swift:174-181`: the check
cannot go stale because `self` is `@MainActor`, cancellation can therefore only
originate on the main actor, and there is no suspension point between the check
and the writes.

## B. Shipped defects

**B1 — `-UITestInMemoryStore` in Release.** `Support/AppDependencies.swift:26-38`.
`inMemory` is declared before the conditional and assigned inside `#if DEBUG`;
the `#else` branch assigns `false`. Comment explains that launch arguments are
not a trusted channel and a Release build honouring this would have discarded
the user's favorites database.

**B2 — `fatalError` → graceful degrade.** `AppDependencies.swift:45-84`.
Extracted to `makeContainer(inMemory:)`: try persistent, on failure log via
`Logger.startup.fault(...)` and fall back to in-memory; only the second failure
is `fatalError`, justified as "the schema itself is malformed". The doc comment
names schema-migration mismatch after an app update as the likely real cause and
the resulting unbreakable crash loop as the reason not to trap.

**B3 — `LiveGitHubClient` error mapping.** `Services/LiveGitHubClient.swift`:
- `URLRequest(url:timeoutInterval: 15)` with `Accept: application/vnd.github+json`
  and `User-Agent: RepoScout/1.0 (reference app)`, via `session.data(for:)` (`:52-63`).
- `case 200..<300: break` (`:73-77`).
- `case 400, 422: throw .invalidQuery` (`:78-85`) — `.invalidQuery` is no longer
  dead code.
- 403 (`:86-98`) maps to `.rateLimited` only when `x-ratelimit-remaining == "0"`
  or a `Retry-After` header is present, else `.server(statusCode: 403)`; comment
  explains 403 is overloaded and a wrong "give it a minute" is worse than silence.
  429 kept as unconditional `.rateLimited` (`:99-101`).
- Dead `catch is CancellationError` clause removed; the `URLError(.cancelled)`
  clause remains with a comment stating URLSession never throws `CancellationError`
  itself (`:64-70`).
- `var session` comment at `:9-14`.

**B4 — Debounce/retry coherence.** `SearchViewModel.swift`.
`removeDuplicates()` replaced by `.filter { @MainActor [weak self] query in query != self?.lastDispatchedQuery }`
(`:89`), after the debounce. `lastDispatchedQuery` declared at `:46`, set in the
sink at `:92`, set in `submitImmediately()` at `:214`, cleared in the failure
`catch` at `:190` and on the blank→idle path at `:157`. Pipeline doc comment
(`:66-84`) makes the point the work order asked for: dedup on the *input* is
only sound when the operation is deterministic, and a network search isn't.

**B5 — Ticker.** `SearchViewModel.startTicker()` seeds `now = .now` before
subscribing (`:120-126`), with the `max(0,...)` clamp kept and re-commented as
belt-and-braces at `:230-232`. The footer is extracted to a new private leaf
view `LastRefreshedFooter` in `Views/Search/SearchView.swift:88-135`, with an
explicit comment that `@Observable` tracks reads per-`body` and that inlining it
invalidates the whole screen once a second. Footer `Text` has `.monospacedDigit()`
(`:112-114`) and the container has `.accessibilityHidden(true)` (`:121-125`) with
the "1Hz VoiceOver element is hostile" rationale.

**B6 — `LoadState` stale-while-revalidate.** `Support/LoadState.swift:15-25` doc
comment plus `case loaded(Value, isRefreshing: Bool)` at `:29`.
`SearchViewModel.search(matching:)` (`:162-169`) keeps existing results and sets
`isRefreshing: true` when already `.loaded`, else `.loading`; success writes
`isRefreshing: false`. `SearchView` matches `.loaded(let repos, _) where repos.isEmpty`
(`:51`) and `.loaded(let repos, let isRefreshing)` (`:53`), passing `isRefreshing`
into the footer leaf which shows a `ProgressView().controlSize(.mini)` beside the
text. The list is never blanked. All test assertions updated.

**B7 — Previews.** `SearchView.swift:139-152`. Both `#Preview` blocks get
`.modelContainer(previewContainer)`, with a comment about `RepoDetailView`'s
`@Query` needing a context to resolve against on navigation. Required adding
`import SwiftData` to the file.

**B8 — `.searchable` ergonomics.** `SearchView.swift:17-25`:
`.textInputAutocapitalization(.never)`, `.autocorrectionDisabled()`,
`.onSubmit(of: .search) { viewModel.submitImmediately() }`.
`submitImmediately()` at `SearchViewModel.swift:206-217`; `retry()` at `:222-224`
now delegates to it (the work order's "retry() can call it" option).

**B9 — `RepoRowView`.** `Views/Search/RepoRowView.swift`:
`Label(repo.stargazersCount.formatted(), systemImage: "star")` (`:63`);
`ViewThatFits(in: .horizontal)` with `HStack`/`VStack` candidates over a shared
`@ViewBuilder private var stats` (`:27-38`, `:47-66`); `@Environment(\.dynamicTypeSize)`
+ `.lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)` (`:9-12`, `:25`);
accessibility sentences interpolate `repo.stargazersCount.formatted()` via a
local `stars` binding, all four whole-sentence variants kept (`:68-89`).

**B10 — `RepoDetailView` favorite button.** `Views/Detail/RepoDetailView.swift:57-77`.
`Button(title, systemImage:)` with `withAnimation`, `.labelStyle(.iconOnly)`,
`.contentTransition(.symbolEffect(.replace))`, `.sensoryFeedback(.success, trigger: isFavorite)`,
`.accessibilityAddTraits(isFavorite ? [.isSelected] : [])`,
`.accessibilityIdentifier("detail.favoriteButton")` kept, manual
`.accessibilityLabel` removed. GitHub `Link` is gated on
`repo.htmlURL.scheme == "https" || == "http"` via `isWebLink` (`:45-53`, `:79-81`).

**B11 — `FavoritesView`.** `Views/Favorites/FavoritesView.swift`. Single always-present
`List` (`:24-33`) with `.overlay { if favorites.isEmpty { ContentUnavailableView(...) } }`
(`:35-44`); `favorites.list` on the List, `favorites.emptyView` on the CUV.
`.toolbar { EditButton() }` (`:46-55`). `delete(at:)` maps offsets to an array and
makes one `store.remove(_:)` call (`:60-71`).

**B12 — `FavoritesStore`.** `Persistence/FavoritesStore.swift:12-22`:
`func isFavorite(_ repo: Repo) throws -> Bool { try existingFavorite(for: repo) != nil }`,
with a comment noting `try?` conflated "fetch threw" with "not favorited" *and*
that the old expression was right only by accident (`try?` flattening made a
successful nil fetch indistinguishable). Batch `remove(_ favorites: some Sequence<FavoriteRepo>)`
with a single `save()` at `:35-45`; single-item `remove(_:)` delegates via
`CollectionOfOne` (`:47-51`). `FavoriteRepo.repoID`'s `.unique` comment rewritten
(`Persistence/FavoriteRepo.swift:12-25`) as a store-level constraint and safety
net, with no upsert claim, pointing at `existingFavorite(for:)` as the dedup the
app relies on.

**B13 — Logger dedup.** New `Support/Logging.swift` with
`Logger.favorites` and `Logger.startup`, both using
`Bundle.main.bundleIdentifier ?? "RepoScout"`. Both views' private static
`Logger` properties removed; `RepoDetailView.swift:76` and `FavoritesView.swift:69`
use `Logger.favorites`. (Added `Logger.startup` beyond the work order because B2
needs a logger in `AppDependencies` and hard-coding a third construction site
would have re-introduced exactly the duplication B13 removes.)

**B14 — `RootView` / identifiers.** `Views/RootView.swift:8-17`:
`Tab("Search", systemImage: "magnifyingglass", role: .search)`.
Both identifier questions in the work order resolved as *not possible*, and
commented rather than silently skipped:
- `Tab` is a result builder for tab *content*, not a `View`; modifiers applied to
  it decorate the screen inside the tab, not the tab-bar button. There is no API
  to identify that button. Comment at `RootView.swift:24-29`; `FavoritesScreen.open()`
  keeps the localized-title query with the explanation at
  `testExampleUITests/Screens/FavoritesScreen.swift:19-27`.
- `.searchable` owns its text field and exposes no identifier API; an
  `.accessibilityIdentifier` around the modifier lands on the content. Comment at
  `testExampleUITests/Screens/SearchScreen.swift:10-15`. The existing
  `app.searchFields.firstMatch` query is unambiguous (one search field on screen).

**B15 — `MockGitHubClient` → actor.** `Services/MockGitHubClient.swift`.
`actor MockGitHubClient: GitHubClient` inside `#if DEBUG`, `let scenario` +
explicit `init(scenario:)` (an actor's synthesized memberwise init would have
been made private by the `private var completedCalls`). Scenarios `success`,
`searchError`, `emptyResults`, `searchErrorOnce` with raw values unchanged/as
specified; `static let fixtureRepos` unchanged. 300ms sleep kept, deliberately
*before* the scenario switch, with the "cancellation is not one of the scenarios;
it is the thing that happens instead of one" comment (`:62-70`). The call counter
increments *after* the sleep so a cancelled call cannot consume the "once".

## C. Test fixes & additions

**C1 — `poll(until:)`.** `testExampleTests/TestSupport.swift:277-317`. Both
overloads do a final `if condition() { return }` after the loop (commented: the
condition can become true during the last sleep), then `Issue.record(...)` and
`throw PollTimeoutError(message:)` (defined at `:265-275`). Every call site was
already inside a `throws` test and needed no change beyond the `try` they already
had.

**C2 — Gated clients.** `TestSupport.swift`. `GatedGitHubClient` (`:70-113`) and
`KeyedGatedGitHubClient` (`:153-232`) wrap their continuation suspension in
`withTaskCancellationHandler`; the handler resumes only that call's continuation
(identified by a per-call `UUID` ticket) and `try Task.checkCancellation()` after
the resume turns the wake-up into `CancellationError`. A `Task.isCancelled` check
*inside* the continuation body closes the already-cancelled-on-entry window that
would otherwise park a continuation nobody owns. Doc comments rewritten to match.

*Deviation:* the work order specifies `[String: [CheckedContinuation<Void, Never>]]`
for `KeyedGatedGitHubClient`. Implemented as `[String: [Waiter]]` where `Waiter`
is a two-field struct of `(ticket: UUID, continuation: CheckedContinuation<Void, Never>)`.
`CheckedContinuation` is not `Equatable` or otherwise identifiable, so a bare
array offers no way to remove *one specific* waiter on cancellation — which is
the whole point of C2. The array-per-key/append/resume-all semantics the work
order asked for are exactly preserved.

**C3 — `StubURLProtocol`.** `TestSupport.swift:234-283`. `nonisolated(unsafe) static var`
replaced with `private static let stored = Mutex<Handler?>(nil)` (`import Synchronization`)
behind a `static var handler` computed property, so call sites are unchanged. The
doc comment now states the real race — test thread vs. `URLSession` loader thread —
and that `.serialized` never ordered those two. The suite's client factory is
replaced by `withStubbedClient(handler:client:)` (`:296-311`), which calls
`session.finishTasksAndInvalidate()` in a `defer`, so the suite no longer leaks a
loader thread per test.

**C4 — Unit tests.** `testExampleTests/`.
- All `LoadState` assertions updated to `.loaded(x, isRefreshing: false)`.
- `refiningKeepsStaleResultsVisible()` (`SearchViewModelTests.swift:65-90`) — uses
  `KeyedGatedGitHubClient` to assert `.loaded(stale, isRefreshing: true)` while
  the refinement is in flight, then `.loaded(fresh, isRefreshing: false)`.
- `retryRecoversFromFailure()` (`:250-267`) — new `ScriptedGitHubClient` actor
  (`TestSupport.swift:23-58`) consumes an array of results per call.
- `retryAfterClearingGoesIdle()` (`:269-286`).
- `sameTextResearchesAfterFailure()` (`:223-247`) and
  `unchangedTextDoesNotResearchAfterSuccess()` (`:206-221`) — both directions of B4.
- `submitImmediatelyBypassesDebounce()` (`:288-308`) — added to cover B8's dedup claim.
- Error mapping table (`LiveGitHubClientTests.swift:52-72`) gained headers and now
  covers 422→`.invalidQuery`, 400→`.invalidQuery`, 403 bare→`.server(403)`,
  403 + `x-ratelimit-remaining: 0`→`.rateLimited`, 403 + `Retry-After`→`.rateLimited`,
  403 + `x-ratelimit-remaining: 42`→`.server(403)`, 429→`.rateLimited`.
  Standalone tests: `transportFailureBecomesNetwork()` (`URLError(.notConnectedToInternet)`),
  `cancellationIsNotAClientError()` (do/catch asserting the thrown error *is*
  `CancellationError` and specifically is not a `GitHubClientError`),
  `successfulResponseMapsToRepos()` (200 + valid JSON → mapped `[Repo]`), and
  `requestCarriesRequiredHeaders()` (B3's headers and timeout).
- `duplicateUniqueIDCollapses()` (`FavoritesStoreTests.swift:96-110`) — two
  `FavoriteRepo` with the same `repoID` inserted directly and saved.
  **Observed behaviour: `fetchCount == 1`.** The assertion matches what actually
  happened, and the comment says the test exists because the constraint's
  behaviour is worth observing rather than assuming.
- `tickerSeedsStartsAndStops()` (`:158-185`) — asserts `now` advances
  *synchronously* across `startTicker()` (before any tick is possible), then that
  it keeps advancing, then that `stopTicker()` stops it.
- `batchRemoveDeletesAll()` (`FavoritesStoreTests.swift:76-94`) — N removed in one
  call, `!context.hasChanges` proving the single save committed all of them.
- `FavoritesStoreTests` updated to `try store.isFavorite(...)`.

*Addition beyond the work order:* `lateResultFromCancelledTaskIsDiscarded()`
(`SearchViewModelTests.swift:127-151`) with a new `UncancellableGatedGitHubClient`
double (`TestSupport.swift:115-151`). C2 makes the gated clients honour
cancellation, which means `supersededSearchCannotClobberNewerResult()` now
exercises the `catch is CancellationError` branch rather than the post-`await`
guard that A5 asks us to document. Without this second test that guard would have
become untested prose. Its comment in the older test was updated accordingly (C6).

**C5 — UI tests.** `testExampleUITests/`.
- `SearchScreen.search(for:)` (`Screens/SearchScreen.swift:44-62`) waits on
  `app.keyboards.firstMatch.waitForExistence(timeout: 15)` before `typeText`, with
  the Simulator ▸ I/O ▸ Keyboard ▸ Connect Hardware Keyboard note. Verified present
  on this machine's simulator (probe reported `KEYBOARD=true`). Added
  `SearchScreen.submit()` (types Return) for tests that need the keyboard gone.
- `testSearchWithNoMatchesShowsTheNoResultsState()` (`SearchFlowUITests.swift:27-49`)
  under `UITEST_SCENARIO=emptyResults`. The element tree was probed rather than
  guessed: `ContentUnavailableView.search(text:)` renders
  `No Results for “zzzz”` and `Check the spelling or try a new search.`, so
  `SearchScreen.noResultsView` matches `label BEGINSWITH "No Results"` (the query
  is interpolated with locale-specific typographic quotes).
- `testRetryRecoversFromATransientFailure()` (`SearchFlowUITests.swift:73-104`)
  under `UITEST_SCENARIO=searchErrorOnce`.
- `testDeletingAFavoriteViaEditButton()` (`FavoritesFlowUITests.swift:46-85`) plus
  `FavoritesScreen.deleteFirstRowInEditMode()` (`Screens/FavoritesScreen.swift:38-65`).
  Also asserts `favorites.list` still exists afterwards, which is the observable
  consequence of B11's overlay. The existing swipe-free round-trip test is kept.
- `LaunchTests.testLaunchPerformance()` (`testExampleUITestsLaunchTests.swift:27-42`)
  with `XCTApplicationLaunchMetric`; the screenshot test is untouched.
- `AccessibilityAuditUITests` — see below.

**C6 — Stale test comments updated.** `unchangedTextDoesNotResearchAfterSuccess()`
now explains the `lastDispatchedQuery` filter rather than `removeDuplicates()`;
`supersededSearchCannotClobberNewerResult()` now says what it actually proves
post-C2 and points at the new companion test; `LiveGitHubClientErrorMappingTests`'
suite comment no longer claims `.serialized` is what makes the handler safe.

## Accessibility audit findings (C5, last bullet)

`AccessibilityAuditUITests.swift`. Two tests: the audit at default text size over
search results and favorites, and the audit at
`UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge` over search results.
`XCUIApplication.launchedForUITest` gained a `contentSizeCategory:` parameter
(`Support/XCUIApplication+Launch.swift`).

**One real app-side defect found and fixed.** The audit reported
*"Contrast is not high enough … unless font size is larger"* against
`RepoRowView`'s summary text and, once that was addressed, again against the
`.caption` stats row. SwiftUI's `.secondary` resolves to the system
`secondaryLabel`, which renders around 3.9:1 against the default background —
under WCAG AA's 4.5:1 for text below 18pt, which is every line in that row.
Fixed at `Views/Search/RepoRowView.swift:14-26` with a single documented
`private static let deemphasized = Color.primary.opacity(0.65)`, applied to both
the summary (`:34`) and the stats (`:44`). That lands near 8:1 in both light and
dark mode while keeping the row's visual hierarchy. This is a genuine finding —
the audit caught something no amount of looking at the screen had.

**Two issues suppressed, both non-defects, both narrowly filtered:**

1. `.hitRegion` on UIKit's "Clear text" button inside the `.searchable` field
   (measured 19.7 × 19.0pt against the 44 × 44 minimum). The button is built and
   laid out by `UISearchTextField`; `.searchable` exposes no hook to resize or
   replace it. Filtered by audit type *and* element label, not by disabling the
   check.
2. `.textClipped` on the star count at default text size. This is a static
   heuristic — it measures at the current size and predicts overflow at a larger
   one — and it cannot see that B9's `ViewThatFits` reflows the stats row at
   runtime. Rather than assert that in a comment, the second test re-runs the same
   audit at AX5 **with this suppression removed**, and passes; a screenshot at AX5
   confirms the row lays out with nothing truncated. If `ViewThatFits` ever stops
   rescuing the layout, that test fails even though the default-size one passes.

A large number of further `.hitRegion` / *"Element has no description"* issues
appear if the software keyboard is on screen — the emoji category strip and the
predictive-text bar. These are system elements no app can fix, so the audit tests
dismiss the keyboard first (via `SearchScreen.submit()`) rather than filter them.

## D. Sanity list

| Check | Result |
|---|---|
| `removeDuplicates` | Gone from code. Remaining hits are comments in `SearchViewModel`, `SearchViewModelTests`, `SearchFlowUITests` explaining why it was replaced. |
| `nonisolated(unsafe)` | Gone from `TestSupport.swift`. One hit remains, in the doc comment explaining what replaced it. |
| `fatalError` | Two remain. `AppDependencies.swift:81` is the truly-unreachable in-memory fallback, as specified. `PreviewSupport.swift:17` is the pre-existing preview-only in-memory container, same unreachable category, `#if DEBUG`, not in the work order's scope — left as is and flagged here. |
| Bare `%lld` key in `Localizable.xcstrings` | **Absent.** |

**String catalog.** `xcodebuild` does not sync `.xcstrings` (only the Xcode IDE
does), so the catalog was regenerated deliberately: `git checkout` to the
committed state, then `xcrun xcstringstool sync` against the compiler-emitted
`.stringsdata` in `Build/Intermediates.noindex/.../Objects-normal/arm64/`. Net
result: bare `%lld` removed; `%@, %lld stars…` × 4 → `%@, %@ stars…` × 4;
`Add to favorites`/`Remove from favorites` → `Add to Favorites`/`Remove from Favorites`.
No stale entries. The catalog is committed in `1dc5aad` and re-verified clean
after the final build.

## Deviations and concerns

1. **`KeyedGatedGitHubClient` continuation storage** — `[String: [Waiter]]` with a
   `UUID` ticket instead of `[String: [CheckedContinuation<Void, Never>]]`.
   Reason: continuations have no identity, so a bare array cannot support the
   targeted removal that C2's cancellation handling requires. Append / resume-all
   semantics preserved. (Detail under C2.)
2. **`Logger.startup` added** beyond B13's single `Logger.favorites`. B2 needs a
   logger in `AppDependencies`; adding a third hand-rolled `Logger` there would
   have undone B13.
3. **One extra unit test and one extra test double** (`lateResultFromCancelledTaskIsDiscarded`,
   `UncancellableGatedGitHubClient`). C2's fix means no existing test reaches the
   post-`await` cancellation guard that A5 asks us to document as an invariant.
   Rather than leave that guard as untested prose, it now has a test.
4. **One extra UI test** (`testSearchResultsSurviveTheLargestDynamicTypeSize`) as
   the evidence behind the `.textClipped` suppression, per the reasoning above.
5. **`RepoRowView` colour change is a visible design change.** `.secondary` →
   `Color.primary.opacity(0.65)` on the summary and stats. It was required to
   clear the audit and it is a genuine accessibility fix, but it is the one change
   in this wave that alters how the app *looks*, so it is worth an explicit eye
   before merge.
6. **`PreviewSupport.swift:17` still calls `fatalError`.** Out of the work order's
   scope, `#if DEBUG`, and the same unreachable in-memory case B2 accepts — but
   noted so the D-list check reads honestly rather than as a clean sweep.
7. **`.searchable` and `Tab` identifier gaps are unfixable, not skipped.** Both are
   commented in place (B14). UI tests continue to query the search field by
   element type and the Favorites tab by its localized title; a localized test run
   would need attention on the latter.
8. **Toolchain is 6.2.3, not 6.3** as the work order assumed. Immaterial —
   `@concurrent` compiled cleanly and A1 needed no fallback.
9. **Simulator flakiness observed once.** One full-UI-suite run logged an
   `FBSOpenApplicationServiceErrorDomain` launch failure on a parallel clone while
   every test still reported `passed`; the re-run was clean end to end
   (`** TEST SUCCEEDED **`). Worth knowing about if CI ever sees it, most likely
   related to `runsForEachTargetApplicationUIConfiguration` plus the new
   launch-metric test running many launches on cloned simulators.
