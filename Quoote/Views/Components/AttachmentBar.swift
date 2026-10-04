import SwiftUI

/// The strip above the editor bar: what the note already holds (read-only), then what is waiting to be sent
/// (with ✕, or a spinner while it uploads). Existing attachments go away by deleting their line in the text.
struct AttachmentBar: View {
    static let height: CGFloat = 72

    let existing: [NoteAttachment]
    /// The vault-relative path of the open note, when it is a vault note.
    var notePath: String? = nil
    @Binding var pendingImages: [PendingImage]
    @Binding var pendingFiles: [PendingFile]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(existing, id: \.identity) { attachment in
                    switch attachment.kind {
                    case .image:
                        AttachmentTile(attachment: attachment, notePath: notePath)
                    case .file:
                        FileChip(name: attachment.name)
                    }
                }
                ForEach(pendingImages) { p in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: p.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        if p.isUploading {
                            ProgressView()
                                .frame(width: 56, height: 56)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Button { pendingImages.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black)
                                    .font(.caption)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
                ForEach(pendingFiles) { f in
                    ZStack(alignment: .topTrailing) {
                        FileChip(name: f.filename)
                        if f.isUploading {
                            ProgressView()
                                .frame(height: 56)
                                .frame(maxWidth: .infinity)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Button { pendingFiles.removeAll { $0.id == f.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black)
                                    .font(.caption)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(height: Self.height)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 16)
    }
}

/// A file as a chip: its type icon and its name, two lines at most.
private struct FileChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: AttachmentFileIcon.symbol(forFilename: name))
                .font(.caption)
            Text(name)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: 80)
        }
        .padding(8)
        .frame(height: 56)
        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}
