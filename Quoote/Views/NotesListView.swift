import SwiftUI
import SwiftData

/// Plain chronological history of notes — no search, no tag cloud, no filters.
/// The screen under the compose sheet; tapping a row opens it on that sheet.
struct NotesListView: View {
    let onOpen: (NoteEditorTarget) -> Void
    let onShowSettings: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Draft.createdAt, order: .forward) private var allDrafts: [Draft]
    @Query private var allEditDrafts: [ServerMemoEditDraft]
    @Query private var allDeleteTasks: [ServerMemoDeleteTask]
    @EnvironmentObject private var serverMemosStore: ServerMemosStore
    @EnvironmentObject private var serverDeleteQueue: ServerMemoDeleteQueueController
    @EnvironmentObject private var pinnedStore: PinnedNotesStore
    @EnvironmentObject private var vaultStore: VaultStore
    @AppStorage("destinationKind") private var destinationRaw = DestinationKind.memos.rawValue

    private var destination: DestinationKind {
        DestinationKind(rawValue: destinationRaw) ?? .memos
    }

    private var hiddenMemoIDs: Set<String> {
        Set(allDeleteTasks.filter { $0.deleteState != .resolved }.map { $0.memoID })
    }

    private var allNotes: [UnifiedNote] {
        switch destination {
        case .memos:
            return UnifiedNote.merge(
                drafts: allDrafts,
                memos: serverMemosStore.memos,
                editDrafts: allEditDrafts,
                hiddenMemoIDs: hiddenMemoIDs
            )
        case .vault:
            return UnifiedNote.merge(vaultEntries: vaultStore.entries, drafts: allDrafts)
        }
    }

    private var activeErrorMessage: String? {
        switch destination {
        case .memos: return serverMemosStore.errorMessage
        case .vault: return vaultStore.errorMessage
        }
    }

    private var activeIsLoading: Bool {
        switch destination {
        case .memos: return serverMemosStore.isLoading
        case .vault: return vaultStore.isLoading
        }
    }

    var body: some View {
        let notes = allNotes
        let pinned = notes.filter { pinnedStore.isPinned($0.id) }
        let groups = NoteDateGrouping.group(notes.filter { !pinnedStore.isPinned($0.id) })

        List {
            if let msg = activeErrorMessage {
                Section {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                    if destination == .vault && vaultStore.needsReconnect {
                        Button("Reconnect Vault") { onShowSettings() }
                            .listRowBackground(Color.clear)
                    }
                }
            }

            if pinned.isEmpty && groups.isEmpty && !activeIsLoading {
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
            // Vault mode has no pages; the whole vault is reconciled by refresh().
            if destination == .memos && !serverMemosStore.reachedEnd {
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
        .refreshable {
            switch destination {
            case .memos: await serverMemosStore.loadAllPages()
            case .vault: await vaultStore.refresh()
            }
        }
        .overlay(alignment: .center) {
            if activeIsLoading && pinned.isEmpty && groups.isEmpty { ProgressView() }
        }
        // The collapsed compose sheet covers the bottom of the list.
        .contentMargins(.bottom, 120, for: .scrollContent)
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onShowSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .tint(.primary)
            }
        }
    }

    @ViewBuilder
    private func noteRow(for note: UnifiedNote) -> some View {
        Button { onOpen(note.editorTarget) } label: {
            NoteRowView(note: note)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        case .vault(let entry):
            do {
                try vaultStore.delete(relativePath: entry.relativePath)
            } catch {
                vaultStore.recordError(error)
            }
        }
    }
}
