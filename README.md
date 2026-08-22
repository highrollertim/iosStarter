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

## Running the tests

RepoScout has two independent test suites: a Swift Testing unit suite that
covers decoding, the search view model's state machine, the live network
client's URL construction, and the SwiftData favorites store; and an
XCTest-based UI suite that drives the real app through its screens against a
mocked network so it stays hermetic and offline.

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

You can equally well run either suite from Xcode's Test navigator (`Cmd-U`
runs both by default; select a specific suite to scope it).

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

`ARCHITECTURE.md` walks through how these pieces connect, with a reading
path for whatever your starting point is.

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
double-click to get there.
