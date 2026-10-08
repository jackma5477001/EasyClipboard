import AppKit
import CryptoKit

enum ClipboardKind: String, Codable, Sendable { case text, image, files }

enum ClipboardPayload: Equatable, Sendable {
    case text(String)
    case image(Data, type: String)
    case files([URL])
}

struct ClipboardFile: Codable, Equatable, Sendable {
    var originalURL: URL
    var relativeCopyPath: String?
    var byteCount: Int64?
    var isDirectory: Bool
    var copyFailed: Bool
    var name: String { originalURL.lastPathComponent }
    var detail: String {
        if isDirectory { return "文件夹 · 原位置" }
        let size = byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let location = relativeCopyPath != nil ? "副本" : (copyFailed ? "原文件（副本未保存）" : "原文件")
        return [size, location].compactMap { $0 }.joined(separator: " · ")
    }
}

struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var timestamp: Date
    var fingerprint: String
    var kind: ClipboardKind
    var text: String?
    var imagePath: String?
    var imageType: String?
    var files: [ClipboardFile]
    var title: String {
        switch kind {
        case .text: return text ?? "文字"
        case .image: return "图片"
        case .files: return files.count == 1 ? (files.first?.name ?? "文件") : "\(files.count) 个文件"
        }
    }
    var attachmentPaths: [String] { [imagePath].compactMap { $0 } + files.compactMap(\.relativeCopyPath) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum ClipboardFailure: LocalizedError {
    case unavailableFiles([String]), missingImage, invalidAttachment, writeFailed
    var errorDescription: String? {
        switch self {
        case .unavailableFiles(let names): return "无法访问这些文件：\(names.joined(separator: "、"))"
        case .missingImage: return "图片数据已无法读取。"
        case .invalidAttachment: return "附件路径无效。"
        case .writeFailed: return "无法写入系统剪贴板，请重试。"
        }
    }
}

@MainActor
protocol PasteboardClient: AnyObject {
    var changeCount: Int { get }
    var currentFileURLs: [URL] { get }
    func read() -> ClipboardPayload?
    func write(_ payload: ClipboardPayload) -> Bool
}

@MainActor
final class SystemPasteboard: PasteboardClient {
    private let board: NSPasteboard
    init(_ board: NSPasteboard = .general) { self.board = board }
    var changeCount: Int { board.changeCount }
    var currentFileURLs: [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    func read() -> ClipboardPayload? {
        let urls = currentFileURLs
        if !urls.isEmpty { return .files(urls) }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type), !data.isEmpty { return .image(data, type: type.rawValue) }
        }
        if let text = board.string(forType: .string), !text.isEmpty { return .text(text) }
        return nil
    }
    func write(_ payload: ClipboardPayload) -> Bool {
        board.clearContents()
        switch payload {
        case .text(let text): return board.setString(text, forType: .string)
        case .image(let data, let type): return board.setData(data, forType: .init(type))
        case .files(let urls): return board.writeObjects(urls.map { $0 as NSURL })
        }
    }
}
