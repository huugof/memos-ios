import Foundation

/// Writes images into the vault's attachment folder and produces the Obsidian
/// wikilink that references them.
///
/// Wikilinks resolve regardless of the note's folder depth, which plain
/// relative markdown paths do not. The cost is portability outside Obsidian,
/// accepted because the destination is named for Obsidian.
enum VaultAttachmentWriter {

    static func filename(forNoteNamed noteName: String, index: Int, fileExtension: String) -> String {
        let stem = (noteName as NSString).deletingPathExtension
        return "\(stem) \(index).\(fileExtension)"
    }

    static func wikilink(for filename: String) -> String {
        "![[\(filename)]]"
    }

    /// Writes the data and returns the path it landed at, relative to the vault root.
    ///
    /// Never replaces an existing file: if `filename` is taken, " 2", " 3", …
    /// is appended before the extension. Callers must build the wikilink from
    /// the returned path, not from the filename they asked for.
    @discardableResult
    static func write(
        data: Data,
        filename: String,
        using store: VaultFileStore,
        folder: String
    ) throws -> String {
        let existing = try store.existingFilenames(inSubfolder: folder)
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = filename
        var suffix = 2
        while existing.contains(candidate) {
            candidate = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            suffix += 1
        }

        let relativePath = folder.isEmpty ? candidate : "\(folder)/\(candidate)"
        let url = store.root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // .withoutOverwriting backstops the existence check against a file
        // that appears in between. It cannot be combined with .atomic —
        // Foundation traps at runtime if both are passed together — so this
        // write is non-atomic; the existence check is still race-safe.
        try data.write(to: url, options: [.withoutOverwriting])
        return relativePath
    }
}
