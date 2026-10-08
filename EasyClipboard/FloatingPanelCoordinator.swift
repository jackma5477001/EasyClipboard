import AppKit
import SwiftUI
import Combine

final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Short histories stay compact; longer histories scroll within the screen's available bounds.
struct ClipboardPanelLayout {
    static func frame(in available: NSRect, itemCount: Int, hasMessage: Bool = false) -> NSRect {
        let count = min(max(itemCount, 0), 5)
        let contentHeight = count == 0 ? 240 : max(220, 128 + CGFloat(count) * 88 + CGFloat(max(count - 1, 0)) * 8)
        let width = min(280, max(0, available.width - 14))
        let height = min(480, max(0, available.height - 24), contentHeight + (hasMessage ? 70 : 0))
        return NSRect(x: available.maxX - width - 14, y: available.midY - height / 2, width: width, height: height)
    }
}

private struct EdgeTab: View {
    var open: () -> Void
    var body: some View {
        Button(action: open) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.2, green: 0.28, blue: 0.35))
                .frame(width: 14, height: 88)
                .background(VisualEffect())
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7))
        }
        .buttonStyle(.plain).help("剪贴板历史").accessibilityLabel("展开剪贴板历史")
    }
}

@MainActor
final class FloatingPanelCoordinator {
    private let controller: ClipboardController
    private let pasteCoordinator: PasteCoordinator
    private let onSelect: (ClipboardEntry) -> Void
    private let openSettings: () -> Void
    private let pointerLocation: () -> NSPoint
    private var tabs: [String: ClipboardPanel] = [:]
    private var panel: ClipboardPanel?
    private var activeScreen: String?
    private var closeWork: DispatchWorkItem?
    private var pointerTimer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    var isVisible: Bool { panel?.isVisible == true }

    init(controller: ClipboardController, pasteCoordinator: PasteCoordinator,
         onSelect: @escaping (ClipboardEntry) -> Void, openSettings: @escaping () -> Void,
         pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }) {
        self.controller = controller
        self.pasteCoordinator = pasteCoordinator
        self.onSelect = onSelect
        self.openSettings = openSettings
        self.pointerLocation = pointerLocation
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildTabs() }
        })
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reorderTabs() }
        })
        rebuildTabs()
        controller.$entries.combineLatest(controller.$message).sink { [weak self] entries, message in
            self?.resizePanel(itemCount: entries.count, hasMessage: message != nil)
        }.store(in: &subscriptions)
        // Geometry remains reliable when SwiftUI child views replace their tracking areas.
        // Reading pointer position does not require an input-monitoring event tap.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPointerRegion() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func screenID(_ screen: NSScreen) -> String { String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? screen) }

    private func makePanel(frame: NSRect) -> ClipboardPanel {
        let panel = ClipboardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .aqua)
        panel.hasShadow = true
        panel.isMovable = false
        return panel
    }

    private func rebuildTabs() {
        close()
        for tab in tabs.values { tab.close() }
        tabs.removeAll()
        for screen in NSScreen.screens {
            let id = screenID(screen)
            let frame = screen.visibleFrame
            let tab = makePanel(frame: NSRect(x: frame.maxX - 14, y: frame.midY - 44, width: 14, height: 88))
            tab.contentView = NSHostingView(rootView: EdgeTab { [weak self] in self?.show(on: screen) })
            tab.hasShadow = false
            tab.orderFrontRegardless()
            tabs[id] = tab
        }
    }

    private func reorderTabs() {
        close()
        for tab in tabs.values { tab.orderFrontRegardless() }
    }

    func showNearPointer() {
        let point = pointerLocation()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main { show(on: screen) }
    }

    private func show(on screen: NSScreen) {
        closeWork?.cancel()
        closeWork = nil
        let id = screenID(screen)
        if activeScreen == id, panel != nil { return }
        panel?.close()
        activeScreen = id
        pasteCoordinator.rememberTarget()
        let window = makePanel(frame: ClipboardPanelLayout.frame(in: screen.visibleFrame, itemCount: controller.entries.count, hasMessage: controller.message != nil))
        window.contentView = NSHostingView(rootView: ContentView(controller: controller, onSelect: onSelect, openSettings: openSettings))
        window.orderFrontRegardless()
        panel = window
    }

    private func resizePanel(itemCount: Int, hasMessage: Bool) {
        guard let panel, let screen = NSScreen.screens.first(where: { screenID($0) == activeScreen }) else { return }
        panel.setFrame(ClipboardPanelLayout.frame(in: screen.visibleFrame, itemCount: itemCount, hasMessage: hasMessage), display: true)
    }

    func checkPointerRegion() {
        let point = pointerLocation()
        // A small margin around the visible tab makes approaching it easy, without capturing clicks.
        if let screen = NSScreen.screens.first(where: { tabs[screenID($0)]?.frame.insetBy(dx: -8, dy: -8).contains(point) == true }) {
            show(on: screen)
            return
        }
        guard let panel else { return }
        if panel.frame.contains(point) {
            closeWork?.cancel()
            closeWork = nil
            return
        }
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            let currentPoint = self.pointerLocation()
            let inTab = self.activeScreen.flatMap { self.tabs[$0] }?.frame.insetBy(dx: -8, dy: -8).contains(currentPoint) == true
            self.closeWork = nil
            if !panel.frame.contains(currentPoint), !inTab { self.close() }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func close() {
        closeWork?.cancel()
        closeWork = nil
        panel?.close()
        panel = nil
        activeScreen = nil
    }

    func stop() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        close()
        for tab in tabs.values { tab.close() }
        tabs.removeAll()
        subscriptions.removeAll()
        for token in notifications {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notifications.removeAll()
    }
}
