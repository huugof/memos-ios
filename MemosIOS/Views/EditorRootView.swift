import SwiftUI
import SwiftData

private enum ActiveEditorSession: Equatable {
    case localDraft(UUID)
    case serverMemo(String)
}

struct EditorRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]
    @Query(sort: \ServerMemoEditDraft.updatedAt, order: .reverse) private var serverEditDrafts: [ServerMemoEditDraft]

    @State private var activeSession: ActiveEditorSession?
    @State private var isSheetPresented = false
    @State private var sheetSurface: PanelSurface = .drafts
    @State private var didBootstrap = false
    @State private var selectedDraftMenuTab: DraftMenuTab = .active
    @StateObject private var sendQueue = DraftSendQueueController()
    @StateObject private var serverSaveQueue = ServerMemoSaveQueueController()
    @StateObject private var serverMemosStore = ServerMemosStore()

    init() {
        let shouldRestoreRoute = DraftResumeCoordinator.shouldResumePreviousDraft(now: Date())
        if shouldRestoreRoute, let rawRoute = AppSettings.lastRouteRaw {
            if let restoredSurface = PanelSurface(rawValue: rawRoute) {
                _sheetSurface = State(initialValue: restoredSurface)
                _isSheetPresented = State(initialValue: true)
            } else {
                _sheetSurface = State(initialValue: .drafts)
                _isSheetPresented = State(initialValue: true)
            }
        } else {
            _sheetSurface = State(initialValue: .drafts)
            _isSheetPresented = State(initialValue: false)
            AppSettings.lastRouteRaw = nil
        }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            editorContent
        }
        .sheet(isPresented: $isSheetPresented) {
            SheetSurfaceShellView(
                surface: $sheetSurface,
                selectedDraftMenuTab: $selectedDraftMenuTab,
                currentDraftID: currentDraftID,
                onSelectDraft: { draft in
                    activateDraft(draft)
                    isSheetPresented = false
                },
                onCreateNewDraft: {
                    createAndActivateNewDraft(from: currentLocalDraft)
                },
                onSendDraft: { draft in
                    _ = queueDraftForSend(draft)
                },
                onSelectServerMemo: { memo in
                    openServerMemoEditor(memo)
                    isSheetPresented = false
                }
            )
            .environmentObject(serverMemosStore)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            applyForegroundRoutePolicy()
            bootstrapIfNeeded()
            sendQueue.startProcessing(in: modelContext)
            sendQueue.retryNow(in: modelContext)
            serverSaveQueue.startProcessing(in: modelContext)
            serverSaveQueue.retryNow(in: modelContext)
            triggerServerRefreshAfterEditorAppears()
        }
        .onChange(of: isSheetPresented) { _, isPresented in
            if !isPresented {
                ensureEditorHasSession()
            }
            persistSheetState()
        }
        .onChange(of: sheetSurface) { _, _ in
            persistSheetState()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                DraftResumeCoordinator.markAppBackgrounded()
                persistSheetState()
                sendQueue.stopProcessing()
                serverSaveQueue.stopProcessing()
                activeSession = nil
                return
            }

            if newPhase == .active {
                applyForegroundRoutePolicy()
                if !didBootstrap {
                    bootstrapIfNeeded()
                    sendQueue.startProcessing(in: modelContext)
                    sendQueue.retryNow(in: modelContext)
                    serverSaveQueue.startProcessing(in: modelContext)
                    serverSaveQueue.retryNow(in: modelContext)
                    triggerServerRefreshAfterEditorAppears()
                    return
                }
                ensureEditorHasSession()
                sendQueue.startProcessing(in: modelContext)
                sendQueue.retryNow(in: modelContext)
                serverSaveQueue.startProcessing(in: modelContext)
                serverSaveQueue.retryNow(in: modelContext)
                triggerServerRefreshAfterEditorAppears()
            }
        }
        .onChange(of: drafts.map(\.id)) { _, ids in
            guard case let .localDraft(activeDraftID) = activeSession else { return }
            guard !ids.contains(activeDraftID) else { return }

            activeSession = nil
            if !isSheetPresented {
                resolvePreferredDraft()
            }
        }
        .onReceive(serverSaveQueue.$lastSuccessfulMemo) { memo in
            guard let memo else { return }
            serverMemosStore.upsertMemo(memo)

            if case let .serverMemo(memoID) = activeSession, memoID == memo.id {
                returnToServerListAfterSaveSuccess()
            }
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        if let session = activeSession {
            switch session {
            case .localDraft(let draftID):
                if let draft = drafts.first(where: { $0.id == draftID }) {
                    DraftEditorView(
                        draft: draft,
                        onOpenDraftsSheet: { current in
                            openDrafts(from: current)
                        },
                        onCreateNewDraft: { current in
                            createAndActivateNewDraft(from: current)
                        },
                        onSendQueued: { queuedDraft in
                            handleSendQueued(from: queuedDraft)
                        }
                    )
                    .id(draft.id)
                } else {
                    ProgressView()
                        .onAppear {
                            ensureEditorHasSession()
                        }
                }
            case .serverMemo(let memoID):
                if let editDraft = serverEditDraft(memoID: memoID) {
                    ServerMemoEditorView(
                        editDraft: editDraft,
                        saveQueue: serverSaveQueue,
                        onCreateNewDraft: {
                            createAndActivateNewDraft(from: nil)
                        },
                        onOpenDraftsSheet: {
                            openDraftsFromServerEditor()
                        },
                        onSaveSucceeded: { memo in
                            serverMemosStore.upsertMemo(memo)
                            returnToServerListAfterSaveSuccess()
                        }
                    )
                    .id("server-\(editDraft.memoID)")
                } else {
                    ProgressView()
                        .onAppear {
                            recoverMissingServerEditSession(memoID: memoID)
                        }
                }
            }
        } else {
            ProgressView()
                .onAppear {
                    ensureEditorHasSession()
                }
        }
    }

    private var currentDraftID: UUID? {
        guard case let .localDraft(id) = activeSession else { return nil }
        return id
    }

    private var currentLocalDraft: Draft? {
        guard case let .localDraft(id) = activeSession else { return nil }
        return drafts.first(where: { $0.id == id })
    }

    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true

        persistSheetState()
        ensureEditorHasSession()
    }

    private func resolvePreferredDraft() {
        let preferred = DraftResumeCoordinator.preferredDraft(from: drafts, in: modelContext)
        activateDraft(preferred)
    }

    private func activateDraft(_ draft: Draft) {
        activeSession = .localDraft(draft.id)
        DraftResumeCoordinator.markActiveDraft(draft)
    }

    private func ensureEditorHasSession() {
        guard !isSheetPresented else { return }
        guard activeSession == nil else { return }
        resolvePreferredDraft()
    }

    private func openDrafts(from draft: Draft) {
        deleteTransientBlankIfNeeded(draft)
        selectedDraftMenuTab = .active
        sheetSurface = .drafts
        isSheetPresented = true
    }

    private func openDraftsFromServerEditor() {
        selectedDraftMenuTab = .server
        sheetSurface = .drafts
        isSheetPresented = true
    }

    private func openServerMemoEditor(_ memo: ServerMemoSummary) {
        selectedDraftMenuTab = .server
        let editDraft = ServerMemoSaveService.upsertEditDraft(for: memo, in: modelContext)
        activeSession = .serverMemo(editDraft.memoID)
        DraftResumeCoordinator.markActiveDraft(nil)
    }

    private func createAndActivateNewDraft(from currentDraft: Draft?) {
        if let currentDraft {
            deleteTransientBlankIfNeeded(currentDraft)
        }

        let draft = DraftStore.createDraft(in: modelContext)
        activateDraft(draft)
        isSheetPresented = false
    }

    private func handleSendQueued(from draft: Draft) {
        let wasPending = draft.sendState == .pending
        guard queueDraftForSend(draft) else { return }
        guard !wasPending else { return }

        if case let .localDraft(activeDraftID) = activeSession, activeDraftID == draft.id {
            activeSession = nil
            DraftResumeCoordinator.markActiveDraft(nil)
        }
        createAndActivateNewDraft(from: nil)
    }

    @discardableResult
    private func queueDraftForSend(_ draft: Draft) -> Bool {
        return sendQueue.enqueue(draft, in: modelContext)
    }

    private func applyForegroundRoutePolicy(now: Date = Date()) {
        guard !DraftResumeCoordinator.shouldResumePreviousDraft(now: now) else { return }

        activeSession = nil
        selectedDraftMenuTab = .active
        sheetSurface = .drafts
        isSheetPresented = false
        AppSettings.lastRouteRaw = nil
    }

    private func triggerServerRefreshAfterEditorAppears() {
        Task { @MainActor in
            await Task.yield()
            await serverMemosStore.refreshIfStale(maxAge: 60)
        }
    }

    private func persistSheetState() {
        AppSettings.lastRouteRaw = isSheetPresented ? sheetSurface.rawValue : nil
    }

    private func deleteTransientBlankIfNeeded(_ draft: Draft) {
        let deleted = DraftStore.deleteTransientBlankIfNeeded(draft, in: modelContext)
        if deleted, case let .localDraft(id) = activeSession, id == draft.id {
            activeSession = nil
        }
    }

    private func serverEditDraft(memoID: String) -> ServerMemoEditDraft? {
        if let draft = serverEditDrafts.first(where: { $0.memoID == memoID }) {
            return draft
        }
        return ServerMemoSaveService.draft(memoID: memoID, in: modelContext)
    }

    private func recoverMissingServerEditSession(memoID: String) {
        if let memo = serverMemosStore.memo(memoID: memoID) {
            let editDraft = ServerMemoSaveService.upsertEditDraft(for: memo, in: modelContext)
            activeSession = .serverMemo(editDraft.memoID)
            return
        }

        activeSession = nil
        returnToServerListAfterSaveSuccess()
    }

    private func returnToServerListAfterSaveSuccess() {
        activeSession = nil
        selectedDraftMenuTab = .server
        sheetSurface = .drafts
        isSheetPresented = true
    }
}
