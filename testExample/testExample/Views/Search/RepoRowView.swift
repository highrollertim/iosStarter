import SwiftUI

/// One search result row. Small, stateless, preview-driven — the default
/// shape for leaf views.
struct RepoRowView: View {
    let repo: Repo

    /// Read so the row can *stop* truncating at accessibility text sizes.
    /// A fixed `lineLimit(2)` is a reasonable default at body size and a
    /// serious bug at AX5, where two lines might hold four words.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// De-emphasis that actually clears WCAG AA — used instead of
    /// `.foregroundStyle(.secondary)`.
    ///
    /// SwiftUI's `.secondary` resolves to the system `secondaryLabel`, which
    /// renders around 3.9:1 against the default background. That is under
    /// AA's 4.5:1 for any text below 18pt, which is *all* of this row, and
    /// `performAccessibilityAudit()` flags it — see
    /// `AccessibilityAuditUITests`. Deriving the de-emphasis from the primary
    /// label colour instead keeps the hierarchy (visibly lighter than the
    /// headline) while landing near 8:1 in both light and dark mode. The
    /// lesson: the system's *aesthetic* defaults are not automatically its
    /// *accessible* ones, and a semantic colour name is not a guarantee.
    private static let deemphasized = Color.primary.opacity(0.65)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(repo.fullName)
                .font(.headline)
            if let summary = repo.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Self.deemphasized)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            // `ViewThatFits` tries the horizontal arrangement first and falls
            // back to the stacked one when it doesn't fit. At accessibility
            // Dynamic Type sizes "67,000" and "C++" side by side overflow the
            // row and truncate to "67,0…" — which is worse than useless,
            // because a truncated number reads as a *different* number. This
            // is the layout-level half of the same problem `lineLimit` above
            // solves for prose.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { stats }
                VStack(alignment: .leading, spacing: 4) { stats }
            }
            .font(.caption)
            .foregroundStyle(Self.deemphasized)
        }
        .padding(.vertical, 2)
        // Merge the row into one accessibility element with a sentence-shaped
        // label, instead of making VoiceOver users step through four fragments.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Extracted so the two `ViewThatFits` candidates differ only in their
    /// container, not their content — there is exactly one definition of
    /// what a row's stats are.
    @ViewBuilder
    private var stats: some View {
        // `.formatted()` rather than "\(repo.stargazersCount)": string
        // interpolation of an `Int` into a `LocalizedStringKey` produces the
        // literal catalog key "%lld" and renders "67000" ungrouped in every
        // locale. `.formatted()` gives "67,000" / "67 000" / "६७,०००"
        // according to the user's locale, and hands `Label` a plain `String`
        // so nothing lands in the string catalog at all.
        Label(repo.stargazersCount.formatted(), systemImage: "star")
        if let language = repo.language {
            Label(language, systemImage: "chevron.left.forwardslash.chevron.right")
        }
    }

    // Whole, localizable sentences — not fragments joined with ", ". Joining
    // fragments (`[a, b, c].joined(separator: ", ")`) bakes in English word
    // order and punctuation; a translator only ever sees isolated pieces
    // like "written in Swift" with no sentence around them, so they can't
    // reorder or re-punctuate for a language that doesn't work like English.
    // `String(localized:)` on each complete sentence gives translators the
    // whole thing to work with instead.
    //
    // The star count is interpolated pre-formatted, for the same reason as
    // above and one more: VoiceOver should speak "sixty-seven thousand", not
    // "six seven zero zero zero".
    private var accessibilityDescription: String {
        let stars = repo.stargazersCount.formatted()
        switch (repo.language, repo.summary) {
        case let (language?, summary?):
            return String(
                localized: "\(repo.fullName), \(stars) stars, written in \(language). \(summary)",
                comment: "VoiceOver label for one search result. Placeholders in order: repository name (owner/repo), star count already formatted for the locale, programming language, one-line description."
            )
        case let (language?, nil):
            return String(
                localized: "\(repo.fullName), \(stars) stars, written in \(language).",
                comment: "VoiceOver label for a search result with no description. Placeholders in order: repository name (owner/repo), star count already formatted for the locale, programming language."
            )
        case let (nil, summary?):
            return String(
                localized: "\(repo.fullName), \(stars) stars. \(summary)",
                comment: "VoiceOver label for a search result with no detected language. Placeholders in order: repository name (owner/repo), star count already formatted for the locale, one-line description."
            )
        case (nil, nil):
            return String(
                localized: "\(repo.fullName), \(stars) stars.",
                comment: "VoiceOver label for a search result with neither a language nor a description. Placeholders in order: repository name (owner/repo), star count already formatted for the locale."
            )
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
