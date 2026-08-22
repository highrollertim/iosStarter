# RepoScout — SwiftUI Reference App Design

**Date:** 2026-08-22
**Status:** Approved

## Purpose

Transform the empty `testExample` Xcode template into **RepoScout**, a small but
production-grade SwiftUI app that serves as a reference for iOS best practices in
2026. The app itself (a GitHub repository search/favorites browser) is a vehicle;
the deliverable is exemplary code.

**Audience:** developers new to iOS/Swift, mid-level developers with some SwiftUI
experience, and experienced pre-SwiftUI iOS developers returning from management
roles. Teaching happens through rich `///` doc comments explaining the *why* of
each pattern, plus a README and ARCHITECTURE.md — the code reads like a great
real codebase, which is itself the lesson.

**Naming:** the Xcode project, targets, and bundle IDs stay `testExample`
(renaming a pbxproj is churn with no teaching value). The app is branded
RepoScout via display name and in-code naming.

## What the app does

Search GitHub's public repository search API (no API key), browse results, view
repo details, and save favorites locally. Structure:

- **TabView** with two tabs: Search and Favorites.
- **Search tab** — text field with live debounced search; results in a `List`;
  explicit loading / empty / error / loaded states.
- **Detail screen** — pushed via `NavigationStack` with type-safe (`Hashable`
  route values) navigation; shows stars, forks, language, description; favorite
  toggle; link out to the repo page.
- **Favorites tab** — SwiftData-backed list, swipe-to-delete, empty state,
  navigates to the same detail screen.

## Architecture

**Pattern: `@Observable` MVVM with protocol-based dependency injection.**

- An `@Observable` view model only where there is real logic: `SearchViewModel`
  owns the search pipeline. The detail and favorites screens deliberately have
  **no view model** — detail reads its `Repo` value and talks to the favorites
  repository directly; favorites reads live data via `@Query` and mutates via
  the repository. This contrast (view model only when it earns its keep) is
  called out in comments. View models run on the main actor (the project uses
  Xcode 26's default-`MainActor` isolation).
- **UI state modeled as an enum** — `LoadState` with `idle`, `loading`,
  `loaded([Repo])`, `failed(message)` cases so impossible states are
  unrepresentable. This is a headline lesson of the codebase.
- **Services behind protocols:** `GitHubClient` protocol with:
  - `LiveGitHubClient` — `URLSession` + `async/await`, typed errors, decodes
    GitHub's search JSON via `Codable` with `CodingKeys`.
  - `MockGitHubClient` — returns fixture data (or errors on demand). Used by
    unit tests, `#Preview`s, and UI tests.
- **Composition root** (`AppDependencies`, owned by the `App` type): selects
  live vs mock client based on a launch argument (`-UITestMockNetwork`) and
  constructor-injects it into view models. SwiftData flows through the SwiftUI
  environment via `.modelContainer`.
- **Persistence:** SwiftData. `FavoriteRepo` is an `@Model`; favorites tab uses
  `@Query`. A thin repository type wraps writes so logic is unit-testable with
  an in-memory `ModelContainer`. UI tests use an in-memory container via launch
  argument so runs are hermetic.
- **Concurrency:** Swift 6 strict concurrency. `Sendable` value-type domain
  models (`Repo`), `async/await` for all one-shot async work.

## Combine's role (honest mix)

Baseline architecture is `@Observable` + `async/await` — Combine appears where
it genuinely wins, with doc comments explaining the boundary:

1. **Debounced search pipeline** — search text flows through a
   `PassthroughSubject` → `debounce` → `removeDuplicates` pipeline that
   triggers the async fetch (cancelling any in-flight `Task`). Comments explain
   why an event-stream operator chain beats hand-rolled `Task.sleep` debouncing.
2. **Periodic ticker** — a `Timer.publish` pipeline drives a lightweight
   recurring UI update (e.g., "last updated n seconds ago" on search results),
   showing publisher lifecycle management (`store(in:)`, cancellation).

Comments state plainly: for one-shot async work, prefer `async/await`; reach
for Combine when modeling *streams of events over time*.

## Testing

### Unit tests — Swift Testing (`import Testing`)

- `@Suite`-organized, `@Test`-annotated, `#expect`/`#require` assertions,
  parameterized tests (e.g., multiple JSON decoding fixtures / error cases).
- Coverage targets:
  - `SearchViewModel` state transitions: idle → loading → loaded/failed,
    driven by `MockGitHubClient`.
  - Debounce behavior: rapid successive inputs produce one fetch.
  - JSON decoding from bundled fixture files (happy path + malformed).
  - Favorites repository: add/remove/duplicate handling against an in-memory
    `ModelContainer`.

### UI tests — XCUITest with BDD activities

- `Given/When/Then` helper functions wrapping `XCTContext.runActivity` so test
  reports read as scenarios.
- **Screen-object pattern:** `SearchScreen`, `DetailScreen`, `FavoritesScreen`
  encapsulate queries and actions behind intention-revealing methods.
- Accessibility identifiers on all interactive elements (doubles as an
  accessibility lesson).
- App launched with `-UITestMockNetwork` + in-memory SwiftData so tests are
  deterministic and offline.
- Scenarios:
  1. Search happy path — type query, see results.
  2. Search failure — mock returns error, error state + retry visible.
  3. Favorite flow — favorite a repo from detail, verify it appears in
     Favorites tab; unfavorite, verify removal.
  4. Launch test (template's `testExampleUITestsLaunchTests` retained,
     cleaned up).

## Professional polish

- Accessibility labels/values/identifiers; Dynamic Type-friendly layouts.
- Semantic colors (dark-mode safe), SF Symbols.
- `#Preview` on every view, backed by mock data.
- Localized strings via String Catalog.
- `.gitignore` (Xcode-appropriate), README.md (what/why/how to run tests),
  ARCHITECTURE.md (layer-by-layer tour addressed to the three audience tiers).
- Repo becomes a git repository with sensible commit history.

## Error handling

- Typed `GitHubClientError` (network, decoding, rate-limited, server) with
  user-facing `LocalizedError` messages.
- Errors surface in UI as a friendly error state with retry — never silent
  failures, never raw error dumps.

## Out of scope (YAGNI)

Authentication, pagination, image loading/caching layers, widgets,
iPad-specific layout, CI configuration, third-party dependencies (zero SPM
packages by design).
