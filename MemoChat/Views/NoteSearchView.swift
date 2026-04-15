import SwiftUI

struct NoteSearchView: View {
    @Binding var searchText: String
    let notes: [UnifiedNote]
    let topTags: [String]
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
            // Tag cloud card
            if !topTags.isEmpty {
                Section {
                    tagCloudCard
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                }
            }

            // Filters
            Section("Suggested") {
                suggestionRow("Notes with Tags",        icon: "tag",       action: onSuggestTags)
                suggestionRow("Notes with Attachments", icon: "paperclip", action: onSuggestAttachments)
                suggestionRow("Notes with Checklists",  icon: "checklist", action: onSuggestChecklists)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var tagCloudCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags")
                .font(.headline)
                .foregroundStyle(.primary)

            FlowLayout(spacing: 8) {
                tagChip("All Tags", isAllTags: true) { onSuggestTags() }
                ForEach(topTags, id: \.self) { tag in
                    tagChip("#\(tag)") { searchText = "#\(tag)" }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func tagChip(_ label: String, isAllTags: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isAllTags ? .primary : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(uiColor: .tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func suggestionRow(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).foregroundStyle(.primary)
        }
    }

    // MARK: Results

    private var resultsView: some View {
        let results = filteredNotes
        return List {
            Section {
                HStack {
                    Text("Notes").font(.headline)
                    Spacer()
                    Text("\(results.count) Found").font(.subheadline).foregroundStyle(.secondary)
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
