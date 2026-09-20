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
        // Independent tests start without a persisted debug overlay. The
        // persistence test relaunches within its own method (not this setup).
        if app.buttons["hide-sign-scores"].exists { app.buttons["hide-sign-scores"].tap() }
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
        XCTAssertTrue(app.staticTexts["recognition-status"].label.contains("references"))
        XCTAssertEqual(app.staticTexts["current-sign"].label, "Tracking")
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
        // The underlying camera now has a caption area; without private
        // references it must remain Tracking, never a fabricated sign.
        XCTAssertEqual(app.staticTexts["current-sign"].label, "Tracking")
        app.buttons["Done"].tap()
    }

    func testAllThreeOverlayControlsAvailable() {
        app.buttons["camera-settings"].tap()
        XCTAssertTrue(actualSwitch("Track face (slower)").exists)
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
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Expression teaching — relaxed-face take"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
    }

    func testExpressionLabEnablesFaceTrackingWithoutRemovingSpelling() {
        app.buttons["camera-settings"].tap()
        let face = actualSwitch("Track face (slower)")
        if face.value as? String == "1" { face.tap() }
        app.buttons["Done"].tap()
        app.buttons["expression-lab"].tap()
        XCTAssertTrue(app.staticTexts["expression-result"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["camera-settings"].tap()
        XCTAssertEqual(actualSwitch("Track face (slower)").value as? String, "1")
        // Restore the word-only performance preference.
        actualSwitch("Track face (slower)").tap()
        app.buttons["Done"].tap()
        app.segmentedControls["recognition-mode"].buttons["Spell name"].tap()
        XCTAssertTrue(app.buttons["manual-spelling"].exists)
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

    func testAllSignScoresCanBeEnabledPersistedAndHidden() {
        app.buttons["camera-settings"].tap()
        let toggle = actualSwitch("Show match scores")
        if toggle.value as? String != "1" { toggle.tap() }
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["scores-disclaimer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["scores-disclaimer"].label.contains("not probability"))
        let list = app.scrollViews["sign-scores-list"]
        XCTAssertTrue(list.exists)
        let hello = app.descendants(matching: .any)["score-HELLO"].firstMatch
        XCTAssertTrue(hello.exists)
        XCTAssertEqual(hello.value as? String, "No current score")
        let mode = app.buttons["score-list-mode"]
        XCTAssertTrue(mode.exists)
        XCTAssertEqual(mode.label, "Show all candidates")
        mode.tap()
        XCTAssertEqual(mode.label, "Show top three matches")
        XCTAssertFalse(app.descendants(matching: .any)["score-CAMERA"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["score-YES"].firstMatch.exists)
        let last = app.descendants(matching: .any)["score-ILOVEYOU"].firstMatch
        for _ in 0..<8 {
            if last.exists && last.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(last.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["hide-sign-scores"].waitForExistence(timeout: 5))
        app.buttons["hide-sign-scores"].tap()
        XCTAssertFalse(app.scrollViews["sign-scores-list"].exists)
        app.buttons["camera-settings"].tap()
        XCTAssertEqual(actualSwitch("Show match scores").value as? String, "0")
        app.buttons["Done"].tap()
    }

    func testScorePanelLargeTextKeepsCameraControlsReachable() {
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()
        app.buttons["camera-settings"].tap()
        let toggle = actualSwitch("Show match scores")
        if toggle.value as? String != "1" { toggle.tap() }
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["camera-settings"].isHittable)
        XCTAssertTrue(app.buttons["pause-resume"].isHittable)
        // Hide through Settings as well as the panel's close control.
        app.buttons["camera-settings"].tap()
        actualSwitch("Show match scores").tap()
        app.buttons["Done"].tap()
    }

    func testSpellingModeNeedsConfirmationAndOnlyAllowsAurelio() {
        app.segmentedControls["recognition-mode"].buttons["Spell name"].tap()
        XCTAssertTrue(app.staticTexts["spelling-draft"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["current-sign"].label, "Watching…")
        XCTAssertFalse(app.buttons["add-letter"].isEnabled)
        app.buttons["manual-spelling"].tap()
        XCTAssertFalse(app.buttons["C (manual)"].exists)
        XCTAssertFalse(app.buttons["P (manual)"].exists)
        XCTAssertFalse(app.buttons["J (manual)"].exists)
        app.buttons["A (manual)"].tap()
        XCTAssertEqual(app.staticTexts["spelling-draft"].label, "A")
        app.buttons["manual-spelling"].tap()
        app.buttons["U (manual)"].tap()
        XCTAssertEqual(app.staticTexts["spelling-draft"].label, "AU")
        app.buttons["delete-letter"].tap()
        XCTAssertEqual(app.staticTexts["spelling-draft"].label, "A")
        app.segmentedControls["recognition-mode"].buttons["Signs"].tap()
        XCTAssertFalse(app.staticTexts["spelling-draft"].exists)
        XCTAssertEqual(app.staticTexts["current-sign"].label, "Tracking")
        app.segmentedControls["recognition-mode"].buttons["Spell name"].tap()
        XCTAssertEqual(app.staticTexts["spelling-draft"].label, "A")
    }

    func testSpellingIsNotSavedAcrossLaunches() {
        app.segmentedControls["recognition-mode"].buttons["Spell name"].tap()
        app.buttons["manual-spelling"].tap()
        app.buttons["A (manual)"].tap()
        app.terminate(); app.launch()
        app.segmentedControls["recognition-mode"].buttons["Spell name"].tap()
        XCTAssertEqual(app.staticTexts["spelling-draft"].label, "Spelling…")
    }

    func testSpellingLargeTextKeepsControlsReachable() {
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()
        app.segmentedControls["recognition-mode"].buttons["Spell name"].tap()
        XCTAssertTrue(app.buttons["camera-settings"].isHittable)
        XCTAssertTrue(app.buttons["pause-resume"].isHittable)
        XCTAssertTrue(app.buttons["manual-spelling"].isHittable)
        XCTAssertTrue(app.buttons["delete-letter"].isHittable)
        XCTAssertFalse(app.staticTexts["recognition-status"].label.contains("unavailable"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot) // simulator-only class guard; never capture a phone.
    }
}
