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
    /// `AccessibilityAuditUITests`. The lesson: the system's *aesthetic*
    /// defaults are not automatically its *accessible* ones, and a semantic
    /// colour name is not a guarantee.
    ///
    /// An **asset colour**, not `Color.primary.opacity(0.65)`. A fixed alpha
    /// is a claim about the background it will be composited over, so it is
    /// only meaningful where that background has been measured — and it opts
    /// the text out of Increase Contrast entirely, because there is nothing
    /// for the system to substitute. `Deemphasized` names four measured
    /// values instead: light, dark, and a high-contrast variant of each, so
    /// a user who has asked for more contrast actually gets it.
    private static let deemphasized = Color("Deemphasized")

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
        // One accessibility element with a sentence-shaped label, instead of
        // making VoiceOver users step through four fragments.
        //
        // `.ignore`, not `.combine`: the label below replaces the children's
        // text completely, so merging their labels in only to overwrite them
        // is wasted work — and `.combine` merges more than text. It absorbs
        // the children's *traits and actions* too, which in a `List`'s edit
        // mode swallowed the row's delete control into this element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityDescription(for: repo))
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

    /// The row's VoiceOver label: one whole sentence per shape of repository.
    ///
    /// Whole, localizable sentences — not fragments joined with ", ". Joining
    /// fragments (`[a, b, c].joined(separator: ", ")`) bakes in English word
    /// order and punctuation; a translator only ever sees isolated pieces like
    /// "written in Swift" with no sentence around them, so they can't reorder
    /// or re-punctuate for a language that doesn't work like English.
    /// `String(localized:)` on each complete sentence gives translators the
    /// whole thing to work with instead.
    ///
    /// **The star count is a raw `Int`, and that is the interesting part.**
    /// The obvious implementation interpolates `stargazersCount.formatted()`,
    /// so the catalog sees `%@` — a string that happens to contain digits —
    /// and every locale reads "1 stars". A `%@` cannot carry a plural
    /// variation, because a plural variation needs a *number* to inflect on.
    /// Passing the `Int` puts `%lld` in the key, and the catalog then attaches
    /// a **substitution** (`%#@starCount@`) to that argument: the sentence
    /// stays one key for the translator, and the noun beside the number
    /// inflects — "1 star"/"5 stars", "1 Stern"/"5 Sterne" — inside it. The
    /// whole-sentence lesson and plural agreement are not in tension; the
    /// pre-formatted `%@` was what put them in tension.
    ///
    /// The visible `Label` above still uses `.formatted()`, because there the
    /// number stands alone with no noun to agree with and locale-correct digit
    /// grouping is the only thing at stake.
    ///
    /// `nonisolated static`, and reachable from tests, for the same reason
    /// `SearchViewModel.refreshedDescription(from:now:)` is: a plural rule
    /// lives in the catalog rather than in any branch of this code, so the
    /// only way to know it is right is to call this and read the sentence
    /// back — in both languages. See `RepoRowLabelTests`. (`nonisolated`
    /// because this is a pure function of a `Repo`; without it the project's
    /// default `MainActor` isolation would follow the enclosing `View` onto
    /// it, and a test suite would have to be main-actor-isolated to say
    /// anything about a string.)
    nonisolated static func accessibilityDescription(for repo: Repo) -> String {
        let stars = repo.stargazersCount
        switch (repo.language, repo.summary) {
        case (let language?, let summary?):
            return String(
                localized: "\(repo.fullName), \(stars) stars, written in \(language). \(summary)",
                comment: "VoiceOver label for one search result. Placeholders in order: repository name (owner/repo), star count, programming language, one-line description. The star count carries a plural substitution so the noun agrees with it."
            )
        case (let language?, nil):
            return String(
                localized: "\(repo.fullName), \(stars) stars, written in \(language).",
                comment: "VoiceOver label for a search result with no description. Placeholders in order: repository name (owner/repo), star count, programming language. The star count carries a plural substitution so the noun agrees with it."
            )
        case (nil, let summary?):
            return String(
                localized: "\(repo.fullName), \(stars) stars. \(summary)",
                comment: "VoiceOver label for a search result with no detected language. Placeholders in order: repository name (owner/repo), star count, one-line description. The star count carries a plural substitution so the noun agrees with it."
            )
        case (nil, nil):
            return String(
                localized: "\(repo.fullName), \(stars) stars.",
                comment: "VoiceOver label for a search result with neither a language nor a description. Placeholders in order: repository name (owner/repo), star count. The star count carries a plural substitution so the noun agrees with it."
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
