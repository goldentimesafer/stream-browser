import XCTest

final class ScreenCaptureTests: XCTestCase {
    @MainActor
    func testExistingInstallKeepsLock() {
        // CI installs a pre-guide preferences fixture before running this test.
        let app = XCUIApplication()
        app.launch()
        let start = app.buttons["시작"]
        guard show(start) else { return }
        XCTAssertFalse(app.switches["앱 잠금 사용"].exists)
        XCTAssertFalse(app.buttons["저장함"].exists)
        start.tap()
        guard show(app.buttons["잠금 해제"]) else { return }
        XCTAssertFalse(app.buttons["저장함"].exists)
        XCTAssertFalse(app.buttons["설정"].exists)
    }

    @MainActor
    func testCaptureMainScreens() {
        let app = XCUIApplication()
        // No launch arguments here: an argument-domain value would override the preference the
        // "시작" button writes, so the welcome screen could never be dismissed. A fresh simulator
        // starts with onboardingDone unset.
        app.launch()
        let start = app.buttons["시작"]
        if start.waitForExistence(timeout: 30) {
            capture("00-welcome", in: app)
            XCTAssertFalse(app.switches["앱 잠금 사용"].exists)
            start.tap()
        } else {
            capture("diagnostic-lock", in: app)
            XCTFail("Welcome screen missing. App state: \(app.state). \(app.debugDescription)")
        }
        let unlock = app.buttons["잠금 해제"]
        if unlock.waitForExistence(timeout: 30) {
            capture("01-lock", in: app)
        } else {
            capture("diagnostic-lock", in: app)
            XCTFail("Unlock button missing. App state: \(app.state). \(app.debugDescription)")
        }
        app.terminate()

        // Apply the existing preferences only to this simulator launch.
        app.launchArguments = ["-appLockEnabled", "NO", "-onboardingDone", "YES"]
        app.launch()
        guard show(app.textFields["주소 또는 검색어"]) else { return }
        capture("02-browser", in: app)

        let tabs = app.tabBars.firstMatch
        guard show(tabs.buttons["저장함"]) else { return }
        tabs.buttons["저장함"].tap()
        let video = app.buttons["예제 동영상"]
        let audio = app.buttons["예제 오디오"]
        guard show(video), show(audio) else { return }
        XCTAssertEqual(video.frame.minY, audio.frame.minY, accuracy: 2)
        XCTAssertLessThan(video.frame.minX, audio.frame.minX)
        let duration = NSPredicate(format: "value CONTAINS %@", "0:04")
        let durationReady = XCTNSPredicateExpectation(predicate: duration, object: video)
        XCTAssertEqual(XCTWaiter.wait(for: [durationReady], timeout: 10), .completed)
        XCTAssertTrue((video.value as? String)?.contains("25") == true)
        capture("03-library", in: app)

        app.buttons["동영상"].tap()
        XCTAssertTrue(video.exists)
        XCTAssertFalse(audio.exists)
        app.buttons["오디오"].tap()
        XCTAssertTrue(audio.exists)
        XCTAssertFalse(video.exists)
        app.buttons["전체"].tap()
        XCTAssertTrue(video.exists)
        XCTAssertTrue(audio.exists)

        tabs.buttons["설정"].tap()
        guard show(app.switches["앱 잠금"]) else { return }
        capture("04-settings", in: app)

        tabs.buttons["탐색"].tap()
        app.buttons["영상 저장"].tap()
        guard show(app.navigationBars["영상 저장"]) else { return }
        capture("05-download", in: app)
    }

    @MainActor
    private func show(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let exists = element.waitForExistence(timeout: 15)
        XCTAssertTrue(exists, "Expected screen element: \(element)", file: file, line: line)
        return exists
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
