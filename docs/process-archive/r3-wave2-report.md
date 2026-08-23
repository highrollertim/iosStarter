> **Archived — point-in-time remediation record (Round 3, Wave 2,
> 2026-08-23).** Superseded by the code, `README.md` and
> `ARCHITECTURE.md`. Line numbers, file listings and "current state"
> claims herein describe the tree as it stood at the end of this wave and
> **MUST NOT** be used as reference — a later wave may have moved any of
> it. Kept only as a record of what was done and why.

# Round 3 — Wave 2 report

Branch: `feature/round3-remediation`. Base: `b7f441d` (end of Round 3 Wave 1).
Five commits of work, plus a sixth carrying this file. Toolchain: Xcode 26.2
(17C52), `swift-format` 6.2.3, simulator iPhone 17 Pro (iOS 26.2, 23C54).

## Commits

| Hash | Scope |
|---|---|
| `6ebd9e4` | A1, A2 — test plan, coverage, scheme, target settings, language gates |
| `479bbd6` | B1, B2, B3 — CI workflow, `.swift-format`, `.gitignore` |
| `64d9066` | C1 — dark and tinted icons re-exported on transparency |
| `2c6f8c2` | D1, D2 — German corrections, star-count plural substitutions |
| `e8e5ee8` | E1–E4 — docs truth pass, archived reports |

## A. Test plan, coverage, scheme

`testExample/testExample.xctestplan` (beside the `.xcodeproj`, not inside a
`PBXFileSystemSynchronizedRootGroup`, so it is not swept into a target as a
resource). Two configurations — **English** (no override) and **German**
(`language: de`, `region: DE`) — both test targets referenced by their
`PBXNativeTarget` identifiers, unit target `parallelizable: true`, UI target
`false`. `defaultOptions.codeCoverage.targets` lists the app target alone.

The scheme's `TestAction` now carries a `TestPlans` block with this plan as
default; the inline `Testables` block is gone (Xcode's own behaviour when a
scheme adopts a plan). `xcodebuild -showTestPlans` lists `testExample`.

Coverage verified through a result bundle rather than assumed:

```
$ xcrun xccov view --report --only-targets final.xcresult   # full suite
ID Name            # Source Files Coverage
0  testExample.app 17             90.40% (1177/1302)

$ xcrun xccov view --report --only-targets unit.xcresult    # unit only
0  testExample.app 17             39.45% (512/1298)
```

One target in both cases, the app's — the test bundles are absent, which is
the point. The gap between the two figures is the honest shape of this
codebase: the unit suite covers the model, the client and the view model, and
the UI suite is what executes the views.

**Both configurations verified to run**, from the same bundle:

```
$ xcrun xcresulttool get test-results summary --path unit.xcresult
English: passedTests 53, failedTests 0
German:  passedTests 53, failedTests 0
```

(53 for a 39-test suite because Swift Testing's parameterized cases expand
into individual runs — the same counter mismatch the appended correction in
`wave2-report.md` is about.)

### Deviation: per-configuration test selection does not exist

The order allowed scoping the German configuration's tests "via
`skippedTests`" inside the configuration. **That does not work**, and this was
measured rather than reasoned about: a plan with

```json
"options": { "language": "de", "region": "DE",
             "skippedTests": ["SearchViewModelTests/refreshedDescription()"] }
```

ran that test in *both* configurations — the key is accepted by the file
format and ignored. Test selection in a plan is per test *target*, and a
target-level skip would have removed the tests from the English run, which is
the run they exist for.

Implemented instead as a runtime gate,
`testExampleUITests/Support/DevelopmentLanguage.swift`:
`skipUnlessRunningInEnglish(matching:)` throws `XCTSkip` unless
`Locale.current.language.languageCode` is `en`, naming the Apple-owned string
the caller matches. (`Locale.current` in the UI-test *runner* does track the
plan's configuration — confirmed by the German run reporting the gated tests
as skipped.) Four test cases gate: both accessibility audits (the "Clear text"
suppression is matched by label),
`testSearchWithNoMatchesShowsTheNoResultsState` ("No Results"), and
`testDeletingAFavoriteViaEditButton` ("Edit"/"Delete").

Everything else runs in both languages, including the whole unit suite.
`SearchViewModelTests.refreshedDescription()` asserts the German plural under
the German configuration rather than being skipped — it is the one test whose
output is a localized string, so it is the one test that has to know which run
it is in.

### A2 — target settings

`TARGETED_DEVICE_FAMILY = "1,2"` → `1` in four blocks (both test targets,
Debug and Release); `IPHONEOS_DEPLOYMENT_TARGET` removed from the unit-test
target's two blocks, where it restated the project-level 26.2. Grep after:
six `TARGETED_DEVICE_FAMILY = 1`, two `IPHONEOS_DEPLOYMENT_TARGET` (both
project-level). `** BUILD SUCCEEDED **`.

## B. CI, format, gitignore

**`.github/workflows/ci.yml`** — 58 lines. Two jobs on `macos-26`, unit and
UI, each selecting Xcode 26.2 and running the shared scheme (therefore the
plan, therefore both languages). The UI job is *not* `continue-on-error`; its
30-minute timeout is the safety valve instead, against a ~11-minute expected
run. It also disables the simulator's hardware-keyboard pairing, because
`SearchScreen.search(for:)` waits on the software keyboard. The header comment
states plainly that the repository has no remote and that nothing has ever
executed the file.

**`.swift-format`** — `swift format dump-configuration` was the starting
point; the deltas are four-space indentation, `lineLength: 120`,
`indentConditionalCompilationBlocks: false`, and `AlwaysUseLowerCamelCase`
off.

The middle one is the interesting tuning. With the default `true`, the linter
produced **324** diagnostics, ~270 of them "indent by 4 spaces" inside the
`#if DEBUG` that wraps whole files (`MockGitHubClient`, `PreviewSupport`,
every `#Preview` block). Turning it off dropped that to 143 without touching a
line of source. Line length was measured rather than guessed: 100 → 167
warnings, 120 → 143, 140 → 136, 160 → 135, so the residue is structural, not a
column count, and 120 is where the order's judgement and the data agree.

The genuine **rule** violations it found, all fixed, were: three
`UseLetInEveryBoundCaseVariable` in `RepoRowView`'s switch (`case let (a?, b?)`
→ `case (let a?, let b?)`), one `GroupNumericLiterals` (`44838949` →
`44_838_949` in `RepoDecodingTests`), and four `AlwaysUseLowerCamelCase` on the
BDD helpers `Given`/`When`/`Then`/`And` — which are deliberate, so the rule is
off in the config rather than the helpers renamed.

Final lint state: **zero rule violations**; 143 pretty-printer diagnostics
(89 `Indentation`, 40 `AddLines`, 12 `LineLength`, 2 `Spacing`), every one of
them an opinion about where to break multi-line call arguments or a single
unbreakable string literal — a translator comment or a doc line. The tree was
not reformatted, and ARCHITECTURE says the config is a record of house style
rather than a gate.

**`.gitignore`** — the seven-line comment defended `!*.xcodeproj/xcshareddata/`,
a negation that never did anything, because nothing above it excluded that
path. Replaced with a three-line comment on `xcuserdata/` saying why its
sibling needs no negation. Added `*.xcscmblueprint`, `timeline.xctimeline`,
`*.hmap`, `*.ipa`, `*.dSYM.zip`. Verified `git check-ignore -v` does not match
the shared scheme.

## C. Icons

Generator: `scratchpad/make-icon.swift`, CoreGraphics only (AppKit used
solely to rasterize `NSImage(systemSymbolName: "magnifyingglass")` into a
`CGImage` whose alpha channel becomes the clip mask — the crash the previous
wave hit was AppKit *drawing*, which this avoids).

| File | Alpha | Background | Glyph |
|---|---|---|---|
| `Icon-Light.png` | **no** — untouched, still the committed bytes | `#0B458A→#16A3A3` | white |
| `Icon-Dark.png` | **yes** | transparent | `#2E7BD6→#2FD4D4` gradient |
| `Icon-Tinted.png` | **yes** | transparent | greyscale, white → 0.45 grey |

The dark variant's gradient is lifted from the light icon's because iOS
composites it over a near-black backdrop, where `#0B458A` nearly vanishes; the
tinted variant spans a wide luminance range because the system maps luminance
onto the user's tint, and a flat grey tints to a flat slab. Both were composed
into a preview strip over a near-black and an orange field and inspected
before committing.

```
$ sips -g pixelWidth -g pixelHeight -g hasAlpha Icon-*.png
Icon-Dark.png:   1024 1024  hasAlpha: yes
Icon-Light.png:  1024 1024  hasAlpha: no
Icon-Tinted.png: 1024 1024  hasAlpha: yes
```

`git status` confirms `Icon-Light.png` was not modified. Build clean: the only
`warning` line in the build log is `appintentsmetadataprocessor`'s unrelated
"No AppIntents.framework dependency found"; no `actool` warnings.

## D. German and the catalog

### D1 — corrections

Applied verbatim from the order: *Repositorys* (Duden) in three strings,
dative *Namen* after *nach*, the Favorites empty state now using the same verb
as the button that fills it, *Inhaber* for a GitHub account owner, *Statistik*
as a section header, *Internetverbindung* where the failure is the network, a
rate-limit message that says what to do, *Ein Fehler ist aufgetreten* in both
the standalone key and the "…Bitte versuche es erneut." variant, present tense
in the decoding-failure message, and U+00A0 before the ellipsis in
"Suche läuft …" (verified at the byte level: `0x74 0xa0 0x2026`).

`RepoScout`'s `de` unit is deleted and the key carries
`"shouldTranslate": false`; the compiled `de.lproj/Localizable.strings`
confirms the key is absent rather than translated-to-itself. Wave 1's stable
`"Favorite"` key already had `"Favorit"` and needed nothing.

### D2 — plural substitutions (approach A, the one the order preferred)

**Chosen: real catalog substitutions**, not the split-string fallback, because
it verified end to end.

`RepoRowView.accessibilityDescription(for:)` interpolates the raw
`repo.stargazersCount` instead of `.formatted()`, so the four keys carry
`%lld` where they used to carry `%@`. Each key's `en` and `de` localizations
gained a `substitutions` entry — `argNum: 2`, `formatSpecifier: "lld"`, plural
`one`/`other` — and the `stringUnit` value uses `%#@starCount@` in place of
the second argument.

Verified in the **compiled** artifact, not just the source:

```
en.lproj/Localizable.stringsdict
  "%@, %lld stars, written in %@." => {
    NSStringLocalizedFormatKey => "%1$@, %2$#@starCount@, written in %3$@."
    starCount => { NSStringFormatSpecTypeKey => NSStringPluralRuleType
                   NSStringFormatValueTypeKey => lld
                   one => "%2$lld star"   other => "%2$lld stars" }
  }
de.lproj — same shape, one => "%2$lld Stern", other => "%2$lld Sterne"
```

…and at runtime by a new `RepoRowLabelTests`, which the plan runs in both
languages: `starCountInflects()` pins "1 star"/"2 stars" and "1 Stern"/"2
Sterne", and `allShapesResolve()` walks all four optional-language /
optional-summary combinations asserting no `%` survives into the output (an
unresolved substitution token would otherwise reach VoiceOver silently).

The label builder became `nonisolated static func` — `static` so a test can
call it without a view, `nonisolated` because it is a pure function of a
`Repo` and the project's default `MainActor` isolation would otherwise force
the test suite onto the main actor to say anything about a string. It mirrors
`SearchViewModel.refreshedDescription(from:now:)` exactly, for the same
reason.

**What was traded away, stated honestly:** `%lld` does not apply digit
grouping, so the *spoken* count is now "67000" rather than "67,000". The
order rated inflection above grouping and that is the right call for a label
read aloud once, but it is a trade. The visible `Label` still uses
`.formatted()` and still groups; it has no noun to agree with.

### D3 — catalog integrity

30 keys. `xcstringstool sync` of a copy of the catalog against all 21
`.stringsdata` files from a clean build produced a **byte-identical** result:
no orphans, no missing German.

## E. Docs

`ARCHITECTURE.md` (285 insertions, 65 deletions) and `README.md` were
rewritten against the current source, file by file, rather than from memory.
The substantive corrections are listed in `e8e5ee8`'s message. The two that
matter most:

1. The section that declared plural agreement impossible alongside formatted
   numbers now shows the substitution JSON that disproves it, and names the
   real cost.
2. The German-testing passage credited `LaunchTests` and listed the Favorites
   tab title among the unfixable locale-bound queries. The tab carries an
   identifier since Wave 1, and the mechanism is a test plan configuration.
   The unfixable list is now exactly three Apple-owned strings, and the
   passage records that per-configuration `skippedTests` is ignored, because
   that measurement is what shaped the design.

`.superpowers/remediation/` is gone: `wave1-report.md`, `wave2-report.md` and
`r3-wave1-report.md` are `git mv`d into `docs/process-archive/` with the same
disclaimer header style the archived planning artifacts carry. The two stale
statements the audit flagged are corrected by *appended* notes rather than by
rewriting them — the "left uncommitted per C6" line (the PDF was committed in
`513c8c7`) and the 40-vs-58 contradiction (two different counters, neither
labelled; the note says to read both rows as "it passed" and nothing more).

`LaunchTests` now uses `XCUIApplication.launchedForUITest()` instead of a
hand-rolled copy of its launch arguments, keeping
`runsForEachTargetApplicationUIConfiguration`, the screenshot attachment and
the launch metric. Its doc comment now distinguishes the two multipliers that
apply to it, because the result bundle is confusing until someone does: the
eight app-derived UI configurations (appearance × supported localization ×
orientation — read out of the bundle, e.g. "Light Appearance, German,
Portrait Upside Down") are metadata permutations, while the plan's two
configurations relaunch the app under `de`/`DE` for real.

## Verification

| Check | Evidence |
|---|---|
| Build after every project edit | `** BUILD SUCCEEDED **` |
| Test plan visible | `xcodebuild -showTestPlans` → `testExample` |
| Both configurations execute | result bundle names `English` and `German` on every run |
| Coverage scoped | `xccov --only-targets` → `testExample.app` only; 90.40% full suite, 39.45% unit only |
| German UI run | 24 executed, 4 skipped, 0 failures |
| English UI run | 24 executed, 0 skipped, 0 failures |
| Icons | `sips -g hasAlpha` → yes / no / yes; no `actool` warnings |
| Catalog | 30 keys; `xcstringstool sync` a no-op |
| Lint | `swift format lint` → 0 rule violations |
| Full suite | see tail below |
| Working tree | clean |

### Full-suite tail

`xcodebuild test` with no `-only-testing`, i.e. both targets in both
configurations, 641 seconds wall clock:

```
# UI, English
Executed 24 tests, with 0 failures (0 unexpected) in 332.999 seconds
# UI, German
Executed 24 tests, with 4 tests skipped and 0 failures in 269.3 seconds
...
2026-08-23 19:00:42.918 xcodebuild[69462] IDETestOperationsObserverDebug:
    641.200 elapsed -- Testing started completed.

** TEST SUCCEEDED **
```

And the same run counted by `xcresulttool`, which is the figure to quote
because it names its configurations:

```
result Passed  total 51  passed 51  failed 0  skipped 0
English  passed 79  failed 0  skipped 0
German   passed 75  failed 0  skipped 4
```

(79 and 75 are *runs*, not tests: parameterized unit cases expand, and
`LaunchTests` repeats across eight app-derived UI configurations. 51 is the
number of distinct test functions. Quoting one without the other is how the
40-vs-58 confusion in `wave2-report.md` happened.)

## Deviations and concerns

1. **Per-configuration `skippedTests` is not a feature** (A1). Measured, then
   replaced with a runtime `XCTSkip` gate. Documented in the source, in
   ARCHITECTURE and above.
2. **`Icon-Light.png` was deliberately not regenerated** (C1). The order said
   it stays opaque and unchanged; the generator can produce it, but leaving
   the committed bytes alone makes "unchanged" literally true.
3. **`swift format lint` is not clean and is not meant to be** (B2). Zero rule
   violations, 143 pretty-printer disagreements about hand-formatted call
   sites. The order forbade reformatting the tree; the config says so and
   nothing runs it in CI.
4. **Digit grouping in the spoken star count is gone** (D2), as the order
   anticipated. Named in ARCHITECTURE rather than buried.
5. **The CI workflow has never run.** There is no remote. Its header says so,
   README says so, ARCHITECTURE says so — but it is untested YAML beyond a
   parser check, which is the honest limit of what can be claimed here.
