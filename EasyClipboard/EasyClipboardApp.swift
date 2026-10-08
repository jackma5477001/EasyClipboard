import SwiftUI
import AppKit

@main
struct EasyClipboardApp: App {
    @NSApplicationDelegateAdaptor(ClipboardAppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class ClipboardAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: ClipboardController?
    private var floatingPanels: FloatingPanelCoordinator?
    private let pasteCoordinator = PasteCoordinator()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var testWindow: NSWindow?
    private var testRoot: URL?
    private var pauseItem: NSMenuItem?
    private var observation: Any?
    private let arguments = ProcessInfo.processInfo.arguments
    private var isUITesting: Bool { arguments.contains("--ui-testing") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit-test hosts must never monitor or alter a user's actual clipboard/history.
        if !isUITesting && (NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil) { return }
        do {
            let root: URL
            let defaults: UserDefaults
            if isUITesting {
                NSApp.setActivationPolicy(.regular)
                root = argument("--test-root").map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("EasyClipboard-UI-\(UUID().uuidString)")
                testRoot = root
                defaults = UserDefaults(suiteName: argument("--test-suite") ?? "EasyClipboard.UITesting")!
            } else {
                NSApp.setActivationPolicy(.accessory)
                root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("EasyClipboard", isDirectory: true)
                defaults = .standard
            }
            let pasteboard: PasteboardClient = isUITesting ? PreviewPasteboard() : SystemPasteboard()
            let repository = try PersistenceController(root: root)
            let controller = try ClipboardController(pasteboard: pasteboard, repository: repository,
                                                     attachments: AttachmentManager(root: root.appendingPathComponent("Attachments")), defaults: defaults)
            self.controller = controller
            if isUITesting {
                if arguments.contains("--seed-history"), controller.entries.isEmpty {
                    let now = Date()
                    let fixtures = [
                        ClipboardEntry(id: UUID(), timestamp: now, fingerprint: "fixture-text", kind: .text, text: "周五前完成界面设计，整理测试结果。", files: []),
                        ClipboardEntry(id: UUID(), timestamp: now.addingTimeInterval(-120), fingerprint: "fixture-file", kind: .files,
                                       files: [ClipboardFile(originalURL: root.appendingPathComponent("界面草图.pdf"), byteCount: 2_400_000, isDirectory: false, copyFailed: false)])
                    ]
                    try repository.save(fixtures)
                    self.controller = try ClipboardController(pasteboard: pasteboard, repository: repository, attachments: controller.attachments, defaults: defaults)
                }
                if arguments.contains("--preview-panel"), let controller = self.controller {
                    NSApp.setActivationPolicy(.accessory)
                    configureApplication(controller)
                    floatingPanels?.showNearPointer()
                } else { showTestWindow() }
            } else {
                configureApplication(controller)
                controller.start()
            }
        } catch {
            // Use a separate attachment root, keeping an unreadable persistent store intact.
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("EasyClipboard-session-\(UUID().uuidString)")
            let controller = try? ClipboardController(pasteboard: isUITesting ? PreviewPasteboard() : SystemPasteboard(),
                repository: MemoryHistoryRepository(), attachments: AttachmentManager(root: fallback),
                defaults: isUITesting ? UserDefaults(suiteName: argument("--test-suite") ?? "EasyClipboard.UITesting")! : .standard)
            self.controller = controller
            controller?.message = "历史存储无法打开，本次仅在内存中记录：\(error.localizedDescription)"
            if let controller { configureApplication(controller); controller.start(); floatingPanels?.showNearPointer() }
        }
    }

    private func configureApplication(_ controller: ClipboardController) {
        floatingPanels = FloatingPanelCoordinator(controller: controller, pasteCoordinator: pasteCoordinator,
            onSelect: { [weak self] entry in self?.select(entry) }, openSettings: { [weak self] in self?.showSettings() })
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "EasyClipboard")
        let menu = NSMenu()
        menu.addItem(withTitle: "打开剪贴板", action: #selector(showHistory), keyEquivalent: "")
        let pause = menu.addItem(withTitle: "暂停记录", action: #selector(togglePause), keyEquivalent: "")
        pauseItem = pause
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "开启自动粘贴权限…", action: #selector(enableAccessibility), keyEquivalent: "")
        menu.addItem(withTitle: "清空历史", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 EasyClipboard", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        item.menu = menu
        statusItem = item
        observation = controller.$isPaused.sink { [weak self] paused in self?.pauseItem?.title = paused ? "继续记录" : "暂停记录" }
    }

    private func select(_ entry: ClipboardEntry) {
        let target = pasteCoordinator.target
        controller?.restore(entry) { [weak self] success in
            guard let self, success else { return }
            self.floatingPanels?.close()
            if !self.isUITesting, let message = self.pasteCoordinator.paste(to: target) {
                self.controller?.message = message
                self.showFallbackNotice(message)
            }
        }
    }

    private func showFallbackNotice(_ message: String) {
        // A transient, non-key notice is visible after the history panel has closed.
        guard let screen = NSScreen.main else { return }
        let panel = ClipboardPanel(contentRect: NSRect(x: screen.visibleFrame.maxX - 374, y: screen.visibleFrame.midY + 60, width: 350, height: 94),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: Text(message).font(.system(size: 12)).padding(16).frame(width: 350, height: 94)
            .background(VisualEffect()).clipShape(RoundedRectangle(cornerRadius: 12)).preferredColorScheme(.light))
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { panel.close() }
    }

    @objc private func showHistory() { floatingPanels?.showNearPointer() }
    @objc private func togglePause() { controller?.togglePause() }
    @objc private func clearHistory() { controller?.clear() }
    @objc private func enableAccessibility() { pasteCoordinator.requestPermission() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        guard let controller else { return }
        floatingPanels?.close()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 170), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "设置"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: ClipboardSettingsView(controller: controller))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showTestWindow() {
        guard let controller else { return }
        let available = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let window = NSWindow(contentRect: ClipboardPanelLayout.frame(in: available, itemCount: controller.entries.count), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "EasyClipboard"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(controller: controller, onSelect: { [weak self] in self?.select($0) }, openSettings: { [weak self] in self?.showSettings() }))
        window.center()
        testWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func argument(_ key: String) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop(); floatingPanels?.stop() }
}

@MainActor
private final class PreviewPasteboard: PasteboardClient {
    var changeCount = 0
    var payload: ClipboardPayload?
    var currentFileURLs: [URL] { if case .files(let urls) = payload { return urls }; return [] }
    func read() -> ClipboardPayload? { payload }
    func write(_ payload: ClipboardPayload) -> Bool { self.payload = payload; changeCount += 1; return true }
}
