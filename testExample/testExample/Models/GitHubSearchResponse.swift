import Foundation

/// Data-transfer objects mirroring GitHub's `/search/repositories` JSON.
///
/// Explicit `CodingKeys` (rather than a global `convertFromSnakeCase`
/// strategy) keep the mapping greppable: search for `full_name` and you land
/// here.
nonisolated struct GitHubSearchResponse: Decodable, Sendable {
    let items: [RepoDTO]
}

nonisolated struct RepoDTO: Decodable, Sendable {
    struct Owner: Decodable, Sendable {
        let login: String
    }

    let id: Int
    let fullName: String
    let owner: Owner
    let description: String?
    let stargazersCount: Int
    let forksCount: Int
    let language: String?
    let htmlUrl: URL

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case owner
        case description
        case stargazersCount = "stargazers_count"
        case forksCount = "forks_count"
        case language
        case htmlUrl = "html_url"
    }
}

extension Repo {
    /// The single seam where API shape becomes domain shape.
    init(dto: RepoDTO) {
        self.init(
            id: dto.id,
            fullName: dto.fullName,
            ownerLogin: dto.owner.login,
            summary: dto.description,
            stargazersCount: dto.stargazersCount,
            forksCount: dto.forksCount,
            language: dto.language,
            htmlURL: dto.htmlUrl
        )
    }
}
