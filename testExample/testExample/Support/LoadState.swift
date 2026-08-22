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
nonisolated enum LoadState<Value: Sendable & Equatable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(message: String)
}
