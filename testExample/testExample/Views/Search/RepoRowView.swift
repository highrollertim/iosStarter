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

    private var accessibilityDescription: String {
        var parts = [repo.fullName, "\(repo.stargazersCount) stars"]
        if let language = repo.language { parts.append("written in \(language)") }
        if let summary = repo.summary { parts.append(summary) }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    List(MockGitHubClient.fixtureRepos) { repo in
        RepoRowView(repo: repo)
    }
}
#endif
