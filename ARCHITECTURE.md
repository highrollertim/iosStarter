# Architecture

This document is a guided tour of RepoScout, organized around three
different starting points. Pick the one that matches your background and
read that section first; the codebase itself doesn't care which order you
approach it in, but a tour does. All three end up pointing at the same
handful of files, just for different reasons.

Two sections at the end — **Accessibility and localization** and **Shipping
hygiene** — belong to no particular path. Read them whichever way you came
in; they cover the parts of an app that are invisible until they're wrong.

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
`.debounce(for: debounceInterval, scheduler: DispatchQueue.main)` and then a
`.filter`:

```swift
querySubject
    .debounce(for: debounceInterval, scheduler: DispatchQueue.main)
    .filter { @MainActor [weak self] query in
        query.trimmingCharacters(in: .whitespacesAndNewlines) != self?.lastDispatchedQuery
    }
    .sink { @MainActor [weak self] query in self?.dispatch(query) }
```

Debounce means a burst of keystrokes only produces one downstream event,
300ms after you stop typing.

The `filter` is where the more interesting lesson is, because the obvious
operator here is `removeDuplicates()` — and this codebase used it, and it was
a bug. `removeDuplicates()` dedups on the **input**: it drops any value equal
to the previous one, regardless of what happened to the work that value
triggered. That is only sound when the operation is *deterministic*, and a
network search is emphatically not — the same text can fail once and succeed
the next time. So a search that failed became literally unrepeatable by
typing: you had to change the text and change it back to get another attempt.

Deduping against `lastDispatchedQuery` instead moves the decision from the
input to the **outcome**. The property is set whenever a query is dispatched
by any route, and cleared whenever a search fails — so re-submitting the same
text after a failure re-fires, while re-submitting it after a success still
doesn't. It also closes the other half of the bug: `retry()` and
`submitImmediately()` set `lastDispatchedQuery` too, so a debounce emission
still in flight when the user taps Retry is filtered here rather than racing
a second identical request onto the wire.

Note that the key and the candidate are **both trimmed**. Storing the trimmed
query alone is not enough: the filter would still compare the raw emission
against it, so typing a trailing space after "swift" reads as a different
query and fires a second identical request. Both sides of a comparison have
to be normalized the same way, or normalizing one side is decoration.

"By any route" is a claim the code makes true rather than hopes for.
`dispatch(_:)` is the single entry point — the debounce sink,
`submitImmediately()`, `retry()` and pull-to-refresh all call it, and
`search(matching:)` is `private` — so two invariants hold by construction:
every in-flight search *is* `searchTask` (a caller with its own `Task` would
be invisible to the cancellation on the next line), and the dedup key always
describes the search that is actually running.

The general form: an input-level dedup is a statement that the operation is a
pure function of its input. If it isn't, dedup on what came back instead.

**`GitHubClient`.** The search task calls
`client.searchRepositories(matching:)` — a single `async throws` function
declared on a protocol, not a concrete network type. In production that
protocol is satisfied by `LiveGitHubClient`, which builds a `URLRequest` with
GitHub's required headers and a 15-second timeout, awaits
`session.data(for:)`, maps the HTTP status onto a small closed error enum,
and decodes. Neither the view model nor the view ever sees `URLSession`
directly.

One trap in that URL building is worth the detour, because it is invisible
until someone searches for the wrong thing. `URLComponents.queryItems`
percent-encodes correctly *for a URL* — and `+` is a legal character in a
query, so it is left alone. GitHub's endpoint then form-decodes the query,
where `+` means a space: searching for "c++" asks GitHub for "c  ". The client
rewrites `percentEncodedQuery` after setting `queryItems`, escaping `+` as
`%2B`, and `LiveGitHubClientTests` pins both halves — that `q=c%2B%2B`, and
that nothing else in the query was disturbed. Encoding is never correct in the
abstract; it is correct with respect to whoever decodes it.

**`LoadState`.** While a *first* request is in flight, the view model sets its
`state` property to `.loading`; when the request finishes it becomes either
`.loaded(repos, isRefreshing: false)` or `.failed(message:stale:)`. `LoadState`
is a four-case enum — `idle`, `loading`, `loaded`, `failed` — that replaces the
more common pattern of separate `isLoading: Bool`, `results: [Repo]`, and
`error: Error?` properties, which together can represent nonsense combinations
(loading *and* showing an old error, for instance) that this enum makes
impossible to construct.

```swift
nonisolated enum LoadState<Value: Sendable & Equatable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value, isRefreshing: Bool)
    case failed(message: String, stale: Value?)
}
```

The two payloads that aren't in the textbook version are worth dwelling on,
because they are the same lesson twice.

`isRefreshing` inside `loaded` exists because the four-case enum cannot
express the fifth state a real search screen has: *results already on screen
while a refinement is in flight*. Without it, refining a search has two bad
options — blank the list back to a spinner (the user loses their place and the
screen flickers on every keystroke) or lie about the request being finished.
The flag lives *inside* `loaded` rather than as a sibling `isLoading` property
precisely so it is impossible to be "refreshing" with nothing to refresh.

`stale` inside `failed` is the same state one step later: the refinement that
was in flight came back as an error, and the results it was refining are still
the best thing anyone has. Blanking them punishes the user for a failure by
throwing away the last thing that worked. A first-load failure has nothing to
keep and carries `nil`, which is what selects the full-screen presentation. An
`Optional` payload rather than a fifth case, so the view's `switch` still has
one failure branch to reason about.

Carrying rows *forward* out of a failure is the part that needs a rule, and
the rule is the interesting bit. When a search starts from a `.failed` state
that kept rows, the view model promotes those rows back onto the screen —
`.loaded(stale, isRefreshing: true)` — only if the incoming query is one of
two things: the query those rows answer (`lastCompletedQuery`, which is what
pull-to-refresh re-runs and what re-submitting the same text produces), or the
query whose failure put the banner there (`lastFailedQuery`, which is what the
banner's own Retry re-runs). Anything else starts blank.

Both halves were bugs at different times. Ungated, a brand-new query typed
from a failure screen resurrected the previous search's rows and displayed
them as its own, with a spinner claiming they were being refreshed — one
query's results labelled as another's. Gated on `lastCompletedQuery` alone, a
failed *refinement* blanked its rows the moment the user tapped the Retry the
banner was offering, which is the one interaction the whole feature exists
for. What the pair concedes is small and deliberate: after a failed
refinement, Retry does redisplay the previous query's rows under the
refinement's banner — but that is the screen the user is already looking at,
and Retry asks to repeat what just happened rather than to ask something
new.

Illegal states stay unrepresentable; the enum just has to be honest about
which states are actually legal.

**`SearchView`'s shape.** Not one branch per case, and the difference is
load-bearing. The view first asks `displayedRows` whether there are rows worth
reading — a non-empty `.loaded`, or a `.failed` that kept non-empty stale
results. If there are, the screen is **one** `List`, and `.loaded` and
`.failed(_, stale:)` are the *same* view identity: crossing between them
updates a list rather than destroying one and building another. That is what
keeps the scroll position, lets rows animate, keeps pull-to-refresh reachable
while the banner is up, and gives the "updated N seconds ago" ticker a
lifetime that spans the failure instead of restarting on it. The bar under
that list carries the error banner (when there is one) above the timestamp:
how old the rows are matters most exactly when they are stale. The same
identity argument, in the other direction, is why `FavoritesView` keeps one
`List` and puts its empty state in an `.overlay`.

Only when there are no rows does a `switch` decide the screen: the idle
prompt; the spinner, because only a load with nothing to keep blanks the
screen; the "no results" view for an empty `.loaded`; and the full-screen
error with a retry button for a `.failed` with nothing to keep.
(The *model* says only "these are the results that were on screen"; the "is
that worth showing" judgement lives in the view, which treats an empty stale
array as nothing to keep — a zero-row list under an error bar is worse than
the full-screen error.)

Be precise about what the compiler checks here. That inner `switch` is
exhaustive over `LoadState`, so a fifth case could not be added without the UI
noticing. But the two arms of `displayedRows` are `where`-guarded, and a
`switch` whose arms are all guarded is not exhaustive — it compiles because of
an unguarded `default`. Nothing in the type system verifies that those guards
describe the states they claim to; the tests do.

Two details come from state living *outside* the enum, which is a judgement
call worth naming. The empty-results branch titles itself with
`viewModel.lastCompletedQuery`, not `searchText`: the live field is still
ahead of the debounce and may already hold the next query, so titling with it
announces "No Results for …" about a search nobody ran. And the list carries
`.refreshable`, which is only safe to expose *because* of the `dispatch(_:)`
funnel — the pull cancels whatever is in flight and becomes the search that
owns the screen — and which re-runs `lastCompletedQuery` rather than the live
field, so a pull mid-debounce cannot search half-typed text.
`lastCompletedQuery` is a property beside `state` rather than a payload inside
it because `LoadState` is a generic lifecycle enum that knows nothing about
searching.

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

**Where the code actually runs (SE-0461, and why `@concurrent` is
load-bearing).** This is the part of the codebase most likely to be
misremembered, so it is worth stating precisely.

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
`SWIFT_APPROACHABLE_CONCURRENCY = YES`. The second of those turns on
`NonisolatedNonsendingByDefault` (SE-0461), and the rule it establishes is
the one to internalize:

> A `nonisolated async` function runs on its **caller's** executor.

Not on a background thread. Not "somewhere else". On whoever called it. The
`async` keyword has never by itself moved work off the main thread; before
SE-0461 that was folklore that happened to be true often enough to survive,
and now it is explicit.

`GitHubClient` declares `func searchRepositories(matching:) async throws`
with no isolation. Its only caller is `SearchViewModel`, which is `@MainActor`
by the project's default isolation. So under SE-0461, a plain conformance
would run the request *and*, far more expensively, the `JSONDecoder().decode`
of a ~100KB search payload **on the main actor**. It would compile without a
diagnostic, pass every test in this repo, and drop frames on a real device
with a slow connection.

`LiveGitHubClient.searchRepositories(matching:)` is therefore marked
`@concurrent`, which opts it back out onto the global concurrent executor.
That one attribute is the reason the decode genuinely leaves the caller, and
it is the reason `Repo` needs to be `Sendable` non-vacuously — there is a
real executor crossing for it to cross.

The mirror image of this is the Combine pipeline, where the isolation
annotations are *not* what makes the code safe. `SearchViewModel` is
`@MainActor`, which is why the `sink` closures type-check when they assign to
`state`. But Combine's `sink` takes an ordinary synchronous closure and
invokes it on whatever thread the upstream publisher delivers on, and the
compiler cannot see that thread. What makes those sinks correct is
`scheduler: DispatchQueue.main` on the debounce and `on: .main` on the timer.
Those arguments are load-bearing: change either to a background queue or
runloop and the code still compiles perfectly cleanly, then traps at runtime
on the main-actor precondition. Both are marked `// load-bearing:` in the
source, and each closure is spelled `{ @MainActor [weak self] ... }` so the
compiler checks the assumption rather than the code merely inheriting it.

The summary worth carrying away: default isolation decides what
*type-checks*; the scheduler arguments and `@concurrent` decide what actually
*runs where*. They are different questions, and conflating them is how a
codebase ends up with a main-thread JSON decoder it believes is on a
background queue.

A small corollary of the same default: `Support/Logging.swift` declares its
two `Logger`s `nonisolated static let`. Under default-`MainActor` isolation
they would otherwise be main-actor-isolated and therefore unreachable from
exactly the code that most needs them — the `nonisolated`/`@concurrent`
network paths where failures happen. `Logger` is `Sendable`, so the keyword
costs nothing and buys reachability.

**Cancellation is a flag, not an error type.** `SearchViewModel` has one
`catch`, and it asks `Task.isCancelled` — never whether the error *is* a
`CancellationError`. The distinction sounds pedantic and is not: this app's
own `LiveGitHubClient` maps any `URLError(.cancelled)` to `CancellationError`,
and `URLSession` raises that code for session invalidation and other teardown
that has nothing to do with `Task` cancellation. An earlier version had a
`catch is CancellationError { return }` clause, and the consequence was a
screen stuck on `.loading` forever: no `.failed` state, so no Retry button
(it lives on `.failed`), and the query still recorded as dispatched, so
retyping it was filtered out too. Asking the flag covers both cases — a
genuinely superseded search returns silently, its successor owning the screen;
anything else becomes a failure the user can act on. The general form: an
error's *type* is a claim its producer made, while `Task.isCancelled` is the
runtime's own answer to the question you are actually asking.

**Roles declare; behaviours are opt-ins.** `RootView`'s search tab is
`Tab(..., role: .search)`, which states what the tab *is* — the system pins it
to the trailing edge and gives it the search presentation for the platform.
It is easy to assume the iOS 26 chrome that usually accompanies it comes along
for free. It doesn't: both behaviours are separate modifiers, applied
explicitly, and they do not even live in the same file.
`.tabBarMinimizeBehavior(.onScrollDown)` (the tab bar getting out of the way)
is on the `TabView` in `RootView`; `.searchToolbarBehavior(.minimize)` (the
search field collapsing toward the tab bar as you scroll into results) is in
`SearchView`, on the same view as the `.searchable` field it governs — which
is the only place it could be, since it configures that field's presentation.
Reading a role as a bundle of appearance is how a codebase acquires behaviour
nobody can point at.

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
| `NotificationCenter` / manually managed `Timer` | Combine publishers. `SearchViewModel` uses `Timer.publish(every:on:in:).autoconnect()` for its "updated N seconds ago" ticker. Note the honest version of this row: `AnyCancellable` changes *how* you invalidate, not *whether* you have to think about it. This ticker's subscription is held in a dedicated `tickerCancellable` that `startTicker()`/`stopTicker()` manage explicitly, because scoping its lifetime to the visible results list is the whole point — see the Combine section below. |
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
event (`debounce`), then decide whether the survivor is worth dispatching
(`filter`). Hand-rolling that with `Task.sleep` and manual cancellation flags
is exactly the kind of fiddly, error-prone bookkeeping that stream operators
exist to make declarative and correct by construction.

The same view model's "updated N seconds ago" ticker
(`Timer.publish(every: 1, on: .main, in: .common).autoconnect()`) is the
smaller, second example — but note it does *not* start in `init`. Earlier
drafts of this codebase did exactly that, and it was a bug: `SearchViewModel`
is built once by the composition root and lives for as long as the app does,
not just while the Search tab is visible, so a timer started in `init` fires
once a second forever — on the Favorites tab, in the background, anywhere —
invalidating this `@Observable` object's state (and re-rendering any view
that reads it) every second for no reason. The fix keeps the Combine lesson
but scopes the publisher's lifetime to the UI that actually needs it:
`startTicker()` builds the `Timer.publish` → `.autoconnect()` → `.sink`
pipeline into its own `tickerCancellable`, and `stopTicker()` cancels and
releases it. `SearchView` calls `startTicker()` from `.onAppear` and
`stopTicker()` from `.onDisappear` on the results list, so the ticker runs
exactly while the "updated N seconds ago" text is on screen. This is the
more general lesson: a `Set<AnyCancellable>` in `cancellables` that the
`deinit` tears down automatically is the right tool for subscriptions that
should live as long as the object — but not every subscription should; some
need a narrower, explicitly managed lifetime, which is what a dedicated
`AnyCancellable` property plus start/stop methods gives you.

Two details of that ticker are worth calling out, because each fixes a bug
that survived the first draft.

`startTicker()` **seeds `now = .now` before subscribing.**
`Timer.publish(every: 1, ...)` does not emit immediately — the first tick is
a whole second away — and `now` has been frozen since the last
`stopTicker()`. Without the seed, leaving the Search tab for a minute and
coming back displayed a stale "Updated 0 seconds ago" for one full second
before the first tick corrected it. A publisher's first value is not
automatically its *current* value, and any UI that shows elapsed time has to
supply the initial state itself.

The footer is **its own `View` struct** (`LastRefreshedFooter`), and that is
not cosmetic factoring. `@Observable` tracks reads *per `body` evaluation*:
every observable property read while a `body` runs becomes a dependency of
that `body`. `lastRefreshedDescription` reads `viewModel.now`, which the
ticker rewrites once a second. Inline that text back into `SearchView` — even
inside the `safeAreaBar` builder — and the read is attributed to
`SearchView.body`, so the entire screen (the `NavigationStack`, the
`searchable` field, the whole `List`) is re-evaluated every second, forever.
Re-evaluated, not re-rendered: SwiftUI's structural diffing elides the rows
that did not change, so the cost is the evaluation rather than a full redraw —
which is still a cost worth not paying once a second. Pulled out into a leaf,
the once-a-second dependency belongs to a view whose body is a spinner and a
`Text`. The rule: **confine time-driven invalidation to the smallest view
that actually displays the time.** This is the single most common way a well-behaved
`@Observable` app quietly starts re-rendering everything.

The insulation is one-directional, which is the part that is easy to
overstate: it keeps the ticker's invalidation inside the leaf, but it does not
exempt the leaf from the parent's. Anything that re-evaluates `SearchView.body`
re-evaluates this too. That direction is harmless; the once-a-second one
compounds.

(The bar itself is `.safeAreaBar(edge: .bottom)`, not `.safeAreaInset`. The
bar variant supplies the system bar background and scroll-edge treatment, so
the leaf carries no `.background(.bar)` and no width-stretching frame of its
own — the container's job stays in the container.)

In 2026, the other credible option for both of these is `AsyncSequence` /
`AsyncStream` — `NotificationCenter.notifications(named:)`-style async
sequences plus `swift-async-algorithms` for `debounce` and friends. This app
sticks with Combine anyway, for reasons specific to *this* codebase rather
than a blanket "Combine is better": it's ubiquitous in existing iOS
codebases a reader of this app will encounter in the wild, it adds zero
third-party dependencies (the `debounce` and `Timer.publish` this app needs
ship in the Combine framework itself, where the async-algorithms equivalents
live in a separate package), and the two use sites here are
exactly the shape Combine was designed for. A team standardizing on
`AsyncStream` throughout would have a reasonable case too — this is a choice
about which ubiquitous tool to teach, not a claim that Combine is
categorically the right answer.

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

## Accessibility and localization

These two are one topic in practice, because the app's best accessibility
lesson is a localization decision.

**Whole sentences, not joined fragments.** `RepoRowView` replaces its four
labels with a single accessibility element
(`.accessibilityElement(children: .ignore)`) so VoiceOver users hear one
result rather than stepping through four fragments. `.ignore` rather than
`.combine`, because the label below replaces the children's text completely:
merging their labels in only to overwrite them is wasted work, and `.combine`
merges more than text — it absorbs the children's traits and actions too,
which is a wider blast radius than this view needs. The interesting part is
how the label is *built*. The obvious implementation collects
fragments and joins them — `[name, "\(stars) stars", "written in \(language)"]
.joined(separator: ", ")` — and that bakes English into the app in a way no
translator can undo: it fixes word order and punctuation in code, and it
hands the translator isolated scraps like "written in Swift" with no sentence
around them. `RepoRowView` instead has four `String(localized:)` calls, one
per combination of optional language and optional summary, each a complete
sentence. A German translator gets "%1$@, %#@starCount@, in %3$@ geschrieben."
and can put the verb where German puts verbs. Four near-duplicate strings
looks like the worse code and is the better product.

**Numbers: formatted where they stand alone, raw where a noun has to agree
with them.** The *visible* star count goes through `.formatted()`.
Interpolating an `Int` directly into a `LocalizedStringKey` produces the
literal catalog key `%lld` and renders "67000" ungrouped in every locale;
`.formatted()` gives "67,000" / "67 000" / "६७,०००" as appropriate. Nothing
lands in the string catalog at all, because `Label` receives a plain `String`.

The accessibility sentences do the opposite, and the reason is the useful
lesson. They used to interpolate the same pre-formatted count, so the catalog
saw a `%@` — a string that happens to contain digits — and every locale read
"1 stars". An earlier draft of this document called that an unavoidable trade:
you could have locale-correct number formatting *or* plural agreement, not
both. **That was wrong**, and the technique that disproves it is worth
knowing: the sentences now interpolate the raw `Int`, so the key carries a
`%lld`, and the catalog attaches a **substitution** to that argument —

```json
"stringUnit": { "value": "%1$@, %#@starCount@, written in %3$@." },
"substitutions": {
  "starCount": {
    "argNum": 2, "formatSpecifier": "lld",
    "variations": { "plural": {
      "one":   { "stringUnit": { "value": "%arg star"  } },
      "other": { "stringUnit": { "value": "%arg stars" } }
    } }
  }
}
```

— so the sentence stays **one key** for the translator while the noun beside
the number inflects inside it: "1 star"/"5 stars", "1 Stern"/"5 Sterne". This
is what a String Catalog substitution is *for*, and it is the thing to reach
for whenever a count sits inside a larger sentence. `RepoRowLabelTests` pins
all four shapes in both languages, because a malformed substitution fails
silently — the sentence just comes back saying "1 stars", or with a literal
`%#@starCount@` in it.

What is genuinely given up is digit grouping in the spoken label: `%lld`
renders "67000" rather than "67,000". For a count VoiceOver reads aloud once,
agreement is worth more than a thousands separator — but it is a trade, not a
free lunch, and the visible label (which has no noun to agree with) still gets
the grouping. The "Updated %lld seconds ago" footer needs no substitution at
all: its number is the whole string's only argument, so plain `one`/`other`
variations on the key suffice.

**Dynamic Type is a layout problem, not a font-size problem.**
`RepoRowView` drops its `lineLimit` entirely at accessibility sizes (two lines
might hold four words at AX5) and wraps its stats row in
`ViewThatFits(in: .horizontal)`, which tries the horizontal arrangement and
falls back to a stacked one when it doesn't fit. The failure it prevents is
worth stating: at AX5, "67,000" and "C++" side by side overflow and truncate
to "67,0…" — and a truncated number doesn't read as an unclear number, it
reads as a *different* number.

**Contrast is an asset, not an opacity.** The row's de-emphasized text used to
be `Color.primary.opacity(0.65)`, which the accessibility audit accepted and a
user with Increase Contrast switched on did not: a fixed alpha is a claim
about the background it will be composited over, and it opts the text out of
the system's contrast substitution entirely, because there is nothing left for
the system to substitute. `Color(.deemphasized)` names four measured values
instead — light, dark, and a high-contrast variant of each — so asking for
more contrast actually produces more contrast. (That spelling matters too: it
is the asset catalog's generated symbol, so the name is checked by the
compiler, where the older `Color("Deemphasized")` resolved at runtime and
rendered a silent black if the asset were ever renamed.) (The reason it is not
`.foregroundStyle(.secondary)` at all is the audit's original finding: the
system `secondaryLabel` renders around 3.9:1 against the default background,
under AA's 4.5:1 for text below 18pt, which is every line in this row. A
semantic colour name is not a guarantee.)

**A toggle's label does not change; its trait does.** The favorite button on
the detail screen is always labelled "Favorite" and carries
`.accessibilityAddTraits(.isSelected)` when the repository is favorited, so
VoiceOver reads "Favorite, selected". The tempting alternative — flipping the
label to "Remove from Favorites" once it is favorited — produces "Remove from
Favorites, selected": a name describing the *action* next to a state
describing the *result*. Say a control's name in its label and its state in
its traits, never both in the label. It also halves the strings a translator
has to keep in sync.

**The ticker is hidden from VoiceOver**, via `.accessibilityHidden(true)` on
the footer. This is not laziness. A VoiceOver element whose label changes once
a second interrupts the user mid-sentence and makes the results list genuinely
hard to escape. "Updated 4 seconds ago" is ambient status for a sighted user
glancing at the screen; it is not content, and the list below it is.

**The catalog carries comments.** Every key in `Localizable.xcstrings` has a
`comment` describing where it appears and what its placeholders hold — added
at the call site via `String(localized:comment:)` where there is one, and
directly in the catalog for SwiftUI literals like `Text("Stars")`. Without
that, a translator seeing "Stars" alone cannot tell a noun from a verb from a
button title, and the four VoiceOver sentences are unreadable.

**German is not a smoke test you remember to run; it is a test plan
configuration.** `testExample.xctestplan` declares two configurations,
English (`language: en`, `region: US`) and German (`language: de`,
`region: DE`), so *every* test invocation — `xcodebuild test`, `Cmd-U`,
either `-only-testing:` suite — runs the whole thing twice. The unit suite's
German pass is what proves the catalog's plural rules; the UI suite's is what
proves the screens still work when every string gets longer.

Almost all of the UI suite survives that, because it queries by accessibility
identifier: screens, rows, the error text, and — since `Tab` carries an
`.accessibilityIdentifier` onto the tab-bar button it produces — the tabs.
Five test cases cannot, because they match strings **Apple** owns and
translates: `ContentUnavailableView.search(text:)`'s "No Results" title,
`EditButton`'s "Edit" together with the "Delete" confirmation it leads to, and
`UISearchTextField`'s "Clear text" button (matched only to *suppress* an
unfixable hit-region issue in the accessibility audit — three tests share that
one). Those five open with `skipUnlessRunningInEnglish(matching:)`, so the
German run reports them as skipped, with the reason, instead of failing on a
string this app does not own.

Two more skip under German for an unrelated reason:
`ScreenshotGalleryUITests` produces the README's images once, from the
development-language run, and its German capture sets `-AppleLanguages` on its
own launch. Those two deliberately do *not* use the same helper — its skip
message says the test matches a string Apple localizes, which would be false
here, and a skip reason that misdescribes itself is worse than none. They
share the language check and supply their own sentence. Seven skips under
German, then, from two different causes; the test report names both.

That gate is a runtime check rather than plan configuration for a reason worth
recording: a test plan configuration carries `language` and `region` but *not*
per-configuration test selection. A `skippedTests` array inside a
configuration's `options` is accepted by the file format and then ignored —
measured, not assumed. Selection in a plan is per *target*, and a target-level
skip would remove those tests from the English run, which is the run they
exist for.

## Shipping hygiene

The unglamorous settings, and why each is what it is.

**The scheme is shared, and it runs a shared test plan.**
`testExample/testExample.xcodeproj/xcshareddata/xcschemes/testExample.xcscheme`
is committed; `.gitignore`
excludes `xcuserdata/` and says, in two lines, why the other half of that pair
needs no negation to stay tracked. Xcode autocreates a *user* scheme the
first time you open a project, which works locally and then doesn't exist on
anyone else's clone — so every `xcodebuild -scheme` command in the README
used to fail for every reader but the author. This is the single highest-value
item in this section: a repo that exists to be read must build from a clone.

The scheme's test action names `testExample.xctestplan` rather than listing
test targets inline, which moves three decisions out of per-user Xcode UI and
into a reviewable file: the two language configurations described above, which
suite is parallelizable (the unit target yes; the UI target no, because
`XCUIApplication` drives one simulator), and code coverage.

**Coverage is on, and scoped to the app.** The plan gathers coverage for the
`testExample` app target only. Left unscoped, the test bundles count as
instrumented code and report their own near-total coverage back into the
number, which then mostly measures how much test code there is. A coverage
figure that flatters itself is worse than none. Read it with
`xcrun xccov view --report --only-targets <result-bundle>`.

**A CI workflow for a remote this repo does not have yet.**
`.github/workflows/ci.yml` runs the unit suite and the UI suite as two jobs on
`macos-26`, each through the shared scheme — which means each through the test
plan, in both languages — plus a third, advisory formatter job. There is no
`git remote` configured, so nothing has ever executed it; the header comment
says so. It is committed anyway because the alternative is that the commands
get reinvented, differently, by whoever first wires up a remote. Two of its
steps are worth knowing about. The software keyboard never appears while the
simulator is paired with a hardware one, and `SearchScreen.search(for:)` waits
on it, so the UI job turns the pairing off. And that job writes a result
bundle and uploads it with `if: always()`: a UI failure on a hosted runner is
otherwise a log line, with the screenshots and accessibility snapshots left
inside a bundle on a machine that is about to be destroyed.

**A `.swift-format` at the root.** Toolchain-native (`swift format`, no
package to add), and tuned *to* this codebase rather than the other way
around: four-space indentation, a 120-column line limit because these files
carry long explanatory comments, `indentConditionalCompilationBlocks: false`
because whole files here are wrapped in `#if DEBUG` and indenting them all by
four would be pure churn, and `AlwaysUseLowerCamelCase` off because the UI
suite's BDD helpers are deliberately `Given`/`When`/`Then`/`And`.

It is a record of house style, not a gate, and the numbers are worth stating
rather than gesturing at.
`xcrun swift-format lint --strict --recursive testExample` reports 188
diagnostics across twelve files: 116 `Indentation`, 58 `AddLines`, 12
`LineLength`, 2 `Spacing`. The first two categories are almost entirely the
pretty-printer's view of how multi-line call arguments and collection literals
should be laid out, which this codebase disagrees with deliberately — the
alternative is reflowing readable fixtures and `#expect`s into the formatter's
shape for no reader's benefit. The twelve long lines are the interesting ones,
and nine of them are `String(localized:comment:)` translator comments: the
`comment:` argument is a `StaticString`, so the only ways to shorten the line
are to put a newline inside the comment a translator reads or to tell them
less. The three that could be broken have been. CI runs the same command with
`|| true` and prints the output; it never fails the build.

**A privacy manifest, entirely empty.** `PrivacyInfo.xcprivacy` declares
`NSPrivacyTracking = false` and three empty arrays. Empty is the *content*
here, not a placeholder: there is no analytics SDK, so no collected data
types; no advertising or attribution, so no tracking domains; and none of
Apple's required-reason APIs are called — favorites live in SwiftData rather
than `UserDefaults`, and the launch-argument checks read `ProcessInfo`,
which is not on the list. An app that collects nothing still has to say so;
a missing manifest reads as an incomplete submission, not as an innocent one.
(The reasoning lives here because plists cannot carry comments.)

**App Transport Security is left completely alone.** There is no
`NSAppTransportSecurity` dictionary in this project, and that is the correct
configuration rather than an oversight — checked, not assumed:
`nscurl --ats-diagnostics https://api.github.com` reports **PASS** for the
default ATS connection and for TLS 1.3. GitHub's API serves TLS 1.3 with
forward secrecy and a modern certificate, which is exactly what ATS requires
by default, so no exception is needed. The reason to spell this out: adding
`NSAllowsArbitraryLoads` "to get things working" is one of the most common
things a reader will find in an existing codebase, and it usually got added
once for a staging server and never removed.

**`ITSAppUsesNonExemptEncryption = NO`.** The app's only cryptography is
HTTPS via `URLSession`, which is exempt. Declaring it in the Info.plist is
what spares every archive upload the export-compliance questionnaire.

**The deployment target is the lowest one the code actually needs.**
`IPHONEOS_DEPLOYMENT_TARGET = 26.0`, not the 26.2 the project was scaffolded
with. Nothing here needs anything newer, and the compiler is what says so: an
availability check runs against the deployment target on every build, so
lowering it and building clean is the evidence. The higher number was
excluding devices in exchange for nothing. A deployment target is a claim
about the oldest OS a binary supports, and inheriting whatever the template
wrote makes that claim by accident.

**Device family is iPhone only.** `TARGETED_DEVICE_FAMILY = 1`. The app was
previously advertising iPad support it had never been designed for, which is
dishonest on its own — but it also exposed a concrete bug class: an
iPad-targeted app can be on screen twice at once, and this app hands both
windows the *same* `SearchViewModel` from its composition root. One debounce
pipeline and one `LoadState` driving two independent screens is not a bug you
fix in the view layer. Scoping to iPhone matches what the app actually is —
and the now-unreachable `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad`
went with it, because a setting that can never apply is a claim, not a
configuration.

**Three app icons, and only one of them is opaque.** `AppIcon.appiconset`
carries a 1024pt light icon plus `luminosity: dark` and `luminosity: tinted`
variants. The light one is the primary icon and **must not** have an alpha
channel — alpha in a primary icon is a submission error. The other two are the
opposite: iOS supplies the background and composites the artwork over it, so
they ship the magnifying glass on **transparency**, with no background plate
of their own. The dark variant's gradient is lifted from the light icon's
`#0B458A→#16A3A3` to `#2E7BD6→#2FD4D4`, because the system's backdrop is
near-black and the darker blue would nearly disappear against it. The tinted
variant is greyscale spanning white to mid-grey: the system maps *luminance*
onto the user's chosen colour, so a flat grey glyph tints to a flat slab and a
wide luminance range is what keeps the shape legible. Verifiable in one line,
from the repository root —
`/usr/bin/sips -g hasAlpha testExample/testExample/Assets.xcassets/AppIcon.appiconset/Icon-*.png`
— which is the point of writing it down.

**No `DEVELOPMENT_TEAM`.** A personal Apple team ID is account-specific and
belongs to a person, not a repository. With `CODE_SIGN_STYLE = Automatic`,
a local build picks up whatever identity the machine has.

**The bundle identifier is `work.timmaher.RepoScout`.** The Xcode project,
its targets and its scheme are all still named `testExample` — deliberately,
as the README explains — but the bundle identifier is the one name a user's
device actually records, and leaving the scaffold's name there was the part
that genuinely mattered.
