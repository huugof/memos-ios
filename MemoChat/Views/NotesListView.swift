import SwiftUI
import SwiftData

/// Plain chronological history of notes — no search, no tag cloud, no filters.
/// The root of the notes drawer; tapping a row opens it in the editor.
struct NotesListView: View {
    /// Slides the drawer back off to the left.
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Draft.createdAt, order: .forward) private var allDrafts: [Draft]
    @Query private var allEditDrafts: [ServerMemoEditDraft]
    @Query private var allDeleteTasks: [ServerMemoDeleteTask]
    @EnvironmentObject private var serverMemosStore: ServerMemosStore
    @EnvironmentObject private var serverDeleteQueue: ServerMemoDeleteQueueController
    @EnvironmentObject private var pinnedStore: PinnedNotesStore

    @State private var showSettings = false

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

    var body: some View {
        let notes = allNotes
        let pinned = notes.filter { pinnedStore.isPinned($0.id) }
        let groups = NoteDateGrouping.group(notes.filter { !pinnedStore.isPinned($0.id) })

        List {
            if let msg = serverMemosStore.errorMessage {
                Section {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            if pinned.isEmpty && groups.isEmpty && !serverMemosStore.isLoading {
                Section {
                    Text("No notes yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { note in noteRow(for: note) }
                }
            }

            ForEach(groups) { group in
                Section(group.header) {
                    ForEach(group.notes) { note in noteRow(for: note) }
                }
            }

            // Pagination sentinel — lazy-loads older pages when scrolled into view.
            if !serverMemosStore.reachedEnd {
                Section {
                    Color.clear
                        .frame(height: 1)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .task { await serverMemosStore.loadNextPageIfNeeded() }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await serverMemosStore.loadAllPages() }
        .overlay(alignment: .center) {
            if serverMemosStore.isLoading && pinned.isEmpty && groups.isEmpty { ProgressView() }
        }
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.large)
        .background { NavigationGestures(edge: .right) { onClose() } }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { onClose() } label: {
                    Image(systemName: "chevron.left")
                        .fontWeight(.semibold)
                }
                .tint(.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .tint(.primary)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onBack: { showSettings = false })
        }
    }

    @ViewBuilder
    private func noteRow(for note: UnifiedNote) -> some View {
        NavigationLink(value: note.editorTarget) {
            NoteRowView(note: note)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { deleteNote(note) } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

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
