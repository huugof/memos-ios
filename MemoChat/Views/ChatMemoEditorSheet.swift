import SwiftUI
import SwiftData

struct ChatMemoEditorSheet: View {
    let entryID: String

    var body: some View {
        if entryID.hasPrefix("m-") {
            ServerMemoPlainEditor(memoID: String(entryID.dropFirst(2)))
        } else if entryID.hasPrefix("d-"),
                  let uuid = UUID(uuidString: String(entryID.dropFirst(2))) {
            LocalDraftPlainEditor(draftID: uuid)
        }
    }
}

// MARK: - Server Memo Editor

private struct ServerMemoPlainEditor: View {
    let memoID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var matchingDrafts: [ServerMemoEditDraft]
    @State private var localText = ""

    init(memoID: String) {
        self.memoID = memoID
        let id = memoID
        _matchingDrafts = Query(filter: #Predicate<ServerMemoEditDraft> { $0.memoID == id })
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $localText)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .navigationTitle("Edit Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            if let editDraft = matchingDrafts.first {
                                ServerMemoSaveService.stageLocalContent(localText, for: editDraft, in: modelContext)
                            }
                            dismiss()
                        }
                    }
                }
        }
        .onAppear {
            localText = matchingDrafts.first?.localContent ?? ""
        }
    }
}

// MARK: - Local Draft Editor

private struct LocalDraftPlainEditor: View {
    let draftID: UUID
    @Environment(\.dismiss) private var dismiss
    @Query private var matchingDrafts: [Draft]

    init(draftID: UUID) {
        self.draftID = draftID
        let id = draftID
        _matchingDrafts = Query(filter: #Predicate<Draft> { $0.id == id })
    }

    var body: some View {
        NavigationStack {
            if let draft = matchingDrafts.first {
                TextEditor(text: Bindable(draft).text)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .navigationTitle("Edit Note")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            } else {
                ProgressView()
            }
        }
    }
}
