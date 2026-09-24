import SwiftUI
import SwiftData

/// App root: history is the screen underneath, and every note is edited on a sheet
/// over it. Launch opens the sheet on a focused capture note (or the pinned note).
/// Dragging the sheet down commits the note — sends a new one, saves an existing
/// one — and reveals history. Local-first, invisible sync.
struct ComposeRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// The note on the sheet; nil while the sheet is down. A new value — even for
    /// the same target — is a new sheet, so the old editor commits on disappear.
    @State private var sheetNote: SheetNote?

    @StateObject private var serverMemosStore = ServerMemosStore()
    @StateObject private var sendQueue = DraftSendQueueController()
    @StateObject private var saveQueue = ServerMemoSaveQueueController()
    @StateObject private var serverDeleteQueue = ServerMemoDeleteQueueController()
    @StateObject private var pinnedStore = PinnedNotesStore()
    @StateObject private var vaultStore = VaultStore()

    @AppStorage("destinationKind") private var destinationRaw = DestinationKind.memos.rawValue
    @AppStorage("vaultBookmark") private var vaultBookmark: Data?
    /// Tracks whether `serverMemosStore` has had its cache-load/save-hook
    /// priming (as `.task` does) run this session — `.task` only runs it
    /// when Memos is the destination at launch, so a later switch into Memos
    /// from a vault-first launch needs to do that priming itself once.
    @State private var memosPrimed = false

    var body: some View {
        NavigationStack {
            NotesListView(onOpen: openSheet, onCompose: openCompose)
        }
        // Full height: with the keyboard up, iOS lifts any shorter detent to the top anyway.
        .sheet(item: $sheetNote) { note in
            NoteEditorView(target: note.target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .tint(appAccent)
                .preferredColorScheme(.dark)
        }
        .tint(appAccent)
        .environmentObject(serverMemosStore)
        .environmentObject(sendQueue)
        .environmentObject(saveQueue)
        .environmentObject(serverDeleteQueue)
        .environmentObject(pinnedStore)
        .environmentObject(vaultStore)
        .preferredColorScheme(.dark)
        .task {
            switch AppSettings.destinationKind {
            case .memos:
                serverMemosStore.loadFromCache(MemoCache.load())
                serverMemosStore.onFirstPageFetched = { MemoCache.save($0) }
                memosPrimed = true
                openCompose()  // after the cache load, so a pinned memo resolves
                await serverMemosStore.refresh(force: true)
            case .vault:
                vaultStore.loadFromIndex()
                openCompose()
                await vaultStore.refresh()
            }
        }
        .task { await autoSyncLoop() }
        .onChange(of: destinationRaw) { _, _ in
            Task {
                switch AppSettings.destinationKind {
                case .memos:
                    if !memosPrimed {
                        // Launched in vault mode, so the `.task` above never
                        // ran this — do the same cache-load/save-hook setup
                        // now, on the first switch into Memos this session.
                        serverMemosStore.loadFromCache(MemoCache.load())
                        serverMemosStore.onFirstPageFetched = { MemoCache.save($0) }
                        memosPrimed = true
                        await serverMemosStore.refresh(force: true)
                    } else {
                        await serverMemosStore.refreshIfStale()
                    }
                case .vault:
                    vaultStore.loadFromIndex()
                    await vaultStore.refresh()
                }
            }
        }
        .onChange(of: vaultBookmark) { _, _ in
            // A different vault was picked: the index describes the old one.
            // Clear it before refreshing so the previous vault's rows don't
            // linger mixed in with the new vault's (Minor 7).
            guard AppSettings.destinationKind == .vault else { return }
            vaultStore.resetForNewVault()
            Task { await vaultStore.refresh() }
        }
        .onAppear {
            sendQueue.startProcessing(in: modelContext)
            serverDeleteQueue.startProcessing(in: modelContext)
            saveQueue.startProcessing(in: modelContext)
        }
        .onChange(of: sendQueue.lastCreatedMemo) { _, memo in
            guard let memo else { return }
            serverMemosStore.upsertMemo(memo)
            // A pinned note stays pinned once sent: follow it from draft to memo.
            if let draftID = sendQueue.lastSentDraftID {
                pinnedStore.migrate(fromDraft: draftID, to: "m-\(memo.id)")
            }
        }
        .onChange(of: saveQueue.lastSuccessfulMemo) { _, memo in
            guard let memo else { return }
            serverMemosStore.upsertMemo(memo)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                AppSettings.lastBackgroundAt = Date()
                sendQueue.stopProcessing()
                serverDeleteQueue.stopProcessing()
                saveQueue.stopProcessing()
            case .active:
                // Start the queues before quick capture runs — popping the editor commits
                // its pending work, and those commits should land on running queues.
                sendQueue.startProcessing(in: modelContext)
                sendQueue.retryNow(in: modelContext)
                serverDeleteQueue.startProcessing(in: modelContext)
                serverDeleteQueue.retryNow(in: modelContext)
                saveQueue.startProcessing(in: modelContext)
                saveQueue.retryNow(in: modelContext)
                handleForegroundResume()
                switch AppSettings.destinationKind {
                case .memos:
                    Task { await serverMemosStore.refreshIfStale() }
                case .vault:
                    Task { await vaultStore.refreshIfStale(maxAge: 5) }
                }
            default:
                break
            }
        }
    }

    private func openSheet(_ target: NoteEditorTarget) {
        sheetNote = SheetNote(target: target)
    }

    private func openCompose() {
        openSheet(composeTarget())
    }

    /// The pinned note when there is one, else a fresh capture note.
    private func composeTarget() -> NoteEditorTarget {
        guard let pinned = pinnedStore.target else { return .newNote }
        if case .localDraft(let id) = pinned {
            let draft = try? modelContext.fetch(
                FetchDescriptor<Draft>(predicate: #Predicate { $0.id == id })
            ).first
            // Deleted, or sent without the pin following it (e.g. the app was killed
            // before the memo came back) — nothing left to reopen.
            guard let draft, !(draft.isArchived && draft.sendState == .sent) else {
                pinnedStore.unpin()
                return .newNote
            }
        }
        return pinned
    }

    /// Quick capture: after being away longer than the configured delay, come back to a
    /// blank note (or the pinned one) — from wherever the user left off, an open
    /// editor included.
    private func handleForegroundResume() {
        guard let backgroundAt = AppSettings.lastBackgroundAt else { return }
        guard let delaySeconds = AppSettings.newNoteDelay.delaySeconds else { return }
        let elapsed = Date().timeIntervalSince(backgroundAt)
        guard elapsed >= TimeInterval(delaySeconds) else { return }
        AppSettings.lastBackgroundAt = nil

        // Swapping the sheet's note runs the old editor's onDisappear, which flushes
        // that text and enqueues the send/save; flushStagedServerEdits covers anything
        // staged but not yet queued. Already on the pinned note: leave it be.
        let target = composeTarget()
        if let current = sheetNote, current.target == target, target != .newNote { return }
        let hadSheet = sheetNote != nil
        openSheet(target)
        if hadSheet { flushStagedServerEdits() }
    }

    /// Enqueue every server note carrying unsaved local edits.
    private func flushStagedServerEdits() {
        let staged = (try? modelContext.fetch(FetchDescriptor<ServerMemoEditDraft>())) ?? []
        for editDraft in staged where editDraft.hasLocalChanges {
            saveQueue.enqueue(editDraft, in: modelContext)
        }
    }

    /// Light foreground polling so server-side changes surface without a manual refresh.
    private func autoSyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            switch AppSettings.destinationKind {
            case .memos:
                await serverMemosStore.refreshIfStale(maxAge: 30)
            case .vault:
                await vaultStore.refreshIfStale(maxAge: 30)
            }
        }
    }
}

/// One presentation of the note sheet.
private struct SheetNote: Identifiable {
    let id = UUID()
    let target: NoteEditorTarget
}
