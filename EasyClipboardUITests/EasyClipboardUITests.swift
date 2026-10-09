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
        XCTAssertFalse(app.staticTexts["文字"].exists)
        XCTAssertLessThan(app.buttons["周五前完成界面设计，整理测试结果。"].frame.height, 72)
        let attachment = XCTAttachment(screenshot: app.windows["EasyClipboard"].screenshot())
        attachment.name = "EasyClipboard-历史"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["pauseRecording"].click()
        XCTAssertTrue(app.staticTexts["记录已暂停，可拖入文件"].exists)
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

    @MainActor func testHoverDeleteKeepsRowHeightAndFollowingEntryPosition() {
        let title = "周五前完成界面设计，整理测试结果。"
        let row = app.buttons[title]
        let following = app.buttons["界面草图.pdf"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.staticTexts["appTitle"].hover()
        let original = row.frame
        let followingOrigin = following.frame.minY

        row.hover()
        let delete = app.buttons["删除\(title)"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        XCTAssertEqual(row.frame.height, original.height, accuracy: 0.5)
        XCTAssertEqual(following.frame.minY, followingOrigin, accuracy: 0.5)
        let attachment = XCTAttachment(screenshot: app.windows["EasyClipboard"].screenshot())
        attachment.name = "EasyClipboard-悬停删除"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.staticTexts["appTitle"].hover()
        XCTAssertFalse(delete.exists)
        XCTAssertEqual(row.frame.height, original.height, accuracy: 0.5)
        row.hover()
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.click()
        XCTAssertFalse(row.exists)
        XCTAssertTrue(following.exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history-")).count, 1)
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

    @MainActor func testFileDragImportsWhilePausedAndPersists() throws {
        app.terminate()
        let file = root.appendingPathComponent("拖入测试.txt")
        try Data("拖入文件的内容".utf8).write(to: file)
        app.launchArguments += ["--drag-test-file", file.path]
        app.launch()
        let source = app.staticTexts["dragTestFile"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        app.buttons["pauseRecording"].click()
        let destination = app.scrollViews["historyList"]
        source.press(forDuration: 0.5, thenDragTo: destination)
        XCTAssertTrue(app.buttons["拖入测试.txt"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["historyCount"].label, "3 / 20")
        app.terminate()
        try FileManager.default.removeItem(at: file)
        app.launchArguments.removeLast(2)
        app.launch()
        XCTAssertTrue(app.buttons["拖入测试.txt"].waitForExistence(timeout: 5))
    }
}
