import SwiftUI

struct NoteSearchView: View {
    @Binding var searchText: String
    let notes: [UnifiedNote]
    let onSuggestTags: () -> Void
    let onSuggestAttachments: () -> Void
    let onSuggestChecklists: () -> Void

    private var filteredNotes: [UnifiedNote] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return notes.filter { $0.content.lowercased().contains(q) }
    }

    private var isTyping: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if isTyping {
            resultsView
        } else {
            suggestionsView
        }
    }

    // MARK: Suggestions

    private var suggestionsView: some View {
        List {
            Section("Suggested") {
                suggestionRow("Notes with Tags", icon: "tag", action: onSuggestTags)
                suggestionRow("Notes with Attachments", icon: "paperclip", action: onSuggestAttachments)
                suggestionRow("Notes with Checklists", icon: "checklist", action: onSuggestChecklists)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func suggestionRow(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .foregroundStyle(.primary)
        }
    }

    // MARK: Results

    private var resultsView: some View {
        let results = filteredNotes
        return List {
            Section {
                HStack {
                    Text("Notes")
                        .font(.headline)
                    Spacer()
                    Text("\(results.count) Found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(results) { note in
                    NavigationLink(value: NotesRoute.editor(note.editorTarget)) {
                        NoteRowView(note: note)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
