import AppKit
import Combine

@MainActor
final class ClipboardController: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry]
    @Published private(set) var limit: Int
    @Published private(set) var isPaused = false
    @Published private(set) var isBusy = false
    @Published var message: String?
    let attachments: AttachmentManager
    private let pasteboard: PasteboardClient
    private let repository: HistoryRepository
    private let defaults: UserDefaults
    private var timer: Timer?
    private var lastObservedChange: Int?
    private var tail: Task<Void, Never>?
    private var pendingOperations = 0
    static let limitKey = "historyLimit"

    init(pasteboard: PasteboardClient, repository: HistoryRepository, attachments: AttachmentManager, defaults: UserDefaults = .standard) throws {
        self.pasteboard = pasteboard
        self.repository = repository
        self.attachments = attachments
        self.defaults = defaults
        let stored = defaults.integer(forKey: Self.limitKey)
        limit = stored > 0 ? stored : 20
        entries = try repository.load().sorted { $0.timestamp > $1.timestamp }
    }

    func start() {
        guard timer == nil else { return }
        enqueue { controller in await controller.trimAndClean(); await controller.poll() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Unchanged clipboard checks must not flash the footer's busy indicator.
                guard let self, !self.isBusy,
                      self.pasteboard.changeCount != self.lastObservedChange else { return }
                self.enqueue { await $0.poll() }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func togglePause() {
        isPaused.toggle()
        // Contents copied while paused are intentionally not recorded when resuming.
        lastObservedChange = pasteboard.changeCount
    }

    func setLimit(_ value: Int) {
        guard value > 0 else { return }
        limit = value
        defaults.set(value, forKey: Self.limitKey)
        enqueue { await $0.trimAndClean() }
    }

    func delete(_ entry: ClipboardEntry) {
        enqueue { controller in
            do {
                try controller.commit(controller.entries.filter { $0.id != entry.id })
                await controller.clean()
            } catch { controller.report(error) }
        }
    }

    func clear() {
        enqueue { controller in
            do { try controller.commit([]); await controller.clean() }
            catch { controller.report(error) }
        }
    }

    /// Explicit imports remain available while automatic clipboard recording is paused.
    @discardableResult
    func addFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        enqueue { controller in
            let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                let unavailable = urls.filter { !FileManager.default.isReadableFile(atPath: $0.path) }
                guard unavailable.isEmpty else { throw ClipboardFailure.unavailableFiles(unavailable.map(\.lastPathComponent)) }
                try await controller.record(.files(urls))
            } catch { controller.report(error) }
            await controller.clean()
        }
        return true
    }

    func restore(_ entry: ClipboardEntry, completion: @escaping (Bool) -> Void) {
        enqueue { controller in
            do {
                let payload = try await controller.attachments.payload(for: entry)
                guard controller.pasteboard.write(payload) else { throw ClipboardFailure.writeFailed }
                controller.lastObservedChange = controller.pasteboard.changeCount
                completion(true)
            } catch { controller.report(error); completion(false) }
        }
    }

    // Serialization prevents cleanup racing with new attachments or persistence operations.
    private func enqueue(_ work: @escaping @MainActor (ClipboardController) async -> Void) {
        let previous = tail
        pendingOperations += 1
        isBusy = true
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
            self.pendingOperations -= 1
            self.isBusy = self.pendingOperations > 0
        }
    }

    func waitUntilIdle() async { await tail?.value }

    /// Exposed internally for deterministic tests; production calls it from the serial queue.
    func poll() async {
        let change = pasteboard.changeCount
        guard change != lastObservedChange else { return }
        if isPaused { lastObservedChange = change; await clean(); return }
        guard let payload = pasteboard.read() else { lastObservedChange = change; await clean(); return }
        // Avoid mixing representations from two clipboard owners.
        guard pasteboard.changeCount == change else { return }
        do {
            try await record(payload)
            lastObservedChange = change
            await clean()
        } catch {
            lastObservedChange = change
            report(error)
            await clean()
        }
    }

    private func record(_ payload: ClipboardPayload) async throws {
        let newEntry = try await attachments.prepare(payload)
        var updated = entries.filter { $0.fingerprint != newEntry.fingerprint }
        updated.insert(newEntry, at: 0)
        try commit(Array(updated.prefix(limit)))
    }

    private func commit(_ updated: [ClipboardEntry]) throws {
        try repository.save(updated)
        entries = updated
    }

    private func trimAndClean() async {
        do {
            if entries.count > limit { try commit(Array(entries.prefix(limit))) }
            await clean()
        } catch { report(error) }
    }

    private func clean() async { await attachments.cleanup(retaining: entries, protectedURLs: pasteboard.currentFileURLs) }
    private func report(_ error: Error) { message = "操作失败：\(error.localizedDescription)" }
}

/// A failed persistent store can fall back to a separate, temporary session without touching its data.
@MainActor
final class MemoryHistoryRepository: HistoryRepository {
    private var entries: [ClipboardEntry] = []
    func load() throws -> [ClipboardEntry] { entries }
    func save(_ entries: [ClipboardEntry]) throws { self.entries = entries }
}
