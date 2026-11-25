import XCTest

final class DeviceCaptureTests: XCTestCase {
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
        app.buttons["capture.stop"].tap()

        let saved = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "保存済み")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
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
        if !markBR.isHittable { app.swipeUp() }
        let canMark = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: markBR)
        XCTAssertEqual(XCTWaiter.wait(for: [canMark], timeout: 10), .completed)
        markBR.tap()
        XCTAssertTrue(app.staticTexts["フレーム 2"].waitForExistence(timeout: 10))
        #endif
    }

    private func waitForRecordingInterval() {
        let interval = expectation(description: "Collect two seconds of camera samples")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { interval.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [interval], timeout: 5), .completed)
    }
}
