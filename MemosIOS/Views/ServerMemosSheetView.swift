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
        lastRefreshAt = Date()
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
                Text(row.content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if let updatedAt = row.updatedAt {
                        Text(updatedAt, style: .relative)
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

                    if row.canEdit {
                        Text("Tap to edit")
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
                onSelectMemo(baseMemo)
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
                content: memo.content,
                updatedAt: memo.updatedAt,
                isPending: false,
                isSaving: false,
                errorMessage: nil,
                canEdit: store.canEdit(memo)
            )
        }

        let showingLocal = draft.hasLocalChanges || draft.saveState != .idle
        let content = showingLocal ? draft.localContent : memo.content
        let updatedAt = showingLocal ? draft.updatedAt : memo.updatedAt

        return RowData(
            content: content,
            updatedAt: updatedAt,
            isPending: draft.saveState == .pending,
            isSaving: draft.saveState == .saving,
            errorMessage: draft.lastError,
            canEdit: store.canEdit(memo)
        )
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
        let errorMessage: String?
        let canEdit: Bool
    }
}
