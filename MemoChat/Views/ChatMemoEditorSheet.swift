import SwiftUI
import SwiftData

struct ChatMemoEditorSheet: View {
    let entryID: String

    var body: some View {
        if entryID.hasPrefix("m-") {
            ServerMemoEditorWrapper(
                memoID: String(entryID.dropFirst(2))
            )
        } else if entryID.hasPrefix("d-"),
                  let uuid = UUID(uuidString: String(entryID.dropFirst(2))) {
            LocalDraftEditorSheet(draftID: uuid)
        }
    }
}

// MARK: - Server Memo Editor

private struct ServerMemoEditorWrapper: View {
    let memoID: String

    @Query private var matchingDrafts: [ServerMemoEditDraft]

    init(memoID: String) {
        self.memoID = memoID
        let id = memoID
        _matchingDrafts = Query(filter: #Predicate<ServerMemoEditDraft> { $0.memoID == id })
    }

    var body: some View {
        NavigationStack {
            if let editDraft = matchingDrafts.first {
                ServerMemoEditorView(
                    editDraft: editDraft,
                    shouldAutoFocus: false,
                    onTagTapped: { _ in }
                )
            } else {
                ProgressView()
            }
        }
    }
}

// MARK: - Local Draft Editor

private struct LocalDraftEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let draftID: UUID

    @Query private var matchingDrafts: [Draft]
    @State private var isFocused = true
    @State private var focusRequestID = UUID()

    init(draftID: UUID) {
        self.draftID = draftID
        let id = draftID
        _matchingDrafts = Query(filter: #Predicate<Draft> { $0.id == id })
    }

    var body: some View {
        NavigationStack {
            if let draft = matchingDrafts.first {
                EditableNoteTextView(
                    text: Bindable(draft).text,
                    isFocused: $isFocused,
                    focusRequestID: focusRequestID
                )
                .padding(.horizontal, 24)
                .padding(.top, 10)
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
