import SwiftUI
import SwiftData

struct AllNotesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Draft.createdAt, order: .forward) private var allDrafts: [Draft]
    @Query private var allEditDrafts: [ServerMemoEditDraft]
    @Query private var allDeleteTasks: [ServerMemoDeleteTask]
    @EnvironmentObject private var serverMemosStore: ServerMemosStore
    @EnvironmentObject private var serverDeleteQueue: ServerMemoDeleteQueueController

    @State private var isSearchActive = false
    @State private var searchText = ""
    @State private var filterByTags = false
    @State private var filterByAttachments = false
    @State private var filterByChecklists = false
    @State private var showMenu = false
    @State private var showSettings = false
    @State private var showAttachmentsBrowser = false

    @FocusState private var searchFocused: Bool

    private var hiddenMemoIDs: Set<String> {
        Set(allDeleteTasks.filter { $0.deleteState != .resolved }.map { $0.memoID })
    }

    private var allNotes: [UnifiedNote] {
        UnifiedNote.merge(
            drafts: allDrafts,
            memos: serverMemosStore.memos,
            editDrafts: allEditDrafts,
            hiddenMemoIDs: hiddenMemoIDs
        )
    }

    private var displayedNotes: [UnifiedNote] {
        var notes = allNotes
        if filterByTags        { notes = notes.filter { !$0.tags.isEmpty } }
        if filterByAttachments { notes = notes.filter { $0.hasAttachments } }
        if filterByChecklists  { notes = notes.filter { $0.hasChecklists } }
        return notes
    }

    private var groups: [NoteDateGrouping.Group] {
        NoteDateGrouping.group(displayedNotes)
    }

    var body: some View {
        ZStack {
            if isSearchActive {
                NoteSearchView(
                    searchText: $searchText,
                    notes: allNotes,
                    onSuggestTags: {
                        filterByTags = true
                        dismissSearch()
                    },
                    onSuggestAttachments: {
                        filterByAttachments = true
                        dismissSearch()
                    },
                    onSuggestChecklists: {
                        filterByChecklists = true
                        dismissSearch()
                    }
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.12)))
            } else {
                notesList
                    .transition(.opacity.animation(.easeInOut(duration: 0.12)))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .navigationTitle("All Notes")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showMenu = true } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showMenu) {
            NotesMenuSheet(
                onRefresh: { Task { await serverMemosStore.loadAllPages() } },
                onShowAttachments: { showAttachmentsBrowser = true },
                onSettings: { showSettings = true }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAttachmentsBrowser) {
            attachmentsBrowserSheet
        }
        .onChange(of: isSearchActive) { _, active in
            if active {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    searchFocused = true
                }
            }
        }
    }

    // MARK: Notes list

    private var notesList: some View {
        List {
            if let errorMessage = serverMemosStore.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            if activeFilterLabel != nil {
                Section {
                    filterChip
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if groups.isEmpty && !serverMemosStore.isLoading {
                Section {
                    Text(activeFilterLabel != nil
                         ? "No notes match this filter."
                         : "No notes yet. Tap the compose button below to create your first note.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            ForEach(groups) { group in
                Section(group.header) {
                    ForEach(group.notes) { note in
                        noteRow(for: note)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await serverMemosStore.loadAllPages() }
        .overlay(alignment: .center) {
            if serverMemosStore.isLoading && groups.isEmpty {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func noteRow(for note: UnifiedNote) -> some View {
        NavigationLink(value: NotesRoute.editor(note.editorTarget)) {
            NoteRowView(note: note)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { deleteNote(note) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: Bottom bar (floating glass pill)

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // Search pill
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16, weight: .medium))

                if isSearchActive {
                    TextField("Search", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                } else {
                    Text("Search")
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isSearchActive && !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 14))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: Capsule())
            .onTapGesture {
                if !isSearchActive {
                    isSearchActive = true
                }
            }

            // Right button: X (search active) or compose (inactive)
            if isSearchActive {
                Button { dismissSearch() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 50, height: 50)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                NavigationLink(value: NotesRoute.editor(.newNote)) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 50, height: 50)
                        .background(.regularMaterial, in: Circle())
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.spring(duration: 0.25), value: isSearchActive)
    }

    private func dismissSearch() {
        searchText = ""
        searchFocused = false
        isSearchActive = false
    }

    // MARK: Filter chip

    private var activeFilterLabel: String? {
        if filterByTags { return "Has Tags" }
        if filterByAttachments { return "Has Attachments" }
        if filterByChecklists { return "Has Checklists" }
        return nil
    }

    private var activeFilterIcon: String {
        if filterByTags { return "tag" }
        if filterByAttachments { return "paperclip" }
        if filterByChecklists { return "checklist" }
        return "line.3.horizontal.decrease"
    }

    @ViewBuilder
    private var filterChip: some View {
        if let label = activeFilterLabel {
            HStack(spacing: 8) {
                Image(systemName: activeFilterIcon).font(.caption)
                Text(label).font(.caption.weight(.medium))
                Button {
                    filterByTags = false
                    filterByAttachments = false
                    filterByChecklists = false
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
    }

    // MARK: Attachments browser

    private var attachmentsBrowserSheet: some View {
        NavigationStack {
            List(allNotes.filter { $0.hasAttachments }) { note in
                NavigationLink(value: NotesRoute.editor(note.editorTarget)) {
                    NoteRowView(note: note)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Attachments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showAttachmentsBrowser = false }
                }
            }
        }
    }

    // MARK: Delete

    private func deleteNote(_ note: UnifiedNote) {
        switch note {
        case .local(let draft):
            DraftStore.delete(draft, in: modelContext)
        case .server(let memo, _):
            serverMemosStore.removeMemo(memoID: memo.id)
            _ = serverDeleteQueue.enqueue(
                memoID: memo.id,
                resourceName: memo.resourceName ?? memo.id,
                in: modelContext
            )
        }
    }
}
