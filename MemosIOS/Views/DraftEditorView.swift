import SwiftUI
import SwiftData

struct DraftEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]

    @Bindable var draft: Draft

    let onBack: (Draft) -> Void
    let onNewNote: (Draft) -> Void
    let onSendSuccess: (Draft) -> Void

    @State private var draftText: String
    @State private var autosaveTask: Task<Void, Never>?
    @State private var remoteTagTask: Task<Void, Never>?
    @State private var sendConfirmationTask: Task<Void, Never>?
    @State private var isEditorFocused = true
    @State private var focusRequestID = UUID()
    @State private var remoteTags: [String] = []
    @State private var tagSuggestions: [String] = []
    @State private var isShowingSendConfirmation = false

    init(
        draft: Draft,
        onBack: @escaping (Draft) -> Void = { _ in },
        onNewNote: @escaping (Draft) -> Void = { _ in },
        onSendSuccess: @escaping (Draft) -> Void = { _ in }
    ) {
        self.draft = draft
        self.onBack = onBack
        self.onNewNote = onNewNote
        self.onSendSuccess = onSendSuccess
        _draftText = State(initialValue: draft.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = draft.lastError, !error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.primary)

                        Button("Retry Send") {
                            sendDraft()
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
            .padding(.top, 24)
            .onChange(of: draftText) { _, _ in
                scheduleAutosave()
                refreshTagSuggestions()
            }
        }
        .opacity(isShowingSendConfirmation ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: isShowingSendConfirmation)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) {
            if isShowingSendConfirmation {
                confirmationControls
            } else {
                quickCaptureControls
            }
        }
        .onAppear {
            isEditorFocused = true
            focusRequestID = UUID()
            refreshTagSuggestions()
            fetchRemoteTagsOnce()
        }
        .onChange(of: drafts.map { "\($0.id.uuidString)-\($0.updatedAt.timeIntervalSince1970)" }) { _, _ in
            refreshTagSuggestions()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                flushPendingAutosave()
            }
        }
        .onChange(of: draft.id) { _, _ in
            autosaveTask?.cancel()
            sendConfirmationTask?.cancel()
            remoteTagTask?.cancel()
            draftText = draft.text
            remoteTags = []
            isShowingSendConfirmation = false
            isEditorFocused = true
            focusRequestID = UUID()
            refreshTagSuggestions()
            fetchRemoteTagsOnce()
        }
        .onDisappear {
            flushPendingAutosave()
            remoteTagTask?.cancel()
            sendConfirmationTask?.cancel()
        }
    }

    private var quickCaptureControls: some View {
        HStack(spacing: 0) {
            Button {
                handleBack()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: sideButtonWidth, height: controlHeight)
            }
            .foregroundStyle(controlForegroundColor)
            .accessibilityLabel("Menu")

            divider

            Button {
                sendDraft()
            } label: {
                if draft.sendState == .sending {
                    ProgressView()
                        .tint(primaryActionColor)
                        .frame(width: middleButtonWidth, height: controlHeight)
                } else {
                    Image(systemName: sendIcon)
                        .font(.system(size: 21, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: middleButtonWidth, height: controlHeight)
                }
            }
            .foregroundStyle(canSendCurrentText ? primaryActionColor : controlForegroundColor.opacity(0.45))
            .disabled(!canSendCurrentText)
            .accessibilityLabel("Send")
        }
        .padding(6)
        .background(
            Capsule(style: .continuous)
                .fill(controlFillColor)
        )
        .shadow(color: controlShadowColor, radius: controlShadowRadius, x: 0, y: controlShadowY)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var confirmationControls: some View {
        HStack {
            Button {
            } label: {
                Image(systemName: sendIcon)
                    .font(.system(size: 21, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: middleButtonWidth, height: controlHeight)
            }
            .disabled(true)
            .foregroundStyle(primaryActionColor)
            .background(
                Capsule(style: .continuous)
                    .fill(controlFillColor)
            )
            .shadow(color: controlShadowColor, radius: controlShadowRadius, x: 0, y: controlShadowY)
            .accessibilityLabel("Sent")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var divider: some View {
        Rectangle()
            .fill(controlSeparatorColor)
            .frame(width: 1, height: 22)
    }

    private var controlHeight: CGFloat { 40 }
    private var sideButtonWidth: CGFloat { 72 }
    private var middleButtonWidth: CGFloat { 188 }

    private var sendIcon: String {
        if isShowingSendConfirmation {
            return "checkmark.circle.fill"
        }
        return "paperplane.fill"
    }

    private var canSendCurrentText: Bool {
        if isShowingSendConfirmation {
            return false
        }

        if draft.sendState == .sending {
            return false
        }

        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        if let lastSentAt = draft.lastSentAt, draft.updatedAt <= lastSentAt, draftText == draft.text {
            return false
        }

        return true
    }

    private var controlFillColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.16)
        }
        return Color.black.opacity(0.08)
    }

    private var controlForegroundColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.92)
        }
        return Color.black.opacity(0.88)
    }

    private var controlShadowColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.12)
        }
        return Color.black.opacity(0.14)
    }

    private var controlShadowRadius: CGFloat {
        6
    }

    private var controlShadowY: CGFloat {
        2
    }

    private var controlSeparatorColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.12)
        }
        return Color.black.opacity(0.10)
    }

    private var primaryActionColor: Color {
        .blue
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let latestText = draftText

        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            await MainActor.run {
                applyDraftChanges(newText: latestText)
            }
        }
    }

    private func flushPendingAutosave() {
        autosaveTask?.cancel()
        applyDraftChanges(newText: draftText)
    }

    private func applyDraftChanges(newText: String) {
        guard draft.text != newText else {
            return
        }

        draft.text = newText
        draft.updatedAt = Date()

        if AppSettings.clearErrorOnEdit {
            draft.lastError = nil
        }

        if draft.lastSentAt != nil {
            draft.sendState = .idle
            draft.isArchived = false
        }

        modelContext.saveOrAssert()
    }

    private func handleBack() {
        guard !isShowingSendConfirmation else { return }
        flushPendingAutosave()
        isEditorFocused = false
        onBack(draft)
    }

    private func handleNewNote() {
        guard !isShowingSendConfirmation else { return }
        flushPendingAutosave()
        isEditorFocused = false
        onNewNote(draft)
    }

    private func sendDraft() {
        guard canSendCurrentText else { return }

        flushPendingAutosave()
        sendConfirmationTask?.cancel()

        Task { @MainActor in
            let outcome = await DraftSendService.send(draft: draft, in: modelContext)
            draftText = draft.text

            if case .success = outcome {
                isEditorFocused = false
                withAnimation(.easeInOut(duration: 0.20)) {
                    isShowingSendConfirmation = true
                }

                sendConfirmationTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    onSendSuccess(draft)
                }
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
        let localTags = extractTags(in: drafts.map(\.text) + [draftText])

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
