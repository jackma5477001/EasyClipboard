import XCTest

final class EasyClipboardUITestsLaunchTests: XCTestCase {
    @MainActor func testEmptyStateScreenshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EasyClipboard-UI-empty-\(UUID().uuidString)")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--test-root", root.path, "--test-suite", "EasyClipboard.UI.Empty"]
        app.launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: "EasyClipboard.UI.Empty")?.removePersistentDomain(forName: "EasyClipboard.UI.Empty")
        }
        XCTAssertTrue(app.staticTexts["剪贴板还是空的"].waitForExistence(timeout: 5))
        let settings = app.buttons["openSettings"]
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(app.windows["EasyClipboard"].frame.contains(settings.frame), "空状态的设置按钮应完整显示")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "EasyClipboard-空状态"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
