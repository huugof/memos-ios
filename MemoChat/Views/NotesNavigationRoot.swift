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
    @StateObject private var pinnedStore = PinnedNotesStore()

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
        .tint(appAccent)
        .environmentObject(serverMemosStore)
        .environmentObject(sendQueue)
        .environmentObject(saveQueue)
        .environmentObject(serverDeleteQueue)
        .environmentObject(pinnedStore)
        .preferredColorScheme(.dark)
        .task {
            serverMemosStore.loadFromCache(MemoCache.load())
            serverMemosStore.onFirstPageFetched = { MemoCache.save($0) }
            await serverMemosStore.refresh(force: true)
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
                Task { await serverMemosStore.refreshIfStale() }
            default:
                break
            }
        }
    }

    private func handleForegroundResume() {
        guard let backgroundAt = AppSettings.lastBackgroundAt else { return }
        guard let delaySeconds = AppSettings.newNoteDelay.delaySeconds else { return }
        let elapsed = Date().timeIntervalSince(backgroundAt)
        guard elapsed >= TimeInterval(delaySeconds) else { return }

        guard case .editor(let target) = path.last else { return }

        // Leave pinned notes alone — preserve lastBackgroundAt so quick capture fires next time.
        let pinnedID: String? = {
            switch target {
            case .newNote: return nil
            case .localDraft(let id): return "d-\(id.uuidString)"
            case .serverMemo(let memoID): return "m-\(memoID)"
            }
        }()
        if let id = pinnedID, pinnedStore.isPinned(id) { return }

        AppSettings.lastBackgroundAt = nil
        // Replace the current editor — onDisappear will commit and send it.
        path = [.editor(.newNote)]
    }
}
