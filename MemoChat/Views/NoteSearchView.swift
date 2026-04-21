import SwiftUI

enum NoteSearchFilter: Equatable {
    case tags, images, files, checklists

    var label: String {
        switch self {
        case .tags:       return "Tags"
        case .images:     return "Images"
        case .files:      return "Files"
        case .checklists: return "Checklists"
        }
    }

    var icon: String {
        switch self {
        case .tags:       return "tag"
        case .images:     return "photo"
        case .files:      return "paperclip"
        case .checklists: return "checklist"
        }
    }
}

struct NoteSearchView: View {
    @Binding var searchText: String
    @Binding var searchFilter: NoteSearchFilter?
    let notes: [UnifiedNote]
    let topTags: [String]
    var isLoadingMore: Bool = false

    private var filteredNotes: [UnifiedNote] {
        var results = notes

        switch searchFilter {
        case .tags:       results = results.filter { !$0.tags.isEmpty }
        case .images:     results = results.filter { $0.hasImages }
        case .files:      results = results.filter { $0.hasFiles }
        case .checklists: results = results.filter { $0.hasChecklists }
        case nil:         break
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            results = results.filter { $0.content.range(of: q, options: .caseInsensitive) != nil }
        }

        return results
    }

    private var showingResults: Bool {
        searchFilter != nil || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if showingResults {
            resultsView
        } else {
            suggestionsView
        }
    }

    // MARK: Suggestions

    private var suggestionsView: some View {
        List {
            Section("Suggested") {
                suggestionRow("Notes with Images",     icon: "photo")     { searchFilter = .images }
                suggestionRow("Notes with Files",      icon: "paperclip") { searchFilter = .files }
                suggestionRow("Notes with Checklists", icon: "checklist") { searchFilter = .checklists }
                suggestionRow("Notes with Tags",       icon: "tag")       { searchFilter = .tags }
                if !topTags.isEmpty {
                    tagCloudCard
                        .listRowSeparator(.hidden)
                }
            }
            loadingMoreFooter
        }
        .listStyle(.insetGrouped)
    }

    private var tagCloudCard: some View {
        FlowLayout(spacing: 8) {
            ForEach(topTags, id: \.self) { tag in
                tagChip("#\(tag)") { searchText = "#\(tag)" }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tagChip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(uiColor: .tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func suggestionRow(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).foregroundStyle(appAccent)
                Text(label).foregroundStyle(.primary)
            }
        }
        .tint(.primary)
    }

    // MARK: Results

    private var resultsView: some View {
        let results = filteredNotes
        let header = results.isEmpty ? "No Results" : "\(results.count) Found"
        return List {
            Section(header) {
                ForEach(results) { note in
                    NavigationLink(value: NotesRoute.editor(note.editorTarget)) {
                        NoteRowView(note: note)
                    }
                }
            }
            loadingMoreFooter
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var loadingMoreFooter: some View {
        if isLoadingMore {
            Section {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75)
                    Text("Loading more notes…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }
}
