import SwiftUI
import SwiftData

struct EditorRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]

    @State private var activeDraftID: UUID?
    @State private var showingMenu = false
    @State private var isResolvingRoute = true
    @State private var didBootstrap = false
    @State private var hasOpenedForCurrentActivation = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            if let draft = activeDraft {
                DraftEditorView(
                    draft: draft,
                    onBack: { current in
                        openMenu(from: current)
                    },
                    onNewNote: { current in
                        createAndActivateNewDraft(from: current)
                    },
                    onSendSuccess: { sentDraft in
                        handleSendSuccess(from: sentDraft)
                    }
                )
                .id(draft.id)
                .opacity(isResolvingRoute ? 0 : 1)
            }
        }
        .sheet(isPresented: $showingMenu, onDismiss: {
            ensureActiveDraftAfterMenuDismiss()
        }) {
            DraftMenuView(
                currentDraftID: activeDraftID,
                onSelectDraft: { draft in
                    activate(draft)
                },
                onCreateNewDraft: {
                    createAndActivateNewDraft(from: nil)
                }
            )
        }
        .onAppear {
            bootstrapIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                DraftResumeCoordinator.markAppBackgrounded()
                hasOpenedForCurrentActivation = false
                isResolvingRoute = true
                return
            }

            if newPhase == .active {
                if !didBootstrap {
                    bootstrapIfNeeded()
                    return
                }

                if !hasOpenedForCurrentActivation {
                    resolvePreferredDraft()
                    hasOpenedForCurrentActivation = true
                }

                isResolvingRoute = false
            }
        }
        .onChange(of: drafts.map(\.id)) { _, ids in
            guard let activeDraftID else { return }
            guard !ids.contains(activeDraftID) else { return }

            self.activeDraftID = nil
            resolvePreferredDraft()
        }
    }

    private var activeDraft: Draft? {
        guard let activeDraftID else { return nil }
        return drafts.first(where: { $0.id == activeDraftID })
    }

    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true

        resolvePreferredDraft()
        hasOpenedForCurrentActivation = true
        isResolvingRoute = false
    }

    private func resolvePreferredDraft() {
        let preferred = DraftResumeCoordinator.preferredDraft(from: drafts, in: modelContext)
        activate(preferred)
    }

    private func activate(_ draft: Draft) {
        activeDraftID = draft.id
        DraftResumeCoordinator.markActiveDraft(draft)
    }

    private func openMenu(from draft: Draft) {
        deleteTransientBlankIfNeeded(draft)
        showingMenu = true
    }

    private func createAndActivateNewDraft(from currentDraft: Draft?) {
        if let currentDraft {
            deleteTransientBlankIfNeeded(currentDraft)
        }

        let draft = DraftStore.createDraft(in: modelContext)
        activate(draft)
    }

    private func handleSendSuccess(from draft: Draft) {
        if draft.isArchived, activeDraftID == draft.id {
            activeDraftID = nil
            DraftResumeCoordinator.markActiveDraft(nil)
        }
        showingMenu = true
    }

    private func ensureActiveDraftAfterMenuDismiss() {
        if activeDraft == nil {
            resolvePreferredDraft()
        }
        isResolvingRoute = false
    }

    private func deleteTransientBlankIfNeeded(_ draft: Draft) {
        let deleted = DraftStore.deleteTransientBlankIfNeeded(draft, in: modelContext)
        if deleted, activeDraftID == draft.id {
            activeDraftID = nil
        }
    }
}
