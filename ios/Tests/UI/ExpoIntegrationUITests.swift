import XCTest

/// Opt-in: install the Release Expo app on a disposable simulator first.
/// Never run on a phone: UI attachments must not capture a real camera feed.
final class ExpoIntegrationUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Simulator only.")
        #endif
        guard ProcessInfo.processInfo.environment["TEST_SIGNLOOP_EXPO"] == "1" else {
            throw XCTSkip("Opt-in Expo installed-app integration suite.")
        }
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.signloop.mobile")
        app.launch()
        let start = app.buttons["Start conversation"]
        XCTAssertTrue(start.waitForExistence(timeout: 40))
        start.tap()
        XCTAssertTrue(app.staticTexts["Your words will appear here."].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Signs"].exists)
        XCTAssertFalse(app.buttons["Spell name"].exists)
    }
    override func tearDownWithError() throws { app?.terminate() }
    private func reveal(_ button: XCUIElement) {
        for _ in 0..<8 {
            if button.exists && button.isHittable { return }
            let scrolls = app.scrollViews.allElementsBoundByIndex
            if let last = scrolls.last { last.swipeUp() } else { app.swipeUp() }
        }
    }
    func testExpoNativeModelsSettingsAndExpressionLab() {
        app.buttons["Conversation menu"].tap()
        app.buttons["Detection settings"].tap()
        XCTAssertTrue(app.switches["Show hand joints"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Show upper-body pose"].exists)
        let scores = app.switches["Show match distances"]
        reveal(scores); scores.tap()
        let done = app.buttons["Done"]; reveal(done); done.tap()
        app.buttons["Conversation menu"].tap()
        app.buttons["Expression lab"].tap()
        XCTAssertTrue(app.staticTexts["expression-result"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["expression-teach"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Expo native expression lab"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Back to conversation"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 10))
    }
}
