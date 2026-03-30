import SwiftUI
import SwiftData

struct ServerMemoEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]

    @Bindable var editDraft: ServerMemoEditDraft

    let saveQueue: ServerMemoSaveQueueController
    let onSaveSucceeded: (ServerMemoSummary) -> Void
    let onDismissAfterSave: () -> Void
    let onTagTapped: (String) -> Void

    @State private var draftText: String
    @State private var remoteTagTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var isEditorFocused: Bool
    @State private var focusRequestID = UUID()
    @State private var remoteTags: [String] = []
    @State private var tagSuggestions: [String] = []
    @State private var isShowingSaveConfirmation = false
    @State private var saveConfirmationTask: Task<Void, Never>?

    init(
        editDraft: ServerMemoEditDraft,
        saveQueue: ServerMemoSaveQueueController,
        shouldAutoFocus: Bool = true,
        onSaveSucceeded: @escaping (ServerMemoSummary) -> Void = { _ in },
        onDismissAfterSave: @escaping () -> Void = {},
        onTagTapped: @escaping (String) -> Void = { _ in }
    ) {
        self.editDraft = editDraft
        self.saveQueue = saveQueue
        self.onSaveSucceeded = onSaveSucceeded
        self.onDismissAfterSave = onDismissAfterSave
        self.onTagTapped = onTagTapped
        _draftText = State(initialValue: editDraft.localContent)
        _isEditorFocused = State(initialValue: shouldAutoFocus)
    }

    private var draftsFingerprint: Int {
        var hasher = Hasher()
        for draft in drafts {
            hasher.combine(draft.id)
            hasher.combine(draft.updatedAt)
        }
        return hasher.finalize()
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

                EditableNoteTextView(
                    text: $draftText,
                    isFocused: $isEditorFocused,
                    focusRequestID: focusRequestID,
                    tagSuggestions: tagSuggestions,
                    onTagAccepted: { tag in
                        rememberAcceptedTag(tag)
                    },
                    onTagTapped: onTagTapped
                )
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .onChange(of: draftText) { _, _ in
                    if draftText.utf16.count <= 4_000 {
                        refreshTagSuggestions()
                    }
                }
            }
        }
        .opacity(isShowingSaveConfirmation ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: isShowingSaveConfirmation)
        .overlay {
            if isShowingSaveConfirmation {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(.green)
                    Text("Saved")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .overlay(alignment: .bottomTrailing) {
            saveButtonOverlay
        }
        .onAppear {
            refreshTagSuggestions()
            fetchRemoteTagsOnce()
        }
        .onChange(of: draftsFingerprint) { _, _ in
            refreshTagSuggestions()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                persistWorkingCopy()
            }
        }
        .onDisappear {
            if hasWorkingCopyChanges {
                persistWorkingCopy()
            }
            remoteTagTask?.cancel()
            saveTask?.cancel()
            saveConfirmationTask?.cancel()
        }
    }

    private var saveButtonContent: RoundCaptureButtonContent {
        if isShowingSaveConfirmation {
            return .symbol("checkmark")
        }
        if editDraft.saveState == .saving {
            return .progress
        }
        return .symbol("paperplane.fill")
    }

    private var saveAccessibilityLabel: String {
        if isShowingSaveConfirmation {
            return "Saved"
        }
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
        .animation(.easeInOut(duration: 0.20), value: isShowingSaveConfirmation)
    }

    private var canSaveCurrentText: Bool {
        if isShowingSaveConfirmation {
            return false
        }

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
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            != editDraft.serverContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistWorkingCopy() {
        _ = ServerMemoSaveService.stageLocalContent(
            draftText,
            for: editDraft,
            in: modelContext,
            persist: true
        )
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
                showSaveConfirmation()
            case .failure:
                break
            }
        }
    }

    private func showSaveConfirmation() {
        saveConfirmationTask?.cancel()
        isEditorFocused = false

        withAnimation(.easeInOut(duration: 0.20)) {
            isShowingSaveConfirmation = true
        }

        saveConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            onDismissAfterSave()
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
