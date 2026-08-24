> **Archived — point-in-time remediation record (Round 4, final wave,
> 2026-08-23).** Superseded by the code, `README.md`, `ARCHITECTURE.md` and
> `docs/guide/reposcout-guide.html`. Line numbers, file listings, counts and
> "current state" claims herein describe the tree as it stood at the end of
> this wave and **MUST NOT** be used as reference — a later wave may have
> moved any of it. Kept only as a record of what was done and why.

# Round 4 — Final wave report

Branch: `feature/round4-remediation`. Base: `b23c866` (end of Wave 2).
Simulator iPhone 17 Pro; every suite runs twice under
`testExample.xctestplan` (English and German).

## Commits

| Hash | Scope |
|---|---|
| `8f2f12a` | AB1 — `LoadState.failed` gains `isRefreshing`; the banner's retry stays `failed`; the blocker-witness test |
| `3428bb6` | AB2 — `ErrorBanner` reflow + transition, and the AX5 audit that makes its suppression honest |
| `b5a7666` | Accompanying minors — test doubles, test plan, accent colour, screen object, CI |
| `8ac05c0` | AB3/AB4 + comment items — re-measured formatter numbers, guide/README/ARCHITECTURE corrections, PDF |

## AB1 — the concurrency blocker

`case failed(message: String, stale: Value?)` became
`case failed(message: String, stale: Value?, isRefreshing: Bool)`, and the
promotion branch in `SearchViewModel.search(matching:)` now writes

```swift
state = .failed(message: existingMessage, stale: stale, isRefreshing: true)
```

instead of `.loaded(stale, isRefreshing: true)`.

### Why it was a bug and not a shorthand

The gate is asymmetric on purpose. Its `.failed` branch asks whether the
incoming query has a claim on the rows currently on screen
(`lastCompletedQuery` or `lastFailedQuery`); its `.loaded` branch asks nothing,
because rows in a genuine `.loaded` were produced by the query being
refreshed. The old promotion made that premise false for the duration of every
banner retry: a query dispatched into that window read a `.loaded` that had
never loaded anything, took the ungated branch, inherited another query's rows
as its own, and — on failure — carried them forward as *its* stale results,
where the next retry laundered them again.

### The witness, and the mutant it must catch

`SearchViewModelTests.keptRowsCannotOutliveTheRetryTheySatUnder`:

1. "swift" succeeds → `.loaded(swiftRows, isRefreshing: false)`;
   `lastCompletedQuery == "swift"`.
2. "swiftui" fails keeping those rows → `.failed(rateLimited, swiftRows,
   isRefreshing: false)`; `lastFailedQuery == "swiftui"`.
3. The banner's Retry is dispatched and **held open** by
   `KeyedGatedGitHubClient`. Asserted mid-flight: `.failed(rateLimited,
   swiftRows, isRefreshing: true)`.
4. "kotlin" is dispatched into that window, cancelling the retry. The
   cancelled retry is awaited to completion *before* the assertion, so "it
   wrote nothing" means finished-and-wrote-nothing rather than not-yet.
   Asserted: `state == .loading`.
5. kotlin's gate is opened with a failure. Asserted: `.failed(network, stale:
   nil, isRefreshing: false)`, and `lastFailedQuery == "kotlin"`.

**Reasoning about the mutant** (restore `state = .loaded(stale, isRefreshing:
true)` in the promotion branch). At step 3 the state becomes
`.loaded(swiftRows, isRefreshing: true)`. At step 4, kotlin's `search` reads
`if case .loaded(let existing, _) = state` — which now matches — takes the
*ungated* branch, and writes `.loaded(swiftRows, isRefreshing: true)` with
`staleResults = swiftRows`. So:

- the step-4 assertion `state == .loading` fails (it is `.loaded` with swift's
  rows and a spinner claiming they are being refreshed — the exact wrong
  screen);
- the step-5 assertion `stale: nil` fails (it is `stale: swiftRows` — swift's
  rows surviving into kotlin's failure).

Two independent assertions, both load-bearing, neither reachable from terminal
states alone. **Verified by running it**: with the mutant applied the test
failed on both simulator clones (English and German configurations); the mutant
was then reverted and the test passes.

### Ripple

`SearchView.displayedRows`, the announcement `onChange`, the full-screen
failure arm, `bottomBar`, and all previews moved to the three-payload shape.
Two behavioural consequences were handled rather than inherited:

- `isRefreshing` now reads *either* case's flag, so the banner does not have to
  disappear for its own spinner to appear.
- The announcement's "is this news?" test moved from the previous state's
  *case* to its *refresh flag*. `if case .failed = previous { return }` was
  correct only while the retry laundered itself through `.loaded` on the way;
  keeping it would have silenced the re-failure it was written to announce.
  The new rule — skip only when the previous state was a *non-refreshing*
  failure — reproduces the old behaviour exactly on every transition.

The existing mid-flight assertions in
`retryFromFailureBannerPreservesStaleResults`,
`retryingAFailedRefinementKeepsTheRowsUnderTheBanner` and
`refreshAfterAFailedRefinementKeepsTheLoadedQuerysRows` moved from
`.loaded(.fixture, isRefreshing: true)` to the failed-refreshing shape.

## AB2 — the banner's reflow and audit

`ErrorBanner` is now `ViewThatFits(in: .horizontal)` over a shared
`@ViewBuilder fragment`, mirroring `RepoRowView.stats`. Identifiers and
`minHeight: 44` unchanged. Added
`AccessibilityAuditUITests.testTheFailureBannerSurvivesTheLargestDynamicTypeSize`:
scenario `searchSucceedsThenFails`, largest accessibility content size,
audited with **only** the "Clear text" hit-region suppression — `.textClipped`
back in play. It passes.

The `ignoringKnownFalsePositives` doc comment now names both AX5 witnesses
(results list, banner) and states plainly that the Favorites screen, which also
uses that filter, has no AX5 witness of its own — its rows are `RepoRowView`,
but "the same view type" is an argument, not a measurement. That admission is
also on the guide's known-edges list.

The banner gained `.transition(.move(edge: .bottom).combined(with: .opacity))`
with `.animation(_, value:)` keyed on a `isShowingFailure` presence flag rather
than on `state`, so a message change or a refresh-flag flip does not re-run the
animation.

## Accompanying items

Test doubles: `withStubbedClient` throws (`StubHandlerGateTimeout`) when
`acquire()` returns `false`, before touching the handler slot; the acquire
deadline uses `guard (try? await Task.sleep(...)) != nil else { return }`; the
`ScriptedGitHubClient` parity comment now excludes
`UncancellableGatedGitHubClient`. Test plan: `userAttachmentLifetime:
keepAlways`. `AccentColor` gained both Increase Contrast variants.
`SearchScreen.open()` replaces the one inline `app.tabBars` query.
`SearchFlowUITests`' post-Retry comment now calls itself a smoke check and
points at the unit tests for the real witness. The dead
`search.emptyRefreshing` identifier is gone (the element is
`accessibilityHidden`, so no XCUITest could ever have matched it).

CI: job-level `DEVELOPER_DIR`, a toolchain diagnostic step, the UI result
bundle tarred before upload, a unit-job result bundle plus
`xccov view --report --only-targets`, and `--strict` dropped from the lint
line.

## Measurements taken for this report

All from this tree, this machine (Xcode 26.2, iPhone 17 Pro simulator).

**Formatter**, `xcrun swift-format lint --recursive testExample` from the
repository root: **265 diagnostics over twelve files — 177 `Indentation`, 77
`AddLines`, 9 `LineLength`, 2 `Spacing`.** All nine `LineLength` warnings are
`String(localized:comment:)` translator comments
(`GitHubClient.swift` ×3, `RepoRowView.swift` ×4, `SearchViewModel.swift` ×2).

One trap worth recording, because it caught this wave: after breaking the four
newly-over-long `#expect` lines, the *derived* total (251 − 4 = 247) was wrong.
Hand-wrapping a call adds `Indentation` and `AddLines` diagnostics, so the real
total went **up**, to 265. The published numbers are a fresh run, not
arithmetic.

**Skips**, from the run: the German configuration executes 29 UI tests with
**8 skipped** — six matching Apple-owned strings (four accessibility audits,
one Favorites edit-mode test, one no-results test) and two screenshot-gallery
captures.

**Launch matrix**, from `/tmp/launch.xcresult` via
`xcrun xcresulttool get test-results tests`: eight configurations per test-plan
configuration, labelled e.g. "Light Appearance, English, Portrait" and "Light
Appearance, German, Portrait Upside Down".

**Wall clock**: UI suite 417s (English) + 290s (German) ≈ 11.8 minutes, which
is what the harmonized "roughly twelve minutes" in README, guide §2 and
`ci.yml` now says.

## Deviations, declared

**M3 could not be implemented as written.** The instruction was to replace the
`LaunchTests` comment's "Light Appearance, German, Portrait Upside Down" with a
*real* configuration label such as "Light Appearance, German, Landscape",
on the grounds that upside-down portrait is not a supported orientation. The
app's `Info.plist` indeed omits `UIInterfaceOrientationPortraitUpsideDown` —
but the result bundle produces "Light Appearance, German, Portrait Upside
Down" verbatim, and produces no bare "Landscape" label at all (it emits
"Landscape Right"). Substituting the suggested string would have replaced a
true quotation with a false one.

Closest correct alternative, implemented: the comment now quotes labels
actually read back from a result bundle, states how they were obtained, and
explains the thing the instruction was reaching for — the orientation axis is
derived from the *device*, not from the app's declared orientations, so the
matrix can name an orientation the app never rotates into.

**Not mutation-tested.** The AB2 reflow's audit test passes, which shows the
banner does not clip at AX5; it was not re-run against a plain-`HStack` mutant,
so "the `ViewThatFits` fallback is what rescues it" rests on the same reasoning
as `RepoRowView`'s rather than on a failing run. The banner's transition is
likewise only asserted negatively (the audit and scenario tests still pass with
it in place); XCUITest has no vocabulary for "this did not pop". Both are on the
guide's known-edges list.

## Verification

- `xcodebuild test` (full plan, both configurations) — green.
- The blocker witness passes in both configurations and fails, on both, against
  the launder-back-to-`.loaded` mutant.
- Formatter numbers in README, `ARCHITECTURE.md` and guide §17 all match a
  fresh run of the documented command from the documented directory.
- `RepoScout-Guide.pdf` re-rendered from the updated HTML with
  `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` and committed
  alongside it.
- Working tree clean.
