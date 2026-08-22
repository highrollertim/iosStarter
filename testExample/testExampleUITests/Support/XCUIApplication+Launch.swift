import XCTest

extension XCUIApplication {
    /// Launches the app hermetically: mock network, in-memory store.
    /// `scenario` maps to `MockGitHubClient.Scenario` raw values in the app.
    static func launchedForUITest(scenario: String = "success") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockNetwork", "-UITestInMemoryStore"]
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        app.launch()
        return app
    }
}
