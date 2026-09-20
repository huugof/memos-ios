import SwiftUI
import SwiftData

/// App root: launch lands directly on a focused compose screen. History is one
/// tap (or a left-edge swipe) away — it slides over the compose screen as a drawer,
/// which keeps the in-progress note alive underneath. Local-first, invisible sync.
struct ComposeRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var showMenu = false
    /// Bumped to spin up a fresh compose draft (the "+" / quick-capture reset).
    @State private var composeResetID = UUID()

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
        ZStack {
            NavigationStack {
                NoteEditorView(
                    target: .newNote,
                    isHome: true,
                    isMenuOpen: showMenu,
                    onNewNote: newNote,
                    onOpenMenu: openMenu
                )
                .id(composeResetID)
            }

            if showMenu {
                NotesMenuRoot(onClose: closeMenu)
                    .transition(.move(edge: .leading))
                    .zIndex(1)  // stays on top while sliding back out, too
            }
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
                await serverMemosStore.refresh(force: true)
            case .vault:
                vaultStore.loadFromIndex()
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

    private func newNote() {
        composeResetID = UUID()
    }

    private func openMenu() {
        guard !showMenu else { return }
        withAnimation(.easeOut(duration: 0.28)) { showMenu = true }
    }

    private func closeMenu() {
        withAnimation(.easeIn(duration: 0.25)) { showMenu = false }
    }

    /// Quick capture: after being away longer than the configured delay, come back to a
    /// blank note — from wherever the user left off, an open editor included.
    private func handleForegroundResume() {
        guard let backgroundAt = AppSettings.lastBackgroundAt else { return }
        guard let delaySeconds = AppSettings.newNoteDelay.delaySeconds else { return }
        let elapsed = Date().timeIntervalSince(backgroundAt)
        guard elapsed >= TimeInterval(delaySeconds) else { return }
        AppSettings.lastBackgroundAt = nil

        guard showMenu else {
            composeResetID = UUID()
            return
        }

        // Tearing the drawer down runs the onDisappear of whatever it held, which flushes
        // that text and enqueues the send/save; flushStagedServerEdits covers anything
        // staged but not yet queued.
        showMenu = false
        flushStagedServerEdits()
        // Defer the reset a runloop so the new editor doesn't grab focus mid-transition.
        Task { @MainActor in composeResetID = UUID() }
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

/// The menu layer. It carries its own navigation stack so tapping a note still pushes
/// the editor and Back still lands on the list — the same flow as when the list lived
/// on the compose stack, just hosted inside the drawer.
private struct NotesMenuRoot: View {
    let onClose: () -> Void

    @State private var path: [NoteEditorTarget] = []

    var body: some View {
        NavigationStack(path: $path) {
            NotesListView(onClose: onClose)
                .navigationDestination(for: NoteEditorTarget.self) { target in
                    NoteEditorView(target: target)
                }
        }
        .background(Color(uiColor: .systemBackground))  // opaque while sliding
    }
}
