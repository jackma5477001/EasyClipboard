import Foundation

actor AttachmentManager {
    static let copyThreshold: Int64 = 10 * 1024 * 1024
    nonisolated let root: URL
    private let manager = FileManager.default
    init(root: URL) { self.root = root.standardizedFileURL }

    func prepare(_ payload: ClipboardPayload, at timestamp: Date = Date()) throws -> ClipboardEntry {
        let id = UUID()
        var entry = ClipboardEntry(id: id, timestamp: timestamp, fingerprint: "", kind: .text, files: [])
        switch payload {
        case .text(let text):
            entry.text = text
            entry.fingerprint = "text:" + ClipboardEntry.digest(Data(text.utf8))
        case .image(let data, let type):
            entry.kind = .image
            entry.imageType = type
            entry.fingerprint = "image:" + ClipboardEntry.digest(data)
            let path = "\(id.uuidString)/image.\(type == "public.png" ? "png" : "tiff")"
            let destination = try attachmentURL(path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            entry.imagePath = path
        case .files(let urls):
            entry.kind = .files
            var fingerprint = Data()
            for (index, url) in urls.enumerated() {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                let isDirectory = values?.isDirectory ?? false
                let size = values?.fileSize.map(Int64.init)
                var file = ClipboardFile(originalURL: url, byteCount: size, isDirectory: isDirectory, copyFailed: false)
                if values?.isRegularFile == true, values?.isSymbolicLink != true, let size, size < Self.copyThreshold {
                    let path = "\(id.uuidString)/\(index)/\(url.lastPathComponent)"
                    do {
                        let destination = try attachmentURL(path)
                        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        // Bound the read even if the source grows after checking its metadata.
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        var data = Data()
                        while data.count < Self.copyThreshold {
                            let count = min(65_536, Int(Self.copyThreshold) - data.count)
                            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                            data.append(chunk)
                        }
                        guard data.count < Self.copyThreshold else { throw CocoaError(.fileReadTooLarge) }
                        try data.write(to: destination, options: .atomic)
                        file.relativeCopyPath = path
                    } catch { file.copyFailed = true }
                } else if values == nil { file.copyFailed = true }
                entry.files.append(file)
                let signature = "\(url.standardizedFileURL.absoluteString)\u{0}\(size ?? -1)\u{0}\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)\u{0}"
                fingerprint.append(Data(signature.utf8))
            }
            entry.fingerprint = "files:" + ClipboardEntry.digest(fingerprint)
        }
        return entry
    }

    nonisolated func attachmentURL(_ path: String) throws -> URL {
        let components = path.split(separator: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains("..") else {
            throw ClipboardFailure.invalidAttachment
        }
        var url = root.resolvingSymlinksInPath()
        let resolvedRoot = url.path + "/"
        for component in components {
            url.appendPathComponent(String(component))
            // Resolve each existing ancestor, even when the final file does not exist yet.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ClipboardFailure.invalidAttachment
            }
        }
        guard url.standardizedFileURL.path.hasPrefix(resolvedRoot) else { throw ClipboardFailure.invalidAttachment }
        return url
    }

    func payload(for entry: ClipboardEntry) throws -> ClipboardPayload {
        switch entry.kind {
        case .text: return .text(entry.text ?? "")
        case .image:
            guard let path = entry.imagePath, let type = entry.imageType,
                  let data = try? Data(contentsOf: attachmentURL(path)) else { throw ClipboardFailure.missingImage }
            return .image(data, type: type)
        case .files:
            var urls: [URL] = []
            var missing: [String] = []
            for file in entry.files {
                let url = try file.relativeCopyPath.map { try attachmentURL($0) } ?? file.originalURL
                if manager.isReadableFile(atPath: url.path) { urls.append(url) }
                else { missing.append(file.name) }
            }
            guard missing.isEmpty else { throw ClipboardFailure.unavailableFiles(missing) }
            return .files(urls)
        }
    }

    /// Only the app-owned tree is cleaned; current pasteboard file references remain alive.
    func cleanup(retaining entries: [ClipboardEntry], protectedURLs: [URL]) {
        let retained = Set(entries.flatMap(\.attachmentPaths).compactMap { try? attachmentURL($0).resolvingSymlinksInPath().path })
        let protected = Set(protectedURLs.map { $0.resolvingSymlinksInPath().path })
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true { directories.append(url); continue }
            let canonical = url.resolvingSymlinksInPath().path
            guard !retained.contains(canonical), !protected.contains(canonical) else { continue }
            try? manager.removeItem(at: url)
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if (try? manager.contentsOfDirectory(atPath: directory.path).isEmpty) == true { try? manager.removeItem(at: directory) }
        }
    }
}
