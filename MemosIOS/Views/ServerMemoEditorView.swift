import SwiftUI
import SwiftData

struct ServerMemoEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]

    @Bindable var editDraft: ServerMemoEditDraft

    let onTagTapped: (String) -> Void

    @State private var draftText: String
    @State private var remoteTagTask: Task<Void, Never>?
    @State private var isEditorFocused: Bool
    @State private var focusRequestID = UUID()
    @State private var remoteTags: [String] = []
    @State private var tagSuggestions: [String] = []

    init(
        editDraft: ServerMemoEditDraft,
        shouldAutoFocus: Bool = true,
        onTagTapped: @escaping (String) -> Void = { _ in }
    ) {
        self.editDraft = editDraft
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
        VStack(spacing: 0) {
            if let error = editDraft.lastError, !error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.primary)

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
        .navigationTitle("Edit Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    persistWorkingCopy()
                    dismiss()
                }
            }
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
        }
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
