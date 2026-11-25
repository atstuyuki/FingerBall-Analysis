import XCTest

final class DeviceCaptureTests: XCTestCase {
    @MainActor
    func testLandscapeCaptureLayout() {
        let device = XCUIDevice.shared
        let originalOrientation = device.orientation
        device.orientation = .landscapeRight
        defer { device.orientation = originalOrientation }
        let app = XCUIApplication()
        let id = "TEST_LAYOUT"
        app.launchArguments = ["-FingerBallTestSubject", id]
        app.launch()

        let preview = app.descendants(matching: .any)["capture.preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(preview.frame.height, app.frame.height * 0.5)
        XCTAssertGreaterThan(preview.frame.width, app.frame.width * 0.8)
        let subject = app.textFields["capture.subjectID"]
        XCTAssertEqual(subject.value as? String, id)
        XCTAssertLessThan(subject.frame.maxY, preview.frame.minY)
        XCTAssertTrue(app.textFields["capture.subjectName"].isHittable)
        XCTAssertTrue(app.buttons["capture.start"].isHittable)
        XCTAssertTrue(app.buttons["capture.settings"].isHittable)
        XCTAssertTrue(app.buttons["capture.library"].isHittable)
        app.buttons["capture.settings"].tap()
        XCTAssertTrue(app.navigationBars["撮影設定"].waitForExistence(timeout: 5))
        app.buttons["完了"].tap()
        app.buttons["capture.library"].tap()
        XCTAssertTrue(app.navigationBars["保存済み動画"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRecordAndReview1080p240() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("このテストは実機カメラを使用します。")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        let testID = "TEST_" + UUID().uuidString.prefix(8)
        app.launchArguments = ["-FingerBallTestSubject", testID]
        app.launch()

        let start = app.buttons["capture.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        if !start.isHittable { app.swipeDown() }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed,
                       "カメラ許可と1920×1080 / 240 fps形式を確認してください。")
        start.tap()
        let recording = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "録画中")).firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 10))
        waitForRecordingInterval()
        let stop = app.buttons["capture.stop"]
        XCTAssertTrue(stop.isHittable)
        XCTAssertEqual(start.exists, false)
        stop.tap()

        let saved = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "保存済み")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
        XCTAssertEqual(app.textFields["capture.subjectID"].value as? String, testID)
        XCTAssertEqual(app.staticTexts["capture.throwNumber"].label, "投球 2")
        XCTAssertTrue(start.isEnabled)
        app.buttons["capture.library"].tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", String(testID))).firstMatch
        for _ in 0..<3 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
        let verified = app.staticTexts["review.videoProperties"]
        XCTAssertTrue(verified.waitForExistence(timeout: 15))
        XCTAssertTrue(verified.label.contains("1920×1080"), verified.label)
        XCTAssertTrue(verified.label.contains("PTS照合済み"), verified.label)
        let frameRateLabel = try XCTUnwrap(verified.label.components(separatedBy: " · ").dropFirst().first)
        let fps = try XCTUnwrap(Double(frameRateLabel.replacingOccurrences(of: " fps", with: "")))
        XCTAssertGreaterThanOrEqual(fps, 235)
        print("Saved recording: \(verified.label)")
        let next = app.buttons["次のフレーム"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(next.isEnabled)
        next.tap()
        let frame = app.staticTexts["review.frame"]
        XCTAssertTrue(frame.label.hasPrefix("フレーム 2 /"), frame.label)
        let markBR = app.buttons["review.mark.BR"]
        for _ in 0..<3 where !markBR.isHittable { app.swipeUp() }
        XCTAssertTrue(markBR.isHittable)
        let canMark = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: markBR)
        XCTAssertEqual(XCTWaiter.wait(for: [canMark], timeout: 10), .completed)
        markBR.tap()
        XCTAssertTrue(app.staticTexts["フレーム 2"].waitForExistence(timeout: 10))
        #endif
    }

    @MainActor
    func testRecoverAfterGoingHomeDuringRecording() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("このテストは実機カメラを使用します。")
        #else
        continueAfterFailure = false
        let (app, id) = beginRecoverableRecording()
        waitForRecordingInterval(seconds: 10)
        XCUIDevice.shared.press(.home)
        app.activate()
        assertRecovery(in: app, id: id)
        #endif
    }

    @MainActor
    func testRecoverAfterRelaunchDuringSaving() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("このテストは実機カメラを使用します。")
        #else
        continueAfterFailure = false
        let (app, id) = beginRecoverableRecording()
        waitForRecordingInterval()
        app.buttons["capture.stop"].tap()
        let finishing = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "保存中")).firstMatch
        XCTAssertTrue(finishing.waitForExistence(timeout: 8))
        app.terminate()
        app.launch()
        assertRecovery(in: app, id: id)
        #endif
    }

    @MainActor
    private func beginRecoverableRecording() -> (XCUIApplication, String) {
        let app = XCUIApplication()
        let id = "TEST_" + UUID().uuidString.prefix(8)
        app.launchArguments = ["-FingerBallTestSubject", id]
        app.launch()
        let start = app.buttons["capture.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        if !start.isHittable { app.swipeDown() }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        start.tap()
        let recording = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "録画中")).firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 10))
        return (app, id)
    }

    @MainActor
    private func assertRecovery(in app: XCUIApplication, id: String) {
        app.buttons["capture.library"].tap()
        let take = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", id)).firstMatch
        for _ in 0..<3 where !take.isHittable { app.swipeUp() }
        XCTAssertTrue(take.isHittable)
        take.tap()
        let recover = app.buttons["review.recover"]
        XCTAssertTrue(recover.waitForExistence(timeout: 15))
        recover.tap()
        let verified = app.staticTexts["review.videoProperties"]
        XCTAssertTrue(verified.waitForExistence(timeout: 150))
        XCTAssertTrue(verified.label.contains("PTS照合済み"))
    }

    private func waitForRecordingInterval(seconds: TimeInterval = 2) {
        let interval = expectation(description: "Collect two seconds of camera samples")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { interval.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [interval], timeout: seconds + 3), .completed)
    }
}
