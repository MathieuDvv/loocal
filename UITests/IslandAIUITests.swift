import XCTest

final class IslandAIUITests: XCTestCase {
    @MainActor
    func testFirstLaunchCanReachModelSetupAndConversationHistory() throws {
        let app = XCUIApplication()
        app.launch()
        // Without a model, the prompt box is the download box.
        let download = app.buttons["composerDownload"]
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        let firstLaunch = XCTAttachment(screenshot: app.screenshot())
        firstLaunch.name = "Loocal first launch"
        firstLaunch.lifetime = .keepAlways
        add(firstLaunch)

        app.buttons["tab-settings"].tap()
        XCTAssertTrue(app.buttons["downloadModel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voiceRow"].exists)

        app.buttons["tab-history"].tap()
        XCTAssertTrue(app.textFields["Search chats"].waitForExistence(timeout: 5))

        app.buttons["tab-chat"].tap()
        XCTAssertTrue(app.buttons["composerDownload"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["temporaryToggle"].exists)
    }
}
