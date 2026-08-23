> **Archived — point-in-time remediation record (Wave 2, 2026-08-22).**
> Superseded by the code and `ARCHITECTURE.md`. Line numbers, code
> listings and "current state" claims herein describe the tree as it
> stood at the end of that wave and **MUST NOT** be used as reference —
> in particular the icon variants and the localization described here
> were both reworked in Round 3. Kept only as a record of what was fixed
> and why.

# Wave 2 remediation report — shipping hygiene, assets, docs, localization

Branch: `feature/audit-remediation`
Toolchain: Xcode 26.2 (17C52), Apple Swift 6.2.3, iOS 26.2 SDK, simulator iPhone 17 Pro (23C54)

## Commits

| Hash | Subject |
|---|---|
| `17f2053` | build: share the testExample scheme so a fresh clone can build |
| `fa9f252` | build: honest target settings — no personal team, iPhone-only, RepoScout ids |
| `06584fb` | build: add a privacy manifest declaring that nothing is collected |
| `01de560` | feat: ship a real app icon and accent colour |
| `1b81218` | build: accept xcodebuild's alphabetical INFOPLIST_KEY ordering |
| `539117a` | docs: add MIT LICENSE, archive the planning artifacts |
| `43d65f7` | i18n: comment every string, add plurals, and ship a German localization |
| `8fa5551` | docs: make README and ARCHITECTURE describe the code as it exists |

Final `git status`: clean apart from the untracked `RepoScout-Guide.pdf`, left
uncommitted per C6.

> *Correction (Round 3, Wave 2):* `RepoScout-Guide.pdf` was committed
> shortly afterwards, in `513c8c7`, and is tracked at the repository root.

## Verification summary

| Check | Evidence |
|---|---|
| Shared scheme visible | `xcodebuild -list` → `Schemes: testExample` |
| Build | `** BUILD SUCCEEDED **` after every pbxproj edit (6 separate builds) |
| Full suite, English | `** TEST SUCCEEDED **`, `result Passed \| passed 40 \| failed 0 \| runs [66]` |
| Full suite after bundle-ID change | `** TEST SUCCEEDED **`, 58 tests passed, 0 failed |
| Privacy manifest in bundle | `find … -name PrivacyInfo.xcprivacy` → `…/testExample.app/PrivacyInfo.xcprivacy` |
| Icon in bundle | `AppIcon60x60@2x.png` emplaced; no actool warnings in build tail |
| German localization compiled | `de.lproj/Localizable.strings` + `de.lproj/Localizable.stringsdict` in the app bundle |
| German launch test | `LaunchTests` under `-testLanguage de` → `** TEST SUCCEEDED **`, 16 runs, 0 failures |

> *Correction (Round 3, Wave 2):* these two rows contradict each other as
> written — both claim to be "the full suite", one says 40 and the other
> 58 — and neither says which counter produced its number. Swift Testing,
> XCTest and `xcodebuild` each count differently (parameterized cases
> expand into runs; the two bundles are summarized separately), so a bare
> total is not a comparable figure. Treat both rows as "it passed" and
> nothing more. The current suite's counts, and the tools that produced
> them, are in `r3-wave2-report.md`.

---

## A. Project plumbing

### A1 — Shared scheme. Done.

Created `testExample/testExample.xcodeproj/xcshareddata/xcschemes/testExample.xcscheme`.
Blueprint identifiers extracted from `project.pbxproj`'s `PBXNativeTarget`
section:

| Target | BlueprintIdentifier | BuildableName |
|---|---|---|
| `testExample` | `A34690DD303A47FF005CD129` | `testExample.app` |
| `testExampleTests` | `A34690EA303A4800005CD129` | `testExampleTests.xctest` |
| `testExampleUITests` | `A34690F4303A4800005CD129` | `testExampleUITests.xctest` |

Container `container:testExample.xcodeproj`. BuildAction (app target, all five
build-for flags), TestAction (Debug, both `TestableReference`s, neither
skipped), LaunchAction (Debug), ProfileAction (Release), AnalyzeAction (Debug),
ArchiveAction (Release).

**Verification.**

```
$ xcodebuild -list -project testExample.xcodeproj
Information about project "testExample":
    Targets:
        testExample
        testExampleTests
        testExampleUITests
    Build Configurations:
        Debug
        Release
    Schemes:
        testExample
```

`xcodebuild build … -scheme testExample` → `** BUILD SUCCEEDED **`.

`.gitignore:5-11` — the `!*.xcodeproj/xcshareddata/` line plus a six-line
comment explaining that Xcode's autocreated user scheme is what made the
README's commands fail on a fresh clone. Note the negation is documentary
rather than functional: nothing in the file excluded `xcshareddata/` in the
first place, so the line asserts an invariant rather than restoring one.

### A2 — pbxproj settings. Done, with one scope note.

All edits made with `perl -i`, each followed by `grep` verification and a
build.

**`DEVELOPMENT_TEAM`.** The work order says "remove both lines"; the file had
**eight** — project-level Debug/Release plus Debug/Release for each of the
three targets. All eight removed (585 → 577 lines), on the work order's own
stated reasoning (a personal team ID does not belong in a public repo), which
applies identically to all eight. `grep -c DEVELOPMENT_TEAM` → `0`.

**New Info.plist keys.** Anchored on
`INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents`, which exists only in
the two app-target blocks, so exactly two insertions of each:
`project.pbxproj:402-403` and `:436-437` at insert time.

Verified in the built `Info.plist`:

```
"ITSAppUsesNonExemptEncryption" => false
"LSApplicationCategoryType" => "public.app-category.developer-tools"
```

**`TARGETED_DEVICE_FAMILY`.** Six occurrences in the file; only the two app
-target ones (then lines 421 and 455) changed to `1`, matched by line number
so the four test-target lines were provably untouched. Post-edit `grep` shows
`= 1;` twice and `= "1,2";` four times. Built `Info.plist`:
`plutil -extract UIDeviceFamily json` → `[1]`.

**`PRODUCT_BUNDLE_IDENTIFIER`.** `work.timmaher.testExample` →
`work.timmaher.RepoScout` (2), `…testExampleTests` → `…RepoScoutTests` (2),
`…testExampleUITests` → `…RepoScoutUITests` (2).

Cross-reference sweep before the change (`grep -rn` over `*.swift *.pbxproj
*.xcscheme *.md *.xcstrings *.plist`) found no other consumer:
- `TEST_HOST` / `BUNDLE_LOADER` reference the app by **product name**
  (`testExample.app` / `$(BUNDLE_EXECUTABLE_FOLDER_PATH)/testExample`), not by
  bundle id.
- `Support/Logging.swift:15,22` read `Bundle.main.bundleIdentifier`, which
  only feeds the OSLog subsystem string.
- The two archived planning documents mention the old id in code listings;
  C4 forbids editing them, and they now carry a header saying they are stale.

**Full suite run immediately after this change, before proceeding**, as
instructed: `** TEST SUCCEEDED **`, `passedTests 58, failedTests 0`. Test-host
launch confirmed against the new id in the log (`Wait for work.timmaher.RepoScout
to idle`).

**Scope note (extra edit, commit `8fa5551`).**
`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` was removed from both
app-target blocks. It became unreachable the moment the device family went to
`1`, and leaving it would have made the new ARCHITECTURE §"Shipping hygiene"
claim false on its own terms. Verified: built `Info.plist` now has only
`UISupportedInterfaceOrientations~iphone`.

**Formatting note (commit `1b81218`).** Wave 1 reported that `xcodebuild`
re-sorts two `INFOPLIST_KEY_*` lines on every run and reverted the churn each
time. The cause is that `INFOPLIST_KEY_CFBundleDisplayName` sat out of
alphabetical order. Since pbxproj edits are in scope this wave, the normalized
ordering was committed instead, making the file a fixed point of xcodebuild's
own formatter. Confirmed: no further churn across the six subsequent builds
and four test runs.

### A3 — Privacy manifest. Done; no fallback needed.

`testExample/testExample/PrivacyInfo.xcprivacy` — `NSPrivacyTracking` false,
`NSPrivacyTrackingDomains` / `NSPrivacyCollectedDataTypes` /
`NSPrivacyAccessedAPITypes` all empty arrays. `plutil -lint` → `OK`.

The synchronized root group picked it up with **no pbxproj change**:

```
$ find ~/Library/Developer/Xcode/DerivedData -name PrivacyInfo.xcprivacy -path '*testExample*'
…/Build/Products/Debug-iphonesimulator/testExample.app/PrivacyInfo.xcprivacy
```

It lands at the bundle root, which is where the App Store expects it. The
"why every array is empty" reasoning is in `ARCHITECTURE.md` §Shipping hygiene
as specified, since plists carry no comments.

## B. Assets

### B1 — App icon. Done.

Generator: `scratchpad/make-icon.swift`, run as `swift make-icon.swift out`.

**Deviation from the work order's method:** the script uses **CoreGraphics**,
not AppKit drawing. The first AppKit implementation (`NSBitmapImageRep` +
`NSGraphicsContext.current` + `NSImage.lockFocus`) rendered the first variant
correctly and then hard-crashed inside AppKit on the second — reproducibly,
and not fixed by un-nesting the `lockFocus` calls. `CGContext` has no ambient
global state, so each variant composes independently. AppKit is still used for
the one thing it is needed for: `NSImage(systemSymbolName: "magnifyingglass")`
with an `NSImage.SymbolConfiguration(pointSize: 800, weight: .medium)`,
rasterized once to a `CGImage` whose alpha channel is used as a mask.

Design as specified: vertical `#0B458A` → `#16A3A3` gradient, white
`magnifyingglass` glyph scaled to 52% of the canvas and offset 3.5% above
centre. Variants:

| File | Background | Glyph |
|---|---|---|
| `Icon-Light.png` | blue→teal gradient | white |
| `Icon-Dark.png` | solid `#101418` | blue→teal gradient |
| `Icon-Tinted.png` | solid `#808080` | white |

All three written through a `CGContext` with `CGImageAlphaInfo.noneSkipLast`,
i.e. **no alpha channel at all** rather than an all-opaque one. Verified:

```
Icon-Dark.png:   pixelWidth: 1024  pixelHeight: 1024  hasAlpha: no  space: RGB
Icon-Light.png:  pixelWidth: 1024  pixelHeight: 1024  hasAlpha: no  space: RGB
Icon-Tinted.png: pixelWidth: 1024  pixelHeight: 1024  hasAlpha: no  space: RGB
```

`AppIcon.appiconset/Contents.json` — each of the three 1024×1024 slots now
carries its `filename`; the `appearances` blocks were already correct and are
unchanged.

**Build verification.** `** BUILD SUCCEEDED **`. The build log's `actool`
invocation produced **no warnings or notices** — the only lines matching
`warning` are the `actool` command line itself (which contains the literal
`--warnings` flag) and an unrelated `appintentsmetadataprocessor` note about
there being no AppIntents framework dependency. `LinkAssetCatalog` reports
`note: Emplaced …/testExample.app/AppIcon60x60@2x.png`, and that file was
opened and visually confirmed to be the rendered icon rather than a
placeholder.

All three 1024px variants were also rendered down and inspected visually
before being committed.

### B2 — AccentColor. Done.

`AccentColor.colorset/Contents.json` — universal `srgb`
`0.059 / 0.427 / 0.698` (#0F6DB2), plus a `luminosity: dark` appearance at
`0.280 / 0.620 / 0.850`. Components as strings, alpha `"1.000"`, per the
schema. Build clean; `actool` runs with `--accent-color AccentColor` and
reports nothing.

## C. Docs and localization

### C1 — LICENSE. Done.

`LICENSE` at repo root — MIT, "Copyright (c) 2026 Tim Maher". Referenced from
`README.md` in a new `## License` section at the bottom.

### C2 — README. Done.

- Shared scheme called out explicitly in "Running the tests"
  (`README.md:52-54`).
- Simulator-substitution note added after the three command blocks
  (`:77-81`), including `-destination 'generic/platform=iOS Simulator'` for
  build-only.
- Two new "what to look at" rows (`:100-101`): Localization → `RepoRowView.swift`
  + `Localizable.xcstrings`; Accessibility → `RepoRowView.swift` +
  `SearchView.swift`.
- `RepoScout-Guide.pdf` mentioned conditionally (`:106-108`).
- License line (`:125-127`).
- The "name and icon" sentence at `:35` is now true and was left as is;
  a new line at `:39-40` states the app is iPhone-only and English/German.
- Staleness fixed: the unit-suite description (`:44-50`) understated what
  Wave 1 added — it now names cancellation behaviour, HTTP-status-to-error
  mapping, and the accessibility audit. The project-name note (`:121-123`)
  gained a sentence saying the bundle identifier *was* changed, so the
  "everything is still called testExample" claim stays accurate after A2.
- Checked and clean: the README never mentioned `removeDuplicates`; all three
  command blocks were verified to run as written.

### C3 — ARCHITECTURE. Done.

Read in full first. Corrections against the current tree:

- **Debounce pipeline** (`:33-66`). The document described `.removeDuplicates()`
  — i.e. it was teaching the bug Wave 1 removed. Replaced with the real
  snippet (`.debounce(for: debounceInterval, scheduler: DispatchQueue.main)`
  then the `lastDispatchedQuery` `filter`) and the reason: input-level dedup
  is only sound for deterministic operations, failure clears the key so
  retyping retries, and `retry()`/`submitImmediately()` set it so a pending
  debounce emission can't race a duplicate onto the wire.
- **`LoadState`** (`:77-103`). Was shown as `.loaded([Repo])` and a plain
  four-case enum. Now carries the real declaration including
  `case loaded(Value, isRefreshing: Bool)` and explains why the flag lives
  inside `loaded` rather than as a sibling property.
- **`GitHubClient`** (`:68-75`). Was `URLSession.data(from:)`; now describes
  the `URLRequest` with GitHub's required headers and 15s timeout,
  `session.data(for:)`, and the status-code mapping.
- **`SearchView`'s switch** (`:105-113`). Now includes the stale-while-
  revalidate branch and the footer spinner.
- **Isolation narrative** (`:196-238`). The document had **no** concurrency
  section at all — `grep -i "isolat|MainActor|nonisolated|concurren|Sendable"`
  over `ARCHITECTURE.md` returned nothing. Written from scratch rather than
  rewritten: states the SE-0461 rule (a `nonisolated async` function runs on
  its **caller's** executor), that the caller here is the `@MainActor`
  `SearchViewModel`, that `@concurrent` on `LiveGitHubClient` is therefore
  what actually moves the ~100KB decode off the main actor, and the
  mirror-image point that the Combine sinks are safe because of
  `scheduler: DispatchQueue.main` / `on: .main` — load-bearing arguments —
  and not because of the default isolation, which only makes them type-check.
- **Ticker** (`:283-308`). Added the seeded start (a publisher's first value
  is not its current value) and the leaf-view invalidation-confinement point
  (`@Observable` tracks reads per `body`, so inlining the footer invalidates
  the whole screen once a second).
- **Path-3 table ticker row** (`:243`). The line claiming `AnyCancellable`
  means "instead of a timer you must remember to invalidate" was exactly
  backwards for the one publisher in this app with an explicitly managed
  lifetime. Reconciled with the `startTicker()`/`stopTicker()` design.
- **Combine section** (`:256-261`, `:435-437`). Two further `removeDuplicates`
  references updated.
- **New `## Accessibility and localization`** (`:344`). Whole-sentence
  `String(localized:)` labels (the app's best lesson, previously undocumented),
  pre-formatted numbers, the plural-variation trade-off, `ViewThatFits` and
  Dynamic Type, the `accessibilityHidden` ticker rationale, catalog comments,
  and the measured German test-suite behaviour.
- **New `## Shipping hygiene`** (`:416`). Shared scheme, empty privacy
  manifest, ATS, export compliance, device family, no `DEVELOPMENT_TEAM`,
  bundle identifier.

Both new sections were promoted to `##` and moved *after* the Combine section
— an intermediate edit had accidentally split it in half.

**The ATS claim was verified rather than asserted:**

```
$ nscurl --ats-diagnostics https://api.github.com
Default ATS Secure Connection
ATS Default Connection
Result : PASS
…
TLSv1.3
Result : PASS
```

and `plutil -p` on the built `Info.plist` confirms no `NSAppTransportSecurity`
key exists.

### C4 — Process archive. Done.

`git mv` both files into `docs/process-archive/`, filenames unchanged:

- `docs/superpowers/plans/2026-08-22-reposcout-reference-app.md` →
  `docs/process-archive/2026-08-22-reposcout-reference-app.md`
- `docs/superpowers/specs/2026-08-22-reposcout-reference-app-design.md` →
  `docs/process-archive/2026-08-22-reposcout-reference-app-design.md`

Git recorded both as renames (`R`). A five-line blockquote header was
prepended to each — point-in-time artifact, superseded by the code and
`ARCHITECTURE.md`, listings predate later fix waves and must not be used as
reference, init-started ticker specifically called out as a later-identified
bug. Nothing else in either file was touched. The now-empty
`docs/superpowers/` directories were removed.

### C5 — String Catalog and localization. Done.

The catalog was synced from the compiler-emitted `.stringsdata` rather than
hand-edited for extraction, because `xcodebuild` does not sync `.xcstrings`
(only the Xcode IDE does) — same technique Wave 1 used:

```
xcrun xcstringstool sync Localizable.xcstrings --stringsdata <…>/Objects-normal/arm64/*.stringsdata
```

**Comments.** All 31 keys now carry one.
- 11 came from `String(localized:comment:)` call sites: `GitHubClient.swift`
  (5 error descriptions), `SearchViewModel.swift` (2), `RepoRowView.swift`
  (4 VoiceOver sentences).
- 20 SwiftUI literal keys (`Text("Stars")`, `Section("Stats")`, tab titles,
  empty-state copy) got their `comment` field filled directly in the catalog
  JSON, since there is no call-site parameter for those.

**Plurals.**
- The footer key `Updated %llds ago` → `Updated %lld seconds ago`, with
  `one`/`other` variations in **both** `en` and `de`. The code string was
  changed from `"Updated \(seconds)s ago"` to `"Updated \(seconds) seconds ago"`
  as the work order permits: the abbreviated form gives an inflecting language
  no noun to inflect, and English itself was rendering "Updated 1s ago" where
  it should read "1 second".
- **The stars sentences correctly get no plurals.** Verified as the work order
  asked: Wave 1 changed the count to a pre-formatted `%@` argument
  (`repo.stargazersCount.formatted()`), so a plural variation has no number to
  key off. Documented as a deliberate trade in ARCHITECTURE rather than left
  implicit.

**German.** All 31 keys translated, `state: "translated"` on every unit.
Informal address throughout (Apple's German register for consumer apps).
Positional specifiers (`%1$@`, `%2$@`, …) used in every multi-placeholder
string so a later rephrasing can reorder without touching code — the VoiceOver
sentence is rendered as "%1$@, %2$@ Sterne, in %3$@ geschrieben." which moves
the participle to the German position. `de` added to `knownRegions` in
`project.pbxproj`, without which the language would not have been built.

Verified in the built bundle:

```
$ ls testExample.app/de.lproj
Localizable.strings    Localizable.stringsdict

$ plutil -p testExample.app/de.lproj/Localizable.stringsdict
"Updated %lld seconds ago" => {
    "one" => "Vor %lld Sekunde aktualisiert"
    "other" => "Vor %lld Sekunden aktualisiert"
}
```

**Unit suite.** 30 tests, `** TEST SUCCEEDED **`.
`SearchViewModelTests.refreshedDescription()` was extended to assert
`"Updated 1 second ago"` and `"Updated 0 seconds ago"` alongside the existing
42-second case — the singular comes from the catalog, not from a branch in the
code, so without that assertion dropping the `one` variation would regress
English silently.

**German UI run.** `LaunchTests` under `-testLanguage de` →
`** TEST SUCCEEDED **`, 16 runs (2 methods × 8 configurations, including
explicit "Light Appearance, German, Portrait" rows), 0 failures. Screenshots
exported from the result bundle and visually confirmed showing
"GitHub durchsuchen", "Finde Repositories nach Name, Thema oder Sprache."
and the German search-field placeholder.

**Beyond the required smoke test**, the two flow suites were also run under
`-testLanguage de`, which found four failures — all in *test* queries against
localized strings, none an app defect:

1. `FavoritesScreen.open()` — `app.tabBars.buttons["Favorites"]`; the tab reads
   "Favoriten".
2. `FavoritesScreen.editButton` — UIKit's `EditButton`, "Bearbeiten".
3. `deleteFirstRowInEditMode()` — the "Delete" confirmation, "Löschen".
4. `SearchScreen.noResultsView` — `ContentUnavailableView.search(text:)`'s
   "No Results" title, "Keine Ergebnisse".
5. `SearchScreen.errorView` — `app.staticTexts["Something went wrong"]`.

**One of these was the app's fault and is fixed.** #5 was matching an *app*
string that the app itself owns. `SearchView.swift` now puts
`.accessibilityIdentifier("search.errorView")` on the error state's
description `Text` — deliberately on that leaf and not on the
`ContentUnavailableView`, whose container identifier gets re-parented onto
merged children and was what clobbered `search.retryButton` in Wave 1.
`SearchScreen.errorView` queries the identifier instead. Re-run under
`-testLanguage de`: **SearchFlowUITests 3/4 pass**, up from 2/4, and the
`testSearchFailureShowsRetryableError` failure is gone.

**The remaining four are queries against strings Apple owns**, and have no
app-side fix that isn't worse than the problem (hard-coding a translation
table of Apple's own UI strings would be wrong the next time Apple rewords
one; SwiftUI's `Tab` exposes no API to identify the tab-bar button it
produces, which Wave 1 already established). Rather than leave that as an
undocumented surprise, the measured behaviour is now written into the screen
objects in place (`Screens/SearchScreen.swift`, `Screens/FavoritesScreen.swift`)
and into ARCHITECTURE: the UI suite is written to run in the development
language, and `LaunchTests` is the German smoke check.

### C6 — Working tree. Clean.

```
$ git status --short
?? RepoScout-Guide.pdf
```

`RepoScout-Guide.pdf` deliberately left untracked and uncommitted for the
controller to regenerate. No stray files; the icon generator and its
intermediates live in the scratchpad, not the repo.

---

## Deviations and concerns

1. **`DEVELOPMENT_TEAM` removed from eight lines, not two.** The work order
   says "both". The file had eight. The stated reason (a personal team ID does
   not belong in a public repo) applies to all of them, so all were removed.
2. **The icon generator uses CoreGraphics, not AppKit drawing.** The AppKit
   implementation the work order describes crashed reproducibly inside AppKit
   after rendering the first of the three variants. AppKit is still used to
   obtain the SF Symbol. Output meets every stated requirement, including the
   no-alpha constraint, which the CG version satisfies more strictly (no alpha
   channel at all, rather than an all-opaque one).
3. **One extra pbxproj edit beyond A2's list:**
   `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` removed. It was dead
   after the device-family change and would have contradicted the new
   ARCHITECTURE section. Verified in the built `Info.plist`.
4. **The normalized `INFOPLIST_KEY_*` ordering was committed** (`1b81218`)
   rather than reverted the way Wave 1 did. This ends a recurring
   dirty-working-tree annoyance; the file is now a fixed point of xcodebuild's
   own formatter. Confirmed stable across six builds and four test runs.
5. **`de` had to be added to `knownRegions`.** Not in the work order, but
   without it the German localization does not reach the bundle, so C5 would
   have been unverifiable.
6. **One app-code change outside the docs/assets scope:**
   `.accessibilityIdentifier("search.errorView")` in `SearchView.swift`, plus
   the matching `SearchScreen.errorView` query. Justified under C5's "fix the
   test to be locale-independent" clause, and it removes a genuine fragility
   (a UI state matched by English prose). Full English suite re-run after it:
   66 test runs, 0 failures.
7. **The UI suite is not fully locale-independent, and cannot cheaply be
   made so.** Four label-based queries hit strings Apple owns
   (`ContentUnavailableView.search`, `EditButton`, the Delete confirmation,
   the Favorites tab title). The work order's required verification — the
   launch test in German — passes; the flow suites do not. This is documented
   in the screen objects and in ARCHITECTURE rather than papered over, but it
   is a real limitation and the honest characterization is: **RepoScout is
   localized; its UI test suite is not.**
8. **`About` is translated as "Beschreibung", not "Über".** The section
   contains the repository's description, and "Beschreibung" is what a German
   iOS app would actually say. A literal translation would have been worse
   German.
9. **The four VoiceOver sentence keys have no plural variations**, by design
   (item C5 above). This is a deliberate trade — locale-correct number
   formatting and correct VoiceOver pronunciation, bought at the cost of
   grammatical agreement on the noun "stars"/"Sterne". Named explicitly in
   ARCHITECTURE so it reads as a decision rather than an oversight.
10. **The `.gitignore` negation line is documentary.** `!*.xcodeproj/xcshareddata/`
    re-includes nothing, because nothing excluded it; the surrounding comment
    is the part that does the work. Added as specified.
11. **`PreviewSupport.swift:17` still calls `fatalError`**, carried over from
    Wave 1's own sanity list. Out of scope for both waves; noted so this
    report doesn't read as a clean sweep either.
