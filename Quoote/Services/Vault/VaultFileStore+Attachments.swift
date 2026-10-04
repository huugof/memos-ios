import CoreGraphics
import Foundation

/// Reading the pictures a note links to. Like the rest of `VaultFileStore`, `root` is injected, so all of this is
/// testable against a temp directory.
extension VaultFileStore {

    /// What reading an attachment's thumbnail produced.
    enum AttachmentThumbnail {
        case image(CGImage, modifiedAt: Date)
        /// iCloud has evicted the file. A download was requested and nothing was read — reading would block on it.
        case notDownloaded
        /// Missing, not a picture, or unreadable.
        case unreadable
    }

    /// What copying an attachment out of the vault produced.
    enum AttachmentCopy: Equatable {
        case copied(URL)
        /// iCloud has the file but not on this device. A download was requested and nothing was copied.
        case notDownloaded
        /// Missing, a folder, or unreadable.
        case unreadable
    }

    /// The vault-relative path of the file a wikilink or embed `target` names, or `nil`. Tried in order, each
    /// accepting the file or its iCloud placeholder:
    ///
    /// 1. the attachments folder, 2. the vault root, 3. the folder of the note that links it, 4. the first file
    /// anywhere in the vault with that name, ignoring case.
    ///
    /// A target that climbs out of the vault (`..`) or starts at `/` is refused.
    func locateAttachment(_ target: String, attachmentsFolder: String, notePath: String?) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/") else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.last, !components.contains(".."), !components.contains(".") else { return nil }
        let relative = components.joined(separator: "/")

        var candidates: [String] = []
        if !attachmentsFolder.isEmpty { candidates.append("\(attachmentsFolder)/\(relative)") }
        candidates.append(relative)
        if let notePath {
            let folder = (notePath as NSString).deletingLastPathComponent
            if !folder.isEmpty { candidates.append("\(folder)/\(relative)") }
        }
        for candidate in candidates where attachmentIsPresent(at: candidate) { return candidate }
        return findAttachment(named: name)
    }

    /// When the file was last changed, or `nil` if it isn't on disk (an evicted file has only its placeholder).
    func attachmentModificationDate(at relativePath: String) -> Date? {
        let url = root.appendingPathComponent(relativePath)
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// A thumbnail of the picture at `relativePath`, at most `maxPixel` on its longest edge. The full-size bitmap
    /// is never held: ImageIO decodes straight to the thumbnail.
    func attachmentThumbnail(at relativePath: String, maxPixel: Int) -> AttachmentThumbnail {
        switch readiness(of: relativePath) {
        case .missing:
            return .unreadable
        case .notDownloaded:
            return .notDownloaded
        case .ready(let url, let modifiedAt):
            var coordinationError: NSError?
            var image: CGImage?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                image = ThumbnailDownsampler.downsample(url: readURL, maxPixel: maxPixel)
            }
            guard coordinationError == nil, let image else { return .unreadable }
            return .image(image, modifiedAt: modifiedAt ?? .distantPast)
        }
    }

    /// A copy of the file at `relativePath` inside `directory`, under the file's own name. The system previewer
    /// reads from another process and the vault is only open while the caller holds its access, so it is handed a
    /// copy. `directory` is created when there is something to put in it.
    func copyAttachment(at relativePath: String, into directory: URL) -> AttachmentCopy {
        switch readiness(of: relativePath) {
        case .missing:
            return .unreadable
        case .notDownloaded:
            return .notDownloaded
        case .ready(let url, _):
            var coordinationError: NSError?
            var copy: URL?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                let destination = directory.appendingPathComponent(url.lastPathComponent)
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                    try fileManager.copyItem(at: readURL, to: destination)
                    copy = destination
                } catch {
                    copy = nil
                }
            }
            guard coordinationError == nil, let copy else { return .unreadable }
            return .copied(copy)
        }
    }

    // MARK: - Helpers

    /// Whether an attachment's bytes can be read now.
    private enum Readiness {
        /// A file, there to read. `modifiedAt` is `nil` when the file system doesn't say.
        case ready(URL, modifiedAt: Date?)
        /// iCloud has the file but not on this device. A download was requested; reading would block on it.
        case notDownloaded
        /// Not there, or a folder.
        case missing
    }

    private func readiness(of relativePath: String) -> Readiness {
        let url = root.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            guard fileManager.fileExists(atPath: placeholderURL(for: relativePath).path) else { return .missing }
            requestDownload(relativePath: relativePath)
            return .notDownloaded
        }

        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey
        ])
        if values?.isDirectory == true { return .missing }
        if values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            requestDownload(relativePath: relativePath)
            return .notDownloaded
        }
        return .ready(url, modifiedAt: values?.contentModificationDate)
    }

    /// `Docs/.report.pdf.icloud` for `Docs/report.pdf`: where iCloud leaves an evicted file.
    private func placeholderURL(for relativePath: String) -> URL {
        let url = root.appendingPathComponent(relativePath)
        return url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// A file (not a folder) is there, or its iCloud placeholder is.
    private func attachmentIsPresent(at relativePath: String) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: root.appendingPathComponent(relativePath).path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return true
        }
        return manager.fileExists(atPath: placeholderURL(for: relativePath).path)
    }

    /// The first file in the vault named `name`, ignoring case. Skips `.obsidian`, `.trash` and any other hidden
    /// folder or file — except an iCloud placeholder, which is reported under the real name.
    private func findAttachment(named name: String) -> String? {
        let wanted = name.lowercased()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }

        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let leaf = url.lastPathComponent
            let realLeaf = Self.mappedFilename(leaf)
            let isPlaceholder = realLeaf != leaf

            if leaf.hasPrefix(".") && !isPlaceholder {
                enumerator.skipDescendants()
                continue
            }
            guard realLeaf.lowercased() == wanted else { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }

            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            var relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if isPlaceholder {
                relative = ((relative as NSString).deletingLastPathComponent as NSString).appendingPathComponent(realLeaf)
            }
            return relative
        }
        return nil
    }
}
