# Round 3 — Wave 1 report

Branch: `feature/round3-remediation`. Base: `513c8c7`. Seven commits, both
suites green. `project.pbxproj` untouched (verified: the project uses
`PBXFileSystemSynchronizedRootGroup`, so the new asset catalog entry and the
temporary probe test needed no project edit).

## Commits

| Hash | Scope |
|---|---|
| `a96eb6b` | A1, B1, B4, B5, C1 |
| `bcd7d29` | A2, C6 (part) |
| `b4addea` | A3 |
| `8fa2cb9` | A4 |
| `03fd078` | A5 |
| `9ff2997` | A6, A7, A8, A9 |
| `f7ac1ad` | A10, B2, B3, B6, B7, C2, C4, C5 |

## A. User-hittable bugs

**A1 — `+` percent-encoding.** `Services/LiveGitHubClient.swift:29-40`.
`percentEncodedQuery` is rewritten after `queryItems` are set, with the
form-decoding trap explained. Test: `LiveGitHubClientTests.swift:20-32`
asserts `q=c%2B%2B` and that the rest of the query is untouched.

*Deviation (mechanical).* The literal one-liner from the order does not
compile — `components?.percentEncodedQuery = components?.percentEncodedQuery?…`
is an overlapping access to `components` and Swift's exclusivity checking
rejects it (`error: overlapping accesses to 'components', but modification
requires exclusive access`). Read into a local first; the comment says why.

**A2 — `catch is CancellationError` deleted.** `SearchViewModel.swift:229-247`.
One catch, guarded on the cancellation flag. Comment states the trap:
`LiveGitHubClient` maps any `URLError(.cancelled)` to `CancellationError`, and
`URLSession` raises that code for teardown unrelated to `Task` cancellation.

- New double `RogueCancellationGitHubClient` (`TestSupport.swift:58-88`).
- New test `rogueCancellationErrorSurfacesAsFailure`
  (`SearchViewModelTests.swift:189-215`): drives the real debounce pipeline,
  asserts `.failed`, then re-types the identical text and asserts it reaches
  the client a second time — the observable proxy for "`lastDispatchedQuery`
  was cleared", since that property is private.
- Supersede test comment rewritten (`SearchViewModelTests.swift:170-182`): it
  pins "a superseded search cannot clobber the newer one", delivered by the
  post-await `guard !Task.isCancelled`; the error's type is never consulted.
- `UncancellableGatedGitHubClient`'s doc comment also referenced the deleted
  branch and was corrected (`TestSupport.swift:143-150`).

**A3 — dedup funnel + refreshable.** `SearchViewModel.swift:160-183`.
`@discardableResult func dispatch(_:) -> Task<Void, Never>` stores the trimmed
query as the dedup key, cancels `searchTask`, stores and returns the new task.
Sink → `dispatch(query)`; `submitImmediately()` → `dispatch(searchText)`;
`retry()` still delegates. `search(matching:)` is `private`. Blank-query
comment replaced with the honest justification. `.refreshable` added to the
results List (`SearchView.swift:85-90`).

*Deviation (necessary to deliver the stated intent).* The order specified
storing the key trimmed to fix the `"swift"` / `"swift "` double-fire, but
storing alone does not fix it — the `filter` compared the *raw* emission
against the key, so a trailing space still passed the filter and produced a
duplicate request for the same trimmed query. The filter now trims its
candidate too (`SearchViewModel.swift:88-94`), so both sides of the comparison
are trimmed. Pinned by a new test, `trailingWhitespaceDoesNotRefire`.

All unit tests that called `search(matching:)` now use
`await viewModel.dispatch("…").value`; the gated tests keep the returned task,
poll, open the gate, then await. The supersede test drives the real production
path — the second `dispatch` performs the cancellation.

Filter-dedup test: `retryDedupesTheFollowingEmission`
(`SearchViewModelTests.swift:398-416`) — after success, `retry()` then an
identical debounce emission inside the window yields exactly two client calls.
(This is also C3.)

**A4 — empty-refresh state hole.** `private(set) var lastCompletedQuery`
(`SearchViewModel.swift:27-36`), set to the trimmed query on success and nil on
blank→idle. `LoadState` stays generic. `SearchView.swift:56-76`: the empty
branch binds `isRefreshing` instead of discarding it, titles with
`lastCompletedQuery ?? searchText`, and overlays a `ProgressView` while
refreshing. Test: `emptyRefinementRecordsItsQuery`.

**A5 — failure keeps stale results.** `LoadState.failed(message:stale:)`
(`Support/LoadState.swift:36`) with the doc comment updated. `SearchViewModel`
captures `staleResults` after the SWR promotion and before the `do` block
(`SearchViewModel.swift:215-221`), and still clears `lastDispatchedQuery` on
failure. `SearchView` renders two presentations
(`SearchView.swift:105-142`), both carrying `search.errorView` and
`search.retryButton`; the compact one is a `safeAreaBar` over the stale List.

*Deviation (presentation only).* The view selects the compact presentation on
`case .failed(let message, let stale?) where !stale.isEmpty`. An empty stale
array is a real possibility (a refinement of an empty result set failing) and
rendering a zero-row List under an error bar is worse than the full-screen
error. The model is exactly as specified — `stale` is whatever was in `.loaded`
— and the "is this worth showing" judgement lives in the view.

Tests: `failedRefinementKeepsStaleResults`,
`firstLoadFailureCarriesNoStaleResults`; all existing `.failed` matches updated
to `stale: nil`. The UI error scenario is a first-load failure, so it still
takes the full-screen branch and passed unchanged.

**A6 — haptic, animation, label, URL gate.** `Views/Detail/RepoDetailView.swift`.
`@State private var toggleCount` incremented in `toggleFavorite()`;
`.sensoryFeedback(trigger: toggleCount) { _, _ in isFavorite ? .success : .impact(weight: .light) }`.
`withAnimation { toggleFavorite() }` → plain call plus
`.animation(.default, value: isFavorite)`. Button label is the stable
`"Favorite"` with `.labelStyle(.iconOnly)` and the `.isSelected` trait
retained, so VoiceOver reads "Favorite, selected" rather than the
contradiction. `detail.favoriteButton` unchanged. Catalog: the two old keys
removed, `"Favorite"` added with `de: "Favorit"`; rebuilt, 30 keys, no missing
German, no orphans. No test referenced the old labels.

URL gate moved to the domain seam: `Repo.webURL` (`Models/Repo.swift:41-63`),
lowercased scheme comparison per RFC 3986, comment naming the real risk
(deep-linking into another app's handler — not `javascript:` execution, which
`openURL` will not perform). The view-side check and its wrong comment are gone.

**A7 — tab identifiers + honest tab comments.** `Views/RootView.swift`.
`.accessibilityIdentifier("tab.search")` / `("tab.favorites")` applied to the
`Tab`s. **Verified against the live element tree**, not assumed — a temporary
probe test dumped the hierarchy and showed
`Button … identifier: 'tab.favorites', label: 'Favorites', Selected` on the
tab-bar button. The probe was deleted after use.

Both "There is no API to identify that button" comments deleted (RootView and
FavoritesScreen). `FavoritesScreen.open()` → `app.tabBars.buttons["tab.favorites"]`,
and that entry is removed from the documented locale-bound list; `editButton`
now carries the note that it, the "Delete" confirmation, and
`SearchScreen.noResultsView` are the remaining genuinely locale-bound queries.

The `role: .search` comment is rewritten to say only what the role does
(declares the tab's role; the system pins it trailing and gives it the
search presentation) and the two behaviours it does *not* imply are now
explicit opt-ins: `.searchToolbarBehavior(.minimize)` on SearchView's content
and `.tabBarMinimizeBehavior(.onScrollDown)` on the TabView. The iPad sidebar
claim is gone. **No UI-test churn** — the full suite passed on the first run
with both behaviours in place; no scrolls, waits or test edits were needed, and
neither modifier had to be dropped.

**A8 — loggers.** `Support/Logging.swift`: both are `nonisolated static let`,
with the reason stated (default MainActor isolation would make them
unreachable from the `nonisolated`/`@concurrent` code where network failures
live; `Logger` is `Sendable`).

**A9 — footer.** `.safeAreaBar(edge: .bottom)` replaces `.safeAreaInset`; the
API is available in this SDK and compiles, so no fallback was needed.
`.background(.bar)` and `.frame(maxWidth: .infinity)` removed from the leaf.
The `HStack` is hoisted out of the `if let refreshed`, so the spinner shows
whenever `isRefreshing` and the `Text` only when a description exists. The
leaf-confinement comment now says "re-evaluated" (noting that structural
diffing elides unchanged rows) and states that the insulation is
one-directional.

**A10 — RepoRowView.** `.accessibilityElement(children: .ignore)` with the
comment corrected (the label replaces the children's text; `.combine` also
merges traits and actions). `Color.primary.opacity(0.65)` → `Color("Deemphasized")`,
backed by `Assets.xcassets/Deemphasized.colorset/Contents.json` with four
variants (any 0.35, dark 0.72, high-contrast any 0.25, high-contrast dark 0.82,
components as strings). Comment explains that a fixed alpha opts out of
Increase Contrast and is only valid against measured backgrounds. Both
accessibility-audit UI tests pass, including the AX5 run with `.textClipped`
un-suppressed.

*Finding — the edit-mode delete workaround stays.* The order asked me to retry
the standard query path after the `.ignore` change. I measured it with the
probe: the delete control is published as
`Image, identifier: 'minus.circle.fill', label: 'remove'`, sitting beside the
row element, not inside it — it is `List`'s own representation, so no
accessibility choice in `RepoRowView` can promote it to a button.
`app.buttons` finds only the row, whose label edit mode prefixes with
"Remove, ", so tapping it opens the detail screen. The workaround is unchanged;
its comment now gives this (measured) reason instead of blaming `.combine`.

## B. Claim discipline

- **B1** `LiveGitHubClient.session` — the doc now says the `var` is what
  creates the `session:` parameter at all, because Swift omits a
  `let`-with-default from the synthesized memberwise init.
- **B2** the `max(0,…)` clamp — states that it *does* fire (body's first
  evaluation precedes `.onAppear`'s seed, so the first frame after a long stop
  computes a negative interval) and that `Int` truncation absorbs sub-second
  lag in steady state. "should never fire" deleted.
- **B3** type-level doc — the `@MainActor` closure annotations insert a
  *dynamic* isolation check; nothing is compile-checked, and the runtime trap
  is the point. The type doc now agrees with the (correct) inline comment.
- **B4** `StubURLProtocol` / `withStubbedClient` — the comment now separates
  the two questions: the `Mutex` removes the data race, and a new process-wide
  `StubHandlerGate` decides which handler answers which request.
- **B5** `KeyedGatedGitHubClient` — `try Task.checkCancellation()` moved
  outside the `if`, so the pre-opened path checks too; `preOpened` documented
  as a `Set` (N opens with no waiter arm one future call).
- **B6** `FavoritesStoreTests` — renamed to
  `batchRemoveDeletesAllAndCommits` / "…and leaves nothing pending", with the
  comment stating that `hasChanges == false` proves committed, not "in one
  save".
- **B7** changelog-style comments pruned to present-tense invariants in
  `FavoritesStore.isFavorite`, `AppDependencies` (both the DEBUG block and the
  fallback), `FavoriteRepo.unique`, `FavoritesView`'s overlay note, and
  `RepoRowView`'s colour comment. The `SearchView` error branch had two
  overlapping identifier-placement comments; it now has one, on the branch
  that needs it. The ContentUnavailableView re-parenting scar-comment is kept,
  in that one place.

*Deviation (B4, mechanical).* The order suggested "a small actor with
`func run<T>(_ body: () async throws -> T) async rethrows -> T`". That does not
compile under Swift 6: sending a non-`Sendable` closure into an actor and
returning a non-`Sendable` `T` back out are both errors
(`Sending value of non-Sendable type … risks causing data races`;
`Non-Sendable 'T'-typed result can not be returned from actor-isolated
instance method`). Implemented as the equivalent the order allows — an async
mutex (`acquire()`/`release()` with direct hand-off so waiters cannot be
barged) taken *around* the body rather than wrapping it, which gives the same
mutual exclusion without forcing `T: Sendable`. `withStubbedClient` changed
from `rethrows` to `throws`; all call sites already used `try await`.

## C. Test additions

- **C1** `successStatusCodesDecode` over `[200, 203, 206]` — pins `200..<300`
  against a mutation to `== 200`.
- **C2** `doubleStartTickerIsANoOp` (two starts, one stop, assert `now` stops
  advancing — proves a single subscription) and
  `stopTickerWithoutStartDoesNotCrash`.
- **C3** `retryDedupesTheFollowingEmission` — exactly two client calls.
- **C4** `SearchViewModel.setStateForPreviews(_:lastCompletedQuery:)` under
  `#if DEBUG`, documented as a preview seam. Previews reworked: "Results",
  "Refreshing", "Empty" (with `lastCompletedQuery`), "Error (first load)",
  "Error (stale kept)". RootView's preview is seeded loaded. Preview plumbing
  migrated to `struct SampleData: PreviewModifier` with a throwing
  `makeSharedContext()` and a `PreviewTrait.sampleData` extension; every call
  site is `#Preview(traits: .sampleData)` and the global `previewContainer` is
  deleted.
- **C5** `MockGitHubClient.searchErrorOnce` keys on a `Set<String>` of queries
  that have already failed; mock doc comment and UI-test comment updated to
  explain that this makes the scenario immune to typing speed.
- **C6** covered by A2, A4 and A5 above.

## D. Sanity

```
catch is CancellationError in SearchViewModel  → none
Color.primary.opacity in RepoRowView code      → none (appears once in a doc
                                                  comment, naming what the
                                                  asset colour replaces)
"no API to identify" (RootView/FavoritesScreen) → none
withAnimation { toggleFavorite                 → none
previewContainer                               → none
viewModel.search(matching:  (tests)            → none
Localizable.xcstrings: 30 keys, 0 missing de, 0 orphans
```

One `"exposes no API to identify"` remains, in
`SearchScreen.searchField` — a different and still-accurate claim about
`.searchable`'s own field, outside this order's scope. Given that A7 disproved
the analogous claim about `Tab`, it is worth a look in a later wave; the
current query (`app.searchFields.firstMatch`) is unambiguous and passing.

## Test tails

Unit — `-only-testing:testExampleTests`:

```
✔ Test run with 39 tests in 5 suites passed after 2.657 seconds.
```

UI — `-only-testing:testExampleUITests`:

```
Test Suite 'testExampleUITests.xctest' passed at 2026-08-23 18:07:32.385.
	 Executed 24 tests, with 0 failures (0 unexpected) in 330.511 (330.535) seconds
Test Suite 'All tests' passed at 2026-08-23 18:07:32.385.
	 Executed 24 tests, with 0 failures (0 unexpected) in 330.511 (330.536) seconds
** TEST SUCCEEDED **
```

No UI-test churn from `safeAreaBar`, `.searchToolbarBehavior(.minimize)` or
`.tabBarMinimizeBehavior(.onScrollDown)`: the suite passed on the first run
after those changes and again on the final run, with no scrolls, waits or
timeout adjustments added.
