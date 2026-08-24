> **Archived — point-in-time remediation record (Round 4, Wave 1,
> 2026-08-23).** Superseded by the code, `README.md` and
> `ARCHITECTURE.md`. Line numbers, file listings and "current state"
> claims herein describe the tree as it stood at the end of this wave and
> **MUST NOT** be used as reference — a later wave may have moved any of
> it. Kept only as a record of what was done and why.

# Round 4 — Wave 1 report

Branch: `feature/round4-remediation`. Base: `4a5b565` (end of Round 3).
Six commits of work, plus a seventh carrying this file. `project.pbxproj`
untouched — Wave 2 owns plumbing. Simulator iPhone 17 Pro; both suites run
under `testExample.xctestplan`, which executes everything twice (English and
German).

## Commits

| Hash | Scope |
|---|---|
| `59a121d` | A1–A6 — one List identity, promotion gate, refresh target, blank-path guard, empty branch, VoiceOver announcement (plus D10 and the first, failed A7 attempt) |
| `83e3e4e` | C1–C8 — comment and doc true-ups, `Logger.network`, the `searchSucceedsThenFails` scenario |
| `8091302` | B1 — the favorite haptic follows the tap, not the `@Query` |
| `b4b6552` | D1–D5, D8–D9 — the toothless tests made to bite, new gate coverage, double hardening |
| `312dfe0` | A7 — Favorites owns its edit mode (three attempts; the UI test picked the winner) |
| `73089e4` | D6–D7, E1 — the failure-with-rows UI test and its audit, bounded retries, unverified notes, 44pt Retry target |

## A. SearchView structural redo

The screen had a `List` in the `.loaded` arm and a second, textually identical
`List` in the `.failed(_, stale:)` arm. Two arms are two view identities, so
every crossing between them destroyed one list and built another: scroll
position reset, rows could not animate, and every modifier attached to the
list restarted. Concretely, the failure state had no `.refreshable` and no
timestamp footer at all, and the ticker's `.onAppear`/`.onDisappear` fired on
each transition.

**A1.** Rows are chosen by `displayedRows: [Repo]?` — non-empty `.loaded`, or
`.failed` with non-empty stale — and `content` builds **one** `List` when it
returns a value. The list carries `.refreshable`, one `.safeAreaBar`, the
ticker's lifetime and the announcement below. Only when there are no rows does
a four-arm `switch` choose a screen (idle, loading, loaded-but-empty,
failed-with-nothing). Identity lesson commented once, mirroring and citing
`FavoritesView`'s version of it.

**A1 (bar).** Under a failure the bar is the banner **above** the timestamp,
in a `VStack`, not the banner alone — the age of the rows matters most exactly
when they are stale. `isRefreshing` is derived inside the bar from `state`.

**A2.** The stale promotion is gated on `trimmed == lastCompletedQuery`. A new
query dispatched from a failure now goes to `.loading`.

**A3.** `.refreshable` dispatches `lastCompletedQuery ?? searchText`.

**A4.** `guard !Task.isCancelled` hoisted above the blank-query guard. The
blank path was the only place a cancelled task wrote state, and what it wrote
was `nil` over a live search's dedup key. The `dispatch(_:)` invariant comment
now reads: the key is claimed before the work starts, and released only by the
failure (or blank-idle) of the search that owns it.

**A5.** The empty branch names `lastCompletedQuery` or, when there is none,
uses the untitled `ContentUnavailableView.search`. The old `?? searchText`
fallback was unreachable in production — every `.loaded` writer records the
query in the same main-actor turn — and the comment now says so. The refresh
spinner in that branch is `.accessibilityHidden(true)`, like the footer.

**A6.** `.onChange(of: viewModel.state)` posts
`AccessibilityNotification.Announcement(message)` on the way **into** a
`.failed` carrying non-empty stale rows. That transition moves no focus and
changes no element the user is on, so VoiceOver was silent for it; the
full-screen failure branch needs no announcement because replacing the content
relocates focus by itself.

**A7.** The strand is real and the fix is **not** the one the order
specified — see the deviation below. `@Environment(\.editMode)` accepts the
write and reads the written value back, and the toolbar's `EditButton` goes on
saying "Done" anyway; that held both from `FavoritesView` and from a child view
inside the `NavigationStack`. `FavoritesView` now owns
`@State private var editMode` and injects it with `.environment(\.editMode,
$editMode)` placed outside `.toolbar`, so button, rows and reset share one
source of truth. Verified at runtime: the UI test deletes the last favorite
via `EditButton`, adds another, and asserts the restored toolbar button reads
"Edit" and that no "Done" is present.

**Contract check.** `search.list`, `search.row.*`, `search.loading`,
`search.emptyRefreshing`, `search.errorView`, `search.retryButton` and every
`favorites.*` / `detail.*` / `tab.*` identifier are unchanged. Exactly one
`List(` remains in `SearchView.swift`; the old `?? viewModel.searchText` in
the empty branch is gone; the same expression is present in `.refreshable`,
which is where it belongs.

## B. The haptic

`.sensoryFeedback` chose between `.success` and `.impact` by reading
`isFavorite` — a `@Query` result that lands on a later update than the tap, as
the `.animation(_:value:)` on the same button already documented. The
direction is recorded at tap time (`lastToggleAddedFavorite`), and the trigger
counter advances only after the store write succeeds, so a failed toggle now
produces no haptic rather than confirming something that did not happen.

## C. Claim true-ups

- **C1** `GitHubClientError`: the error type is a hint, not proof; callers must
  ask `Task.isCancelled`.
- **C2** `SearchViewModel`: the INVARIANT block no longer rests on "only
  main-actor code can cancel us" (`Task.cancel()` is `nonisolated`, and the
  suite itself cancels from a test). It now rests on turn atomicity. The
  `searchTask` comment is scoped to the variable, not the task's lifetime.
- **C3/C4** `MockGitHubClient`: "never records anything" → narrows the window
  to a single actor hop; per-query keying stops a prefix *consuming* the
  query's failure, not a prefix putting a banner on screen first.
- **C5** `SearchView` header: two shapes, four arms in the inner switch, the
  `where` clauses are not compiler-verified (only the `default` makes
  `displayedRows` exhaustive), and two readers of state beside the enum.
- **C6** "two Texts" → "a spinner and a Text", in the comment and in
  `ARCHITECTURE.md`. The same file's description of the switch was rewritten:
  it claimed one branch per case and compiler-guaranteed exhaustiveness, which
  is neither the current shape nor ever the whole truth.
- **C7** `Logger.network` exists and is used from both of
  `LiveGitHubClient`'s transport catch clauses (`debug` for the cancelled one,
  `error` for the generic one), which is what makes the `Logging.swift`
  rationale true and the rogue-`CancellationError` story field-diagnosable.
- **C8** `staleResults` is produced inside each promotion branch, so "the
  failure restores the rows this search was refining" is structural rather
  than a re-read of `state`.

## D. Tests

### The three toothless ones, and the mutant each now catches

Each was checked **by running the mutant**, not only by reasoning. Every row
below failed in *both* language configurations with the stated deletion in
place, and passes without it.

| Test | Mutant it now catches |
|---|---|
| `doubleStartTickerIsANoOp` | delete `guard tickerCancellable == nil else { return }` in `startTicker()` |
| `retryFromFailureBannerPreservesStaleResults` | delete the `else if case .failed(_, let stale?)` promotion branch in `search(matching:)` |
| `leadingPaddedQueryDoesNotRefireWhenTrimmed` (the direction added to `trailingWhitespaceDoesNotRefire`) | drop the trim in `dispatch(_:)` (`lastDispatchedQuery = query`) |
| `newQueryFromAFailureStartsBlank` | delete `trimmed == lastCompletedQuery` from the promotion gate |
| `retryFromAFailureWithEmptyStaleResultsBlanksToLoading` | delete `!stale.isEmpty` from the promotion gate |
| `cancelledBlankSearchLeavesTheLiveKeyAlone` | move `guard !Task.isCancelled` back below the blank-query guard |

Why the old versions could not fail:

- **D1** `doubleStartTickerIsANoOp` asserted that `now` stops advancing after a
  single `stopTicker()`. Assigning a second `AnyCancellable` over the first
  releases it and its `deinit` cancels the subscription, so there is never a
  second live timer to detect — the test could not fail, and its comment
  taught the opposite. The rewrite asserts what the guard actually protects:
  the second `startTicker()` must not re-seed `now`. No sleeps.
- **D2** `retryFromFailureBannerPreservesStaleResults` inspected only terminal
  states, where the promotion is invisible. It is now driven by
  `KeyedGatedGitHubClient` and asserts the in-flight moment —
  `.loaded(stale, isRefreshing: true)` while the retry is suspended — then the
  terminal `.failed` carrying the same rows.
- **D3** `trailingWhitespaceDoesNotRefire` walked one direction of a
  two-direction rule and passed with the other trim deleted. The added test
  walks padded-first-then-bare, which pins `dispatch(_:)`'s trim of the key
  rather than the `filter`'s trim of the candidate.

### The rest

- **D4** `cancelledBlankSearchLeavesTheLiveKeyAlone` reproduces the probe:
  `dispatch("")` then `dispatch("swift")` on one main-actor turn, then proves
  the key survived by re-submitting the identical text and counting client
  calls.
- **D5** both polarities of the A2 gate, plus the `!stale.isEmpty` guard.
- **D6** `MockGitHubClient.searchSucceedsThenFails` and
  `testAFailedRefreshKeepsTheResultsAndItsRetryKeepsThemToo`: results on
  screen, a failing re-submission, rows + banner + retry all present, then
  Retry — which this scenario also fails — leaving the rows and bringing the
  banner back. The same screen is added to `AccessibilityAuditUITests`.
- **D7** the recovery step of `testRetryRecoversFromATransientFailure` is a
  bounded 3-attempt loop, so a prefix query's failure cannot break it.
- **D8** `StubHandlerGate` gains a `@TaskLocal` reentrancy precondition and a
  30s acquire deadline that records an issue and returns `false` (the caller
  then does not release a gate it never owned) instead of hanging the run. The
  `.serialized` trait on the mapping suite is documented as no longer
  load-bearing.
- **D9** `ScriptedGitHubClient` checks cancellation before consuming a script
  entry, matching the gated doubles.
- **D10** `FavoritesView.delete(at:)` guards the indices instead of
  subscripting an `IndexSet` blind.

## E. Verify-on-device notes

Neither interaction is covered by a test, and both now say so at the site,
in `SearchScreen`'s honest style:

- the toolbar `.contentTransition(.symbolEffect(.replace))` — a UI test cannot
  observe an animation;
- `.refreshable` versus `.searchToolbarBehavior(.minimize)` — both claim the
  top overscroll region, and which wins was not measured. The UI suite drives
  refreshes by re-submitting the query rather than by pulling, so nothing in
  it would notice if the gesture were unreachable.

## Verification

Both suites green, on iPhone 17 Pro, both test-plan configurations.

```
# Unit — xcodebuild test … -only-testing:testExampleTests
** TEST SUCCEEDED **
# result bundle: 46 tests, 46 passed, 0 failed, 0 skipped (23 tests × 2 configurations)

# UI — xcodebuild test … -only-testing:testExampleUITests
Test Suite 'All tests' passed at 2026-08-23 22:10:48.899.
	 Executed 26 tests, with 5 tests skipped and 0 failures (0 unexpected) in 289.972 (289.995) seconds
** TEST SUCCEEDED **
```

The five skips are the pre-existing English-only gates (`ContentUnavailableView.search`'s
title, `EditButton`/"Delete", and now three audits sharing the "Clear text"
suppression), reported as skips by `skipUnlessRunningInEnglish(matching:)`.

Mutation evidence for the rewritten tests is in the D table above: six
deletions, six targeted failures, each in both configurations.

## Deviations and concerns

1. **A7 could not be implemented as written, and the alternative is
   declared.** The order asked for `@Environment(\.editMode)` plus an
   `.onChange` reset, with a fallback of documenting the edge if the binding
   were "nil/inert". It is neither nil nor obviously inert: it reads back
   exactly what is written to it, and the toolbar's `EditButton` ignores it.
   Instrumented to be sure — a temporary on-screen probe reported
   `editMode == .inactive` and two `isEmpty` transitions at the moment the
   navigation bar was still showing "Done". Both placements (declaring view
   and child inside the stack) behaved identically. The closest correct
   alternative — the screen owning the binding and injecting it — works and is
   pinned by the UI test. No guide §18 "known edge" entry was added, because
   after the fix there is no unresolved edge to document; the finding lives in
   `FavoritesView`'s comment instead.

2. **A2 has a UX consequence worth confirming.** With the gate in place,
   `retry()` re-runs `searchText`, so a failure produced by a *refinement*
   (`searchText != lastCompletedQuery`) now blanks its stale rows on Retry:
   the promotion does not apply, the state goes to `.loading`, and a second
   failure carries `stale: nil`. That follows directly from the specified
   gate — rows may only be shown under the query they answer — but it is a
   behaviour change to the Round-3 "retry preserves stale results" story, and
   the Round-3 test that appeared to cover it was passing for the other
   reason. The paths that keep their rows are the ones where the failing query
   *is* the loaded one: pull-to-refresh (A3 guarantees it), and re-submitting
   the same text. The new UI test drives exactly that path.

3. **`ContentUnavailableView.search()` does not exist**; the SDK spells the
   untitled variant as a static property, `ContentUnavailableView.search`.
   Used the property.

4. **`searchSucceedsThenFails` is keyed per query**, not "first completed call
   overall" — the order offered both. Per query for the same reason
   `searchErrorOnce` is: typing "swift" emits prefix queries, and a scenario
   counting calls process-wide makes the test depend on typing speed. The
   tests using it are additionally written to hold whichever way that race
   lands (bounded re-submission loops rather than single waits).

5. **One product change was needed to pass the new audit**: the banner's Retry
   button had no minimum touch target (a footnote-sized `.bordered` button
   measures ~34pt against the audit's 44pt floor). It now carries
   `.frame(minHeight: 44)`. Flagged because it is a visual change, not just a
   test.

6. **E1 stayed notes, not measurements.** The symbol-effect animation is not
   observable from XCUITest at all. Pull-to-refresh versus
   `.searchToolbarBehavior(.minimize)` is observable only through a synthesized
   swipe, whose outcome depends on which of the two consumes the overscroll —
   precisely the unknown — so a test of it would have been the least reliable
   in the suite and could not have distinguished "gesture unreachable" from
   "gesture flaky". Both sites now carry one-line unverified notes. This is
   the item most worth spending a few minutes of human hands on.

7. **An untracked `.claude/` directory sits at the repo root**, containing
   only `scheduled_tasks.lock`. It was present before this wave started and
   was not created here, so it has been left alone and uncommitted.

