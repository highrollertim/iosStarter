import Foundation
import Testing
@testable import testExample

/// Pins the row's VoiceOver sentences — and, specifically, the plural
/// agreement in them.
///
/// The agreement is not produced by any branch in `RepoRowView`; it comes from
/// a `substitutions` entry in `Localizable.xcstrings`, attached to the `%lld`
/// star count. That makes it exactly the kind of behaviour that reads as
/// obviously working and silently isn't: nothing fails to compile if the
/// substitution is malformed, dropped, or wired to the wrong argument — the
/// sentence just comes back saying "1 stars", or with a literal
/// `%#@starCount@` in it.
///
/// `testExample.xctestplan` runs this suite in English and in German, so the
/// German assertions below are not a translation of the English ones — they
/// are a second run of the same code under a second set of plural rules.
@Suite("RepoRowView accessibility label")
struct RepoRowLabelTests {

    private static var isGerman: Bool {
        Locale.current.language.languageCode?.identifier == "de"
    }

    private static func repo(
        stars: Int,
        language: String? = "C++",
        summary: String? = "The Swift Programming Language"
    ) -> Repo {
        Repo(
            id: 1,
            fullName: "apple/swift",
            ownerLogin: "apple",
            summary: summary,
            stargazersCount: stars,
            forksCount: 10_000,
            language: language,
            htmlURL: URL(string: "https://github.com/apple/swift")!
        )
    }

    @Test("the star count inflects the noun beside it")
    func starCountInflects() {
        let one = RepoRowView.accessibilityDescription(for: Self.repo(stars: 1))
        let many = RepoRowView.accessibilityDescription(for: Self.repo(stars: 2))

        if Self.isGerman {
            #expect(one == "apple/swift, 1 Stern, in C++ geschrieben. The Swift Programming Language")
            #expect(many == "apple/swift, 2 Sterne, in C++ geschrieben. The Swift Programming Language")
        } else {
            #expect(one == "apple/swift, 1 star, written in C++. The Swift Programming Language")
            #expect(many == "apple/swift, 2 stars, written in C++. The Swift Programming Language")
        }
    }

    @Test("every sentence shape resolves to a real sentence")
    func allShapesResolve() {
        // One case per combination of optional language and optional summary —
        // four separate catalog keys, each with its own substitution, and a
        // typo in any one of them only shows up for the repositories that hit
        // that shape.
        let shapes = [
            RepoRowView.accessibilityDescription(for: Self.repo(stars: 1)),
            RepoRowView.accessibilityDescription(for: Self.repo(stars: 1, summary: nil)),
            RepoRowView.accessibilityDescription(for: Self.repo(stars: 1, language: nil)),
            RepoRowView.accessibilityDescription(for: Self.repo(stars: 1, language: nil, summary: nil)),
        ]

        let star = Self.isGerman ? "1 Stern" : "1 star"
        for sentence in shapes {
            #expect(sentence.hasPrefix("apple/swift, \(star)"))
            // An unresolved substitution token would survive into the output
            // rather than failing anywhere earlier.
            #expect(!sentence.contains("%"))
        }
    }
}
