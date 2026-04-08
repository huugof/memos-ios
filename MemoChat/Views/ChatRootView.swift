import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct PendingImage: Identifiable {
    let id = UUID()
    let image: UIImage
    var uploadedURL: String? = nil
    var isUploading: Bool = true
}

struct PendingFile: Identifiable {
    let id = UUID()
    let filename: String
    var uploadedURL: String? = nil
    var isUploading: Bool = true
}

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

private enum PlusSheetAction {
    case photos, files
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
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var plusSheetPendingAction: PlusSheetAction?
    @State private var pendingImages: [PendingImage] = []
    @State private var pendingFiles: [PendingFile] = []
    @State private var imageUploadError: String?
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchAutoFocus = true
    @State private var editingTarget: EditingTarget?
    @State private var showTodosOnly = false
    @State private var showDraftsOnly = false
    @State private var showAttachmentsOnly = false
    @State private var inputFocusTrigger = UUID()
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
            if hasLocalEdits, let editDraft {
                let local = editDraft.localContent.trimmingCharacters(in: .whitespacesAndNewlines)
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
            entries = entries.filter { $0.sendState == nil && !$0.hasLocalEdits && !$0.isSavePending }
        }

        // Mutually exclusive filter modes
        if showDraftsOnly {
            entries = entries.filter { $0.sendState != nil || $0.hasLocalEdits || $0.isSavePending }
        } else if showAttachmentsOnly {
            entries = entries.filter { $0.text.contains("![") }
        } else if showTodosOnly {
            entries = entries.compactMap { entry -> TimelineEntry? in
                let openTodos = entry.text.components(separatedBy: "\n").filter { $0.contains("- [ ]") }
                guard !openTodos.isEmpty else { return nil }
                var copy = entry
                copy.text = openTodos.joined(separator: "\n")
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

    private static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dayFormatter: DateFormatter  = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
    private static let fullFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f }()

    private static func headerLabel(for date: Date) -> String {
        let cal = Calendar.current
        let time = timeFormatter.string(from: date)
        if cal.isDateInToday(date)     { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "\(dayFormatter.string(from: date)) \(time)" }
        return "\(fullFormatter.string(from: date)) at \(time)"
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            timeline
                // Fill behind the Dynamic Island only — not behind the input bar
                .background(Color(uiColor: .systemBackground).ignoresSafeArea(.container, edges: .top))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomBar
                }
        }
        .sheet(item: $editingTarget) { target in
            ChatMemoEditorSheet(entryID: target.id)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItems, maxSelectionCount: nil, matching: .images)
        .onChange(of: selectedPhotoItems) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run { handleImageSelected(image) }
                    }
                }
                selectedPhotoItems = []
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let filename = url.lastPathComponent
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            handleFileSelected(url: url, filename: filename, mimeType: mimeType)
        }
        .sheet(isPresented: $showPlusSheet, onDismiss: {
            if let action = plusSheetPendingAction {
                plusSheetPendingAction = nil
                switch action {
                case .photos: showPhotoPicker = true
                case .files: showFilePicker = true
                }
            }
        }) {
            ChatPlusSheet(
                isPresented: $showPlusSheet,
                showTodosOnly: $showTodosOnly,
                showDraftsOnly: $showDraftsOnly,
                showAttachmentsOnly: $showAttachmentsOnly,
                showDrafts: $showDrafts,
                onSearch: {
                    searchAutoFocus = true
                    isSearching = true
                },
                onRefresh: {
                    Task { await serverMemosStore.loadAllPages() }
                },
                onPhotoPicker: { plusSheetPendingAction = .photos },
                onFilePicker: { plusSheetPendingAction = .files },
                onSendAll: handleSendAll
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Upload Failed", isPresented: .init(
            get: { imageUploadError != nil },
            set: { if !$0 { imageUploadError = nil } }
        )) {
            Button("OK") { imageUploadError = nil }
        } message: {
            if let err = imageUploadError { Text(err) }
        }
        .task { await serverMemosStore.loadAllPages() }
        .onAppear {
            ensureActiveDraft()
            sendQueue.startProcessing(in: modelContext)
            serverDeleteQueue.startProcessing(in: modelContext)
            saveQueue.startProcessing(in: modelContext)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                inputFocusTrigger = UUID()
            }
        }
        .onChange(of: sendQueue.lastCreatedMemo) { _, memo in
            guard let memo else { return }
            serverMemosStore.upsertMemo(memo)
        }
        .onChange(of: saveQueue.lastSuccessfulMemo) { _, memo in
            guard let memo else { return }
            serverMemosStore.upsertMemo(memo)
        }
        .onChange(of: showTodosOnly) { _, isActive in
            guard !isActive else { return }
            // Only enqueue drafts that actually have local changes (avoids state churn on clean drafts)
            // Note: manual send handles syncing; auto-enqueue removed per item 12.
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
                    setActiveDraftID: { activeDraftID = $0 }
                )
                sendQueue.startProcessing(in: modelContext)
                sendQueue.retryNow(in: modelContext)
                serverDeleteQueue.startProcessing(in: modelContext)
                serverDeleteQueue.retryNow(in: modelContext)
                saveQueue.startProcessing(in: modelContext)
                saveQueue.retryNow(in: modelContext)
                Task { await serverMemosStore.refreshAllIfStale() }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        let gradient = LinearGradient(
            colors: [.clear, Color(uiColor: .systemBackground).opacity(0.6)],
            startPoint: .top,
            endPoint: .bottom
        )
        ZStack(alignment: .bottom) {
            // Always in the hierarchy so the keyboard never dismisses on mode switch.
            ChatInputBar(
                activeDraft: activeDraft,
                keyboardVisible: keyboard.isVisible,
                focusTrigger: inputFocusTrigger,
                onCommit: commitActiveDraft,
                onPlusTapped: { showPlusSheet = true },
                onImageSelected: handleImageSelected,
                pendingImages: pendingImages,
                onRemoveImage: { id in pendingImages.removeAll { $0.id == id } },
                pendingFiles: pendingFiles,
                onRemoveFile: { id in pendingFiles.removeAll { $0.id == id } },
                tagSuggestions: tagsByFrequency
            )
            .opacity(isSearching ? 0 : 1)
            .allowsHitTesting(!isSearching)

            if isSearching {
                ChatSearchBar(text: $searchText, keyboardVisible: keyboard.isVisible, autoFocus: searchAutoFocus) {
                    // Reclaim input focus before search bar leaves — keeps keyboard up.
                    inputFocusTrigger = UUID()
                    isSearching = false
                    searchText = ""
                    showTodosOnly = false
                    showDraftsOnly = false
                    showAttachmentsOnly = false
                }
            }
        }
        .background(alignment: .bottom) {
            gradient.frame(height: 220).offset(y: 44).allowsHitTesting(false)
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
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
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
                                onSaveToServer: entry.hasLocalEdits ? { handleSaveToServer(entry) } :
                                                (entry.id.hasPrefix("d-") ? { handleSendDraft(entry) } : nil),
                                onCheckboxToggled: entry.id.hasPrefix("m-") ? { handleCheckboxToggle(entry, newText: $0) } : nil,
                                onTagTapped: { handleTagTap($0) },
                                suppressLocalEditsBadge: showTodosOnly
                            )
                            .transaction { $0.animation = nil }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 3)
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
            .background(Color(uiColor: .systemBackground))
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
            .refreshable { await serverMemosStore.loadAllPages() }
            .onChange(of: showTodosOnly) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: showDraftsOnly) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: showAttachmentsOnly) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: isSearching) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: mergedTimeline.count) { oldCount, newCount in
                // Only scroll to bottom when new messages are added, not on delete/edit
                guard newCount > oldCount else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: keyboard.isVisible) { _, visible in
                if visible {
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
        guard let draft = activeDraft else { return }
        let readyImages = pendingImages.filter { $0.uploadedURL != nil }
        let readyFiles = pendingFiles.filter { $0.uploadedURL != nil }
        guard draft.hasStartedText || !readyImages.isEmpty || !readyFiles.isEmpty else { return }
        for p in readyImages {
            guard let url = p.uploadedURL else { continue }
            let sep = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
            draft.text += sep + "![](\(url))"
        }
        for f in readyFiles {
            guard let url = f.uploadedURL else { continue }
            let sep = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
            draft.text += sep + "[\(f.filename)](\(url))"
        }
        if !readyImages.isEmpty || !readyFiles.isEmpty { draft.updatedAt = Date(); modelContext.saveOrAssert() }
        pendingImages.removeAll()
        pendingFiles.removeAll()
        sendQueue.enqueue(draft, in: modelContext)
        let newDraft = DraftStore.createDraft(in: modelContext)
        activeDraftID = newDraft.id
    }

    private func handleImageSelected(_ image: UIImage) {
        let resized = image.resizedToMaxEdge(1024)
        guard let data = resized.jpegData(compressionQuality: 0.75) else { return }
        var pending = PendingImage(image: resized)
        pendingImages.append(pending)
        let pendingID = pending.id
        Task {
            do {
                let result = try await MemosClient().uploadResource(
                    imageData: data,
                    mimeType: "image/jpeg",
                    filename: "image.jpg",
                    baseURLString: AppSettings.endpointBaseURL,
                    token: KeychainTokenStore.getToken(),
                    allowInsecureHTTP: AppSettings.allowInsecureHTTP
                )
                let base = AppSettings.endpointBaseURL.trimmingCharacters(in: .init(charactersIn: "/"))
                let url = "\(base)\(result.fileURLPath)"
                if let idx = pendingImages.firstIndex(where: { $0.id == pendingID }) {
                    pendingImages[idx].uploadedURL = url
                    pendingImages[idx].isUploading = false
                }
            } catch {
                pendingImages.removeAll { $0.id == pendingID }
                imageUploadError = error.localizedDescription
            }
        }
    }

    private func handleFileSelected(url: URL, filename: String, mimeType: String) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            imageUploadError = "Could not read file data"
            return
        }
        let pending = PendingFile(filename: filename)
        pendingFiles.append(pending)
        let pendingID = pending.id
        Task {
            do {
                let result = try await MemosClient().uploadResource(
                    imageData: data,
                    mimeType: mimeType,
                    filename: filename,
                    baseURLString: AppSettings.endpointBaseURL,
                    token: KeychainTokenStore.getToken(),
                    allowInsecureHTTP: AppSettings.allowInsecureHTTP
                )
                let base = AppSettings.endpointBaseURL.trimmingCharacters(in: .init(charactersIn: "/"))
                let resourceURL = "\(base)\(result.fileURLPath)"
                if let idx = pendingFiles.firstIndex(where: { $0.id == pendingID }) {
                    pendingFiles[idx].uploadedURL = resourceURL
                    pendingFiles[idx].isUploading = false
                }
            } catch {
                pendingFiles.removeAll { $0.id == pendingID }
                imageUploadError = error.localizedDescription
            }
        }
    }

    private func handleEdit(_ entry: TimelineEntry) {
        if entry.id.hasPrefix("m-") {
            let memoID = String(entry.id.dropFirst(2))
            guard let memo = serverMemosStore.memo(memoID: memoID), memo.hasFullContent else { return }
            _ = ServerMemoSaveService.upsertEditDraft(for: memo, in: modelContext)
        }
        editingTarget = EditingTarget(id: entry.id)
    }

    private func handleSendAll() {
        for draft in allDrafts where !draft.isBlank && !draft.isArchived && draft.id != activeDraftID {
            sendQueue.enqueue(draft, in: modelContext)
        }
        for editDraft in allEditDrafts where editDraft.hasLocalChanges {
            Task { @MainActor in
                await saveQueue.saveNow(editDraft, in: modelContext)
            }
        }
    }

    private func handleSendDraft(_ entry: TimelineEntry) {
        guard entry.id.hasPrefix("d-"),
              let uuid = UUID(uuidString: String(entry.id.dropFirst(2))),
              let draft = allDrafts.first(where: { $0.id == uuid }) else { return }
        sendQueue.enqueue(draft, in: modelContext)
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

        // Use the current local content as the base (if it exists and is non-empty) rather than
        // the server content. This ensures:
        //   (a) Multiple rapid checkbox toggles don't revert each other (local content already
        //       has the first toggle applied, server content doesn't yet).
        //   (b) Locally-added todo lines that don't exist on the server yet are preserved instead
        //       of falling back to the truncated filtered-only text.
        let existingLocalContent = editDraftByMemoID[memoID]?.localContent ?? ""
        let baseContent = existingLocalContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? memo.content : existingLocalContent

        // In todo mode, entry.text is a filtered subset of the full memo. We need to find
        // which checkbox line changed and apply that same change to the full memo content.
        let fullContent = applyCheckboxChange(from: entry.text, to: newText, in: baseContent)

        let editDraft = ServerMemoSaveService.upsertEditDraft(for: memo, in: modelContext)
        ServerMemoSaveService.stageLocalContent(fullContent, for: editDraft, in: modelContext)
        // Changes are staged locally; user must manually send via context menu or double-tap.
    }

    /// Finds the line that changed between `oldFiltered` and `newFiltered` and applies
    /// that same substitution inside `fullContent`. Falls back to `newFiltered` if no
    /// single-line diff can be detected (i.e. the entry text was the full content).
    private func applyCheckboxChange(from oldFiltered: String, to newFiltered: String, in fullContent: String) -> String {
        let oldLines = oldFiltered.components(separatedBy: "\n")
        let newLines = newFiltered.components(separatedBy: "\n")
        guard oldLines.count == newLines.count else { return newFiltered }

        // Find the single line that changed
        var changedOld: String?
        var changedNew: String?
        for (old, new) in zip(oldLines, newLines) where old != new {
            if changedOld != nil { return newFiltered } // more than one line changed — bail
            changedOld = old
            changedNew = new
        }
        guard let from = changedOld, let to = changedNew else { return newFiltered }

        // Replace the first occurrence of that line in the full content
        let fullLines = fullContent.components(separatedBy: "\n")
        var replaced = false
        let resultLines = fullLines.map { line -> String in
            if !replaced && line == from {
                replaced = true
                return to
            }
            return line
        }
        return replaced ? resultLines.joined(separator: "\n") : newFiltered
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

private extension UIImage {
    /// Scales the image down so its longest edge is at most `maxEdge` points.
    /// Returns self unchanged if already within the limit.
    func resizedToMaxEdge(_ maxEdge: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxEdge else { return self }
        let scale = maxEdge / longest
        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
