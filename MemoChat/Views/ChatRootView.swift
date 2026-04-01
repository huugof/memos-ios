import SwiftUI
import SwiftData

private struct TimelineEntry: Identifiable {
    let id: String
    let date: Date
    var text: String
    var sendState: Draft.SendState? = nil
    var isSentAndUnedited: Bool = false
    var hasLocalEdits: Bool = false
    var isSavePending: Bool = false
}

private struct EditingTarget: Identifiable {
    let id: String  // "m-{memoID}" or "d-{uuid}"
}

private enum DisplayItem: Identifiable {
    case header(id: String, label: String)
    case message(TimelineEntry)

    var id: String {
        switch self {
        case .header(let id, _): return id
        case .message(let e):    return e.id
        }
    }
}

struct ChatRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Draft.createdAt, order: .forward) private var allDrafts: [Draft]
    @Query private var allEditDrafts: [ServerMemoEditDraft]

    @State private var activeDraftID: UUID?
    @State private var showPlusSheet = false
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchAutoFocus = true
    @State private var editingTarget: EditingTarget?
    @State private var showTodosOnly = false
    @State private var showDraftsOnly = false
    @AppStorage("chatShowDrafts") private var showDrafts = true

    @StateObject private var sendQueue = DraftSendQueueController()
    @StateObject private var serverMemosStore = ServerMemosStore()
    @StateObject private var serverDeleteQueue = ServerMemoDeleteQueueController()
    @StateObject private var saveQueue = ServerMemoSaveQueueController()
    @StateObject private var keyboard = KeyboardStateObserver()

    private var activeDraft: Draft? {
        guard let id = activeDraftID else { return nil }
        return allDrafts.first { $0.id == id }
    }

    private var editDraftByMemoID: [String: ServerMemoEditDraft] {
        Dictionary(allEditDrafts.map { ($0.memoID, $0) }, uniquingKeysWith: { f, _ in f })
    }

    private var mergedTimeline: [TimelineEntry] {
        var entries: [TimelineEntry] = []
        var serverTexts: Set<String> = []

        for memo in serverMemosStore.memos {
            let editDraft = editDraftByMemoID[memo.id]
            let hasLocalEdits = editDraft?.hasLocalChanges == true
            let isSavePending = editDraft?.saveState == .pending || editDraft?.saveState == .saving
            let displayText: String
            if hasLocalEdits {
                let local = editDraft!.localContent.trimmingCharacters(in: .whitespacesAndNewlines)
                displayText = local.isEmpty
                    ? memo.preferredDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
                    : local
            } else {
                displayText = memo.preferredDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !displayText.isEmpty else { continue }
            entries.append(TimelineEntry(
                id: "m-\(memo.id)",
                date: memo.updatedAt ?? .distantPast,
                text: displayText,
                hasLocalEdits: hasLocalEdits,
                isSavePending: isSavePending
            ))
            // Include all known content versions for this memo in the dedup set so that old
            // drafts matching any version of the text stay hidden from the timeline.
            [
                memo.preferredDisplayText,
                editDraft?.serverContent,
                editDraft?.localContent,
                editDraft?.previousServerContent
            ]
            .compactMap { $0 }
            .forEach { serverTexts.insert($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        for draft in allDrafts where !draft.isBlank && !draft.isArchived && draft.id != activeDraftID {
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serverTexts.contains(text) else { continue }
            entries.append(TimelineEntry(
                id: "d-\(draft.id.uuidString)",
                date: draft.createdAt,
                text: text,
                sendState: draft.sendState,
                isSentAndUnedited: draft.isSentAndUnedited
            ))
        }

        return entries.sorted { $0.date < $1.date }
    }

    private func extractTags(from text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for match in text.matches(of: /\#([A-Za-z0-9_\-]+)/) {
            let tag = String(match.output.1).lowercased()
            if seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }

    private var tagsByFrequency: [String] {
        var counts: [String: Int] = [:]
        for entry in mergedTimeline {
            for tag in extractTags(from: entry.text) {
                counts[tag, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    private func handleTagTap(_ tag: String) {
        searchText = "#\(tag)"
        searchAutoFocus = false
        isSearching = true
    }

    private var filteredTimeline: [TimelineEntry] {
        var entries = mergedTimeline

        // Persistent draft visibility preference (overridden when drafts filter is active)
        if !showDrafts && !showDraftsOnly {
            entries = entries.filter { $0.sendState == nil }
        }

        // Mutually exclusive filter modes
        if showDraftsOnly {
            entries = entries.filter { $0.sendState != nil }
        } else if showTodosOnly {
            entries = entries.compactMap { entry -> TimelineEntry? in
                let todoLines = entry.text.components(separatedBy: "\n").filter { $0.contains("- [ ]") }
                guard !todoLines.isEmpty else { return nil }
                var copy = entry
                copy.text = todoLines.joined(separator: "\n")
                return copy
            }
        }

        // Text search applies on top of active filter
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.text.lowercased().contains(q) }
    }

    // Group messages: insert a time header whenever > 1 hour passes between messages
    private var displayTimeline: [DisplayItem] {
        var result: [DisplayItem] = []
        var prevDate: Date? = nil

        for entry in filteredTimeline {
            let needsHeader = prevDate.map { entry.date.timeIntervalSince($0) > 3600 } ?? true
            if needsHeader {
                result.append(.header(id: "h-\(entry.id)", label: Self.headerLabel(for: entry.date)))
            }
            result.append(.message(entry))
            prevDate = entry.date
        }
        return result
    }

    private static func headerLabel(for date: Date) -> String {
        let cal = Calendar.current
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let time = tf.string(from: date)

        if cal.isDateInToday(date)     { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }

        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 {
            let df = DateFormatter(); df.dateFormat = "EEE"
            return "\(df.string(from: date)) \(time)"
        }
        let df = DateFormatter(); df.dateFormat = "EEE, MMM d"
        return "\(df.string(from: date)) at \(time)"
    }

    var body: some View {
        ZStack {
            timeline
                // Fill behind the Dynamic Island only — not behind the input bar
                .background(Color(uiColor: .systemBackground).ignoresSafeArea(.container, edges: .top))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Group {
                        if isSearching {
                            ChatSearchBar(text: $searchText, keyboardVisible: keyboard.isVisible, autoFocus: searchAutoFocus) {
                                isSearching = false
                                searchText = ""
                            }
                        } else {
                            ChatInputBar(activeDraft: activeDraft, keyboardVisible: keyboard.isVisible, onCommit: commitActiveDraft, onPlusTapped: { showPlusSheet = true })
                        }
                    }
                    .background(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, Color(uiColor: .systemBackground).opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 220)
                        .offset(y: 44)
                        .allowsHitTesting(false)
                    }
                }
        }
        .sheet(item: $editingTarget) { target in
            ChatMemoEditorSheet(entryID: target.id)
        }
        .sheet(isPresented: $showPlusSheet) {
            ChatPlusSheet(
                isPresented: $showPlusSheet,
                showTodosOnly: $showTodosOnly,
                showDraftsOnly: $showDraftsOnly,
                showDrafts: $showDrafts,
                onSearch: {
                    searchAutoFocus = true
                    isSearching = true
                },
                onTagSearch: { tag in
                    searchText = "#\(tag)"
                    searchAutoFocus = false
                    isSearching = true
                },
                onRefresh: {
                    Task { await serverMemosStore.refresh(force: true) }
                },
                tags: tagsByFrequency
            )
            .presentationDetents([.height(520)])
            .presentationDragIndicator(.visible)
        }
        .task { await serverMemosStore.ensureInitialLoad() }
        .onAppear {
            ensureActiveDraft()
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
                ChatAutoCommitCoordinator.onBackground()
                sendQueue.stopProcessing()
                serverDeleteQueue.stopProcessing()
                saveQueue.stopProcessing()
            case .active:
                ChatAutoCommitCoordinator.onForeground(
                    activeDraftID: activeDraftID,
                    allDrafts: allDrafts,
                    modelContext: modelContext,
                    sendQueue: sendQueue,
                    setActiveDraftID: { activeDraftID = $0 }
                )
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

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayTimeline) { item in
                        switch item {
                        case .header(_, let label):
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 14)
                                .padding(.top, 4)

                        case .message(let entry):
                            ChatBubbleView(
                                text: entry.text,
                                sendState: entry.sendState,
                                isSentAndUnedited: entry.isSentAndUnedited,
                                hasLocalEdits: entry.hasLocalEdits,
                                isSavePending: entry.isSavePending,
                                onEdit: { handleEdit(entry) },
                                onDelete: { handleDelete(entry) },
                                onSaveToServer: entry.hasLocalEdits ? { handleSaveToServer(entry) } : nil,
                                onDoubleTap: entry.hasLocalEdits ? { handleSaveToServer(entry) } : nil,
                                onCheckboxToggled: entry.id.hasPrefix("m-") ? { handleCheckboxToggle(entry, newText: $0) } : nil,
                                onTagTapped: { handleTagTap($0) }
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                            .id(entry.id)
                        }
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // Extend scroll view behind the floating bar; keyboard safe area still applies
            .ignoresSafeArea(.container, edges: .bottom)
            // Push scroll content up so last message can be fully above the bar
            .contentMargins(.bottom, 110, for: .scrollContent)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color(uiColor: .systemBackground), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 50)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
            .refreshable { await serverMemosStore.refresh(force: true) }
            .onChange(of: mergedTimeline.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func ensureActiveDraft() {
        if let id = activeDraftID, allDrafts.contains(where: { $0.id == id }) { return }
        let draft = DraftStore.createDraft(in: modelContext)
        activeDraftID = draft.id
    }

    func commitActiveDraft() {
        guard let draft = activeDraft, draft.hasStartedText else { return }
        sendQueue.enqueue(draft, in: modelContext)
        let newDraft = DraftStore.createDraft(in: modelContext)
        activeDraftID = newDraft.id
    }

    private func handleEdit(_ entry: TimelineEntry) {
        if entry.id.hasPrefix("m-") {
            let memoID = String(entry.id.dropFirst(2))
            guard let memo = serverMemosStore.memo(memoID: memoID), memo.hasFullContent else { return }
            _ = ServerMemoSaveService.upsertEditDraft(for: memo, in: modelContext)
            editingTarget = EditingTarget(id: entry.id)
        } else {
            editingTarget = EditingTarget(id: entry.id)
        }
    }

    private func handleSaveToServer(_ entry: TimelineEntry) {
        guard entry.id.hasPrefix("m-") else { return }
        let memoID = String(entry.id.dropFirst(2))
        guard let editDraft = editDraftByMemoID[memoID] else { return }
        Task { @MainActor in
            await saveQueue.saveNow(editDraft, in: modelContext)
            // Timeline updates via onChange(of: saveQueue.lastSuccessfulMemo)
        }
    }

    private func handleCheckboxToggle(_ entry: TimelineEntry, newText: String) {
        guard entry.id.hasPrefix("m-") else { return }
        let memoID = String(entry.id.dropFirst(2))
        guard let memo = serverMemosStore.memo(memoID: memoID), memo.hasFullContent else { return }
        let editDraft = ServerMemoSaveService.upsertEditDraft(for: memo, in: modelContext)
        ServerMemoSaveService.stageLocalContent(newText, for: editDraft, in: modelContext)
        _ = saveQueue.enqueue(editDraft, in: modelContext)
    }

    private func handleDelete(_ entry: TimelineEntry) {
        if entry.id.hasPrefix("d-"),
           let uuid = UUID(uuidString: String(entry.id.dropFirst(2))),
           let draft = allDrafts.first(where: { $0.id == uuid }) {
            DraftStore.delete(draft, in: modelContext)
        } else if entry.id.hasPrefix("m-") {
            let memoID = String(entry.id.dropFirst(2))
            if let memo = serverMemosStore.memo(memoID: memoID) {
                serverMemosStore.removeMemo(memoID: memoID)
                _ = serverDeleteQueue.enqueue(
                    memoID: memoID,
                    resourceName: memo.resourceName ?? memoID,
                    in: modelContext
                )
            }
        }
    }
}

private struct ChatSearchBar: View {
    @Binding var text: String
    let keyboardVisible: Bool
    let autoFocus: Bool
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    private let buttonSize: CGFloat = 50  // matches singleLinePillHeight in ChatInputBar
    private var horizontalPad: CGFloat { keyboardVisible ? 12 : 28 }
    private var bottomPad: CGFloat { keyboardVisible ? 10 : -10 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Cancel button — mirrors the plus button position
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: buttonSize, height: buttonSize)
                    .glassEffect(in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            // Search pill — mirrors the input pill position and style
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .frame(minHeight: buttonSize)
            .glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, horizontalPad)
        .padding(.top, 8)
        .padding(.bottom, bottomPad)
        .animation(.easeOut(duration: 0.2), value: keyboardVisible)
        .onAppear { if autoFocus { focused = true } }
    }
}
