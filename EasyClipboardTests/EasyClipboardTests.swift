import AppKit
import CoreData
import SwiftUI
import Testing
@testable import EasyClipboard

@MainActor
@Suite(.serialized)
struct EasyClipboardTests {
    @Test func defaultLimitAndSettingsSurviveRelaunch() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        #expect(env.controller.limit == 20)
        env.controller.setLimit(7)
        await env.controller.waitUntilIdle()
        let reopened = try env.makeController()
        #expect(reopened.limit == 7)
        reopened.setLimit(0)
        #expect(reopened.limit == 7)
    }

    @Test func newestFirstAndDuplicatesMoveToFront() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        await env.copy(.text("第一条"))
        await env.copy(.text("第二条"))
        await env.copy(.text("第一条"))
        #expect(env.controller.entries.map(\.text) == ["第一条", "第二条"])
        #expect(try env.repository.load().count == 2)
    }

    @Test func capacityTrimsOldestAndReducingLimitActsImmediately() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        for index in 0..<22 { await env.copy(.text("内容\(index)")) }
        #expect(env.controller.entries.count == 20)
        #expect(env.controller.entries.last?.text == "内容2")
        env.controller.setLimit(3)
        await env.controller.waitUntilIdle()
        #expect(env.controller.entries.map(\.text) == ["内容21", "内容20", "内容19"])
        #expect(try env.repository.load().count == 3)
    }

    @Test func ownRestorationDoesNotRecordAgain() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        await env.copy(.text("粘贴我"))
        let entry = try #require(env.controller.entries.first)
        var success = false
        env.controller.restore(entry) { success = $0 }
        await env.controller.waitUntilIdle()
        await env.controller.poll()
        #expect(success)
        #expect(env.board.payload == .text("粘贴我"))
        #expect(env.controller.entries == [entry])
    }

    @Test func pausedCopiesAreSkippedAndResumeRecordsNewCopies() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        env.controller.togglePause()
        await env.copy(.text("暂停时复制"))
        env.controller.togglePause()
        await env.controller.poll()
        #expect(env.controller.entries.isEmpty)
        await env.copy(.text("恢复后复制"))
        #expect(env.controller.entries.first?.text == "恢复后复制")
    }

    @Test func emptyAndUnsupportedPayloadsDoNotCreateEntries() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        await env.copy(nil)
        #expect(env.controller.entries.isEmpty)
    }

    @Test func textRowsFitContentsAndLimitLongPreviewsWithoutChangingPaste() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        func height(for text: String) -> CGFloat {
            let entry = ClipboardEntry(id: UUID(), timestamp: Date(), fingerprint: "layout", kind: .text, text: text, files: [])
            let host = NSHostingView(rootView: ClipboardRow(entry: entry, attachments: env.attachments).frame(width: 240))
            return host.fittingSize.height
        }
        let single = height(for: "EasyClipboard")
        let multiple = height(for: "第一行\n第二行\n第三行")
        let original = "  开头保留空格\n" + String(repeating: "完整原文仍然可以粘贴。\n", count: 30) + "  "
        let long = height(for: original)
        #expect(single < 72)
        #expect(single < multiple)
        #expect(multiple < long)
        #expect(long <= 120)
        await env.copy(.text(original))
        env.controller.restore(try #require(env.controller.entries.first)) { #expect($0) }
        await env.controller.waitUntilIdle()
        #expect(env.board.payload == .text(original))
    }

    @Test func droppedFilesPersistWhilePausedAndRestoreSavedCopies() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        await env.copy(.text("原剪贴板内容"))
        env.controller.togglePause()
        let first = try env.file("拖入的说明.txt", size: 16)
        let second = try env.file("拖入的图片.png", size: 24)
        let folder = env.root.appendingPathComponent("拖入的文件夹")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let before = env.board.changeCount
        #expect(env.controller.addFiles([first, second, folder]))
        await env.controller.waitUntilIdle()
        let entry = try #require(env.controller.entries.first)
        #expect(entry.kind == .files)
        #expect(entry.files.map(\.originalURL) == [first, second, folder])
        #expect(entry.files[0].relativeCopyPath != nil)
        #expect(entry.files[1].relativeCopyPath != nil)
        #expect(entry.files[2].isDirectory)
        #expect(entry.files[2].relativeCopyPath == nil)
        #expect(env.board.changeCount == before)
        #expect(env.board.payload == .text("原剪贴板内容"))
        #expect(try env.makeController().entries.first == entry)
        try FileManager.default.removeItem(at: first)
        env.controller.restore(entry) { #expect($0) }
        await env.controller.waitUntilIdle()
        guard case .files(let urls) = env.board.payload else { Issue.record("应恢复拖入的文件"); return }
        #expect(urls.count == 3)
        #expect(FileManager.default.isReadableFile(atPath: urls[0].path))
    }

    @Test func droppedFilesShareDeduplicationAndHistoryLimitWithCopiedFiles() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let source = try env.file("同一个文件.txt", size: 16)
        await env.copy(.files([source]))
        await env.copy(.text("第二条"))
        env.controller.addFiles([source])
        await env.controller.waitUntilIdle()
        #expect(env.controller.entries.count == 2)
        #expect(env.controller.entries.first?.files.first?.originalURL == source)
        env.controller.setLimit(1)
        let next = try env.file("新文件.txt", size: 16)
        env.controller.addFiles([next])
        await env.controller.waitUntilIdle()
        #expect(env.controller.entries.count == 1)
        #expect(env.controller.entries.first?.files.first?.originalURL == next)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func invalidDropsAndFailedImportsKeepExistingHistory() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        await env.copy(.text("保留历史"))
        let before = env.controller.entries
        #expect(!env.controller.addFiles([]))
        #expect(!env.controller.addFiles([URL(string: "https://example.com/file.txt")!]))
        let source = try env.file("可用.txt", size: 16)
        env.controller.addFiles([source, env.root.appendingPathComponent("不存在.txt")])
        await env.controller.waitUntilIdle()
        #expect(env.controller.entries == before)
        #expect(env.controller.message?.contains("不存在.txt") == true)
        env.repository.failSave = true
        env.controller.addFiles([source])
        await env.controller.waitUntilIdle()
        #expect(env.controller.entries == before)
        #expect(env.controller.message?.contains("磁盘写入失败") == true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: env.attachments.root.path).isEmpty) == true)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func imageDataRoundTripsAndMissingImageIsReported() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let bytes = try #require(NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.tiffRepresentation)
        await env.copy(.image(bytes, type: NSPasteboard.PasteboardType.tiff.rawValue))
        let entry = try #require(env.controller.entries.first)
        #expect(entry.kind == .image)
        #expect(try await env.attachments.payload(for: entry) == .image(bytes, type: NSPasteboard.PasteboardType.tiff.rawValue))
        let url = try env.attachments.attachmentURL(try #require(entry.imagePath))
        try FileManager.default.removeItem(at: url)
        env.controller.restore(entry) { #expect(!$0) }
        await env.controller.waitUntilIdle()
        #expect(env.controller.message?.contains("图片") == true)
    }

    @Test func perFileThresholdAndFoldersAlwaysReferenceSource() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let below = try env.file("小文件.bin", size: AttachmentManager.copyThreshold - 1)
        let exact = try env.file("临界文件.bin", size: AttachmentManager.copyThreshold)
        let above = try env.file("大文件.bin", size: AttachmentManager.copyThreshold + 1)
        let directory = env.root.appendingPathComponent("文件夹")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await env.copy(.files([below, exact, above, directory]))
        let entry = try #require(env.controller.entries.first)
        #expect(entry.files.count == 4)
        #expect(entry.files[0].relativeCopyPath != nil)
        #expect(entry.files[1].relativeCopyPath == nil)
        #expect(entry.files[2].relativeCopyPath == nil)
        #expect(entry.files[3].isDirectory)
        #expect(entry.files[3].relativeCopyPath == nil)
        let copy = try env.attachments.attachmentURL(try #require(entry.files[0].relativeCopyPath))
        #expect(copy.lastPathComponent == below.lastPathComponent)
    }

    @Test func copiedFileWorksAfterOriginalIsDeleted() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let source = try env.file("说明.txt", size: 16)
        await env.copy(.files([source]))
        let entry = try #require(env.controller.entries.first)
        try FileManager.default.removeItem(at: source)
        guard case .files(let urls) = try await env.attachments.payload(for: entry) else { Issue.record("应恢复文件"); return }
        #expect(urls.count == 1)
        #expect(FileManager.default.isReadableFile(atPath: urls[0].path))
    }

    @Test func missingSourcePreventsPartialMultiFilePaste() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let small = try env.file("保留.txt", size: 16)
        let large = try env.file("失效.bin", size: AttachmentManager.copyThreshold)
        await env.copy(.files([small, large]))
        let entry = try #require(env.controller.entries.first)
        try FileManager.default.removeItem(at: large)
        let before = env.board.changeCount
        env.controller.restore(entry) { #expect(!$0) }
        await env.controller.waitUntilIdle()
        #expect(env.board.changeCount == before)
        #expect(env.controller.message?.contains("失效.bin") == true)
    }

    @Test func failedCopyFallsBackToSourceAndSourceIsNeverDeleted() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let blockedRoot = try env.file("不可写入附件目录", size: 1)
        let manager = AttachmentManager(root: blockedRoot)
        let source = try env.file("原文件.txt", size: 12)
        let entry = try await manager.prepare(.files([source]))
        #expect(entry.files[0].relativeCopyPath == nil)
        #expect(entry.files[0].copyFailed)
        #expect(try await manager.payload(for: entry) == .files([source]))
        await manager.cleanup(retaining: [], protectedURLs: [])
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func cleanupProtectsClipboardCopiesUntilClipboardChanges() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let source = try env.file("副本.txt", size: 12)
        await env.copy(.files([source]))
        let entry = try #require(env.controller.entries.first)
        let copy = try env.attachments.attachmentURL(try #require(entry.files[0].relativeCopyPath))
        env.controller.restore(entry) { #expect($0) }
        await env.controller.waitUntilIdle()
        env.controller.clear()
        await env.controller.waitUntilIdle()
        #expect(env.controller.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        await env.copy(.text("新的剪贴板内容"))
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func pathTraversalAndSymlinkEscapeAreRejected() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        #expect(throws: (any Error).self) { try env.attachments.attachmentURL("../原文件") }
        try FileManager.default.createDirectory(at: env.attachments.root, withIntermediateDirectories: true)
        let escape = env.attachments.root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: env.root)
        #expect(throws: (any Error).self) { try env.attachments.attachmentURL("escape/原文件") }
    }

    @Test func coreDataPersistsAcrossStoreReopen() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let location = env.root.appendingPathComponent("Persistent")
        var store: PersistenceController? = try PersistenceController(root: location)
        let entry = try await env.attachments.prepare(.text("重启后保留"))
        try store?.save([entry])
        for persistent in store!.container.persistentStoreCoordinator.persistentStores {
            try store!.container.persistentStoreCoordinator.remove(persistent)
        }
        store = nil
        let reopened = try PersistenceController(root: location)
        #expect(try reopened.load() == [entry])
    }

    @Test func persistenceFailureKeepsPreviousHistoryAndReportsError() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        await env.copy(.text("已保存"))
        env.repository.failSave = true
        await env.copy(.text("写入失败"))
        #expect(env.controller.entries.map(\.text) == ["已保存"])
        #expect(env.controller.message?.contains("操作失败") == true)
    }

    @Test func originalTemplateStoreMigratesWithoutLosingAccess() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let location = env.root.appendingPathComponent("Migration")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        let modelDirectory = try #require(Bundle.main.url(forResource: "EasyClipboard", withExtension: "momd"))
        let oldModel = try #require(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("EasyClipboard.mom")))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: location.appendingPathComponent("History.sqlite"))
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let item = NSEntityDescription.insertNewObject(forEntityName: "Item", into: context)
        item.setValue(Date(), forKey: "timestamp")
        try context.save()
        try coordinator.remove(store)
        let migrated = try PersistenceController(root: location)
        #expect(try migrated.load().isEmpty)
        let entry = try await env.attachments.prepare(.text("迁移后记录"))
        try migrated.save([entry])
        #expect(try migrated.load() == [entry])
    }

    @Test func restoreFailureIsReportedWithoutPretendingSuccess() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        await env.copy(.text("内容"))
        env.board.failWrite = true
        env.controller.restore(try #require(env.controller.entries.first)) { #expect(!$0) }
        await env.controller.waitUntilIdle()
        #expect(env.controller.message?.contains("系统剪贴板") == true)
    }

    @Test func pastePermissionAndTargetChangesNeverPostToWrongApplication() {
        let target = NSRunningApplication.current
        var front: NSRunningApplication? = target
        var permission = false
        var requests = 0
        var posted: [pid_t] = []
        let coordinator = PasteCoordinator(frontmost: { front }, trusted: { permission }, requestAccess: { requests += 1 }, postPaste: { posted.append($0); return true })
        #expect(coordinator.paste(to: target)?.contains("辅助功能") == true)
        #expect(coordinator.paste(to: target) != nil)
        #expect(requests == 1)
        #expect(posted.isEmpty)
        permission = true
        #expect(coordinator.paste(to: target) == nil)
        #expect(posted == [target.processIdentifier])
        front = nil
        #expect(coordinator.paste(to: target)?.contains("切换") == true)
        #expect(posted.count == 1)
    }

    @Test func nativePasteboardRecognizesFilesBeforeImageAndText() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let client = SystemPasteboard(board)
        let file = URL(fileURLWithPath: "/private/tmp/例子.png")
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setString("文本表示", forType: .string)
        item.setData(Data([1, 2, 3]), forType: .png)
        board.writeObjects([item])
        #expect(client.read() == .files([file]))
        board.clearContents()
        board.setData(Data([4, 5]), forType: .png)
        board.setString("文本表示", forType: .string)
        #expect(client.read() == .image(Data([4, 5]), type: NSPasteboard.PasteboardType.png.rawValue))
        board.clearContents()
        #expect(client.write(.text("  保留空白\n")))
        #expect(client.read() == .text("  保留空白\n"))
        board.clearContents()
        board.setString("", forType: .string)
        #expect(client.read() == nil)
    }

    @Test func compactPanelFitsShortHistoryAndScreenBounds() {
        let screen = NSRect(x: -1280, y: -200, width: 1280, height: 800)
        let single = ClipboardPanelLayout.frame(in: screen, itemCount: 1)
        let several = ClipboardPanelLayout.frame(in: screen, itemCount: 3)
        let many = ClipboardPanelLayout.frame(in: screen, itemCount: 20)
        #expect(single.width == 280)
        #expect(single.height <= 240)
        #expect(single.height < several.height)
        #expect(many.height <= 480)
        #expect(screen.contains(single))
        #expect(screen.contains(many))
        let shortScreen = NSRect(x: 0, y: 0, width: 640, height: 300)
        #expect(shortScreen.contains(ClipboardPanelLayout.frame(in: shortScreen, itemCount: 20, hasMessage: true)))
    }

    @Test func hostedPanelStaysCenteredAndHeightLimitedAsContentChanges() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let screen = try #require(NSScreen.screens.first)
        let available = screen.visibleFrame
        let point = NSPoint(x: available.maxX - 7, y: available.midY)
        let coordinator = FloatingPanelCoordinator(controller: env.controller, pasteCoordinator: PasteCoordinator(),
            onSelect: { _ in }, openSettings: {}, pointerLocation: { point })
        defer { coordinator.stop() }

        for index in 0..<13 {
            await env.copy(.text("条目\(index)\n" + String(repeating: "较长的历史内容应在面板内滚动。\n", count: 12)))
        }
        env.controller.message = "内容已复制。请按 Command+V 粘贴；开启辅助功能权限后可自动粘贴。"
        coordinator.showNearPointer()
        let panel = try #require(NSApp.windows.first {
            $0 is ClipboardPanel && $0.contentView is NSHostingView<ContentView>
        })

        func expectFrame(itemCount: Int, hasMessage: Bool) {
            let expected = ClipboardPanelLayout.frame(in: available, itemCount: itemCount, hasMessage: hasMessage)
            #expect(abs(panel.frame.height - expected.height) < 0.5)
            #expect(panel.frame.height <= 480)
            // AppKit rounds the window origin to screen pixels.
            #expect(abs(panel.frame.midY - available.midY) <= 0.5)
            #expect(panel.maxSize.height <= 480)
            #expect(abs(panel.frame.maxX - (available.maxX - 14)) < 0.5)
            #expect(available.contains(panel.frame))
            #expect(panel.contentView?.frame.size == panel.frame.size)
        }
        try await Task.sleep(for: .milliseconds(150))
        panel.contentView?.layoutSubtreeIfNeeded()
        expectFrame(itemCount: 13, hasMessage: true)

        env.controller.message = nil
        env.controller.setLimit(1)
        await env.controller.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(150))
        panel.contentView?.layoutSubtreeIfNeeded()
        expectFrame(itemCount: 1, hasMessage: false)

        env.controller.clear()
        await env.controller.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(150))
        panel.contentView?.layoutSubtreeIfNeeded()
        expectFrame(itemCount: 0, hasMessage: false)
    }

    @Test func approachingTabOpensAndLeavingClosesWithReentryGrace() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let screen = try #require(NSScreen.screens.first)
        let frame = screen.visibleFrame
        // Just outside the visible tab, within its approach margin.
        var point = NSPoint(x: frame.maxX - 18, y: frame.midY)
        let coordinator = FloatingPanelCoordinator(controller: env.controller, pasteCoordinator: PasteCoordinator(),
            onSelect: { _ in }, openSettings: {}, pointerLocation: { point })
        defer { coordinator.stop() }
        let previousKeyWindow = NSApp.keyWindow
        coordinator.checkPointerRegion()
        #expect(coordinator.isVisible)
        #expect(NSApp.keyWindow === previousKeyWindow)
        point = NSPoint(x: frame.minX + 20, y: frame.minY + 20)
        coordinator.checkPointerRegion()
        #expect(coordinator.isVisible)
        try await Task.sleep(for: .milliseconds(150))
        let panelFrame = ClipboardPanelLayout.frame(in: frame, itemCount: 0)
        point = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
        coordinator.checkPointerRegion()
        try await Task.sleep(for: .milliseconds(220))
        #expect(coordinator.isVisible)
        point = NSPoint(x: frame.minX + 20, y: frame.minY + 20)
        coordinator.checkPointerRegion()
        try await Task.sleep(for: .milliseconds(360))
        #expect(!coordinator.isVisible)
    }
}

@MainActor
private final class TestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let board = FakePasteboard()
    let repository = FakeRepository()
    let attachments: AttachmentManager
    var controller: ClipboardController!
    init() throws {
        suite = "EasyClipboard.Tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EasyClipboard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        attachments = AttachmentManager(root: root.appendingPathComponent("Attachments"))
        controller = try makeController()
    }
    func makeController() throws -> ClipboardController { try ClipboardController(pasteboard: board, repository: repository, attachments: attachments, defaults: defaults) }
    func copy(_ payload: ClipboardPayload?) async { board.payload = payload; board.changeCount += 1; await controller.poll() }
    func file(_ name: String, size: Int64) throws -> URL {
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }
    func cleanup() {
        controller.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class FakePasteboard: PasteboardClient {
    var changeCount = 0
    var payload: ClipboardPayload?
    var failWrite = false
    var currentFileURLs: [URL] { if case .files(let urls) = payload { return urls }; return [] }
    func read() -> ClipboardPayload? { payload }
    func write(_ payload: ClipboardPayload) -> Bool {
        guard !failWrite else { return false }
        self.payload = payload
        changeCount += 1
        return true
    }
}

@MainActor
private final class FakeRepository: HistoryRepository {
    var entries: [ClipboardEntry] = []
    var failSave = false
    func load() throws -> [ClipboardEntry] { entries }
    func save(_ entries: [ClipboardEntry]) throws {
        if failSave { throw NSError(domain: "TestStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "磁盘写入失败"]) }
        self.entries = entries
    }
}
