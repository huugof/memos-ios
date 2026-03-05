import SwiftUI
import SwiftData

struct EditorRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]

    @State private var activeDraftID: UUID?
    @State private var isSheetPresented = false
    @State private var sheetSurface: PanelSurface = .drafts
    @State private var didBootstrap = false
    @StateObject private var sendQueue = DraftSendQueueController()
    @StateObject private var serverMemosStore = ServerMemosStore()

    init() {
        if let rawRoute = AppSettings.lastRouteRaw {
            if let restoredSurface = PanelSurface(rawValue: rawRoute) {
                _sheetSurface = State(initialValue: restoredSurface)
                _isSheetPresented = State(initialValue: true)
            } else {
                // Backward compatibility for removed routes (e.g. "notes").
                _sheetSurface = State(initialValue: .drafts)
                _isSheetPresented = State(initialValue: true)
            }
        } else {
            _sheetSurface = State(initialValue: .drafts)
            _isSheetPresented = State(initialValue: false)
        }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            if let draft = activeDraft {
                DraftEditorView(
                    draft: draft,
                    onOpenDraftsSheet: { current in
                        openDrafts(from: current)
                    },
                    onSendQueued: { queuedDraft in
                        handleSendQueued(from: queuedDraft)
                    }
                )
                .id(draft.id)
            } else {
                ProgressView()
                    .onAppear {
                        ensureEditorHasDraft()
                    }
            }
        }
        .sheet(isPresented: $isSheetPresented) {
            SheetSurfaceShellView(
                surface: $sheetSurface,
                currentDraftID: activeDraftID,
                onSelectDraft: { draft in
                    activate(draft)
                    isSheetPresented = false
                },
                onCreateNewDraft: {
                    createAndActivateNewDraft(from: nil)
                },
                onSendDraft: { draft in
                    _ = queueDraftForSend(draft)
                }
            )
            .environmentObject(serverMemosStore)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            bootstrapIfNeeded()
            sendQueue.startProcessing(in: modelContext)
            sendQueue.retryNow(in: modelContext)
            triggerServerRefreshAfterEditorAppears()
        }
        .onChange(of: isSheetPresented) { _, isPresented in
            if !isPresented {
                ensureEditorHasDraft()
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
                return
            }

            if newPhase == .active {
                if !didBootstrap {
                    bootstrapIfNeeded()
                    sendQueue.startProcessing(in: modelContext)
                    sendQueue.retryNow(in: modelContext)
                    triggerServerRefreshAfterEditorAppears()
                    return
                }
                ensureEditorHasDraft()
                sendQueue.startProcessing(in: modelContext)
                sendQueue.retryNow(in: modelContext)
                triggerServerRefreshAfterEditorAppears()
            }
        }
        .onChange(of: drafts.map(\.id)) { _, ids in
            guard let activeDraftID else { return }
            guard !ids.contains(activeDraftID) else { return }

            self.activeDraftID = nil
            if !isSheetPresented {
                resolvePreferredDraft()
            }
        }
    }

    private var activeDraft: Draft? {
        guard let activeDraftID else { return nil }
        return drafts.first(where: { $0.id == activeDraftID })
    }

    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true

        persistSheetState()
        ensureEditorHasDraft()
    }

    private func resolvePreferredDraft() {
        let preferred = DraftResumeCoordinator.preferredDraft(from: drafts, in: modelContext)
        activate(preferred)
    }

    private func activate(_ draft: Draft) {
        activeDraftID = draft.id
        DraftResumeCoordinator.markActiveDraft(draft)
    }

    private func ensureEditorHasDraft() {
        guard !isSheetPresented else { return }
        guard activeDraft == nil else { return }
        resolvePreferredDraft()
    }

    private func openDrafts(from draft: Draft) {
        deleteTransientBlankIfNeeded(draft)
        sheetSurface = .drafts
        isSheetPresented = true
    }

    private func createAndActivateNewDraft(from currentDraft: Draft?) {
        if let currentDraft {
            deleteTransientBlankIfNeeded(currentDraft)
        }

        let draft = DraftStore.createDraft(in: modelContext)
        activate(draft)
        isSheetPresented = false
    }

    private func handleSendQueued(from draft: Draft) {
        let wasPending = draft.sendState == .pending
        guard queueDraftForSend(draft) else { return }
        guard !wasPending else { return }

        if activeDraftID == draft.id {
            activeDraftID = nil
            DraftResumeCoordinator.markActiveDraft(nil)
        }
        createAndActivateNewDraft(from: nil)
    }

    @discardableResult
    private func queueDraftForSend(_ draft: Draft) -> Bool {
        return sendQueue.enqueue(draft, in: modelContext)
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
        if deleted, activeDraftID == draft.id {
            activeDraftID = nil
        }
    }
}
