import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var controller: ClipboardController
    var onSelect: (ClipboardEntry) -> Void
    var openSettings: () -> Void
    @State private var hoveredID: UUID?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color(red: 0.17, green: 0.23, blue: 0.29))
                VStack(alignment: .leading, spacing: 3) {
                    Text("EasyClipboard").font(.system(size: 17, weight: .semibold)).accessibilityIdentifier("appTitle")
                    Text("剪贴板历史").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityIdentifier("historyTitle")
                }
                .accessibilityElement(children: .contain)
                Spacer()
                Button { controller.togglePause() } label: {
                    Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12)).frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.045), in: Circle())
                }
                .buttonStyle(.plain)
                .help(controller.isPaused ? "继续记录" : "暂停记录")
                .accessibilityIdentifier("pauseRecording")
                .accessibilityLabel(controller.isPaused ? "继续记录" : "暂停记录")
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            if let message = controller.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { controller.message = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }
                .foregroundStyle(Color(red: 0.23, green: 0.34, blue: 0.48))
                .padding(12).background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 14).padding(.bottom, 8)
                .accessibilityIdentifier("statusMessage")
            }

            if controller.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text(controller.isPaused ? "已暂停记录" : "剪贴板还是空的").font(.system(size: 15, weight: .medium))
                    Text("复制文字、图片，或将文件拖到这里。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("emptyHistory")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.entries) { entry in
                            let highlighted = hoveredID == entry.id || (hoveredID == nil && controller.entries.first?.id == entry.id)
                            Button { onSelect(entry) } label: {
                                ClipboardRow(entry: entry, attachments: controller.attachments)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("history-\(entry.id.uuidString)")
                            .accessibilityLabel(entry.title)
                            .help("粘贴：\(entry.title)")
                            .mask {
                                Rectangle().padding(.trailing, hoveredID == entry.id ? 30 : 0)
                            }
                            .overlay(alignment: .trailing) {
                                if hoveredID == entry.id {
                                    Button { controller.delete(entry) } label: {
                                        Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(.secondary)
                                            .frame(width: 24, height: 32)
                                    }
                                    .buttonStyle(.plain).padding(.trailing, 6)
                                    .accessibilityLabel("删除\(entry.title)")
                                }
                            }
                            .background(highlighted ? Color.blue.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                            .onHover { hovering in hoveredID = hovering ? entry.id : nil }
                            .contextMenu {
                                Button("粘贴") { onSelect(entry) }
                                Button("删除", role: .destructive) { controller.delete(entry) }
                            }
                            if entry.id != controller.entries.last?.id {
                                Divider().overlay(Color.black.opacity(0.025)).padding(.horizontal, 12).padding(.vertical, 5)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .accessibilityIdentifier("historyList")
            }

            Divider().padding(.horizontal, 16)
            HStack(spacing: 8) {
                if controller.isBusy { ProgressView().controlSize(.small) }
                Text(controller.isPaused ? "记录已暂停，可拖入文件" : "点击粘贴，也可拖入文件")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Text("\(controller.entries.count) / \(controller.limit)")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityIdentifier("historyCount")
                Button(action: openSettings) { Label("设置", systemImage: "gearshape").font(.system(size: 12)) }
                    .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("openSettings")
            }
            .accessibilityElement(children: .contain)
            .padding(.horizontal, 14).padding(.vertical, 11)
        }
        .frame(maxHeight: ClipboardPanelLayout.maximumHeight)
        .background(VisualEffect())
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.blue.opacity(0.08))
                    .strokeBorder(Color.blue, lineWidth: 2)
                    .overlay {
                        Label("松开以添加文件", systemImage: "plus.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .dropDestination(for: URL.self) { urls, _ in
            controller.addFiles(urls)
        } isTargeted: { isDropTargeted = $0 }
        .preferredColorScheme(.light)
    }
}

struct ClipboardRow: View {
    let entry: ClipboardEntry
    let attachments: AttachmentManager
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if entry.kind == .text {
                Text(entry.text ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.leading).foregroundStyle(Color.primary)
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).frame(maxHeight: 120, alignment: .topLeading).clipped()
            } else {
                attachmentRow
            }
        }
        .task(id: entry.imagePath) {
            guard let path = entry.imagePath, let url = try? attachments.attachmentURL(path) else { return }
            let data = await ThumbnailCache.shared.load(url)
            thumbnail = data.flatMap(NSImage.init(data:))
        }
    }

    private var attachmentRow: some View {
        HStack(spacing: 12) {
            switch entry.kind {
            case .text: EmptyView()
            case .image:
                Group {
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
                    else { Image(systemName: "photo").font(.system(size: 25)).foregroundStyle(.secondary) }
                }
                .frame(width: 72, height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
            case .files:
                Image(nsImage: fileIcon).resizable().scaledToFit().frame(width: 40, height: 46)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    .multilineTextAlignment(.leading).foregroundStyle(Color.primary)
                HStack(alignment: .bottom, spacing: 6) {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(relativeTime(to: context.date)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(10).frame(minHeight: 72)
    }

    private var detail: String {
        switch entry.kind {
        case .text: return "文字"
        case .image: return "图片"
        case .files: return entry.files.count == 1 ? (entry.files.first?.detail ?? "文件") : entry.files.map(\.name).joined(separator: "、")
        }
    }
    private var fileIcon: NSImage {
        if entry.files.count > 1 { return NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "多个文件")! }
        guard let file = entry.files.first else { return NSWorkspace.shared.icon(for: .data) }
        if FileManager.default.fileExists(atPath: file.originalURL.path) { return NSWorkspace.shared.icon(forFile: file.originalURL.path) }
        let type = file.isDirectory ? UTType.folder : (UTType(filenameExtension: file.originalURL.pathExtension) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }
    private func relativeTime(to date: Date) -> String {
        if date.timeIntervalSince(entry.timestamp) < 60 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: entry.timestamp, relativeTo: date)
    }
}

private actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSData>()
    init() { cache.countLimit = 100 }
    func load(_ url: URL) -> Data? {
        if let cached = cache.object(forKey: url as NSURL) { return cached as Data }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else { return nil }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let data = buffer as Data
        cache.setObject(data as NSData, forKey: url as NSURL)
        return data
    }
}

struct ClipboardSettingsView: View {
    @ObservedObject var controller: ClipboardController
    @State private var draft: String
    init(controller: ClipboardController) {
        self.controller = controller
        _draft = State(initialValue: String(controller.limit))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("历史保留条数").font(.system(size: 14))
                Spacer()
                TextField("20", text: $draft).multilineTextAlignment(.trailing).frame(width: 62)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("historyLimit")
                    .onChange(of: draft) { _, value in
                        if let number = Int(value), number > 0, number != controller.limit { controller.setLimit(number) }
                    }
                Stepper("", value: Binding(get: { controller.limit }, set: { draft = String($0) }), in: 1...Int.max)
                    .labelsHidden().accessibilityIdentifier("limitStepper")
            }
            Divider()
            Text(validDraft ? "仅保存在本机" : "请输入大于 0 的整数")
                .font(.system(size: 12)).foregroundStyle(validDraft ? Color.secondary : Color.red)
            Button("清空历史", role: .destructive) { controller.clear() }
                .accessibilityIdentifier("clearHistory")
        }
        .padding(24).frame(width: 350).preferredColorScheme(.light)
        .onChange(of: controller.limit) { _, value in if validDraft { draft = String(value) } }
    }
    private var validDraft: Bool { (Int(draft) ?? 0) > 0 }
}
