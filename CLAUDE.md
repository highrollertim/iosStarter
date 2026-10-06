# RepoScout (iosStarter)

A small, complete SwiftUI reference app: search GitHub repositories, favorite them,
persist favorites with SwiftData. It exists to be read as much as run. Every file
demonstrates one current Apple-platform practice, and the tests prove the practice
works. `README.md` is the front door, `ARCHITECTURE.md` is the guided tour. Read
the relevant section of `ARCHITECTURE.md` before changing a file it describes.

## Toolchain and language mode

- Xcode 26.2, Swift 6 language mode, approachable concurrency on for all targets.
- Default actor isolation is `MainActor` on the **app target only**. The unit test
  target is not main-actor by default, so suites that touch `SearchViewModel` carry
  an explicit `@MainActor` and a comment saying why. Keep that pattern.
- The Xcode project uses synchronized folder groups. Adding or moving a Swift file
  does not require editing `project.pbxproj`. Do not edit it to add files.

## Layout

```
testExample/testExample/            app target
  RepoScoutApp.swift                 entry point; AppDependencies() is the only composition root
  Models/                            Codable models (Repo, GitHubSearchResponse)
  Services/                          GitHubClient protocol, LiveGitHubClient, MockGitHubClient
  ViewModels/SearchViewModel.swift   the only view model; debounced Combine pipeline
  Persistence/                       SwiftData FavoritesStore and FavoriteRepo
  Support/                           LoadState, Logging, AppDependencies, previews
  Views/                             RootView, Search/, Detail/, Favorites/
  Localizable.xcstrings              every user-facing string, English and German
testExample/testExampleTests/        Swift Testing unit suite (@Suite, @Test, #expect)
testExample/testExampleUITests/      XCTest UI suite; Screens/ are page objects, Support/ has launch helpers
testExample/testExample.xctestplan   runs every suite twice: English and German
.github/workflows/ci.yml             unit tests and advisory swift-format on every PR; full UI suite on main
.github/workflows/pr-review.yml      Claude Code review on every PR via claude-code-action, submitted as a PR review
.github/workflows/pr-ui-tests.yml    Claude picks the UI test classes the diff needs; LaunchTests always runs
```

## Commands

Run test commands from `testExample/`. Lint runs from the repo root.

```bash
# compile only, no simulator needed
xcodebuild build -project testExample.xcodeproj -scheme testExample -destination 'generic/platform=iOS Simulator'

# unit tests (both languages, a couple of minutes)
xcodebuild test -project testExample.xcodeproj -scheme testExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:testExampleTests

# UI tests (both languages, roughly four minutes; the full run is about six)
xcodebuild test -project testExample.xcodeproj -scheme testExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:testExampleUITests

# formatter, advisory, from the repo root
xcrun swift-format lint --recursive testExample
```

Prefer the compile-only command while iterating, the unit suite before opening a PR,
and the UI suite only when a view or a screen object changed.

## Conventions that the reviewer checks

- **State is an enum.** `LoadState` replaces `isLoading` / `results` / `error`
  triples. Do not add parallel booleans that can disagree with it.
- **Seams are protocols.** Network access goes through `GitHubClient`. Tests use
  spies or `MockGitHubClient`; nothing outside `LiveGitHubClient` touches
  `URLSession`.
- **Errors are closed enums** with `LocalizedError` copy in one place.
  `CancellationError` is never folded into a failure case. Callers check
  `Task.isCancelled`, not the error type.
- **Combine stays on main.** `scheduler: DispatchQueue.main` and `on: .main` are
  load-bearing. Sinks that touch view model state are marked `@MainActor`.
- **Dedup on outcome, not input.** No `removeDuplicates()` on a non-deterministic
  operation. Compare trimmed against trimmed.
- **Every user-facing string** is `String(localized:comment:)` with a translator
  comment, and has an entry in `Localizable.xcstrings` for both `en` and `de`.
  The German test configuration is the localization check.
- **Accessibility labels are tested.** Row labels have unit tests in both
  languages. New rows or controls need the same.
- **Tests ship with the change.** Unit tests use Swift Testing. UI tests drive
  screen objects under `Screens/` against the mocked client and stay hermetic.
- **Formatter is a record, not a gate.** Match the surrounding style: four-space
  indentation, 120 columns, doc comments that explain why.

## Working model

1. **Start from an intent brief.** The PR body follows
   `.github/pull_request_template.md`: what, why, acceptance, constraints, risk
   tag. Write it before the first edit. The reviewer reads it first.
2. **Build, then verify.** Run the compile-only command after each change, the
   unit suite before the PR. Read the diff. Ask what would break on a device.
3. **Tag risk honestly.** Routine: an isolated view, model, or test. Elevated:
   `SearchViewModel`, `LiveGitHubClient`, `FavoritesStore`, anything under
   `Support/`. Critical: the paths the hook guards (below).
4. **Run `/review-pr` locally** before opening the PR. CI runs the same skill.
5. **If the harness is wrong, fix the harness.** Skills live in
   `.claude/skills/`, the hook in `.claude/hooks/`. Change them in a PR.

## Critical paths, guarded by a hook

A `PreToolUse` hook in `.claude/settings.json` blocks agent edits to these paths.
They change rarely, by hand, in a PR tagged `risk:critical`:

- `.github/workflows/*` and `.github/scripts/*` (the review publisher and the test-selection decision live there)
- `testExample.xcodeproj/project.pbxproj`
- `testExample/testExample/PrivacyInfo.xcprivacy`
- `testExample/testExample.xctestplan`
- `.claude/settings.json` and `.claude/hooks/*`

Set `HARNESS_ALLOW_CRITICAL=1` in the environment to lift the block for a session
that is deliberately doing critical work.
