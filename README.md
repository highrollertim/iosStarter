# RepoScout

RepoScout is a small, complete reference app for practicing 2026-era iOS
development. It searches GitHub's public repository index and lets you save
results as favorites, and it exists to be *read* as much as to be run: every
file is written to demonstrate one current Apple-platform practice cleanly,
with the surrounding tests as proof that the practice actually works. If
you're relearning iOS after a few years away, or just want a compact example
of how a modern SwiftUI app is put together end to end — networking, state
management, persistence, and testing — this is meant to be a useful map.

The app itself is intentionally modest. A Search tab lets you type a query
into a `searchable` field and see live results from GitHub's
`/search/repositories` API, with debounced input so it doesn't fire a
request per keystroke. Tapping a result opens a detail screen showing stars,
forks, language, and a link back to GitHub, plus a button to favorite it. A
Favorites tab lists everything you've favorited, backed by on-device
persistence, so it survives relaunches and updates live as favorites change
anywhere else in the app.

## Requirements

Building and running RepoScout requires **Xcode 26.2 or later**. The project
targets Swift 6 language mode with the compiler's default actor isolation
set to `MainActor` and approachable concurrency enabled — both are project
settings, not something you need to configure yourself, but they're why the
codebase reads the way it does (see `ARCHITECTURE.md` for what that means in
practice).

## Running the app

Open `testExample/testExample.xcodeproj` in Xcode and run the `testExample`
scheme on a simulator or device. (The project and its scheme are still named
`testExample` — see the note at the bottom of this file for why — but the
app that launches is RepoScout, with that name and icon.) No API key or
configuration is required: GitHub's search endpoint is public and the app
calls it directly over `URLSession`.

The app is iPhone-only and English/German. Both are deliberate; see the
"Shipping hygiene" section of `ARCHITECTURE.md`.

## Running the tests

RepoScout has two independent test suites: a Swift Testing unit suite that
covers decoding, the search view model's state machine and cancellation
behaviour, the live network client's URL construction and HTTP-status-to-error
mapping, and the SwiftData favorites store; and an XCTest-based UI suite that
drives the real app through its screens against a mocked network so it stays
hermetic and offline, including an accessibility audit at default and
accessibility text sizes.

The scheme is shared (`testExample.xcodeproj/xcshareddata/xcschemes/`), so
every command below works on a fresh clone — no "scheme not found", and
nothing to configure in Xcode first.

**Every command below runs the suite twice.** The scheme's test action points
at a shared test plan, `testExample/testExample.xctestplan`, which declares two
configurations: English (no override) and German (`de`/`DE`). So a plain
`xcodebuild test` runs both languages, and the German pass is the app's
localization check rather than something a maintainer has to remember. Budget
roughly twice the wall-clock time you would expect — about eleven minutes for
the UI suite across both configurations, a couple of minutes for the unit
suite. Four UI tests match strings Apple localizes (the "No Results" title,
`EditButton`/"Delete", the search field's "Clear text" button) and report
themselves as *skipped* under German, with the reason; that is expected, not a
failure.

Run everything — unit and UI — from the command line:

```bash
cd testExample
xcodebuild test -project testExample.xcodeproj -scheme testExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Run just the unit tests:

```bash
cd testExample
xcodebuild test -project testExample.xcodeproj -scheme testExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:testExampleTests
```

Run just the UI tests:

```bash
cd testExample
xcodebuild test -project testExample.xcodeproj -scheme testExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:testExampleUITests
```

The plan also turns code coverage on, scoped to the app target so the number
describes the code under test rather than being inflated by the test bundles'
coverage of themselves. Ask for a result bundle and read it back:

```bash
cd testExample
xcodebuild test -project testExample.xcodeproj -scheme testExample \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -resultBundlePath /tmp/RepoScout.xcresult
xcrun xccov view --report --only-targets /tmp/RepoScout.xcresult
```

Replace `iPhone 17 Pro` with any simulator you actually have installed
(`xcrun simctl list devices available` will tell you), or — if you only want
to check that the project compiles — use
`-destination 'generic/platform=iOS Simulator'` with `xcodebuild build`,
which needs no booted device at all.

You can equally well run either suite from Xcode's Test navigator (`Cmd-U`
runs both by default; select a specific suite to scope it). The configuration
picker in the test plan editor is where you can run just one language.

There is a GitHub Actions workflow at `.github/workflows/ci.yml` that runs the
two suites as separate jobs on a macOS 26 runner. Nothing has ever executed
it — this repository has no remote — but it is the same two commands as above,
committed so the first push to a remote inherits them.

A `.swift-format` at the repository root records the house style (four-space
indentation, 120 columns) for `swift format`, which ships with the toolchain.
It is a reference, not a gate: no build or CI step runs it.

## What to look at

Each of these files or directories is the clearest example of the practice
next to it. If you're skimming rather than reading front to back, this is
the fastest path to the interesting parts.

| Practice | Where |
| --- | --- |
| `LoadState` — a closed enum instead of boolean soup for async state | `testExample/testExample/Support/LoadState.swift` |
| Combine debounce over a keystroke stream | `testExample/testExample/ViewModels/SearchViewModel.swift` |
| Protocol-based dependency injection | `testExample/testExample/Services/GitHubClient.swift`, `testExample/testExample/Support/AppDependencies.swift` |
| SwiftData persistence (model, reads via `@Query`, writes via a store) | `testExample/testExample/Persistence/` |
| Swift Testing (the modern `#expect`/`@Test` unit-test framework) | `testExample/testExampleTests/` |
| BDD-style UI tests (Given/When/Then over XCUITest) | `testExample/testExampleUITests/` |
| Localization (String Catalog, commented keys, plural *substitutions* inside whole-sentence accessibility labels, full German) | `testExample/testExample/Views/Search/RepoRowView.swift`, `testExample/testExample/Localizable.xcstrings` |
| A test plan with two language configurations, and coverage scoped to the app | `testExample/testExample.xctestplan` |
| Accessibility (merged row elements, Dynamic Type via `ViewThatFits`, a VoiceOver-safe ticker) | `testExample/testExample/Views/Search/RepoRowView.swift`, `testExample/testExample/Views/Search/SearchView.swift` |

`ARCHITECTURE.md` walks through how these pieces connect, with a reading
path for whatever your starting point is.

`RepoScout-Guide.pdf`, at the repository root, is a rendered field guide to
this codebase — the same ground as the two documents above, laid out for
reading away from an editor.

## A note on the project name

The Xcode project, its schemes, and its targets are still named
`testExample` — that's deliberate, not an oversight. The project was
scaffolded under that name before RepoScout was designed, and renaming an
Xcode project after the fact touches a lot of fragile, auto-generated
`project.pbxproj` machinery for zero functional benefit. Rather than risk
that churn, the product identity (display name, app icon, and everything a
user or reader actually sees) was layered on as RepoScout while the
underlying project scaffolding kept its original name. `RepoScoutApp.swift`
is the `@main` entry point; `testExample.xcodeproj` is just the file you
double-click to get there. The one place the scaffold name genuinely
mattered — the bundle identifier, which is what a device actually records —
*was* changed: the app ships as `work.timmaher.RepoScout`.

## License

MIT — see [`LICENSE`](LICENSE). Copy anything here into your own project.
