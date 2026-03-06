import SwiftUI
import SwiftData

struct ServerMemoEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]

    @Bindable var editDraft: ServerMemoEditDraft

    let saveQueue: ServerMemoSaveQueueController
    let onOpenDraftsSheet: () -> Void
    let onSaveSucceeded: (ServerMemoSummary) -> Void

    @State private var draftText: String
    @State private var remoteTagTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var isEditorFocused = true
    @State private var focusRequestID = UUID()
    @State private var remoteTags: [String] = []
    @State private var tagSuggestions: [String] = []
    @State private var isTopBarHidden = false
    @StateObject private var keyboard = KeyboardStateObserver()

    init(
        editDraft: ServerMemoEditDraft,
        saveQueue: ServerMemoSaveQueueController,
        onOpenDraftsSheet: @escaping () -> Void = {},
        onSaveSucceeded: @escaping (ServerMemoSummary) -> Void = { _ in }
    ) {
        self.editDraft = editDraft
        self.saveQueue = saveQueue
        self.onOpenDraftsSheet = onOpenDraftsSheet
        self.onSaveSucceeded = onSaveSucceeded
        _draftText = State(initialValue: editDraft.localContent)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let error = editDraft.lastError, !error.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.primary)

                            Button("Retry Save") {
                                saveNote()
                            }
                            .font(.footnote.weight(.semibold))
                        }

                        Spacer()
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.12))
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }

                NoteTextView(
                    text: $draftText,
                    isFocused: $isEditorFocused,
                    focusRequestID: focusRequestID,
                    tagSuggestions: tagSuggestions,
                    onTagAccepted: { tag in
                        rememberAcceptedTag(tag)
                    }
                )
                .padding(.horizontal, 24)
                .padding(.top, 0)
                .onChange(of: draftText) { _, _ in
                    if draftText.utf16.count <= 4_000 {
                        refreshTagSuggestions()
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .overlay(alignment: .bottomTrailing) {
            saveButtonOverlay
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isTopBarHidden {
                topBar
                    .transition(.opacity)
            }
        }
        .onAppear {
            isEditorFocused = true
            focusRequestID = UUID()
            isTopBarHidden = keyboard.isVisible
            refreshTagSuggestions()
            fetchRemoteTagsOnce()
        }
        .onChange(of: keyboard.isVisible) { _, isVisible in
            var transaction = Transaction()
            transaction.animation = .easeInOut(duration: 0.24)
            withTransaction(transaction) {
                isTopBarHidden = isVisible
            }
        }
        .onChange(of: drafts.map { "\($0.id.uuidString)-\($0.updatedAt.timeIntervalSince1970)" }) { _, _ in
            refreshTagSuggestions()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                persistWorkingCopy()
            }
        }
        .onDisappear {
            persistWorkingCopy()
            remoteTagTask?.cancel()
            saveTask?.cancel()
        }
    }

    private var saveButtonContent: RoundCaptureButtonContent {
        if editDraft.saveState == .saving {
            return .progress
        }
        return .symbol("paperplane.fill")
    }

    private var saveAccessibilityLabel: String {
        if editDraft.saveState == .saving {
            return "Saving"
        }
        if editDraft.saveState == .pending {
            return "Save pending"
        }
        return "Save"
    }

    private var saveButtonOverlay: some View {
        RoundCaptureButton(
            content: saveButtonContent,
            isEnabled: canSaveCurrentText,
            action: saveNote,
            accessibilityLabel: saveAccessibilityLabel
        )
        .padding(.trailing, 20)
        .padding(.bottom, 12)
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Text("Memos")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)
            openDraftsButton
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(.clear)
    }

    private var openDraftsButton: some View {
        Button(action: handleOpenDraftsSheet) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Drafts")
    }

    private var canSaveCurrentText: Bool {
        if editDraft.saveState == .saving {
            return false
        }

        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        if hasWorkingCopyChanges {
            return true
        }

        return editDraft.saveState == .pending
    }

    private var hasWorkingCopyChanges: Bool {
        draftText != editDraft.serverContent
    }

    private func persistWorkingCopy() {
        _ = ServerMemoSaveService.stageLocalContent(
            draftText,
            for: editDraft,
            in: modelContext,
            persist: true
        )
    }

    private func handleOpenDraftsSheet() {
        persistWorkingCopy()
        isEditorFocused = false
        onOpenDraftsSheet()
    }

    private func saveNote() {
        guard canSaveCurrentText else { return }

        persistWorkingCopy()
        saveTask?.cancel()

        saveTask = Task { @MainActor in
            let outcome = await saveQueue.saveNow(editDraft, in: modelContext)
            switch outcome {
            case .success(let memo):
                onSaveSucceeded(memo)
            case .failure:
                break
            }
        }
    }

    private func fetchRemoteTagsOnce() {
        remoteTagTask?.cancel()
        remoteTagTask = Task { @MainActor in
            do {
                let tags = try await MemosClient().fetchTags(
                    baseURLString: AppSettings.endpointBaseURL,
                    token: KeychainTokenStore.getToken(),
                    allowInsecureHTTP: AppSettings.allowInsecureHTTP
                )
                guard !Task.isCancelled else { return }
                remoteTags = tags
                refreshTagSuggestions()
            } catch {
                // Best-effort only; autocomplete remains available from local tags.
            }
        }
    }

    private func refreshTagSuggestions() {
        let currentTextForSuggestions: String
        if draftText.utf16.count > 4_000 {
            currentTextForSuggestions = String(draftText.prefix(2_000))
        } else {
            currentTextForSuggestions = draftText
        }
        let localTags = extractTags(in: drafts.map(\.text) + [currentTextForSuggestions])

        var canonicalByLowercase: [String: String] = [:]
        for tag in localTags + remoteTags {
            let normalized = normalizedTag(tag)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            if canonicalByLowercase[key] == nil {
                canonicalByLowercase[key] = normalized
            }
        }

        let recentRanking = Dictionary(
            uniqueKeysWithValues: AppSettings.recentAcceptedTags.enumerated().map { ($0.element.lowercased(), $0.offset) }
        )

        tagSuggestions = canonicalByLowercase.values.sorted { lhs, rhs in
            let lhsRank = recentRanking[lhs.lowercased()] ?? Int.max
            let rhsRank = recentRanking[rhs.lowercased()] ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func rememberAcceptedTag(_ tag: String) {
        let normalized = normalizedTag(tag)
        guard !normalized.isEmpty else { return }

        var current = AppSettings.recentAcceptedTags
        current.removeAll { $0.compare(normalized, options: .caseInsensitive) == .orderedSame }
        current.insert(normalized, at: 0)
        AppSettings.recentAcceptedTags = Array(current.prefix(100))
        refreshTagSuggestions()
    }

    private func extractTags(in texts: [String]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"#([A-Za-z0-9_-]+)"#) else {
            return []
        }

        var results: [String] = []
        for text in texts {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, options: [], range: range) {
                guard match.numberOfRanges > 1,
                      let swiftRange = Range(match.range(at: 1), in: text) else { continue }
                results.append(String(text[swiftRange]))
            }
        }

        return results
    }

    private func normalizedTag(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        let filtered = value.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return filtered
    }
}
