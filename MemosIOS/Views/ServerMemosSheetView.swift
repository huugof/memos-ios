import SwiftUI
import SwiftData

@MainActor
final class ServerMemosStore: ObservableObject {
    @Published private(set) var memos: [ServerMemoSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNextPage = false
    @Published var errorMessage: String?
    @Published private(set) var isEditingSupported = true
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var openingMemoID: String?
    @Published private(set) var openingErrorByMemoID: [String: String] = [:]

    private var hasLoaded = false
    private var nextPageToken: String?
    private var reachedEnd = false

    func ensureInitialLoad() async {
        guard !hasLoaded else { return }
        await refresh(force: true)
    }

    func refreshIfStale(maxAge: TimeInterval = 60) async {
        let now = Date()
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < maxAge, hasLoaded {
            return
        }
        await refresh(force: true)
    }

    func refresh(force: Bool = true) async {
        if isLoading {
            return
        }
        if !force, hasLoaded {
            return
        }

        isLoading = true
        isLoadingNextPage = false
        reachedEnd = false
        nextPageToken = nil
        defer { isLoading = false }

        do {
            let page = try await MemosClient().fetchMemosPage(
                baseURLString: AppSettings.endpointBaseURL,
                token: KeychainTokenStore.getToken(),
                allowInsecureHTTP: AppSettings.allowInsecureHTTP,
                pageSize: 30,
                pageToken: nil
            )
            memos = page.memos
            nextPageToken = page.nextPageToken
            reachedEnd = page.nextPageToken == nil
            errorMessage = nil
            hasLoaded = true
            lastRefreshAt = Date()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadNextPageIfNeeded() async {
        guard !isLoading else { return }
        guard !isLoadingNextPage else { return }
        guard !reachedEnd else { return }
        guard let token = nextPageToken, !token.isEmpty else {
            reachedEnd = true
            return
        }

        isLoadingNextPage = true
        defer { isLoadingNextPage = false }

        do {
            let page = try await MemosClient().fetchMemosPage(
                baseURLString: AppSettings.endpointBaseURL,
                token: KeychainTokenStore.getToken(),
                allowInsecureHTTP: AppSettings.allowInsecureHTTP,
                pageSize: 30,
                pageToken: token
            )

            var seen = Set(memos.map(\.id))
            for memo in page.memos where !seen.contains(memo.id) {
                memos.append(memo)
                seen.insert(memo.id)
            }
            nextPageToken = page.nextPageToken
            reachedEnd = page.nextPageToken == nil
            errorMessage = nil
            lastRefreshAt = Date()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func canEdit(_ memo: ServerMemoSummary) -> Bool {
        isEditingSupported && memo.isEditable
    }

    func memo(memoID: String) -> ServerMemoSummary? {
        memos.first(where: { $0.id == memoID })
    }

    func upsertMemo(_ memo: ServerMemoSummary) {
        if let index = memos.firstIndex(where: { $0.id == memo.id }) {
            memos[index] = memo
        } else {
            memos.insert(memo, at: 0)
        }

        memos.sort { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (l?, r?):
                if l != r { return l > r }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return lhs.id < rhs.id
        }

        errorMessage = nil
        openingErrorByMemoID[memo.id] = nil
        lastRefreshAt = Date()
    }

    func openingError(for memoID: String) -> String? {
        openingErrorByMemoID[memoID]
    }

    func memoForEditing(_ memo: ServerMemoSummary) async -> ServerMemoSummary? {
        openingErrorByMemoID[memo.id] = nil

        if memo.hasFullContent {
            return memo
        }

        guard let resourceName = memo.resourceName, !resourceName.isEmpty else {
            openingErrorByMemoID[memo.id] = "Unable to open this note."
            return nil
        }

        if openingMemoID == memo.id {
            return nil
        }

        openingMemoID = memo.id
        defer {
            if openingMemoID == memo.id {
                openingMemoID = nil
            }
        }

        do {
            let refreshed = try await MemosClient().fetchMemo(
                resourceName: resourceName,
                baseURLString: AppSettings.endpointBaseURL,
                token: KeychainTokenStore.getToken(),
                allowInsecureHTTP: AppSettings.allowInsecureHTTP
            )

            guard refreshed.hasFullContent else {
                openingErrorByMemoID[memo.id] = "Full note content is unavailable for editing."
                return nil
            }

            upsertMemo(refreshed)
            return refreshed
        } catch {
            openingErrorByMemoID[memo.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }
}

struct ServerMemosSheetView: View {
    let showsHeader: Bool
    let topContentInset: CGFloat
    let onSelectMemo: (ServerMemoSummary) -> Void

    @EnvironmentObject private var store: ServerMemosStore
    @Query(sort: \ServerMemoEditDraft.updatedAt, order: .reverse) private var editDrafts: [ServerMemoEditDraft]

    init(
        showsHeader: Bool = true,
        topContentInset: CGFloat = 0,
        onSelectMemo: @escaping (ServerMemoSummary) -> Void = { _ in }
    ) {
        self.showsHeader = showsHeader
        self.topContentInset = topContentInset
        self.onSelectMemo = onSelectMemo
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack {
                    Text("Notes")
                        .font(.title2.weight(.bold))
                    Spacer()
                    Button {
                        Task {
                            await store.refresh(force: true)
                        }
                    } label: {
                        if store.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isLoading)
                    .accessibilityLabel("Refresh")
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !store.isEditingSupported {
                        Text("Server note editing is unavailable for this server version.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 6)
                    }

                    if store.isLoading && store.memos.isEmpty {
                        loadingStateView
                    } else if let errorMessage = store.errorMessage, store.memos.isEmpty {
                        errorStateView(message: errorMessage)
                    } else if store.memos.isEmpty {
                        emptyStateView
                    } else {
                        memoRows
                    }
                }
                .padding(.bottom, 16)
            }
            .refreshable {
                await store.refresh(force: true)
            }
            .padding(.top, contentTopInset)
            .task {
                await store.ensureInitialLoad()
            }
        }
    }

    private var loadingStateView: some View {
        ProgressView("Loading notes…")
            .frame(maxWidth: .infinity, minHeight: 320)
            .padding(.horizontal, 20)
            .padding(.top, 14)
    }

    @ViewBuilder
    private func errorStateView(message: String) -> some View {
        VStack(spacing: 12) {
            Text("Unable to load notes")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await store.refresh(force: true)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Notes",
            systemImage: "tray",
            description: Text("Pull to refresh after configuring your endpoint and token.")
        )
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    @ViewBuilder
    private var memoRows: some View {
        ForEach(store.memos.indices, id: \.self) { index in
            let baseMemo = store.memos[index]
            let row = rowData(for: baseMemo)

            VStack(alignment: .leading, spacing: 8) {
                if let timestamp = row.timestampText {
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(row.content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if row.isOpening {
                        Text("Opening")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if row.attachmentCount > 0 {
                        Text(row.attachmentLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if row.isPending {
                        Text("Pending")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if row.isSaving {
                        Text("Saving")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = row.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                guard row.canEdit else { return }
                Task {
                    guard let openMemo = await store.memoForEditing(baseMemo) else { return }
                    onSelectMemo(openMemo)
                }
            }
            .onAppear {
                guard index >= store.memos.count - 5 else { return }
                Task {
                    await store.loadNextPageIfNeeded()
                }
            }

            if index < store.memos.count - 1 {
                Divider()
                    .padding(.horizontal, 14)
            }
        }

        if store.isLoadingNextPage {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
        }
    }

    private func rowData(for memo: ServerMemoSummary) -> RowData {
        guard let draft = editDraftByMemoID[memo.id] else {
            return RowData(
                content: displayContent(for: memo.content, fallback: memo),
                updatedAt: memo.updatedAt,
                isPending: false,
                isSaving: false,
                isOpening: store.openingMemoID == memo.id,
                attachmentCount: memo.attachmentCount,
                errorMessage: store.openingError(for: memo.id),
                canEdit: store.canEdit(memo) && store.openingMemoID != memo.id
            )
        }

        let showingLocal = draft.hasLocalChanges || draft.saveState != .idle
        let content = showingLocal
            ? displayContent(for: draft.localContent, fallback: memo)
            : displayContent(for: memo.content, fallback: memo)
        let updatedAt = showingLocal ? draft.updatedAt : memo.updatedAt

        return RowData(
            content: content,
            updatedAt: updatedAt,
            isPending: draft.saveState == .pending,
            isSaving: draft.saveState == .saving,
            isOpening: store.openingMemoID == memo.id,
            attachmentCount: memo.attachmentCount,
            errorMessage: draft.lastError ?? store.openingError(for: memo.id),
            canEdit: store.canEdit(memo) && store.openingMemoID != memo.id
        )
    }

    private func displayContent(for content: String, fallback memo: ServerMemoSummary) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return content
        }

        let snippet = memo.snippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !snippet.isEmpty {
            return memo.snippet ?? snippet
        }

        if memo.attachmentCount > 0 {
            return "(Attachment note)"
        }

        return "(Empty note)"
    }

    private var editDraftByMemoID: [String: ServerMemoEditDraft] {
        var map: [String: ServerMemoEditDraft] = [:]
        for draft in editDrafts {
            if map[draft.memoID] == nil {
                map[draft.memoID] = draft
            }
        }
        return map
    }

    private var contentTopInset: CGFloat {
        if showsHeader {
            return 0
        }
        return max(0, topContentInset)
    }

    private struct RowData {
        let content: String
        let updatedAt: Date?
        let isPending: Bool
        let isSaving: Bool
        let isOpening: Bool
        let attachmentCount: Int
        let errorMessage: String?
        let canEdit: Bool

        var attachmentLabel: String {
            if attachmentCount == 1 {
                return "Attachment"
            }
            return "Attachments \(attachmentCount)"
        }

        var timestampText: String? {
            guard let updatedAt else { return nil }
            let now = Date()
            let age = now.timeIntervalSince(updatedAt)
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
}
