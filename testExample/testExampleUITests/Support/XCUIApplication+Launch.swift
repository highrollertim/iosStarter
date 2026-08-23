import XCTest

extension XCUIApplication {
    /// Launches the app hermetically: mock network, in-memory store.
    /// `scenario` maps to `MockGitHubClient.Scenario` raw values in the app.
    ///
    /// `contentSizeCategory` takes a `UIContentSizeCategory` raw value (e.g.
    /// `"UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"`) and is
    /// applied through the same `-UIPreferredContentSizeCategoryName` launch
    /// argument the Xcode scheme editor uses, so a test can assert about
    /// Dynamic Type without anyone touching Settings.
    static func launchedForUITest(
        scenario: String = "success",
        contentSizeCategory: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockNetwork", "-UITestInMemoryStore"]
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        app.launch()
        return app
    }
}
