import XCTest

final class EasyClipboardUITests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!
    private var suite: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EasyClipboard-UI-\(UUID().uuidString)")
        suite = "EasyClipboard.UI.\(UUID().uuidString)"
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--seed-history", "--test-root", root.path, "--test-suite", suite]
        app.launch()
    }
    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @MainActor func testHistorySettingsPauseAndClear() {
        XCTAssertTrue(app.staticTexts["剪贴板历史"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["周五前完成界面设计，整理测试结果。"].exists)
        let attachment = XCTAttachment(screenshot: app.windows["EasyClipboard"].screenshot())
        attachment.name = "EasyClipboard-历史"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["pauseRecording"].click()
        XCTAssertTrue(app.staticTexts["记录已暂停"].exists)
        app.buttons["pauseRecording"].click()
        app.buttons["openSettings"].click()
        let field = app.textFields["historyLimit"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("5")
        XCTAssertEqual(field.value as? String, "5")
        app.windows["设置"].buttons[XCUIIdentifierCloseWindow].click()
        app.buttons["openSettings"].click()
        XCTAssertEqual(app.textFields["historyLimit"].value as? String, "5")
        app.windows["设置"].buttons[XCUIIdentifierCloseWindow].click()
        app.buttons["openSettings"].click()
        app.buttons["clearHistory"].click()
        app.windows["设置"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.staticTexts["剪贴板还是空的"].waitForExistence(timeout: 3))
    }

    @MainActor func testDeleteAndSettingsPersistAcrossRelaunch() {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        app.menuItems["删除"].click()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history-")).count, 1)
        app.buttons["openSettings"].click()
        let field = app.textFields["historyLimit"]
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("8")
        app.terminate()
        app.launch()
        app.buttons["openSettings"].click()
        XCTAssertEqual(app.textFields["historyLimit"].value as? String, "8")
    }
}
