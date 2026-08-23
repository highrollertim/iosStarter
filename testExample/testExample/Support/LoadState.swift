/// The lifecycle of any asynchronously loaded value, as a closed enum.
///
/// This is the headline pattern of the codebase: instead of juggling
/// `isLoading: Bool` + `items: [Repo]` + `error: Error?` (eight combinations,
/// most of them nonsense), one enum makes illegal states unrepresentable.
/// The UI layer `switch`es over it and the compiler guarantees every state
/// has a screen.
///
/// `failed` carries a display-ready message rather than the `Error` itself:
/// errors aren't `Equatable`, and by the time state reaches the view the only
/// question left is "what do we tell the user?".
///
/// It also carries `stale`, for the same reason `loaded` carries
/// `isRefreshing`: a failure is not automatically a reason to blank the
/// screen. When a refinement fails with results already showing, those
/// results are still the best thing anyone has — the failure belongs in a
/// banner over them, not in a full-screen error that throws away work the
/// user can still read. A first-load failure has nothing to keep and carries
/// `nil`, which is what selects the full-screen presentation. Optional rather
/// than a separate case so the view's `switch` still has one failure branch
/// to reason about.
///
/// `loaded` carries `isRefreshing` because of the standard critique of the
/// naive four-case load enum: it cannot represent *stale-while-revalidate* —
/// results already on screen while a refinement is in flight. With only
/// `loading` and `loaded`, refining a search has two bad options: blank the
/// list back to a spinner (the user loses their place and the screen flickers
/// on every keystroke) or lie about the request being finished. The extra
/// `Bool` earns its place by making that fifth real state representable, and
/// it stays *inside* `loaded` rather than becoming a sibling `isLoading`
/// property — so it is impossible to be "refreshing" with nothing to refresh.
nonisolated enum LoadState<Value: Sendable & Equatable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value, isRefreshing: Bool)
    case failed(message: String, stale: Value?)
}
