import Foundation

/// The app's domain model for a repository.
///
/// Deliberately separate from the network DTO (`RepoDTO`): the API's shape is
/// GitHub's decision, this type's shape is ours. When the API changes, only
/// the DTO and its mapping move.
///
/// `nonisolated`: this project uses Xcode's default-`MainActor` isolation, so
/// types that must cross concurrency boundaries (decoded on a background
/// URLSession task, displayed on the main actor) opt out explicitly.
/// `Sendable` is trivially satisfied because this is an immutable value type.
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
