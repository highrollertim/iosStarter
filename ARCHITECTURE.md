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
    .filter { @MainActor [weak self] query in query != self?.lastDispatchedQuery }
    .sink { @MainActor [weak self] query in ... }
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

**`LoadState`.** While a *first* request is in flight, the view model sets its
`state` property to `.loading`; when the request finishes it becomes either
`.loaded(repos, isRefreshing: false)` or `.failed(message:)`. `LoadState` is a
four-case enum — `idle`, `loading`, `loaded`, `failed` — that replaces the more
common pattern of separate `isLoading: Bool`, `results: [Repo]`, and `error:
Error?` properties, which together can represent nonsense combinations
(loading *and* showing an old error, for instance) that this enum makes
impossible to construct.

```swift
nonisolated enum LoadState<Value: Sendable & Equatable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value, isRefreshing: Bool)
    case failed(message: String)
}
```

The `isRefreshing` flag inside `loaded` is worth dwelling on, because the
textbook four-case enum cannot express the fifth state a real search screen
has: *results already on screen while a refinement is in flight*. Without it,
refining a search has two bad options — blank the list back to a spinner (the
user loses their place and the screen flickers on every keystroke) or lie
about the request being finished. The flag lives *inside* `loaded` rather than
as a sibling `isLoading` property precisely so it is impossible to be
"refreshing" with nothing to refresh. Illegal states stay unrepresentable; the
enum just has to be honest about which states are actually legal.

**`SearchView`'s switch.** The view's body is a `switch` over
`viewModel.state` with one branch per case: an empty-state prompt for
`.idle`, a spinner for `.loading`, a "no results" view for `.loaded` with an
empty array, the results list for `.loaded` (which passes `isRefreshing` down
to the footer, so a refinement shows a small spinner beside "Updated 3 seconds
ago" instead of clearing the list), and an error view with a retry button for
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
inside the `safeAreaInset` builder — and the read is attributed to
`SearchView.body`, so the entire screen (the `NavigationStack`, the
`searchable` field, the whole `List`) is invalidated every second, forever.
Pulled out into a leaf, the once-a-second dependency belongs to a view whose
body is two `Text`s. The rule: **confine time-driven invalidation to the
smallest view that actually displays the time.** This is the single most
common way a well-behaved `@Observable` app quietly starts re-rendering
everything.

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

**Whole sentences, not joined fragments.** `RepoRowView` merges its four
labels into a single accessibility element
(`.accessibilityElement(children: .combine)`) so VoiceOver users hear one
result rather than stepping through four fragments. The interesting part is
how the label is *built*. The obvious implementation collects fragments and
joins them — `[name, "\(stars) stars", "written in \(language)"]
.joined(separator: ", ")` — and that bakes English into the app in a way no
translator can undo: it fixes word order and punctuation in code, and it
hands the translator isolated scraps like "written in Swift" with no sentence
around them. `RepoRowView` instead has four `String(localized:)` calls, one
per combination of optional language and optional summary, each a complete
sentence. A German translator gets "%1$@, %2$@ Sterne, in %3$@ geschrieben."
and can put the verb where German puts verbs. Four near-duplicate strings
looks like the worse code and is the better product.

**Numbers are formatted, not interpolated.** The star count goes through
`.formatted()` before it reaches either the visible label or the
accessibility sentence. Interpolating an `Int` directly into a
`LocalizedStringKey` produces the literal catalog key `%lld` and renders
"67000" ungrouped in every locale; `.formatted()` gives "67,000" / "67 000" /
"६७,०००" as appropriate, and VoiceOver says "sixty-seven thousand" instead of
"six seven zero zero zero".

That choice has a cost, and it is the honest trade to name here: because the
count arrives as a pre-formatted `%@` rather than a `%lld`, those four
sentences **cannot** carry plural variations — a plural variation needs a
number to inflect on. For a screen-reader label read aloud once, locale-correct
number formatting is worth more than agreement on the word "stars". The
"Updated %lld seconds ago" footer, where the number is small and genuinely
integral, keeps its `%lld` and *does* have `one`/`other` variations in both
languages. Different strings, different right answers.

**Dynamic Type is a layout problem, not a font-size problem.**
`RepoRowView` drops its `lineLimit` entirely at accessibility sizes (two lines
might hold four words at AX5) and wraps its stats row in
`ViewThatFits(in: .horizontal)`, which tries the horizontal arrangement and
falls back to a stacked one when it doesn't fit. The failure it prevents is
worth stating: at AX5, "67,000" and "C++" side by side overflow and truncate
to "67,0…" — and a truncated number doesn't read as an unclear number, it
reads as a *different* number.

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

**The one thing localization broke was the test suite**, which is worth
knowing before you run it in another language. Under `-testLanguage de` the
UI suite's *identifier*-based queries all pass; its *label*-based queries do
not. One of those was the app's fault and is fixed — the error state now
carries `search.errorView` on its description text instead of being matched
by the literal string "Something went wrong". The rest are queries against
strings Apple owns: `ContentUnavailableView.search(text:)`'s "No Results"
title, `EditButton`'s "Edit", the "Delete" confirmation, and the Favorites
tab's title (SwiftUI's `Tab` exposes no way to identify the tab-bar button
it produces). Those have no app-side fix that isn't worse than the problem,
so the suite is written to run in the development language and `LaunchTests`
serves as the German smoke check.

## Shipping hygiene

The unglamorous settings, and why each is what it is.

**The scheme is shared.** `xcshareddata/xcschemes/testExample.xcscheme` is
committed; `.gitignore` excludes `xcuserdata/` and explicitly says why the
other half of that pair stays tracked. Xcode autocreates a *user* scheme the
first time you open a project, which works locally and then doesn't exist on
anyone else's clone — so every `xcodebuild -scheme` command in the README
used to fail for every reader but the author. This is the single highest-value
item in this section: a repo that exists to be read must build from a clone.

**A privacy manifest, entirely empty.** `PrivacyInfo.xcprivacy` declares
`NSPrivacyTracking = false` and three empty arrays. Empty is the *content*
here, not a placeholder: there is no analytics SDK, so no collected data
types; no advertising or attribution, so no tracking domains; and none of
Apple's required-reason APIs are called — favorites live in SwiftData rather
than `UserDefaults`, and the one launch-argument check reads `ProcessInfo`,
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

**No `DEVELOPMENT_TEAM`.** A personal Apple team ID is account-specific and
belongs to a person, not a repository. With `CODE_SIGN_STYLE = Automatic`,
a local build picks up whatever identity the machine has.

**The bundle identifier is `work.timmaher.RepoScout`.** The Xcode project,
its targets and its scheme are all still named `testExample` — deliberately,
as the README explains — but the bundle identifier is the one name a user's
device actually records, and leaving the scaffold's name there was the part
that genuinely mattered.
