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
        XCTAssertTrue(app.buttons["Spell name"].waitForExistence(timeout: 20))
    }
    override func tearDownWithError() throws { app?.terminate() }
    private func reveal(_ button: XCUIElement) {
        for _ in 0..<8 {
            if button.exists && button.isHittable { return }
            let scrolls = app.scrollViews.allElementsBoundByIndex
            if let last = scrolls.last { last.swipeUp() } else { app.swipeUp() }
        }
    }
    func testExpoSpellingConfirmationTranscriptAndNoAutomaticCaption() {
        app.buttons["Spell name"].tap()
        XCTAssertTrue(app.staticTexts["Use one hand · tap Add to keep a letter"].waitForExistence(timeout: 10),
                      "The actual pod-bundled alphabet model must load.")
        let manual = app.buttons["Manual letters"]
        reveal(manual); manual.tap()
        XCTAssertFalse(app.buttons["C"].exists)
        XCTAssertFalse(app.buttons["P"].exists)
        for letter in ["A", "U", "R", "E", "L", "I", "O"] {
            let key = app.buttons[letter].firstMatch
            reveal(key); key.tap()
        }
        let confirm = app.buttons["Confirm spelled name"]
        reveal(confirm)
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        app.buttons["Conversation menu"].tap()
        app.buttons["View transcript"].tap()
        XCTAssertTrue(app.staticTexts["AURELIO"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Expo confirmed spelling"; shot.lifetime = .keepAlways; add(shot)
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
