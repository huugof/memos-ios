import SwiftUI
import SwiftData

/// App root: history is the screen underneath, and compose rides on a sheet over
/// it that never closes. Launch lands with the sheet at 3/4 height and the
/// keyboard up; dragging it down to a strip reveals the history, and tapping a
/// note there opens it on the same sheet, pushed over the compose note so Back
/// returns to it. Local-first, invisible sync.
struct ComposeRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// Notes opened from history, pushed over the compose note on the sheet.
    @State private var sheetPath: [NoteEditorTarget] = []
    @State private var detent: PresentationDetent = ComposeSheet.standard
    @State private var showSettings = false
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
        NavigationStack {
            NotesListView(onOpen: openNote, onShowSettings: { showSettings = true })
        }
        .sheet(isPresented: .constant(true)) {
            ComposeSheet(
                path: $sheetPath,
                detent: $detent,
                showSettings: $showSettings,
                composeResetID: composeResetID,
                onNewNote: newNote
            )
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

    /// Opens a history note on the sheet, replacing any note already open there.
    private func openNote(_ target: NoteEditorTarget) {
        sheetPath = [target]
        withAnimation { detent = ComposeSheet.standard }
    }

    /// Quick capture: after being away longer than the configured delay, come back to a
    /// blank note — from wherever the user left off, an open editor included.
    private func handleForegroundResume() {
        guard let backgroundAt = AppSettings.lastBackgroundAt else { return }
        guard let delaySeconds = AppSettings.newNoteDelay.delaySeconds else { return }
        let elapsed = Date().timeIntervalSince(backgroundAt)
        guard elapsed >= TimeInterval(delaySeconds) else { return }
        AppSettings.lastBackgroundAt = nil

        detent = ComposeSheet.standard
        guard !sheetPath.isEmpty else {
            composeResetID = UUID()
            return
        }

        // Popping the open note runs its onDisappear, which flushes that text and
        // enqueues the send/save; flushStagedServerEdits covers anything staged but
        // not yet queued.
        sheetPath = []
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

/// The compose sheet. It is never dismissed — only collapsed — so the note in
/// progress stays mounted and is never sent just because history was glanced at.
private struct ComposeSheet: View {
    @Binding var path: [NoteEditorTarget]
    @Binding var detent: PresentationDetent
    @Binding var showSettings: Bool
    let composeResetID: UUID
    let onNewNote: () -> Void

    /// Tall enough to leave the editor bar showing above the home indicator.
    static let peek = PresentationDetent.height(110)
    static let standard = PresentationDetent.fraction(0.75)

    private var isCollapsed: Bool { detent == Self.peek }

    var body: some View {
        NavigationStack(path: $path) {
            // The compose note hands the keyboard over while a history note sits
            // on top of it, and takes it back when that note is popped.
            NoteEditorView(
                target: .newNote,
                isHome: true,
                isMenuOpen: isCollapsed || !path.isEmpty,
                onNewNote: onNewNote,
                onOpenMenu: toggleCollapsed
            )
            .id(composeResetID)
            .navigationDestination(for: NoteEditorTarget.self) { target in
                NoteEditorView(target: target, isMenuOpen: isCollapsed)
            }
        }
        .tint(appAccent)
        .preferredColorScheme(.dark)
        .presentationDetents([Self.peek, Self.standard, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.peek))
        .interactiveDismissDisabled()
        // Presented from here, not from the history list: that list's screen is
        // already presenting this sheet, so it can't present another.
        .sheet(isPresented: $showSettings) {
            SettingsView(onBack: { showSettings = false })
                .preferredColorScheme(.dark)
        }
    }

    private func toggleCollapsed() {
        withAnimation { detent = isCollapsed ? Self.standard : Self.peek }
    }
}
