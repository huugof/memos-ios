import Foundation

struct VaultFileMetadata: Codable, Equatable {
    let relativePath: String
    let modifiedAt: Date
    let fileSize: Int
}

enum VaultWriteResult: Equatable {
    case written(VaultFileMetadata)
    case conflictCopy(path: String, metadata: VaultFileMetadata)
}

/// Every byte MemoChat reads from or writes to the vault goes through here.
///
/// `root` is injected rather than resolved internally so the whole type is
/// testable against a temp directory — no bookmark, no simulator state, no
/// real vault.
struct VaultFileStore {

    let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
    }

    // MARK: - Listing

    /// Metadata for every `.md` file in the vault, recursively.
    ///
    /// Deliberately metadata-only: content is never read here. In an iCloud
    /// vault most files may be `.notDownloaded`, and materializing all of them
    /// just to draw a list is unacceptable. VaultIndex decides what to read.
    func listMarkdownFiles() throws -> [VaultFileMetadata] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [VaultFileMetadata] = []
        for case let url as URL in enumerator {
            // .obsidian holds vault config, not notes.
            if url.pathComponents.contains(".obsidian") {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let relativePath = relativePath(for: url) else { continue }
            results.append(try metadata(for: url, relativePath: relativePath))
        }
        return results
    }

    func existingFilenames(inSubfolder subfolder: String) throws -> Set<String> {
        let folder = subfolder.isEmpty ? root : root.appendingPathComponent(subfolder, isDirectory: true)
        guard fileManager.fileExists(atPath: folder.path) else { return [] }
        let names = try fileManager.contentsOfDirectory(atPath: folder.path)
        return Set(names)
    }

    // MARK: - Reading

    func read(relativePath: String) throws -> VaultNote {
        let url = root.appendingPathComponent(relativePath)
        let text = try readText(at: url)

        let (frontmatter, body) = Frontmatter.parse(text)
        let meta = try metadata(for: url, relativePath: relativePath)
        return VaultNote(
            relativePath: relativePath,
            frontmatter: frontmatter,
            body: body,
            modifiedAt: meta.modifiedAt,
            fileSize: meta.fileSize,
            originalText: text
        )
    }

    // MARK: - Writing

    @discardableResult
    func write(_ text: String, to relativePath: String) throws -> VaultFileMetadata {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { writeURL in
            do {
                try text.write(to: writeURL, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }

        return try metadata(for: url, relativePath: relativePath)
    }

    /// Writes only if the file's current content still matches `expectedText`
    /// — the exact text the note was last read as. If it changed externally,
    /// the in-app version is saved beside it as a conflict copy and the
    /// external edit is left untouched — the Dropbox/Obsidian Sync convention.
    /// Never prompts, never clobbers.
    ///
    /// Content comparison, not mtime/size, is deliberate: some file providers
    /// preserve a file's original modification date when materializing a
    /// downloaded change, which would make an mtime-based check fail to
    /// detect a real external edit — not just in a narrow same-second race,
    /// but systematically. A save must never destroy a vault edit, so the
    /// detector has to be one that can't miss, not merely one that rarely
    /// does.
    func writeChecked(
        _ text: String,
        to relativePath: String,
        expectedText: String
    ) throws -> VaultWriteResult {
        let url = root.appendingPathComponent(relativePath)

        guard fileManager.fileExists(atPath: url.path) else {
            // Deleted externally: write fresh rather than resurrect the path.
            return .written(try write(text, to: relativePath))
        }

        let currentText = try readText(at: url)

        if currentText == expectedText {
            return .written(try write(text, to: relativePath))
        }

        let conflictPath = Self.conflictPath(for: relativePath, at: Date())
        let metadata = try write(text, to: conflictPath)
        return .conflictCopy(path: conflictPath, metadata: metadata)
    }

    func delete(relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { deleteURL in
            do {
                try fileManager.removeItem(at: deleteURL)
            } catch {
                deleteError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let deleteError { throw deleteError }
    }

    // MARK: - Helpers

    static func conflictPath(for relativePath: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: date)

        let path = relativePath as NSString
        let directory = path.deletingLastPathComponent
        let stem = (path.lastPathComponent as NSString).deletingPathExtension
        let name = "\(stem) (conflict \(stamp)).md"
        return directory.isEmpty ? name : "\(directory)/\(name)"
    }

    private func relativePath(for url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Coordinated read of a file's raw text. Shared by `read(relativePath:)`
    /// and `writeChecked`'s content comparison.
    private func readText(at url: URL) throws -> String {
        var text = ""
        var coordinationError: NSError?
        var readError: Error?

        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do {
                text = try String(contentsOf: readURL, encoding: .utf8)
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        return text
    }

    private func metadata(for url: URL, relativePath: String) throws -> VaultFileMetadata {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return VaultFileMetadata(
            relativePath: relativePath,
            modifiedAt: values.contentModificationDate ?? .distantPast,
            fileSize: values.fileSize ?? 0
        )
    }
}
