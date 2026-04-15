import SwiftUI
import SwiftData

struct NotesNavigationRoot: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Draft.createdAt, order: .forward) private var allDrafts: [Draft]

    @State private var path: [NotesRoute] = [.editor(.newNote)]

    @StateObject private var serverMemosStore = ServerMemosStore()
    @StateObject private var sendQueue = DraftSendQueueController()
    @StateObject private var saveQueue = ServerMemoSaveQueueController()
    @StateObject private var serverDeleteQueue = ServerMemoDeleteQueueController()

    var body: some View {
        NavigationStack(path: $path) {
            AllNotesView()
                .navigationDestination(for: NotesRoute.self) { route in
                    switch route {
                    case .editor(let target):
                        NoteEditorView(target: target)
                    }
                }
        }
        .environmentObject(serverMemosStore)
        .environmentObject(sendQueue)
        .environmentObject(saveQueue)
        .environmentObject(serverDeleteQueue)
        .preferredColorScheme(.dark)
        .task {
            serverMemosStore.loadFromCache(MemoCache.load())
            serverMemosStore.onFirstPageFetched = { MemoCache.save($0) }
            await serverMemosStore.loadAllPages()
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
                handleForegroundResume()
                sendQueue.startProcessing(in: modelContext)
                sendQueue.retryNow(in: modelContext)
                serverDeleteQueue.startProcessing(in: modelContext)
                serverDeleteQueue.retryNow(in: modelContext)
                saveQueue.startProcessing(in: modelContext)
                saveQueue.retryNow(in: modelContext)
                Task { await serverMemosStore.loadAllPagesIfStale() }
            default:
                break
            }
        }
    }

    private func handleForegroundResume() {
        guard let backgroundAt = AppSettings.lastBackgroundAt else { return }
        AppSettings.lastBackgroundAt = nil

        guard let delaySeconds = AppSettings.newNoteDelay.delaySeconds else { return }
        let elapsed = Date().timeIntervalSince(backgroundAt)
        guard elapsed >= TimeInterval(delaySeconds) else { return }

        // If the editor is open with an existing draft that has content, push a fresh note
        if case .editor(let target) = path.last {
            let hasContent: Bool
            switch target {
            case .newNote:
                hasContent = false
            case .localDraft(let id):
                hasContent = allDrafts.first(where: { $0.id == id })?.hasStartedText == true
            case .serverMemo:
                hasContent = true
            }
            if hasContent {
                path.append(.editor(.newNote))
            }
        }
    }
}
