import Foundation

/// What the drawer needs to draw a row, without the file's content.
struct VaultIndexEntry: Codable, Equatable, Identifiable {
    let relativePath: String
    let title: String
    let preview: String
    let tags: [String]
    let modifiedAt: Date
    let fileSize: Int

    var id: String { relativePath }

    static func make(from note: VaultNote) -> VaultIndexEntry {
        VaultIndexEntry(
            relativePath: note.relativePath,
            title: note.title,
            preview: Self.preview(forBody: note.body),
            tags: note.tags,
            modifiedAt: note.modifiedAt,
            fileSize: note.fileSize
        )
    }

    /// The first body line after the title line, matching UnifiedNote.preview.
    private static func preview(forBody body: String) -> String {
        var pastTitle = false
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !pastTitle {
                if !trimmed.isEmpty { pastTitle = true }
                continue
            }
            if !trimmed.isEmpty { return trimmed }
        }
        return "No additional text"
    }
}

struct VaultIndexDiff: Equatable {
    let needsRead: [String]
    let unchanged: [VaultIndexEntry]
    let removed: [String]
}

/// A persisted index of the vault, so the drawer renders instantly at launch
/// and content is downloaded only for files that actually changed.
///
/// In an iCloud vault a file may be `.notDownloaded`; reading its content
/// forces a download. Diffing on cheap metadata keeps that to the minimum.
enum VaultIndex {
    private static let filename = "vault_index_v1.json"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static var indexURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(filename)
    }

    static func load() -> [VaultIndexEntry] {
        guard let url = indexURL,
              let data = try? Data(contentsOf: url),
              let entries = try? decoder.decode([VaultIndexEntry].self, from: data)
        else { return [] }
        return entries
    }

    /// Writes synchronously. Callers already run this off the main thread
    /// where it matters (e.g. after a background vault scan), and a
    /// synchronous write means the index on disk is guaranteed current the
    /// moment `save` returns — including immediately after in a test.
    static func save(_ entries: [VaultIndexEntry]) {
        guard let url = indexURL, let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Compares the persisted index against a metadata-only directory listing.
    /// A one-second tolerance on modification dates absorbs filesystem
    /// timestamp granularity differences across file providers.
    static func diff(index: [VaultIndexEntry], disk: [VaultFileMetadata]) -> VaultIndexDiff {
        let indexByPath = Dictionary(index.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let diskPaths = Set(disk.map(\.relativePath))

        var needsRead: [String] = []
        var unchanged: [VaultIndexEntry] = []

        for file in disk {
            guard let existing = indexByPath[file.relativePath] else {
                needsRead.append(file.relativePath)
                continue
            }
            let sameDate = abs(existing.modifiedAt.timeIntervalSince(file.modifiedAt)) < 1
            if sameDate && existing.fileSize == file.fileSize {
                unchanged.append(existing)
            } else {
                needsRead.append(file.relativePath)
            }
        }

        let removed = index.map(\.relativePath).filter { !diskPaths.contains($0) }
        return VaultIndexDiff(needsRead: needsRead, unchanged: unchanged, removed: removed)
    }
}
