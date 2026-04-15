import SwiftUI

struct NoteSearchView: View {
    @Binding var searchText: String
    let notes: [UnifiedNote]
    let onDismiss: () -> Void
    let onSuggestTags: () -> Void
    let onSuggestAttachments: () -> Void
    let onSuggestChecklists: () -> Void

    @FocusState private var searchFocused: Bool

    private var filteredNotes: [UnifiedNote] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return notes.filter { $0.content.lowercased().contains(q) }
    }

    private var isEmpty: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            Divider()
                .background(Color(uiColor: .separator))

            if isEmpty {
                suggestionsView
            } else {
                resultsView
            }
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))

            Button("Cancel") {
                searchText = ""
                onDismiss()
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var suggestionsView: some View {
        List {
            Section("Suggested") {
                Button {
                    onSuggestTags()
                } label: {
                    Label("Notes with Tags", systemImage: "tag")
                        .foregroundStyle(.primary)
                }

                Button {
                    onSuggestAttachments()
                } label: {
                    Label("Notes with Attachments", systemImage: "paperclip")
                        .foregroundStyle(.primary)
                }

                Button {
                    onSuggestChecklists()
                } label: {
                    Label("Notes with Checklists", systemImage: "checklist")
                        .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.plain)
    }

    private var resultsView: some View {
        let results = filteredNotes
        return List {
            HStack {
                Text("Notes")
                    .font(.headline)
                Spacer()
                Text("\(results.count) Found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .padding(.top, 4)

            ForEach(results) { note in
                NavigationLink(value: NotesRoute.editor(note.editorTarget)) {
                    NoteRowView(note: note)
                }
            }
        }
        .listStyle(.plain)
    }
}
