import SwiftUI
import UniformTypeIdentifiers

/// The SF Symbol and the label a file tile shows for a filename's type.
enum AttachmentFileIcon {

    static func symbol(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    /// The uppercased extension (`PDF`), or an empty string when there is none.
    static func label(forFilename filename: String) -> String {
        String((filename as NSString).pathExtension.uppercased().prefix(4))
    }
}

/// A 56 pt square standing for one attachment: the picture for an image, a type icon and extension for a file.
/// Display only — it takes no taps of its own; `AttachmentBar` wraps one in a button where a preview can open.
struct AttachmentTile: View {
    static let size: CGFloat = 56
    private static let corner: CGFloat = 8

    let attachment: NoteAttachment
    /// The vault-relative path of the note holding the attachment, when it has one: `![[a.png]]` may name a file
    /// that sits beside the note.
    var notePath: String? = nil
    /// How many more attachments the note holds, shown as "+N".
    var extra: Int = 0
    var loader: AttachmentThumbnailLoader = .shared

    @State private var image: UIImage?

    init(
        attachment: NoteAttachment,
        notePath: String? = nil,
        extra: Int = 0,
        loader: AttachmentThumbnailLoader = .shared
    ) {
        self.attachment = attachment
        self.notePath = notePath
        self.extra = extra
        self.loader = loader
        // Seeded from memory, so a picture seen before is there on the first frame instead of flashing an icon.
        _image = State(initialValue: loader.cachedImage(for: attachment, notePath: notePath))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.corner)
                .fill(Color(uiColor: .secondarySystemFill))
            content
        }
        .frame(width: Self.size, height: Self.size)
        .overlay(alignment: .bottomTrailing) {
            if extra > 0 { badge }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .task(id: "\(attachment.identity)|\(notePath ?? "")") { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch attachment.kind {
        case .image:
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.size, height: Self.size)
                    .clipShape(RoundedRectangle(cornerRadius: Self.corner))
                    .transition(.opacity)
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        case .file:
            VStack(spacing: 2) {
                Image(systemName: AttachmentFileIcon.symbol(forFilename: attachment.name))
                    .font(.title3)
                Text(AttachmentFileIcon.label(forFilename: attachment.name))
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var badge: some View {
        Text("+\(extra)")
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(3)
    }

    private var accessibilityText: String {
        let base = attachment.kind == .image ? "Image attachment" : "File: \(attachment.name)"
        return extra > 0 ? "\(base), and \(extra) more" : base
    }

    private func load() async {
        guard attachment.kind == .image else { return }
        // A recycled row can arrive still holding the previous attachment's picture.
        image = loader.cachedImage(for: attachment, notePath: notePath)
        guard let loaded = await loader.thumbnail(for: attachment, notePath: notePath), loaded !== image else { return }
        withAnimation(.easeIn(duration: 0.15)) { image = loaded }
    }
}
