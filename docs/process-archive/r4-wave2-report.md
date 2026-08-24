> **Archived — point-in-time remediation record (Round 4, Wave 2,
> 2026-08-23).** Superseded by the code, `README.md` and
> `ARCHITECTURE.md`. Line numbers, file listings, counts and "current
> state" claims herein describe the tree as it stood at the end of this
> wave and **MUST NOT** be used as reference — a later wave may have moved
> any of it. Kept only as a record of what was done and why.

# Round 4 — Wave 2 report

Branch: `feature/round4-remediation`. Base: `f625754` (end of Wave 1).
Five commits. Simulator iPhone 17 Pro; every suite runs twice under
`testExample.xctestplan` (English and German).

## Commits

| Hash | Scope |
|---|---|
| `593f14f` | A0 — the promotion middle ground: `lastFailedQuery`, plus two mutation-verified tests |
| `2b85545` | B — test-plan locale pin and timeouts, deployment target, CI result bundle + advisory lint job, `.gitignore` |
| `dfecced` | C — the four German corrections, and a catalog/source reconciliation |
| `6d99ad5` | D — `ScreenshotGalleryUITests` and the README gallery |
| `83fb15b` | E — the docs truth pass, re-measured, plus the two code changes it turned up |

## A0. The promotion middle ground

Wave 1's gate — `trimmed == lastCompletedQuery` — was right about
brand-new queries and wrong about the case the feature was built for. The
banner's Retry re-runs `searchText`, which after a failed *refinement* is
the refinement's query, not the query the rows answer; so the one tap the
banner exists to offer sent the screen to `.loading` and blanked the rows
the banner had just promised to keep. Wave 1 declared this as deviation #2
rather than hiding it, which is how it got fixed here.

`SearchViewModel` now records `private(set) var lastFailedQuery: String?`
— written in the `catch`, in the same main-actor turn as the `.failed` it
accompanies; cleared on success and on the blank trip to idle. The gate
became:

```swift
} else if case .failed(_, let stale?) = state, !stale.isEmpty,
          trimmed == lastCompletedQuery || trimmed == lastFailedQuery {
```

Stated once, in the source, and echoed in both documents: the stale rows
stay when the incoming query is either **the one they answer** (pull-to-
refresh, which `.refreshable` guarantees re-runs `lastCompletedQuery`, or
re-submitting the same text) or **the one whose failure put the banner
up** (Retry). Anything else still starts blank, because showing one
query's rows under another's search was the round-3 defect.

What the middle ground concedes is written down rather than glossed:
after a failed refinement, Retry does redisplay the previous query's rows
under the refinement's banner. That is the screen the user is already
looking at, and Retry asks to repeat what just happened rather than to ask
something new.

### Mutation evidence

Three mutants, each run in **both** language configurations:

| Mutant | Test that failed |
|---|---|
| drop `\|\| trimmed == lastFailedQuery` | `retryingAFailedRefinementKeepsTheRowsUnderTheBanner` (the refresh test still passed) |
| drop `trimmed == lastCompletedQuery \|\|` | `refreshAfterAFailedRefinementKeepsTheLoadedQuerysRows` (the retry test still passed) |
| drop the whole gate | `newQueryFromAFailureStartsBlank` |

Two arms, two independent witnesses — which is the point of adding the
second test rather than only the one the order asked for. Both new tests
are driven by `KeyedGatedGitHubClient` and assert the **in-flight** state
(`.loaded(stale, isRefreshing: true)`), because a terminal state cannot
distinguish a promotion from a fresh load that happened to fail with the
same stale array attached.

`newQueryFromAFailureStartsBlank` needed no structural change: its "swift"
succeeded *and* failed, so the "swiftui" it dispatches already differed
from both keys. Its comment now says so, since that is now the property
under test rather than an accident.

The Wave-1 UI test `testAFailedRefreshKeepsTheResultsAndItsRetryKeepsThemToo`
needed no change either: it re-submits the *same* query, so it was already
written around rows surviving, not around blanking. Re-checked by reading
it, and it passes.

## B. Plumbing

**B1.** The test plan's English configuration had `"options": {}`. An
empty dictionary means "whatever the host is set to", so on a German-locale
Mac both configurations would have run German and every
`skipUnlessRunningInEnglish` test would have vanished from the run without
even a skip to show for it. Pinned to `en`/`US`. Test timeouts enabled with
`"defaultTestExecutionTimeAllowance": 120`.

**B2.** `IPHONEOS_DEPLOYMENT_TARGET` 26.2 → 26.0 in both project-level
build configuration blocks — grep-verified as the only two occurrences
(`CreatedOnToolsVersion = 26.2` is a different setting and was left). The
build and the unit suite are the evidence that nothing needs the higher
number: availability is checked against the deployment target on every
build.

**B3.** The UI job writes `-resultBundlePath UITests.xcresult` and uploads
it with `actions/upload-artifact` under `if: always()`. A third job runs
`xcrun swift-format lint --strict --recursive testExample || true` and is
explicitly advisory; the header note now says "the two test jobs" and
accounts for the third, so it stays accurate.

**B4.** `.gitignore` gains `*.xcresult` and `.claude/`, which resolves
Wave 1's deviation #7 (the untracked directory that was left alone).

## C. German

The four round-3 native suggestions, applied verbatim in intent:
*Suchanfrage* to match the neighbouring rate-limit string's own wording;
"nach Namen, Themen oder Sprachen"; "Die Antwort von GitHub konnte nicht
gelesen werden."; "die du als Favorit markierst", matching the affordance's
own label.

The catalog was reconciled against the source rather than assumed: thirty
keys, thirty user-facing literals in the app target, no orphan in either
direction. Wave 1 added no strings — the failure banner reuses the
full-screen error's message and its "Retry" — which is why nothing needed
adding. Every key still carries a comment; every key but `RepoScout`
(`shouldTranslate: false`) still carries German.

## D. Screenshots

`ScreenshotGalleryUITests` captures four `XCTAttachment`s with
`.keepAlways` lifetime: search results, repo detail, populated favorites,
and search results in German. The German one launches with
`-AppleLanguages (de)` / `-AppleLocale de_DE` of its own, so it does not
depend on which configuration is running. Exported with

```
xcrun xcresulttool export attachments --path … --output-path …
```

which worked first time — no `simctl` fallback was needed. PNGs are
resized to 800pt tall (`sips -Z 800`), 29–51 KB each, committed under
`docs/screenshots/` and shown in a four-column table at the very top of
the README, with the regeneration commands directly beneath them.

Both methods are gated to the English configuration. They deliberately do
**not** use `skipUnlessRunningInEnglish(matching:)`: that helper's message
reads "this test matches …, a system string Apple localizes", which is
true of the five tests that use it and false of these two. A skip reason
that misdescribes itself is worse than none, so the language check was
factored out (`currentTestLanguage`) and each caller supplies its own
sentence. This was found during E, and is the one place where the truth
pass changed test code.

## E. Docs

Written last, against the finished tree, with every number re-measured.

**Two shipped errors in the guide.** §11 said the container build has no
`fatalError`. There is one, and it is deliberate: the persistent path
degrades to in-memory and logs at fault level; the in-memory path traps,
because a container that needs no disk, no migration and no permissions
can only fail on a malformed schema — a programmer error present on every
launch on every device. §8 justified the post-`await` cancellation guard
with "cancellation can only originate on the main actor", which is false
(`Task.cancel()` is `nonisolated`; this suite calls it) and which the
*source* comment had already been corrected to turn atomicity in Wave 1.
The guide had been left behind.

**Counts.** §15's "German runs: 75 test executions, 4 skips, 0 failures"
is replaced by "the entire suite minus seven explicit skips", which
survives the next test anyone adds. The skip figure was re-measured, not
carried over: **seven**, from two causes — five tests matching Apple-owned
strings, two producing the gallery — and the same sentence now appears, in
the same shape, in the guide, `README.md` and `ARCHITECTURE.md`. Coverage
stopped being "~90%": the measured figure is 94.66%, and both mentions now
say "mid-nineties" and point at the command instead of freezing a number
that will drift.

**§§7–9 caught up with round 4**: the single `List` identity and why two
identical `List`s in two `switch` arms are two views; the banner above the
timestamp in one bar; the two-key promotion gate; the VoiceOver
announcement on the way *into* a failure that keeps rows; the 44pt Retry
target; the haptic driven by recorded intent rather than by the `@Query`;
`FavoritesView` owning its edit mode, including that
`@Environment(\.editMode)` reads back what you write and the toolbar
ignores it; `Logger.network` in both of the live client's transport
catches; `searchSucceedsThenFails` in the mock's scenario list. §4's flow
diagram no longer claims the view is a compiler-checked exhaustive switch.

**M4** is fixed with the distinction that was missing: the AX5 audit drops
the **clipping** suppression; the clear-button hit-region suppression
still applies there, because `.searchable` offers no hook to resize
UIKit's button at any text size.

**S3, honestly.** `swift-format lint --strict` reports **188** diagnostics
across twelve files: 116 `Indentation`, 58 `AddLines`, 12 `LineLength`,
2 `Spacing`. Of the twelve long lines, nine are
`String(localized:comment:)` translator comments — the argument is a
`StaticString`, so the only ways to shorten the line are to put a newline
inside the comment a translator reads or to tell them less. The three that
were genuinely breakable were broken (all in `SearchViewModelTests`).
Every document now states the breakdown rather than the old, false "rule
violations: zero".

**Smaller true-ups.** M1 (one "run from `testExample/`" note instead of
four `cd` lines); M2 (`/usr/bin/sips` with the full path to the icons, from
the repository root); M6 ("target settings", plus the note that
default-`MainActor` isolation is app-target-only on purpose — the unit
target is deliberately not main-actor, which is why its suites carry an
explicit `@MainActor`); M7 (scheme path root-relative and complete, in
both documents); M8 (`RepoRowLabelTests` in the suite inventory); M9 (the
`.loading` row borrows the source's "only a load with nothing to keep
blanks the screen"); M10 (`.searchToolbarBehavior` attributed to
`SearchView`, in `ARCHITECTURE.md`, the guide, *and* `RootView`'s own
comment, which claimed both opt-ins were "below"); S7 (the README's
iPhone-only/German pointer names both `ARCHITECTURE.md` sections). M13:
`Color(.deemphasized)`, the generated symbol, compile-checked. M15 skipped
as instructed, with nothing written about it.

Two more corrections the pass turned up on its own:
`AccessibilityAuditUITests` said "Both tests in this class" when Wave 1 had
made it three, and the guide's "Third edition / two rounds of audit"
callout now declines to count, on the same principle as §15.

The new deployment target is recorded in both documents with the reason it
is checkable (availability is evaluated against it on every build).

**E3.** The archived plan's disclaimer gains a sentence: it was written for
an agentic executor, so its `REQUIRED SUB-SKILL` note and checkbox syntax
are part of the artifact, not guidance to a human reader.

The guide's HTML and the PDF were re-rendered together, with the header's
render command corrected to the real binary path
(`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`) — `chrome`
is not on `PATH` on a stock macOS install, so the old command could not
have worked as written.

## Verification

Full suite, iPhone 17 Pro, both test-plan configurations, run against the
final tree after every commit had landed:

```
xcodebuild test … -resultBundlePath /tmp/final.xcresult
** TEST SUCCEEDED **
English:  90 passed, 0 skipped, 0 failed
German:   83 passed, 7 skipped, 0 failed
app-target coverage: 94.66% (1508/1593)
```

The seven German skips are the five Apple-owned-string gates
(`ContentUnavailableView.search(text:)`'s title, `EditButton`/"Delete",
and the three audits sharing the "Clear text" suppression) plus the two
screenshot captures. Each reports its own reason.

Mutation evidence for A0 is the table above: three mutants, three targeted
failures, each in both configurations, with the non-target test passing in
each of the first two.

Working tree clean; `.claude/` is now ignored rather than untracked.

## Deviations and concerns

1. **The screenshot gallery does not use the shared English gate, and that
   is a deliberate divergence from the order.** The order said "gated like
   the other English-only tests". Using `skipUnlessRunningInEnglish(matching:)`
   verbatim would have produced the skip message "this test matches the
   README's screenshots, **a system string Apple localizes**" — false, and
   in a repository whose stated first principle is that comments must be
   true, a false skip reason is a defect. The language check was factored
   into `currentTestLanguage` and each gate supplies its own sentence. Same
   behaviour, honest report.

2. **`lastFailedQuery` being cleared on success is bookkeeping hygiene,
   not a behaviour the promotion can observe.** The `catch` writes the key
   and the `.failed` state in one turn, so whenever `state` is `.failed`
   the key already names that failure's query; there is no reachable state
   in which the clear changes the gate's answer. It is still done, and the
   property's doc comment says exactly this rather than implying the clear
   is load-bearing. A reader who deletes it will find no test failing —
   which is the honest situation, and worth knowing.

3. **The formatter's diagnostics are advisory by decision, not by
   accident.** 188 is a large number to leave standing. The judgement:
   116 `Indentation` + 58 `AddLines` are the pretty-printer's opinion about
   wrapping call arguments and collection literals, and accepting them
   would reflow readable test fixtures into a shape no reader benefits
   from. The nine unbreakable long lines are translator comments. If a
   future round wants a green lint, the honest route is to disable those
   two rules in `.swift-format` and let the rest gate the build — not to
   reformat the codebase into the tool's taste.

4. **Two items from Wave 1 remain unverified and are still only notes at
   their sites**: the toolbar's `.contentTransition(.symbolEffect(.replace))`
   (not observable from XCUITest) and `.refreshable` versus
   `.searchToolbarBehavior(.minimize)` competing for the top overscroll
   region. This wave added no measurement of either. They remain the items
   most worth a few minutes of human hands.

5. **The screenshots are not asserted against.** `ScreenshotGalleryUITests`
   proves only that the app reached each screen; nothing checks that the
   resulting image is well-composed, and a layout regression that still
   renders would produce a committed picture of the regression. The type
   comment says so. The mitigation is that the images are cheap to
   regenerate and a human sees them in the README.

6. **Test timeouts are enabled at 120 seconds and have never fired.** The
   longest observed UI test in this wave was well under that, so the
   allowance is a hang detector rather than a tuned budget. A slower
   machine — a cold CI runner in particular — could plausibly need more,
   and the failure mode would be a spurious timeout rather than a silent
   hang. The number is in one place in the test plan if it needs raising.
