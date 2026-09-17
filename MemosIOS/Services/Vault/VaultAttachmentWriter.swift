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
    ///
    /// Delegates to `VaultFileStore.writeNewFile`, which writes through a
    /// temp file and a coordinated move rather than a raw `Data.write` — the
    /// same coordination every other vault write goes through.
    @discardableResult
    static func write(
        data: Data,
        filename: String,
        using store: VaultFileStore,
        folder: String
    ) throws -> String {
        try store.writeNewFile(data, preferredName: filename, inSubfolder: folder)
    }
}
