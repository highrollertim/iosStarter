import XCTest

/// Smoke test: the app launches at all, on every UI-appearance configuration
/// the suite runs under, and we keep a screenshot in the result bundle.
final class LaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMockNetwork", "-UITestInMemoryStore"]
        app.launch()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Launch time is a user-visible feature and the easiest thing in an app
    /// to regress by accident — one eager `ModelContainer`, one synchronous
    /// file read in the composition root, and it is gone. `measure` with
    /// `XCTApplicationLaunchMetric` records it per run, so the number lives in
    /// the result bundle and a regression is visible rather than folklore.
    ///
    /// Launched hermetically, same as every other test here: this measures
    /// *our* startup, not the network's mood.
    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments += ["-UITestMockNetwork", "-UITestInMemoryStore"]
            app.launch()
        }
    }
}
