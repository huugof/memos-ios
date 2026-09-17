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
            // .obsidian holds vault config, not notes; .trash holds files
            // deleted from within the app (see `delete(relativePath:)`).
            // Neither belongs in the note list.
            if url.pathComponents.contains(".obsidian") || url.pathComponents.contains(".trash") {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let relativePath = relativePath(for: url) else { continue }
            // A single file whose metadata can't be read (a transient
            // iCloud/file-provider failure, a race with an external delete,
            // …) must not fail the whole listing — just skip that one file.
            guard let fileMetadata = try? metadata(for: url, relativePath: relativePath) else { continue }
            results.append(fileMetadata)
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
    /// — the exact text the note was last read as. If it changed externally
    /// — including having been deleted — the in-app version is saved beside
    /// it (or, if the original is gone, under a fresh conflict-style name) as
    /// a conflict copy, and the external state is left untouched — the
    /// Dropbox/Obsidian Sync convention. Never prompts, never clobbers, and
    /// never resurrects a path the desktop just deleted.
    ///
    /// Content comparison, not mtime/size, is deliberate. A metadata check
    /// misses any external edit that lands in the same second and leaves the
    /// file the same size — a `VaultFileStoreTests` probe reproduced exactly
    /// that, silently clobbering the external edit. The window is narrow, but
    /// the cost of losing to it is a destroyed vault edit, so the detector
    /// here has to be one that cannot miss rather than one that rarely does.
    /// Reading the file back is affordable because a note being saved is
    /// already materialized.
    func writeChecked(
        _ text: String,
        to relativePath: String,
        expectedText: String
    ) throws -> VaultWriteResult {
        let url = root.appendingPathComponent(relativePath)

        guard fileManager.fileExists(atPath: url.path) else {
            // Deleted externally: save as a new file rather than resurrect
            // the path — writing straight back would silently erase the
            // fact that the original was removed out from under us.
            return try writeConflictCopy(text, originalRelativePath: relativePath)
        }

        let currentText = try readText(at: url)

        if currentText == expectedText {
            return .written(try write(text, to: relativePath))
        }

        return try writeConflictCopy(text, originalRelativePath: relativePath)
    }

    /// Writes `text` as a conflict copy of `originalRelativePath`, disambiguated
    /// against what's already on disk in the *original's* directory (which may
    /// be nested — not the vault root), so a second conflict inside the same
    /// minute gets " 2" appended instead of silently replacing the first
    /// conflict copy via `write()`'s atomic replace semantics. Shared by both
    /// `writeChecked` branches that need one: an external edit, and an
    /// external deletion.
    private func writeConflictCopy(_ text: String, originalRelativePath: String) throws -> VaultWriteResult {
        let directory = (originalRelativePath as NSString).deletingLastPathComponent
        let existing = try existingFilenames(inSubfolder: directory)
        let conflictPath = Self.conflictPath(for: originalRelativePath, at: Date(), existing: existing)
        let metadata = try write(text, to: conflictPath)
        return .conflictCopy(path: conflictPath, metadata: metadata)
    }

    /// Moves the file to `<root>/.trash/`, Obsidian's own "move to Obsidian
    /// trash" convention, rather than deleting it outright — a swipe-delete
    /// in the app must not be unrecoverable for a note that also lives on
    /// the user's desktop vault.
    ///
    /// A source that's already missing counts as success: deleting something
    /// that's already gone is the outcome the caller wanted.
    func delete(relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }

        let trashFolder = root.appendingPathComponent(".trash", isDirectory: true)
        try fileManager.createDirectory(at: trashFolder, withIntermediateDirectories: true)

        let filename = (relativePath as NSString).lastPathComponent
        let existing = try existingFilenames(inSubfolder: ".trash")
        let destName = Self.disambiguatedName(filename, existing: existing)
        let destURL = trashFolder.appendingPathComponent(destName)

        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forMoving,
            writingItemAt: destURL, options: .forReplacing,
            error: &coordinationError
        ) { readURL, writeURL in
            do {
                try fileManager.moveItem(at: readURL, to: writeURL)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // Vanished between the existence check above and the move:
                // still counts as a successful delete.
            } catch {
                moveError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
    }

    // MARK: - Writing new files

    /// Writes `data` as a new file, never overwriting an existing one.
    ///
    /// Used for attachments and anything else that's writing brand-new bytes
    /// rather than updating a known note: the data is written to a temp file
    /// first, then moved into place inside a coordinated write. `moveItem`
    /// fails if the destination already exists, which is what preserves the
    /// no-overwrite guarantee here (a plain `Data.write` can't give that
    /// atomically together with `.atomic`, which Foundation forbids pairing
    /// with `.withoutOverwriting`). The temp file is removed if the move
    /// fails.
    func writeNewFile(_ data: Data, preferredName: String, inSubfolder subfolder: String) throws -> String {
        let existing = try existingFilenames(inSubfolder: subfolder)
        let candidate = Self.disambiguatedName(preferredName, existing: existing)
        let relativePath = subfolder.isEmpty ? candidate : "\(subfolder)/\(candidate)"
        let destURL = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let tempURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tempURL)

        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destURL, options: [], error: &coordinationError) { writeURL in
            do {
                try fileManager.moveItem(at: tempURL, to: writeURL)
            } catch {
                moveError = error
            }
        }

        if coordinationError != nil || moveError != nil {
            try? fileManager.removeItem(at: tempURL)
            if let coordinationError { throw coordinationError }
            if let moveError { throw moveError }
        }

        return relativePath
    }

    // MARK: - Helpers

    /// Disambiguates a full filename (with extension) against `existing`
    /// filenames in the same directory by appending " 2", " 3", … before the
    /// extension until it's unique. Shared by conflict-copy naming, trash
    /// naming, and new-file writing so the " 2"/" 3" rule lives in one place.
    static func disambiguatedName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var suffix = 2
        while existing.contains(candidate) {
            candidate = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }

    /// Builds a conflict-copy path, disambiguating against `existing` filenames
    /// in the original's directory the same way `VaultNoteSerializer.filename`
    /// disambiguates timestamp filenames: append " 2", " 3", … before the
    /// extension on collision. `existing` must be scoped to the original's
    /// directory (see `existingFilenames(inSubfolder:)`), not the vault root,
    /// or collisions in nested folders go undetected.
    static func conflictPath(for relativePath: String, at date: Date, existing: Set<String>) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: date)

        let path = relativePath as NSString
        let directory = path.deletingLastPathComponent
        let stem = (path.lastPathComponent as NSString).deletingPathExtension
        let baseName = "\(stem) (conflict \(stamp)).md"

        let candidate = disambiguatedName(baseName, existing: existing)
        return directory.isEmpty ? candidate : "\(directory)/\(candidate)"
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
