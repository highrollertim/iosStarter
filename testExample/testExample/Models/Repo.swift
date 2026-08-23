import Foundation

/// The app's domain model for a repository.
///
/// Deliberately separate from the network DTO (`RepoDTO`): the API's shape is
/// GitHub's decision, this type's shape is ours. When the API changes, only
/// the DTO and its mapping move.
///
/// `nonisolated`: this project uses Xcode's default-`MainActor` isolation, so
/// without the keyword this type would itself be `@MainActor` and unusable
/// from anywhere else. Three concrete things need it to be non-isolated:
///
/// 1. **Reachability.** `GitHubClient` and its implementations are
///    `nonisolated`; a `@MainActor` `Repo` could not appear in their
///    signatures.
/// 2. **Genericity.** `LoadState<Value: Sendable & Equatable>` requires
///    `Sendable`, and a main-actor-isolated type only satisfies that
///    vacuously — it cannot be *used* off the main actor.
/// 3. **A real boundary crossing.** `LiveGitHubClient.searchRepositories` is
///    `@concurrent`, so decoding genuinely happens off the caller's executor
///    and these values are genuinely returned across an executor hop to the
///    main actor. (Note that this is true *because* of `@concurrent`: under
///    this project's SE-0461 semantics, a plain `nonisolated async` function
///    would have run on the main actor and crossed nothing.)
///
/// `Sendable` itself is trivially satisfied — every stored property is a
/// `let` of a `Sendable` type.
nonisolated struct Repo: Identifiable, Hashable, Sendable {
    let id: Int
    let fullName: String
    let ownerLogin: String
    /// GitHub calls this `description`; renamed to avoid colliding with
    /// `CustomStringConvertible.description` conventions.
    let summary: String?
    let stargazersCount: Int
    let forksCount: Int
    let language: String?
    let htmlURL: URL
}

extension Repo {
    /// `htmlURL` if it is safe to hand to `openURL`, `nil` otherwise.
    ///
    /// The scheme comes straight off a network payload, so it is the server's
    /// choice, not ours. The risk is *deep-linking*: a custom scheme opens
    /// whichever app has registered it, which is a way to push the user into
    /// another app's handler on a tap they thought stayed here. (It is not
    /// script execution — `openURL` will not run a `javascript:` URL.)
    ///
    /// Compared lowercased because RFC 3986 defines schemes as
    /// case-insensitive: `HTTPS://…` is a perfectly ordinary web URL, and an
    /// exact-match check would have refused to render it.
    ///
    /// It lives on the model rather than in the view because "is this URL one
    /// we are willing to open" is a fact about the repository, and a second
    /// screen that linked out would otherwise have to remember to re-derive
    /// it.
    var webURL: URL? {
        let scheme = htmlURL.scheme?.lowercased()
        return (scheme == "https" || scheme == "http") ? htmlURL : nil
    }
}
