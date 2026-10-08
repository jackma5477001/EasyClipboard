import AppKit
import SwiftUI

final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var hoverChanged: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
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
    private var tabs: [String: ClipboardPanel] = [:]
    private var panel: ClipboardPanel?
    private var activeScreen: String?
    private var hoveredAreas = Set<String>()
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var notifications: [NSObjectProtocol] = []

    init(controller: ClipboardController, pasteCoordinator: PasteCoordinator,
         onSelect: @escaping (ClipboardEntry) -> Void, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.pasteCoordinator = pasteCoordinator
        self.onSelect = onSelect
        self.openSettings = openSettings
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildTabs() }
        })
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reorderTabs() }
        })
        rebuildTabs()
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
        hoveredAreas.removeAll()
        for tab in tabs.values { tab.close() }
        tabs.removeAll()
        for screen in NSScreen.screens {
            let id = screenID(screen)
            let frame = screen.visibleFrame
            let tab = makePanel(frame: NSRect(x: frame.maxX - 14, y: frame.midY - 44, width: 14, height: 88))
            let host = HoverHostingView(rootView: EdgeTab { [weak self] in self?.show(on: screen) })
            host.hoverChanged = { [weak self] inside in self?.hover(inside, area: "\(id):tab", screen: screen, isTab: true) }
            tab.contentView = host
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
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main { show(on: screen) }
    }

    private func show(on screen: NSScreen) {
        closeWork?.cancel()
        openWork?.cancel()
        let id = screenID(screen)
        if activeScreen == id, panel != nil { return }
        panel?.close()
        activeScreen = id
        pasteCoordinator.rememberTarget()
        let available = screen.visibleFrame
        let width = min(360, max(200, available.width - 14))
        let height = min(680, available.height - 24)
        let window = makePanel(frame: NSRect(x: available.maxX - width - 14, y: available.midY - height / 2, width: width, height: height))
        let host = HoverHostingView(rootView: ContentView(controller: controller, onSelect: onSelect, openSettings: openSettings))
        host.hoverChanged = { [weak self] inside in self?.hover(inside, area: "\(id):panel", screen: screen, isTab: false) }
        window.contentView = host
        window.orderFrontRegardless()
        panel = window
    }

    private func hover(_ inside: Bool, area: String, screen: NSScreen, isTab: Bool) {
        if inside {
            hoveredAreas.insert(area)
            closeWork?.cancel()
            if isTab, activeScreen != screenID(screen) {
                openWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.hoveredAreas.contains(area) else { return }
                    self.show(on: screen)
                }
                openWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        } else {
            hoveredAreas.remove(area)
            if isTab { openWork?.cancel() }
            guard let activeScreen, !hoveredAreas.contains(where: { $0.hasPrefix(activeScreen + ":") }) else { return }
            closeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let id = self.activeScreen,
                      !self.hoveredAreas.contains(where: { $0.hasPrefix(id + ":") }) else { return }
                self.close()
            }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    func close() {
        openWork?.cancel()
        closeWork?.cancel()
        panel?.close()
        panel = nil
        if let activeScreen { hoveredAreas.remove(activeScreen + ":panel") }
        activeScreen = nil
    }

    func stop() {
        close()
        for tab in tabs.values { tab.close() }
        tabs.removeAll()
        for token in notifications {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notifications.removeAll()
    }
}
