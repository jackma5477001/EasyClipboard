import AppKit
import ApplicationServices

@MainActor
final class PasteCoordinator {
    private(set) var target: NSRunningApplication?
    private let frontmost: () -> NSRunningApplication?
    private let trusted: () -> Bool
    private let requestAccess: () -> Void
    private let postPaste: @MainActor (pid_t) -> Bool
    private var prompted = false

    init(frontmost: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
         trusted: @escaping () -> Bool = { AXIsProcessTrusted() && CGPreflightPostEventAccess() },
         requestAccess: @escaping () -> Void = {
             let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
             _ = AXIsProcessTrustedWithOptions(options)
         }, postPaste: @escaping @MainActor (pid_t) -> Bool = PasteCoordinator.postCommandV) {
        self.frontmost = frontmost
        self.trusted = trusted
        self.requestAccess = requestAccess
        self.postPaste = postPaste
    }

    func rememberTarget() {
        let app = frontmost()
        target = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    }
    func requestPermission() { prompted = true; requestAccess() }

    /// Never changes the active app. A failure leaves content on the clipboard for manual paste.
    func paste(to rememberedTarget: NSRunningApplication?) -> String? {
        guard let target = rememberedTarget, !target.isTerminated,
              frontmost()?.processIdentifier == target.processIdentifier else {
            return "内容已复制，目标应用已切换，请在需要的位置按 Command+V。"
        }
        guard trusted() else {
            if !prompted { requestPermission() }
            return "内容已复制。请按 Command+V 粘贴；开启辅助功能权限后可自动粘贴。"
        }
        guard postPaste(target.processIdentifier) else { return "内容已复制，请按 Command+V 粘贴。" }
        return nil
    }

    private static func postCommandV(_ pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}
