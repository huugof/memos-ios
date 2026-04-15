import SwiftUI

struct NotesMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onRefresh: () -> Void
    let onShowAttachments: () -> Void
    let onSettings: () -> Void

    var body: some View {
        List {
            Section {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onRefresh() }
                } label: {
                    Label("Refresh from Server", systemImage: "arrow.clockwise")
                }
                .foregroundStyle(.primary)

                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onShowAttachments() }
                } label: {
                    Label("Show Attachments", systemImage: "paperclip")
                }
                .foregroundStyle(.primary)
            }

            Section {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onSettings() }
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                .foregroundStyle(.primary)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
