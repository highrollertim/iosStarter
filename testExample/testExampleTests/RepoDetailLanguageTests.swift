import Foundation
import Testing
@testable import testExample

/// Pins the detail screen's Language row value in both languages.
///
/// The placeholder for a repository with no primary language is a catalog
/// entry, not a branch in `RepoDetailView`, so a dropped or mistranslated
/// German unit compiles clean and only shows up on a device set to German.
/// `testExample.xctestplan` runs this suite under English and German, so the
/// German assertion below is a second run of the same code under the second
/// catalog, not a translation of the first.
@Suite("RepoDetailView language row")
struct RepoDetailLanguageTests {

    private static var isGerman: Bool {
        Locale.current.language.languageCode?.identifier == "de"
    }

    private static func repo(language: String?) -> Repo {
        Repo(
            id: 1,
            fullName: "apple/swift",
            ownerLogin: "apple",
            summary: "The Swift Programming Language",
            stargazersCount: 70_000,
            forksCount: 10_000,
            language: language,
            htmlURL: URL(string: "https://github.com/apple/swift")!
        )
    }

    @Test("a repository with no language shows the localized placeholder")
    func nilLanguageShowsPlaceholder() {
        let value = RepoDetailView.languageValue(for: Self.repo(language: nil))

        if Self.isGerman {
            #expect(value == "Nicht angegeben")
        } else {
            #expect(value == "Not specified")
        }
    }

    @Test("a repository with a language passes it through unchanged")
    func languagePassesThrough() {
        let value = RepoDetailView.languageValue(for: Self.repo(language: "Swift"))

        #expect(value == "Swift")
    }
}
