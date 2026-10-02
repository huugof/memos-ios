import SwiftUI
import SwiftData

/// Plain chronological history of notes — no search, no tag cloud, no filters.
/// The screen under the note sheet; tapping a row opens that note on the sheet.
struct NotesListView: View {
    let onOpen: (NoteEditorTarget) -> Void
    /// Brings the sheet back up on a capture note (or the pinned one).
    let onCompose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Draft.createdAt, order: .forward) private var allDrafts: [Draft]
    @Query private var allEditDrafts: [ServerMemoEditDraft]
    @Query private var allDeleteTasks: [ServerMemoDeleteTask]
    @EnvironmentObject private var serverMemosStore: ServerMemosStore
    @EnvironmentObject private var serverDeleteQueue: ServerMemoDeleteQueueController
    @EnvironmentObject private var pinnedStore: PinnedNotesStore
    @EnvironmentObject private var vaultStore: VaultStore
    @AppStorage("destinationKind") private var destinationRaw = DestinationKind.memos.rawValue

    @State private var showSettings = false
    /// Status bar height: the list runs up under it and fades out there.
    @State private var topInset: CGFloat = 0

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
            Text("Notes")
                .font(.largeTitle.bold())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 64))
                .listRowSeparator(.hidden)

            if let msg = activeErrorMessage {
                Section {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                    if destination == .vault && vaultStore.needsReconnect {
                        Button("Reconnect Vault") { showSettings = true }
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
        // Scroll all the way up to the screen's edge, fading out as the sheet's text does.
        .contentMargins(.top, topInset, for: .scrollContent)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black.opacity(0.25), location: 0.35),
                        .init(color: .black.opacity(0.7), location: 0.7),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: topInset + Self.topFade)
                Color.black
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        .refreshable {
            switch destination {
            case .memos: await serverMemosStore.loadAllPages()
            case .vault: await vaultStore.refresh()
            }
        }
        .overlay(alignment: .center) {
            if activeIsLoading && pinned.isEmpty && groups.isEmpty { ProgressView() }
        }
        .overlay(alignment: .bottomTrailing) {
            Button { onCompose() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(appAccent)
                    .frame(width: 60, height: 60)
                    .glassCircle()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(.bottom, 12)
        }
        .overlay(alignment: .topTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.primary)
            .padding(.trailing, 20)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSettings) {
            SettingsView(onBack: { showSettings = false })
        }
    }

    /// How far below the status bar the fade reaches — short, so the title isn't dimmed at rest.
    private static let topFade: CGFloat = 12

    @ViewBuilder
    private func noteRow(for note: UnifiedNote) -> some View {
        Button { onOpen(note.editorTarget) } label: {
            NoteRowView(note: note)
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
