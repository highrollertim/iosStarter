import SwiftUI

/// One search result row. Small, stateless, preview-driven — the default
/// shape for leaf views.
struct RepoRowView: View {
    let repo: Repo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(repo.fullName)
                .font(.headline)
            if let summary = repo.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Label("\(repo.stargazersCount)", systemImage: "star")
                if let language = repo.language {
                    Label(language, systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        // Merge the row into one accessibility element with a sentence-shaped
        // label, instead of making VoiceOver users step through four fragments.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // Whole, localizable sentences — not fragments joined with ", ". Joining
    // fragments (`[a, b, c].joined(separator: ", ")`) bakes in English word
    // order and punctuation; a translator only ever sees isolated pieces
    // like "written in Swift" with no sentence around them, so they can't
    // reorder or re-punctuate for a language that doesn't work like English.
    // `String(localized:)` on each complete sentence gives translators the
    // whole thing to work with instead.
    private var accessibilityDescription: String {
        switch (repo.language, repo.summary) {
        case let (language?, summary?):
            String(localized: "\(repo.fullName), \(repo.stargazersCount) stars, written in \(language). \(summary)")
        case let (language?, nil):
            String(localized: "\(repo.fullName), \(repo.stargazersCount) stars, written in \(language).")
        case let (nil, summary?):
            String(localized: "\(repo.fullName), \(repo.stargazersCount) stars. \(summary)")
        case (nil, nil):
            String(localized: "\(repo.fullName), \(repo.stargazersCount) stars.")
        }
    }
}

#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    List(MockGitHubClient.fixtureRepos) { repo in
        RepoRowView(repo: repo)
    }
}
#endif
