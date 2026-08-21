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
    @Published private(set) var reachedEnd = false

    var onFirstPageFetched: (([ServerMemoSummary]) -> Void)? = nil

    private var hasLoaded = false
    private var nextPageToken: String?
    private var recentUpserts: [String: Date] = [:]

    func ensureInitialLoad() async {
        guard !hasLoaded else { return }
        await refresh(force: true)
    }

    /// Populates the feed from a local cache without marking `hasLoaded`.
    /// Subsequent calls to `refresh()` will still hit the network.
    func loadFromCache(_ cached: [ServerMemoSummary]) {
        guard !hasLoaded, !cached.isEmpty else { return }
        memos = cached
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
            let serverIDs = Set(page.memos.map(\.id))
            let cutoff = Date().addingTimeInterval(-60)

            // Build a lookup for O(1) existing-memo access during merge.
            let existingByID = Dictionary(uniqueKeysWithValues: memos.map { ($0.id, $0) })

            // Merge server memos with recently-upserted local data
            var refreshed = page.memos.map { serverMemo -> ServerMemoSummary in
                if let upsertDate = recentUpserts[serverMemo.id], upsertDate > cutoff,
                   let existing = existingByID[serverMemo.id] {
                    return mergeMemo(existing: existing, incoming: serverMemo)
                }
                return serverMemo
            }

            // Preserve recently-upserted memos not yet in server response
            for memo in memos where !serverIDs.contains(memo.id) {
                if let upsertDate = recentUpserts[memo.id], upsertDate > cutoff {
                    refreshed.append(memo)
                }
            }

            memos = refreshed
            recentUpserts = recentUpserts.filter { $0.value > cutoff }
            nextPageToken = page.nextPageToken
            reachedEnd = page.nextPageToken == nil
            errorMessage = nil
            hasLoaded = true
            lastRefreshAt = Date()
            onFirstPageFetched?(memos)
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

            let seen = Set(memos.map(\.id))
            let newMemos = page.memos.filter { !seen.contains($0.id) }
            if !newMemos.isEmpty {
                memos.append(contentsOf: newMemos)
            }
            nextPageToken = page.nextPageToken
            reachedEnd = page.nextPageToken == nil
            errorMessage = nil
            lastRefreshAt = Date()
            MemoCache.save(memos)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Fetches all pages sequentially. Used by MemoChat so the full history is
    /// available for display and search without requiring the user to scroll.
    func loadAllPages() async {
        await refresh(force: true)
        while !reachedEnd {
            await loadNextPageIfNeeded()
        }
    }

    /// Loads remaining pages without resetting — safe to call while the main list is mid-scroll.
    func loadRemainingPages() async {
        guard !reachedEnd else { return }
        guard !isLoading else { return }
        while !reachedEnd {
            await loadNextPageIfNeeded()
        }
    }

    /// Fetches all pages, but only if the first page is stale. Used by MemoChat on foreground resume.
    func loadAllPagesIfStale(maxAge: TimeInterval = 300) async {
        let now = Date()
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < maxAge, hasLoaded {
            return
        }
        await loadAllPages()
    }

    func canEdit(_ memo: ServerMemoSummary) -> Bool {
        isEditingSupported && memo.isEditable
    }

    func memo(memoID: String) -> ServerMemoSummary? {
        memos.first(where: { $0.id == memoID })
    }

    func upsertMemo(_ memo: ServerMemoSummary) {
        let mergedMemo: ServerMemoSummary
        if let index = memos.firstIndex(where: { $0.id == memo.id }) {
            mergedMemo = mergeMemo(existing: memos[index], incoming: memo)
            memos.remove(at: index)
        } else {
            mergedMemo = memo
        }

        // Binary-search for the correct sorted position instead of sorting the full array.
        var lo = 0
        var hi = memos.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if isBefore(memos[mid], mergedMemo) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        memos.insert(mergedMemo, at: lo)

        recentUpserts[mergedMemo.id] = Date()
        errorMessage = nil
        openingErrorByMemoID[mergedMemo.id] = nil
        lastRefreshAt = Date()
    }

    private func isBefore(_ lhs: ServerMemoSummary, _ rhs: ServerMemoSummary) -> Bool {
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

    func removeMemo(memoID: String) {
        memos.removeAll { $0.id == memoID }
        openingErrorByMemoID[memoID] = nil
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

    private func mergeMemo(existing: ServerMemoSummary, incoming: ServerMemoSummary) -> ServerMemoSummary {
        let preservedUpdatedAt = incoming.updatedAt ?? existing.updatedAt
        let mergedResourceName = incoming.resourceName ?? existing.resourceName
        let mergedSnippet = incoming.snippet ?? existing.snippet
        let mergedAttachmentCount = max(existing.attachmentCount, incoming.attachmentCount)
        let mergedHasFullContent = incoming.hasFullContent || existing.hasFullContent
        let mergedContent: String
        if incoming.hasFullContent {
            mergedContent = incoming.content
        } else if existing.hasFullContent {
            mergedContent = existing.content
        } else {
            mergedContent = incoming.content
        }

        return ServerMemoSummary(
            id: incoming.id,
            resourceName: mergedResourceName,
            content: mergedContent,
            updatedAt: preservedUpdatedAt,
            snippet: mergedSnippet,
            attachmentCount: mergedAttachmentCount,
            hasFullContent: mergedHasFullContent
        )
    }
}
