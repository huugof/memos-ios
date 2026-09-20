import UIKit

struct PendingImage: Identifiable {
    let id = UUID()
    let image: UIImage
    var uploadedURL: String? = nil
    /// The vault-relative path this image was written to, set ONLY when it
    /// was captured while the destination was the Obsidian vault. Separate
    /// from `uploadedURL` so `AttachmentMarkdownBuilder` can tell which
    /// destination produced this image even if the user switches
    /// destinations before sending — see Minor 2.
    var vaultPath: String? = nil
    var isUploading: Bool = true
}

struct PendingFile: Identifiable {
    let id = UUID()
    let filename: String
    var uploadedURL: String? = nil
    var isUploading: Bool = true
}

/// Builds the markdown for pending attachments, choosing wikilink vs.
/// `![](url)` per image based on the destination it was actually captured
/// under (`PendingImage.vaultPath`), not the app's CURRENT destination
/// setting. An image captured under the other destination is dropped
/// rather than mis-linked (Minor 2).
enum AttachmentMarkdownBuilder {
    static func build(
        images: [PendingImage],
        files: [PendingFile],
        currentDestination: DestinationKind
    ) -> [String] {
        var parts: [String] = []
        for p in images {
            guard let uploadedURL = p.uploadedURL else { continue }
            if let vaultPath = p.vaultPath {
                // Captured under the vault: only linkable while the
                // destination is still the vault.
                guard currentDestination == .vault else { continue }
                parts.append(VaultAttachmentWriter.wikilink(for: (vaultPath as NSString).lastPathComponent))
            } else {
                // Captured under the server: only linkable while the
                // destination is still the server.
                guard currentDestination == .memos else { continue }
                parts.append("![](\(uploadedURL))")
            }
        }
        for f in files where f.uploadedURL != nil {
            parts.append("[\(f.filename)](\(f.uploadedURL!))")
        }
        return parts
    }
}
