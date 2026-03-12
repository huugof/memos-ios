import SwiftUI
import SwiftData

fileprivate enum ActiveEditorSession: Equatable {
    case localDraft(UUID)
    case serverMemo(String)
}

private enum RootSheet: String, Identifiable {
    case settings
    case allNotes

    var id: String { rawValue }
}

struct NotesSearchQuery: Equatable {
    let rawValue: String
    let textTokens: [String]
    let tagTokens: [String]

    init(rawValue: String) {
        self.rawValue = rawValue

        var parsedTextTokens: [String] = []
        var parsedTagTokens: [String] = []

        for token in rawValue.split(whereSeparator: { $0.isWhitespace }) {
            let value = String(token)
            if value.lowercased().hasPrefix("tag:") {
                let rawTag = String(value.dropFirst(4))
                if let normalized = Self.normalizedTag(rawTag) {
                    parsedTagTokens.append(normalized.lowercased())
                }
                continue
            }

            let normalizedText = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedText.isEmpty {
                parsedTextTokens.append(normalizedText.lowercased())
            }
        }

        textTokens = parsedTextTokens
        tagTokens = parsedTagTokens
    }

    var isEmpty: Bool {
        textTokens.isEmpty && tagTokens.isEmpty
    }

    func matches(text: String, tags: [String] = []) -> Bool {
        if isEmpty {
            return true
        }

        let searchableText = text.lowercased()
        let normalizedTags = Set((tags + Self.extractTags(from: text)).compactMap { Self.normalizedTag($0)?.lowercased() })

        for token in textTokens where !searchableText.contains(token) {
            return false
        }

        for tag in tagTokens where !normalizedTags.contains(tag) {
            return false
        }

        return true
    }

    static func extractTags(from text: String) -> [String] {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        return hashtagRegex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let rawTag = nsText.substring(with: match.range(at: 1))
            return normalizedTag(rawTag)
        }
    }

    static func normalizedTag(_ rawTag: String) -> String? {
        var value = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("tag:") {
            value.removeFirst(4)
        }
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard !value.isEmpty else { return nil }
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return value
    }

    private static let hashtagRegex = try! NSRegularExpression(pattern: #"#([A-Za-z0-9_-]+)"#)
}

private struct ServerTimelineRowData {
    let memo: ServerMemoSummary?
    let editDraft: ServerMemoEditDraft?

    var memoID: String {
        memo?.id ?? editDraft?.memoID ?? "memos/unknown"
    }

    var updatedAt: Date? {
        if let editDraft, editDraft.hasLocalChanges || editDraft.saveState != .idle {
            return editDraft.updatedAt
        }

        if let memoDate = memo?.updatedAt {
            return memoDate
        }

        if memo == nil {
            return editDraft?.updatedAt
        }

        return nil
    }

    var displayContent: String {
        if let editDraft, editDraft.hasLocalChanges || editDraft.saveState != .idle {
            let trimmed = editDraft.localContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return editDraft.localContent
            }
        }

        if let memo {
            let trimmedContent = memo.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedContent.isEmpty {
                return memo.content
            }

            let snippet = memo.snippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !snippet.isEmpty {
                return memo.snippet ?? snippet
            }

            if memo.attachmentCount > 0 {
                return "(Attachment note)"
            }
        }

        if let editDraft {
            let trimmed = editDraft.localContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return editDraft.localContent
            }
        }

        return "(Empty note)"
    }

    var isPending: Bool {
        guard let editDraft else { return false }
        return editDraft.saveState == .pending
    }

    var isSaving: Bool {
        guard let editDraft else { return false }
        return editDraft.saveState == .saving
    }

    var attachmentCount: Int {
        memo?.attachmentCount ?? 0
    }

    var errorMessage: String? {
        editDraft?.lastError
    }

    var hasOpenableMemo: Bool {
        memo != nil || editDraft != nil
    }

    var deleteResourceName: String {
        if let resourceName = editDraft?.resourceName, !resourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return resourceName
        }

        if let resourceName = memo?.resourceName, !resourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return resourceName
        }

        return memoID
    }

}

private struct MergedTimelineRow: Identifiable {
    enum Source {
        case localPending(Draft)
        case server(ServerTimelineRowData)
    }

    let id: String
    let updatedAt: Date
    let source: Source
}

struct EditorRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]
    @Query(sort: \ServerMemoEditDraft.updatedAt, order: .reverse) private var serverEditDrafts: [ServerMemoEditDraft]

    @State private var activeSession: ActiveEditorSession?
    @State private var activeSheet: RootSheet?
    @State private var allNotesInitialQuery = ""
    @State private var didBootstrap = false

    @StateObject private var sendQueue = DraftSendQueueController()
    @StateObject private var serverSaveQueue = ServerMemoSaveQueueController()
    @StateObject private var serverDeleteQueue = ServerMemoDeleteQueueController()
    @StateObject private var serverMemosStore = ServerMemosStore()

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            editorContent
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topHeader
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView(onBack: {
                    activeSheet = nil
                })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)

            case .allNotes:
                AllNotesSheetView(
                    currentSession: activeSession,
                    initialQuery: allNotesInitialQuery,
                    saveQueue: serverSaveQueue,
                    deleteQueue: serverDeleteQueue,
                    onOpenSettings: {
                        activeSheet = nil
                        DispatchQueue.main.async {
                            activeSheet = .settings
                        }
                    },
                    onSelectDraft: { draft in
                        activateDraft(draft)
                        activeSheet = nil
                    },
                    onSelectServerMemo: { memo in
                        openServerMemoEditor(memo)
                        activeSheet = nil
                    },
                    onSelectServerEditDraft: { editDraft in
                        openServerEditDraft(editDraft)
                        activeSheet = nil
                    }
                )
                .id("all-notes-sheet-\(allNotesInitialQuery)")
                .environmentObject(serverMemosStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .onAppear {
            applyForegroundRoutePolicy()
            pruneInactiveTransientBlankDrafts(preserving: AppSettings.lastActiveDraftID)
            bootstrapIfNeeded()
            sendQueue.startProcessing(in: modelContext)
            sendQueue.retryNow(in: modelContext)
            serverSaveQueue.startProcessing(in: modelContext)
            serverSaveQueue.retryNow(in: modelContext)
            serverDeleteQueue.startProcessing(in: modelContext)
            serverDeleteQueue.retryNow(in: modelContext)
            triggerServerRefreshAfterEditorAppears()
            AppSettings.lastRouteRaw = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                DraftResumeCoordinator.markAppBackgrounded()
                sendQueue.stopProcessing()
                serverSaveQueue.stopProcessing()
                serverDeleteQueue.stopProcessing()
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
                    serverDeleteQueue.startProcessing(in: modelContext)
                    serverDeleteQueue.retryNow(in: modelContext)
                    triggerServerRefreshAfterEditorAppears()
                    return
                }
                ensureEditorHasSession()
                sendQueue.startProcessing(in: modelContext)
                sendQueue.retryNow(in: modelContext)
                serverSaveQueue.startProcessing(in: modelContext)
                serverSaveQueue.retryNow(in: modelContext)
                serverDeleteQueue.startProcessing(in: modelContext)
                serverDeleteQueue.retryNow(in: modelContext)
                triggerServerRefreshAfterEditorAppears()
            }
        }
        .onChange(of: activeSession) { _, newSession in
            pruneInactiveTransientBlankDrafts(preserving: preservedDraftID(for: newSession))
        }
        .onChange(of: drafts.map(\.id)) { _, ids in
            guard case let .localDraft(activeDraftID) = activeSession else { return }
            guard !ids.contains(activeDraftID) else { return }

            activeSession = nil
            resolvePreferredDraft()
        }
        .onReceive(serverSaveQueue.$lastSuccessfulMemo) { memo in
            guard let memo else { return }
            serverMemosStore.upsertMemo(memo)
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
                        onSendQueued: { queuedDraft in
                            handleSendQueued(from: queuedDraft)
                        },
                        onTagTapped: { tag in
                            applyTagSearch(tag)
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
                        onSaveSucceeded: { memo in
                            handleServerSaveSucceeded(memo)
                        },
                        onTagTapped: { tag in
                            applyTagSearch(tag)
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

    private var topHeader: some View {
        HStack(spacing: 0) {
            Text("Memos")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    createAndActivateNewDraft(from: currentLocalDraft)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New note")

                Button {
                    allNotesInitialQuery = ""
                    activeSheet = .allNotes
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All notes")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var currentLocalDraft: Draft? {
        guard case let .localDraft(id) = activeSession else { return nil }
        return drafts.first(where: { $0.id == id })
    }

    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
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
        guard activeSession == nil else { return }
        resolvePreferredDraft()
    }

    private func openServerMemoEditor(_ memo: ServerMemoSummary) {
        let editDraft = ServerMemoSaveService.upsertEditDraft(for: memo, in: modelContext)
        activeSession = .serverMemo(editDraft.memoID)
        DraftResumeCoordinator.markActiveDraft(nil)
    }

    private func openServerEditDraft(_ editDraft: ServerMemoEditDraft) {
        activeSession = .serverMemo(editDraft.memoID)
        DraftResumeCoordinator.markActiveDraft(nil)
    }

    private func createAndActivateNewDraft(from currentDraft: Draft?) {
        if let currentDraft {
            deleteTransientBlankIfNeeded(currentDraft)
        }

        let draft = DraftStore.createDraft(in: modelContext)
        activateDraft(draft)
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

    private func handleServerSaveSucceeded(_ memo: ServerMemoSummary) {
        serverMemosStore.upsertMemo(memo)

        guard case let .serverMemo(activeMemoID) = activeSession, activeMemoID == memo.id else {
            return
        }

        activeSession = nil
        DraftResumeCoordinator.markActiveDraft(nil)
        createAndActivateNewDraft(from: nil)
    }

    @discardableResult
    private func queueDraftForSend(_ draft: Draft) -> Bool {
        return sendQueue.enqueue(draft, in: modelContext)
    }

    private func applyForegroundRoutePolicy(now: Date = Date()) {
        guard !DraftResumeCoordinator.shouldResumePreviousDraft(now: now) else { return }

        activeSession = nil
        AppSettings.lastRouteRaw = nil
    }

    private func triggerServerRefreshAfterEditorAppears() {
        Task { @MainActor in
            await Task.yield()
            await serverMemosStore.refreshIfStale(maxAge: 60)
        }
    }

    private func deleteTransientBlankIfNeeded(_ draft: Draft) {
        let deleted = DraftStore.deleteTransientBlankIfNeeded(draft, in: modelContext)
        if deleted, case let .localDraft(id) = activeSession, id == draft.id {
            activeSession = nil
        }
    }

    private func pruneInactiveTransientBlankDrafts(preserving preservedDraftID: UUID?) {
        let deletedIDs = DraftStore.deleteInactiveTransientBlankDrafts(
            preserving: preservedDraftID,
            from: drafts,
            in: modelContext
        )
        guard let activeDraftID = currentLocalDraft?.id else { return }
        if deletedIDs.contains(activeDraftID) {
            activeSession = nil
        }
    }

    private func preservedDraftID(for session: ActiveEditorSession?) -> UUID? {
        guard case let .localDraft(id) = session else { return nil }
        return id
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
        ensureEditorHasSession()
    }

    private func applyTagSearch(_ rawTag: String) {
        guard let normalizedTag = NotesSearchQuery.normalizedTag(rawTag) else { return }
        allNotesInitialQuery = "tag:\(normalizedTag)"
        activeSheet = .allNotes
    }
}

private struct AllNotesSheetView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var serverMemosStore: ServerMemosStore
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]
    @Query(sort: \ServerMemoEditDraft.updatedAt, order: .reverse) private var serverEditDrafts: [ServerMemoEditDraft]
    @Query(sort: \ServerMemoDeleteTask.updatedAt, order: .reverse) private var deleteTasks: [ServerMemoDeleteTask]

    let currentSession: ActiveEditorSession?
    let initialQuery: String
    let saveQueue: ServerMemoSaveQueueController
    let deleteQueue: ServerMemoDeleteQueueController
    let onOpenSettings: () -> Void
    let onSelectDraft: (Draft) -> Void
    let onSelectServerMemo: (ServerMemoSummary) -> Void
    let onSelectServerEditDraft: (ServerMemoEditDraft) -> Void

    @State private var searchQueryText: String
    @State private var stableRowOrder: [String: Int] = [:]
    @State private var nextStableRowIndex: Int = 0

    init(
        currentSession: ActiveEditorSession?,
        initialQuery: String,
        saveQueue: ServerMemoSaveQueueController,
        deleteQueue: ServerMemoDeleteQueueController,
        onOpenSettings: @escaping () -> Void,
        onSelectDraft: @escaping (Draft) -> Void,
        onSelectServerMemo: @escaping (ServerMemoSummary) -> Void,
        onSelectServerEditDraft: @escaping (ServerMemoEditDraft) -> Void
    ) {
        self.currentSession = currentSession
        self.initialQuery = initialQuery
        self.saveQueue = saveQueue
        self.deleteQueue = deleteQueue
        self.onOpenSettings = onOpenSettings
        self.onSelectDraft = onSelectDraft
        self.onSelectServerMemo = onSelectServerMemo
        self.onSelectServerEditDraft = onSelectServerEditDraft
        _searchQueryText = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("All Notes")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Button {
                    Task {
                        resetStableRowOrder()
                        await serverMemosStore.refresh(force: true)
                        syncStableRowOrder(unsentDrafts: unsentDraftsFiltered, mergedRows: mergedRows)
                    }
                } label: {
                    if serverMemosStore.isLoading {
                        ProgressView()
                            .frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                    }
                }
                .buttonStyle(.plain)
                .disabled(serverMemosStore.isLoading)
                .accessibilityLabel("Refresh notes")

                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search all notes", text: $searchQueryText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                if !searchQueryText.isEmpty {
                    Button {
                        searchQueryText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            List {
                if !displayedUnsentDrafts.isEmpty {
                    ForEach(displayedUnsentDrafts, id: \.id) { draft in
                        unsentDraftRowView(draft)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteDraft(draft)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }

                if mergedRows.isEmpty && displayedUnsentDrafts.isEmpty {
                    emptyView
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(Array(displayedRows.enumerated()), id: \.element.id) { index, row in
                        mergedRowView(row)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .onAppear {
                                guard index >= displayedRows.count - 5 else { return }
                                Task {
                                    await serverMemosStore.loadNextPageIfNeeded()
                                }
                            }
                    }
                }

                if serverMemosStore.isLoadingNextPage {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .task {
            await serverMemosStore.refreshIfStale(maxAge: 10)
        }
        .onAppear {
            syncStableRowOrder(unsentDrafts: unsentDraftsFiltered, mergedRows: mergedRows)
        }
        .onChange(of: unsentDraftsFiltered.map(\.id)) { _, _ in
            syncStableRowOrder(unsentDrafts: unsentDraftsFiltered, mergedRows: mergedRows)
        }
        .onChange(of: mergedRows.map(\.id)) { _, _ in
            syncStableRowOrder(unsentDrafts: unsentDraftsFiltered, mergedRows: mergedRows)
        }
    }

    @ViewBuilder
    private func unsentDraftRowView(_ draft: Draft) -> some View {
        let isCurrent = draft.id == currentDraftID
        let openDraft = {
            onSelectDraft(draft)
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if let timestamp = timestampText(updatedAt: draft.updatedAt) {
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.9)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    statusPill("Draft", color: .indigo)
                    if isCurrent {
                        statusPill("Current", color: .blue)
                    }
                    if draft.sendState == .failed {
                        statusPill("Failed", color: .red)
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
            }
            .frame(minHeight: 24, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture(perform: openDraft)

            draftContentView(draft, onBodyTap: openDraft)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .animation(nil, value: draft.sendState)
    }

    @ViewBuilder
    private func mergedRowView(_ row: MergedTimelineRow) -> some View {
        switch row.source {
        case .localPending(let draft):
            let isCurrent = draft.id == currentDraftID
            let openDraft = {
                onSelectDraft(draft)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    if let timestamp = timestampText(updatedAt: draft.updatedAt) {
                        Text(timestamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.9)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        statusPill("Draft", color: .indigo)

                        if draft.sendState == .sending {
                            statusPill("Sending", color: .blue)
                        } else {
                            statusPill("Pending", color: .orange)
                        }

                        if isCurrent {
                            statusPill("Current", color: .blue)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
                .frame(minHeight: 24, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture(perform: openDraft)

                draftContentView(draft, onBodyTap: openDraft)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .animation(nil, value: draft.sendState)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    deleteDraft(draft)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

        case .server(let rowData):
            let isOpening = serverMemosStore.openingMemoID == rowData.memoID
            let isCurrent = rowData.memoID == currentServerMemoID

            let openServerRow = {
                guard !isOpening, rowData.hasOpenableMemo else { return }

                if let memo = rowData.memo {
                    Task {
                        guard let openMemo = await serverMemosStore.memoForEditing(memo) else { return }
                        onSelectServerMemo(openMemo)
                    }
                } else if let editDraft = rowData.editDraft {
                    onSelectServerEditDraft(editDraft)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    if let timestamp = timestampText(updatedAt: rowData.updatedAt) {
                        Text(timestamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.9)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        if isCurrent {
                            statusPill("Draft", color: .indigo)
                            statusPill("Current", color: .blue)
                        }

                        if isOpening {
                            statusPill("Opening", color: .mint)
                        }

                        if rowData.isSaving {
                            statusPill("Saving", color: .blue)
                        } else if rowData.isPending {
                            statusPill("Pending Save", color: .orange)
                        }

                        if rowData.attachmentCount > 0 {
                            let label = rowData.attachmentCount == 1
                                ? "Attachment"
                                : "Attachments \(rowData.attachmentCount)"
                            statusPill(label, color: .teal)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
                .frame(minHeight: 24, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture(perform: openServerRow)

                serverContentView(rowData, onBodyTap: openServerRow)

                if let error = rowData.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .animation(nil, value: rowData.isSaving)
            .animation(nil, value: rowData.isPending)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    deleteServerRow(rowData)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        VStack(spacing: 12) {
            if !currentSearch.isEmpty {
                Text("No matching notes")
                    .font(.body.weight(.semibold))
                Text("Try a different query or clear search.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if serverMemosStore.isLoading {
                ProgressView("Loading notes…")
            } else if let error = serverMemosStore.errorMessage {
                Text("Unable to load notes")
                    .font(.body.weight(.semibold))
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task {
                        await serverMemosStore.refresh(force: true)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("No notes yet")
                    .font(.body.weight(.semibold))
                Text("Pull to refresh after configuring endpoint and token.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.horizontal, 20)
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
    }

    private var currentSearch: NotesSearchQuery {
        NotesSearchQuery(rawValue: searchQueryText)
    }

    private var currentDraftID: UUID? {
        guard case let .localDraft(id) = currentSession else { return nil }
        return id
    }

    private var currentServerMemoID: String? {
        guard case let .serverMemo(memoID) = currentSession else { return nil }
        return memoID
    }

    private var hiddenMemoIDs: Set<String> {
        Set(deleteTasks.map(\.memoID))
    }

    private var unsentDraftsFiltered: [Draft] {
        let base = DraftStore.visibleUnsentDrafts(from: drafts)

        return base.filter { draft in
            currentSearch.matches(text: draft.text)
        }
    }

    private var mergedRows: [MergedTimelineRow] {
        var rows: [MergedTimelineRow] = []

        let pendingLocalDrafts = drafts.filter { draft in
            guard !draft.isArchived else { return false }
            return draft.sendState == .pending || draft.sendState == .sending
        }

        rows.append(contentsOf: pendingLocalDrafts.map { draft in
            MergedTimelineRow(
                id: "pending-draft-\(draft.id.uuidString)",
                updatedAt: draft.updatedAt,
                source: .localPending(draft)
            )
        })

        var editDraftByMemoID: [String: ServerMemoEditDraft] = [:]
        for editDraft in serverEditDrafts {
            if editDraftByMemoID[editDraft.memoID] == nil {
                editDraftByMemoID[editDraft.memoID] = editDraft
            }
        }

        var seenMemoIDs: Set<String> = []

        for memo in serverMemosStore.memos {
            guard !hiddenMemoIDs.contains(memo.id) else { continue }

            let rowData = ServerTimelineRowData(
                memo: memo,
                editDraft: editDraftByMemoID[memo.id]
            )

            rows.append(
                MergedTimelineRow(
                    id: "server-\(memo.id)",
                    updatedAt: rowData.updatedAt ?? .distantPast,
                    source: .server(rowData)
                )
            )
            seenMemoIDs.insert(memo.id)
        }

        for editDraft in serverEditDrafts where !seenMemoIDs.contains(editDraft.memoID) {
            guard !hiddenMemoIDs.contains(editDraft.memoID) else { continue }

            let rowData = ServerTimelineRowData(memo: nil, editDraft: editDraft)
            rows.append(
                MergedTimelineRow(
                    id: "server-local-only-\(editDraft.memoID)",
                    updatedAt: rowData.updatedAt ?? editDraft.updatedAt,
                    source: .server(rowData)
                )
            )
        }

        let filteredRows = rows.filter { row in
            switch row.source {
            case .localPending(let draft):
                return currentSearch.matches(text: draft.text)
            case .server(let rowData):
                return currentSearch.matches(text: rowData.displayContent)
            }
        }

        return filteredRows.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
    }

    private var displayedUnsentDrafts: [Draft] {
        guard !stableRowOrder.isEmpty else {
            return unsentDraftsFiltered
        }

        return unsentDraftsFiltered.sorted { lhs, rhs in
            let lhsOrder = stableRowOrder[unsentRowID(for: lhs)] ?? Int.max
            let rhsOrder = stableRowOrder[unsentRowID(for: rhs)] ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private var displayedRows: [MergedTimelineRow] {
        guard !stableRowOrder.isEmpty else {
            return mergedRows
        }

        return mergedRows.sorted { lhs, rhs in
            let lhsOrder = stableRowOrder[lhs.id] ?? Int.max
            let rhsOrder = stableRowOrder[rhs.id] ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
    }

    private func syncStableRowOrder(unsentDrafts: [Draft], mergedRows: [MergedTimelineRow]) {
        if stableRowOrder.isEmpty {
            var seeded: [String: Int] = [:]
            var index = 0
            for draft in unsentDrafts {
                seeded[unsentRowID(for: draft)] = index
                index += 1
            }
            for row in mergedRows {
                seeded[row.id] = index
                index += 1
            }
            stableRowOrder = seeded
            nextStableRowIndex = index
            return
        }

        var map = stableRowOrder
        var nextIndex = nextStableRowIndex
        for draft in unsentDrafts where map[unsentRowID(for: draft)] == nil {
            map[unsentRowID(for: draft)] = nextIndex
            nextIndex += 1
        }
        for row in mergedRows where map[row.id] == nil {
            map[row.id] = nextIndex
            nextIndex += 1
        }
        stableRowOrder = map
        nextStableRowIndex = nextIndex
    }

    private func resetStableRowOrder() {
        stableRowOrder = [:]
        nextStableRowIndex = 0
    }

    private func unsentRowID(for draft: Draft) -> String {
        "unsent-draft-\(draft.id.uuidString)"
    }

    @ViewBuilder
    private func draftContentView(_ draft: Draft, onBodyTap: @escaping () -> Void) -> some View {
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Text("(Empty note)")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onBodyTap)
        } else {
            RenderedNoteTextView(
                text: Binding(
                    get: { draft.text },
                    set: { newValue in
                        applyDraftChangeFromSheet(draft, newText: newValue)
                    }
                ),
                allowsScrolling: false,
                onTagTapped: { tag in
                    applyTagFilter(tag)
                },
                onNonInteractiveTap: onBodyTap
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func serverContentView(_ rowData: ServerTimelineRowData, onBodyTap: @escaping () -> Void) -> some View {
        let renderedText = serverRenderableText(for: rowData)
        if renderedText == "(Empty note)" || renderedText == "(Attachment note)" {
            Text(renderedText)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onBodyTap)
        } else {
            RenderedNoteTextView(
                text: Binding(
                    get: { serverRenderableText(for: rowData) },
                    set: { newValue in
                        applyServerRowContentChange(rowData, newText: newValue)
                    }
                ),
                allowsScrolling: false,
                onTagTapped: { tag in
                    applyTagFilter(tag)
                },
                onNonInteractiveTap: onBodyTap
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func serverRenderableText(for rowData: ServerTimelineRowData) -> String {
        if let editDraft = rowData.editDraft, editDraft.hasLocalChanges || editDraft.saveState != .idle || rowData.memo == nil {
            return displayContent(for: editDraft.localContent)
        }

        if let memo = rowData.memo {
            let trimmedContent = memo.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedContent.isEmpty {
                return memo.content
            }

            let snippet = memo.snippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !snippet.isEmpty {
                return memo.snippet ?? snippet
            }

            if memo.attachmentCount > 0 {
                return "(Attachment note)"
            }
        }

        return rowData.displayContent
    }

    private func applyDraftChangeFromSheet(_ draft: Draft, newText: String) {
        guard draft.text != newText else { return }

        draft.text = newText
        draft.updatedAt = Date()

        if AppSettings.clearErrorOnEdit {
            draft.lastError = nil
        }

        if draft.sendState == .pending || draft.sendState == .failed {
            draft.sendState = .idle
        }

        if draft.lastSentAt != nil {
            draft.sendState = .idle
            draft.isArchived = false
        }

        modelContext.saveOrAssert()
    }

    private func applyServerRowContentChange(_ rowData: ServerTimelineRowData, newText: String) {
        let targetDraft: ServerMemoEditDraft
        if let existingDraft = rowData.editDraft {
            targetDraft = existingDraft
        } else if let memo = rowData.memo, memo.hasFullContent {
            targetDraft = ServerMemoSaveService.upsertEditDraft(for: memo, in: modelContext)
        } else {
            return
        }

        let didChange = ServerMemoSaveService.stageLocalContent(
            newText,
            for: targetDraft,
            in: modelContext,
            persist: true
        )
        guard didChange else { return }

        _ = saveQueue.enqueue(targetDraft, in: modelContext)
    }

    private func applyTagFilter(_ rawTag: String) {
        guard let normalizedTag = NotesSearchQuery.normalizedTag(rawTag) else { return }
        searchQueryText = "tag:\(normalizedTag)"
    }

    private func deleteDraft(_ draft: Draft) {
        DraftStore.delete(draft, in: modelContext)
    }

    private func deleteServerRow(_ rowData: ServerTimelineRowData) {
        if let editDraft = rowData.editDraft {
            modelContext.delete(editDraft)
            modelContext.saveOrAssert()
        }

        serverMemosStore.removeMemo(memoID: rowData.memoID)
        _ = deleteQueue.enqueue(
            memoID: rowData.memoID,
            resourceName: rowData.deleteResourceName,
            in: modelContext
        )
    }

    private func displayContent(for rawContent: String) -> String {
        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "(Empty note)"
        }
        return rawContent
    }

    private func timestampText(updatedAt: Date?) -> String? {
        guard let updatedAt else { return nil }
        let age = Date().timeIntervalSince(updatedAt)
        if age >= 24 * 60 * 60 {
            return updatedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }

        let fullHours = max(1, Int(age / 3600))
        if fullHours == 1 {
            return "1 hour ago"
        }
        return "\(fullHours) hours ago"
    }
}
