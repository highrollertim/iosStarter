import XCTest

/// BDD-style structuring for XCUITests.
///
/// Each step wraps `XCTContext.runActivity`, so the Xcode test report and
/// `xcresult` bundle read as living Gherkin:
///
///     ▸ Given the app has launched to the Search tab
///     ▸ When I search for "swift"
///     ▸ Then I see the apple/swift repository
///
/// No framework, no .feature files — activities are the standard-library way
/// to get scenario-shaped reports.
@MainActor
func Given(_ description: String, _ body: () throws -> Void) rethrows {
    try XCTContext.runActivity(named: "Given \(description)") { _ in try body() }
}

@MainActor
func When(_ description: String, _ body: () throws -> Void) rethrows {
    try XCTContext.runActivity(named: "When \(description)") { _ in try body() }
}

@MainActor
func Then(_ description: String, _ body: () throws -> Void) rethrows {
    try XCTContext.runActivity(named: "Then \(description)") { _ in try body() }
}

@MainActor
func And(_ description: String, _ body: () throws -> Void) rethrows {
    try XCTContext.runActivity(named: "And \(description)") { _ in try body() }
}
