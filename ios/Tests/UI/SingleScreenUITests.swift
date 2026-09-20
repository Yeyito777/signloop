import XCTest

/// Run on a disposable simulator. Declines the actual Camera prompt. Tests
/// screen behavior without taking photos or inventing recognized signs.
final class SingleScreenUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Use a disposable simulator: UI-test attachments must never record a real camera feed.")
        #endif
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = system.alerts.firstMatch.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Don")).firstMatch
        if deny.waitForExistence(timeout: 3) { deny.tap() }
    }

    override func tearDownWithError() throws { app?.terminate() }

    private func actualSwitch(_ label: String) -> XCUIElement {
        let row = app.switches[label].firstMatch
        for _ in 0..<5 {
            if row.exists && row.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // SwiftUI exposes a full-row switch containing a native UISwitch. The
        // row's center is blank space, not the actual trailing touch control.
        return row.switches.firstMatch.exists ? row.switches.firstMatch : row
    }

    func testCameraDeniedShowsRecoveryAndKeepsSettingsAccessible() {
        XCTAssertTrue(app.buttons["Allow camera in Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["camera-settings"].exists)
        XCTAssertTrue(app.staticTexts["analysis-mode"].label.contains("Offline"))
        XCTAssertFalse(app.staticTexts["Connecting…"].exists)
    }

    func testCameraRecoveryScreenContrast() throws {
        XCTAssertTrue(app.buttons["Allow camera in Settings"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: .contrast)
    }

    func testOverlayPreferencePersistsAfterRelaunch() {
        let settings = app.buttons["camera-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let joints = actualSwitch("Show hand joints")
        let before = joints.value as? String
        joints.tap()
        let changed = joints.value as? String
        XCTAssertNotEqual(before, changed)
        app.buttons["Done"].tap()
        app.terminate()
        app.launch()
        app.buttons["camera-settings"].tap()
        XCTAssertEqual(actualSwitch("Show hand joints").value as? String, changed)
        // Leave the original setting intact for independent test runs.
        actualSwitch("Show hand joints").tap()
        app.buttons["Done"].tap()
    }

    func testPauseResumeDoesNotDependOnBackend() {
        let pause = app.buttons["pause-resume"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        XCTAssertTrue(app.staticTexts["tracking-title"].label.contains("Paused"))
        XCTAssertTrue(app.staticTexts["tracking-status"].label.contains("paused"))
        pause.tap()
        XCTAssertTrue(app.buttons["Allow camera in Settings"].waitForExistence(timeout: 5))
    }

    func testCameraScreenHasNoCloudSetupOrNetworkDependency() {
        XCTAssertTrue(app.buttons["camera-settings"].waitForExistence(timeout: 10))
        app.buttons["camera-settings"].tap()
        XCTAssertFalse(app.switches["Experimental cloud signs"].exists)
        let privacy = app.staticTexts["offline-privacy"]
        for _ in 0..<10 {
            if privacy.exists && privacy.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(privacy.exists)
        XCTAssertTrue(privacy.label.contains("no images or video are recorded or sent"))
        XCTAssertTrue(privacy.label.contains("numeric calibration"))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["analysis-mode"].label.contains("Offline"))
    }

    func testInspectorShowsMissingDataNotInventedCoordinates() {
        XCTAssertTrue(app.buttons["skeleton-inspector"].waitForExistence(timeout: 10))
        app.buttons["skeleton-inspector"].tap()
        XCTAssertTrue(app.staticTexts["probe-missing"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["current-sign"].exists)
        app.buttons["Done"].tap()
    }

    func testAllThreeOverlayControlsAvailable() {
        app.buttons["camera-settings"].tap()
        XCTAssertTrue(actualSwitch("Show hand joints").exists)
        XCTAssertTrue(actualSwitch("Show upper-body pose").exists)
        XCTAssertTrue(actualSwitch("Show facial features").exists)
        app.buttons["Done"].tap()
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.isHittable && element.frame.minY > 110 && element.frame.maxY < app.frame.maxY - 40 { break }
            app.scrollViews.firstMatch.swipeUp()
        }
    }

    func testExpressionLabCannotTeachWithoutFace() {
        XCTAssertTrue(app.buttons["expression-lab"].waitForExistence(timeout: 10))
        app.buttons["expression-lab"].tap()
        XCTAssertEqual(app.staticTexts["expression-result"].label, "No face")
        let teach = app.buttons["expression-teach"]
        reveal(teach)
        teach.tap()
        let step = app.staticTexts["expression-teaching-step"]
        XCTAssertTrue(step.waitForExistence(timeout: 5))
        XCTAssertTrue(step.label.contains("relaxed face"))
        let capture = app.buttons["expression-capture"]
        reveal(capture)
        XCTAssertTrue(capture.exists)
        XCTAssertFalse(capture.isEnabled)
        XCTAssertFalse(app.buttons["expression-save-profile"].exists)
        XCTAssertEqual(app.staticTexts["expression-teaching-breakdown"].label, "0/12 teaching captures · 0/6 checks passed")
        for label in ["neutral", "joy", "anger", "fear", "sadness", "disgust"] {
            let status = app.staticTexts["expression-status-\(label)"]
            reveal(status)
            XCTAssertTrue(status.label.contains("Teaching incomplete"))
        }
        XCTAssertFalse(app.staticTexts["expression-teaching-attention"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Expression teaching — six-expression checklist"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
    }

    func testExpressionSetupStaysInLabAndRequiresCompleteProfileForExport() {
        XCTAssertTrue(app.buttons["expression-lab"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["expression-teach"].exists)
        app.buttons["expression-lab"].tap()
        let export = app.buttons["expression-export"]
        reveal(export)
        XCTAssertTrue(export.exists)
        XCTAssertFalse(export.isEnabled)
        let teach = app.buttons["expression-teach"]
        // Return to the beginning so the teaching button is fully on screen.
        app.scrollViews.firstMatch.swipeDown()
        reveal(teach)
        teach.tap()
        let cancel = app.buttons["expression-cancel-teaching"]
        reveal(cancel)
        cancel.tap()
        XCTAssertFalse(app.buttons["expression-capture"].exists)
        app.buttons["Done"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["expression-lab"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["expression-capture"].exists)
        app.buttons["expression-lab"].tap()
        XCTAssertTrue(app.buttons["expression-teach"].exists)
        XCTAssertFalse(app.buttons["expression-capture"].exists)
        app.buttons["Done"].tap()
    }

    func testDemoBuildUsesBundledProfileWithoutTeachingEntry() throws {
        #if SIGNLOOP_DEMO
        XCTAssertTrue(app.buttons["camera-settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["expression-lab"].exists)
        XCTAssertFalse(app.buttons["expression-teach"].exists)
        XCTAssertTrue(app.staticTexts["live-expression-preset"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["live-expression-preset"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["expression-lab"].exists)
        #else
        throw XCTSkip("Run this check with HonkAndTellDemo and an explicit synthetic simulator fixture.")
        #endif
    }

    func testLargeTextKeepsCoreControlsReachable() {
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()
        let settings = app.buttons["camera-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(app.buttons["pause-resume"].isHittable)
        settings.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].isHittable)
        app.buttons["Done"].tap()
    }
}
