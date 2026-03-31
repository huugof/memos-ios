import SwiftUI
import SwiftData

private struct TimelineEntry: Identifiable {
    let id: String
    let date: Date
    let text: String
    var sendState: Draft.SendState? = nil
    var isSentAndUnedited: Bool = false
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

    @State private var activeDraftID: UUID?
    @State private var showPlusSheet = false
    @State private var isSearching = false
    @State private var searchText = ""

    @StateObject private var sendQueue = DraftSendQueueController()
    @StateObject private var serverMemosStore = ServerMemosStore()
    @StateObject private var serverDeleteQueue = ServerMemoDeleteQueueController()

    private var activeDraft: Draft? {
        guard let id = activeDraftID else { return nil }
        return allDrafts.first { $0.id == id }
    }

    private var mergedTimeline: [TimelineEntry] {
        var entries: [TimelineEntry] = []

        for draft in allDrafts where !draft.isBlank && !draft.isArchived && draft.id != activeDraftID {
            entries.append(TimelineEntry(
                id: "d-\(draft.id.uuidString)",
                date: draft.createdAt,
                text: draft.text,
                sendState: draft.sendState,
                isSentAndUnedited: draft.isSentAndUnedited
            ))
        }

        for memo in serverMemosStore.memos {
            let text = memo.preferredDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            entries.append(TimelineEntry(
                id: "m-\(memo.id)",
                date: memo.updatedAt ?? .distantPast,
                text: text
            ))
        }

        return entries.sorted { $0.date < $1.date }
    }

    private var filteredTimeline: [TimelineEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return mergedTimeline }
        return mergedTimeline.filter { $0.text.lowercased().contains(q) }
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
                    if isSearching {
                        ChatSearchBar(text: $searchText) {
                            isSearching = false
                            searchText = ""
                        }
                    } else {
                        ChatInputBar(activeDraft: activeDraft, onCommit: commitActiveDraft, onPlusTapped: { showPlusSheet = true })
                    }
                }
        }
        .sheet(isPresented: $showPlusSheet) {
            ChatPlusSheet(
                isPresented: $showPlusSheet,
                onTagInsert: {
                    guard let draft = activeDraft else { return }
                    draft.text.append("#")
                    draft.updatedAt = Date()
                },
                onRefresh: {
                    Task { await serverMemosStore.refresh(force: true) }
                },
                onSearch: {
                    isSearching = true
                }
            )
            .presentationDetents([.height(260)])
            .presentationDragIndicator(.visible)
        }
        .task { await serverMemosStore.ensureInitialLoad() }
        .onAppear {
            ensureActiveDraft()
            sendQueue.startProcessing(in: modelContext)
            serverDeleteQueue.startProcessing(in: modelContext)
        }
        .onChange(of: sendQueue.lastCreatedMemo) { _, memo in
            guard let memo else { return }
            serverMemosStore.upsertMemo(memo)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                ChatAutoCommitCoordinator.onBackground()
                sendQueue.stopProcessing()
                serverDeleteQueue.stopProcessing()
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
                                onEdit: { handleEdit(entry) },
                                onDelete: { handleDelete(entry) }
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 2)
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
            .contentMargins(.bottom, 74, for: .scrollContent)
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
        guard let draft = activeDraft else { return }
        draft.text = entry.text
        draft.updatedAt = Date()
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
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    private let buttonSize: CGFloat = 50  // matches singleLinePillHeight in ChatInputBar

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Cancel button — mirrors the plus button position
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
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
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .frame(minHeight: buttonSize)
            .glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .onAppear { focused = true }
    }
}
