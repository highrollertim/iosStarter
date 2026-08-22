# Architecture

This document is a guided tour of RepoScout, organized around three
different starting points. Pick the one that matches your background and
read that section first; the codebase itself doesn't care which order you
approach it in, but a tour does. All three end up pointing at the same
handful of files, just for different reasons.

## Path 1: New to iOS

The best way into this codebase is to follow a single keystroke from the
user's finger to the screen. Every hop below is one file, and each one only
does the one thing it's named for.

**`RepoScoutApp.swift`** is where the app boots. It's a `WindowGroup`
wrapped around `RootView`, and just above that, one line —
`AppDependencies()` — builds every long-lived object the app needs exactly
once. That single composition root is the only place in the whole app that
decides which concrete network client or database configuration to use;
everything downstream just receives what it's handed.

**The search field.** `SearchView` attaches SwiftUI's `.searchable(text:)`
modifier to a binding on the view model's `searchText` property. There is no
button to press — every character you type writes straight into
`searchText`.

**`SearchViewModel.searchText`.** That property has a `didSet` that forwards
every new value into a Combine `PassthroughSubject`. This is the one place
in the app where typing becomes a *stream* of values rather than a single
event, and it matters: the next step needs to see the whole stream, not just
the latest character, to do its job.

**Combine debounce.** The subject is piped through
`.debounce(for: .milliseconds(300), scheduler: .main)` and then
`.removeDuplicates()`. Debounce means a burst of keystrokes only produces
one downstream event, 300ms after you stop typing; `removeDuplicates`
means retyping the same text twice in a row (e.g. after deleting and
retyping) doesn't fire a second, redundant search. Only after both of those
does the pipeline start an async search task.

**`GitHubClient`.** The search task calls
`client.searchRepositories(matching:)` — a single `async throws` function
declared on a protocol, not a concrete network type. In production that
protocol is satisfied by `LiveGitHubClient`, which builds a URL and awaits
`URLSession.data(from:)`. Neither the view model nor the view ever sees
`URLSession` directly.

**`LoadState`.** While the request is in flight, the view model sets its
`state` property to `.loading`; when the request finishes it becomes either
`.loaded([Repo])` or `.failed(message:)`. `LoadState` is a four-case enum —
`idle`, `loading`, `loaded`, `failed` — that replaces the more common
pattern of separate `isLoading: Bool`, `results: [Repo]`, and `error:
Error?` properties, which together can represent nonsense combinations
(loading *and* showing an old error, for instance) that this enum makes
impossible to construct.

**`SearchView`'s switch.** The view's body is a `switch` over
`viewModel.state` with one branch per case: an empty-state prompt for
`.idle`, a spinner for `.loading`, a list for `.loaded` (or a "no results"
view if the list is empty), and an error view with a retry button for
`.failed`. Because the switch is exhaustive, the compiler itself guarantees
every state the view model can be in has a corresponding screen — there's no
way to add a fifth `LoadState` case later and forget to handle it in the UI.

That's the whole round trip: a keystroke becomes a stream event, the stream
event becomes (after debouncing) an async call behind a protocol, the async
call's outcome becomes an enum value, and the enum value becomes exactly one
screen.

## Path 2: I've written some SwiftUI

If you already know your way around `@State`, `@Observable`, and basic
networking, the interesting part of this codebase isn't any single
technique — it's a handful of decisions about where to spend structure and
where to deliberately not.

**`LoadState` over boolean soup.** Covered above from the beginner's angle;
from an experienced-SwiftUI angle, the thing worth stealing is the
discipline of modeling *mutually exclusive* states as an enum rather than as
independent properties. It's a small change that eliminates a whole category
of "why is `isLoading` true and `results` non-empty at the same time" bugs,
and it composes: `LoadState<Value>` is generic, so the same type could serve
any other screen with an async load in this app.

**A view model only where it earns its keep.** `SearchView` has a view
model (`SearchViewModel`) because it has real asynchronous orchestration to
own: a Combine pipeline, task cancellation, a live "updated N seconds ago"
timer. `RepoDetailView` and `FavoritesView` have none. Detail's only state
is "is this repo currently favorited," which comes for free and live from a
SwiftData `@Query` filtered to that repo's id; the only action is a
one-line call into `FavoritesStore`. Giving either of those screens a view
model would be pure ceremony — a class whose only job is to forward a
`@Query` result and a function call. The rule this codebase follows: reach
for a view model when there's a state machine or async pipeline to own, not
by default for every screen.

**DTO vs. domain model.** `GitHubSearchResponse.swift` defines `RepoDTO`,
a `Decodable` type whose shape and `CodingKeys` mirror GitHub's JSON exactly
(`full_name`, `stargazers_count`, and so on). `Repo.swift` defines a
separate, plain `Repo` struct that the rest of the app actually works with,
and a single `Repo.init(dto:)` is the only place the two shapes meet. When
GitHub changes its API — a renamed field, a new nested object — only the DTO
and that one initializer need to move; `SearchViewModel`, the views, and the
persistence layer never see a `RepoDTO`. `FavoriteRepo`, the SwiftData
model, is a *third*, separate shape for the same reason: its schema evolves
on a different clock (local migrations) than either the API or the domain
model.

**Constructor injection from a composition root.** Nothing in this codebase
reaches for a singleton or a service locator. `AppDependencies` is
constructed once, in `RepoScoutApp`, and it decides — based on
`ProcessInfo.processInfo.arguments`, checked once, at launch — whether
`SearchViewModel` gets a `LiveGitHubClient` or a `MockGitHubClient`, and
whether the SwiftData `ModelContainer` is on-disk or in-memory. That
decision then flows down through plain initializer parameters:
`SearchViewModel(client:)`, `FavoritesStore(context:)`. UI tests flip
launch arguments to get deterministic, offline doubles; nothing in the view
or view-model layer has to know that's happening.

**`@Query` for reads, a store for writes.** `FavoritesView` and
`RepoDetailView` both read favorites straight off SwiftData with `@Query` —
which gives live, animated updates for free whenever a favorite is added or
removed anywhere in the app, with zero manual wiring. But neither view calls
`context.insert` or `context.delete` directly. All writes go through
`FavoritesStore`, a small struct wrapping `ModelContext`, so that the rules
that matter — toggling favorites without creating duplicates, when a save
actually happens — live in one place that's unit-tested directly
(`FavoritesStoreTests.swift`) instead of being duplicated or drifting across
every view that happens to mutate favorites.

## Path 3: I shipped ObjC/UIKit, then went into management

If your mental model is still UIKit and Core Data, here's a rough
translation table. None of these are exact 1:1 replacements — some of the
old concepts split into two new ones, and one (Combine) mostly *disappears*
— but each row should give you a foothold.

| UIKit/ObjC-era concept | RepoScout equivalent |
| --- | --- |
| View controller | A SwiftUI `View` struct, plus — only when there's real state or async work to own — an `@Observable` view model. `SearchView` + `SearchViewModel` is the "yes" case; `RepoDetailView` and `FavoritesView`, with no view model at all, are the "no" case. |
| Delegate / KVO for state changes | `@Observable` (from the `Observation` module) plus SwiftUI automatically tracking whichever properties a view's `body` actually reads. No delegate protocol to declare, no manual `willChangeValue`/`didChangeValue` bookkeeping. |
| `NSFetchedResultsController` | `@Query` in SwiftData views (`FavoritesView`, `RepoDetailView`). Same job — a live, observed result set backed by the persistence layer — with far less ceremony: no delegate, no diffing callback, just a property. |
| Core Data stack (`NSPersistentContainer` setup) | `ModelContainer`, built once in `AppDependencies.init` and handed to the view hierarchy via `.modelContainer(_:)`. |
| `NotificationCenter` / manually managed `Timer` | Combine publishers. `SearchViewModel` uses `Timer.publish(every:on:in:).autoconnect()` for its "updated N seconds ago" ticker — a stream you subscribe to and let `AnyCancellable` tear down, instead of a timer you must remember to invalidate. |
| GCD (`DispatchQueue.async`, semaphores, completion handlers) | `async`/`await`, plus actors for shared mutable state. `LiveGitHubClient.searchRepositories(matching:)` is a single `async throws` function with no completion handler; the test doubles in `TestSupport.swift` (`SpyGitHubClient`, `GatedGitHubClient`) are actors specifically to show that actors, not manual locks, are the default answer for state a test needs to touch from multiple tasks safely. |
| XCTest + OCMock (or hand-rolled protocol mocks) | Swift Testing (`@Test`, `#expect`, `@Suite`) for the unit suite, with protocol conformances as test doubles — no mocking framework, no runtime method swizzling. `MockGitHubClient` (a real, if fixture-backed, `GitHubClient` conformance) plays the same role for UI tests and Xcode previews. |

### The honest Combine section

Combine appears in exactly two places in this codebase, and it's
conspicuously absent everywhere else — that split is deliberate, not an
oversight, and it's worth being explicit about where the line falls.

Combine still earns its place where the underlying thing genuinely *is* a
stream of values arriving over time, and where the interesting behavior is
about how those values relate to each other temporally. `SearchViewModel`'s
`querySubject` is the clear case: keystrokes are a stream, and the app
needs to reason about that stream as a whole — collapse a burst into one
event (`debounce`), ignore a repeat (`removeDuplicates`). Hand-rolling that
with `Task.sleep` and manual cancellation flags is exactly the kind of
fiddly, error-prone bookkeeping that stream operators exist to make
declarative and correct by construction. The same view model's
"updated N seconds ago" ticker (`Timer.publish(every: 1, on: .main, in:
.common).autoconnect()`) is the smaller, second example: a timer is also a
stream, and Combine's ownership model (a sink lives in a `Set<AnyCancellable>`
that tears down automatically) is a clean fit for something that needs to
keep firing for the life of the view model and then just stop.

Combine does *not* appear in `LiveGitHubClient`, and that's the more
important half of the story. A single network request — send once, get one
response or one error back — is not a stream; it's one value, produced
once, and `async`/`await` says exactly that with no extra machinery: no
`AnyPublisher` return type to erase, no `.sink` with a completion case to
handle, no cancellable to store and forget. Wrapping a one-shot request in
Combine (a `Future`, a single-element publisher) was a common pattern when
Combine was the only structured-concurrency-shaped tool available; in 2026,
with `async`/`await` built into the language and standard library, it's
needless indirection over what a plain `async throws` function already
expresses. The line this app draws — Combine for streams of values over
time, `async`/`await` for one-shot asynchronous work — isn't a stylistic
preference so much as a direct reading of what each tool was actually
designed to model. `LiveGitHubClient`'s doc comment makes this explicit
in-place: "Note what is *not* here: no Combine."
