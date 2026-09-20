import SwiftUI

/// What `VaultStore.update` did, plus the note as it now exists on disk.
struct VaultSaveOutcome: Equatable {
    let result: VaultWriteResult
    let note: VaultNote
}

/// The vault's answer to ServerMemosStore: an observable list of notes the
/// views render, backed by the persisted index and the file store.
///
/// Deliberately queue-free. Network writes deserve retry and backoff; file
/// writes fail structurally — a stale bookmark is not fixed by trying again in
/// fifteen seconds — so failures surface as messages instead.
@MainActor
final class VaultStore: ObservableObject {

    @Published private(set) var entries: [VaultIndexEntry] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Set when `errorMessage` came from a `VaultAccessError` (a missing or
    /// stale bookmark) rather than some other failure, so the UI can offer a
    /// "Reconnect Vault" affordance without string-matching the message
    /// (Minor 4).
    @Published private(set) var needsReconnect = false
    /// Set when a save had to go to a conflict copy, so the UI can say so.
    @Published private(set) var lastConflictPath: String?

    private let storeProvider: () throws -> VaultFileStore
    private var lastRefreshAt: Date?

    /// Bumped every time the app is pointed at a different vault. A refresh
    /// captures this when it starts and discards its result if it no longer
    /// matches, so a pass that was already in flight against the previous
    /// vault can't publish that vault's notes as the new one's.
    private var vaultGeneration = 0

    /// Set when `refresh()` is called while one is already running. The
    /// in-flight pass runs another when it finishes, so a refresh asked for
    /// mid-pass — notably the one right after picking a new vault — isn't
    /// silently dropped until the next poll.
    private var refreshRequestedDuringRefresh = false

    /// create/update/delete calls that land on the main actor while a
    /// refresh() is in flight (i.e. while suspended at the detached-work
    /// `await`). refresh()'s background pass computes its result from a
    /// snapshot of the index taken before any such write, so without
    /// tracking these separately, merging that stale result back in would
    /// silently revert a concurrent write (or resurrect a concurrent
    /// delete) until the next refresh happens to run. `nil` value means the
    /// path was deleted during the window.
    private var localChangesDuringRefresh: [String: VaultIndexEntry?] = [:]

    /// Resolves the file store through the user's saved bookmark. Tests inject
    /// a temp-directory store instead.
    ///
    /// `nonisolated`: a default-argument expression (used below in `init`) is
    /// evaluated outside of `VaultStore`'s main-actor isolation, so a plain
    /// `@MainActor`-isolated `static let` here would warn under Swift 6 mode.
    /// The closure body only calls `VaultBookmarkStore.resolve()`, which
    /// isn't actor-isolated, so this is safe to leave unisolated.
    nonisolated static let bookmarkStoreProvider: () throws -> VaultFileStore = {
        VaultFileStore(root: try VaultBookmarkStore.resolve())
    }

    init(storeProvider: @escaping () throws -> VaultFileStore = VaultStore.bookmarkStoreProvider) {
        self.storeProvider = storeProvider
    }

    // MARK: - Loading

    /// Renders the drawer from the persisted index — no I/O wait, no download.
    func loadFromIndex() {
        guard entries.isEmpty else { return }
        entries = VaultIndex.load().sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < maxAge { return }
        await refresh()
    }

    /// Reconciles the index against the vault, reading content only for files
    /// that are new or changed.
    ///
    /// The enumerate/read work happens off the main actor: reading a
    /// not-yet-downloaded iCloud file blocks under `NSFileCoordinator` until
    /// the download completes, and doing that on the main actor would freeze
    /// the UI at launch. The security scope is opened and closed inside that
    /// detached work; only the published-state assignment and the index save
    /// happen back on the main actor.
    ///
    /// Because that detached work suspends this method, a `create`/`update`/
    /// `delete` call can run to completion on the main actor before this
    /// resumes. Those are recorded in `localChangesDuringRefresh` and
    /// replayed onto the detached result below, so a concurrent write can't
    /// be reverted (or a concurrent delete resurrected) by this refresh.
    func refresh() async {
        guard !isLoading else {
            refreshRequestedDuringRefresh = true
            return
        }
        await runRefreshPass()
        while refreshRequestedDuringRefresh {
            refreshRequestedDuringRefresh = false
            await runRefreshPass()
        }
    }

    /// One reconcile pass. Split out of `refresh()` so a request that arrives
    /// mid-pass can be honored by running this again rather than being dropped.
    private func runRefreshPass() async {
        isLoading = true
        localChangesDuringRefresh = [:]
        let generation = vaultGeneration
        defer { isLoading = false }

        let root: URL
        do {
            root = try storeProvider().root
        } catch {
            recordError(error)
            localChangesDuringRefresh = [:]
            return
        }

        let result = await Task.detached(priority: .utility) {
            Self.performRefresh(root: root)
        }.value

        guard shouldPublishRefresh(startedAtGeneration: generation) else {
            // The user picked a different vault while this pass was in flight.
            // The result describes a vault the app is no longer connected to,
            // so publishing it would show the old vault's notes as the new
            // one's — and persist them under the new vault's index.
            localChangesDuringRefresh = [:]
            return
        }

        switch result {
        case .success(var refreshed):
            // Replay writes that landed on the main actor while the above
            // detached work was in flight — see `localChangesDuringRefresh`.
            for (path, change) in localChangesDuringRefresh {
                refreshed.removeAll { $0.relativePath == path }
                if let change {
                    refreshed.append(change)
                }
            }
            refreshed.sort { $0.modifiedAt > $1.modifiedAt }

            entries = refreshed
            VaultIndex.save(refreshed)
            lastRefreshAt = Date()
            clearError()
        case .failure(let error):
            recordError(error)
        }
        localChangesDuringRefresh = [:]
    }

    /// Off-main-actor body of `refresh()`. A `VaultFileStore` is rebuilt from
    /// `root` here rather than captured from the main actor, since the
    /// `storeProvider` closure that produced it is not `Sendable`.
    private nonisolated static func performRefresh(root: URL) -> Result<[VaultIndexEntry], Error> {
        let fileStore = VaultFileStore(root: root)
        return Result {
            try withSecurityScope(of: fileStore) { fileStore in
                let index = VaultIndex.load()
                let onDisk = try fileStore.listMarkdownFiles()
                let diff = VaultIndex.diff(index: index, disk: onDisk)
                let priorByPath = Dictionary(index.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
                let diskByPath = Dictionary(onDisk.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

                var refreshed = diff.unchanged
                for path in diff.needsRead {
                    if let diskMeta = diskByPath[path], diskMeta.needsDownload {
                        // I4: never force a download just to draw the list.
                        // Kick one off in the background (best-effort; a
                        // plain temp-directory path, and any transient
                        // failure, is fine to ignore here) and show what's
                        // already known instead of blocking on it.
                        try? FileManager.default.startDownloadingUbiquitousItem(
                            at: root.appendingPathComponent(path)
                        )
                        if let prior = priorByPath[path] {
                            // Keep showing the last known content, but mark
                            // it for another look next refresh — mtime/size
                            // may not change at all while still downloading.
                            refreshed.append(VaultIndexEntry(
                                relativePath: prior.relativePath,
                                title: prior.title,
                                preview: prior.preview,
                                tags: prior.tags,
                                modifiedAt: prior.modifiedAt,
                                fileSize: prior.fileSize,
                                needsContent: true
                            ))
                        } else {
                            let filename = (path as NSString).lastPathComponent
                            let title = (filename as NSString).deletingPathExtension
                            refreshed.append(VaultIndexEntry(
                                relativePath: path,
                                title: title,
                                preview: "",
                                tags: [],
                                modifiedAt: diskMeta.modifiedAt,
                                fileSize: diskMeta.fileSize,
                                needsContent: true
                            ))
                        }
                        continue
                    }
                    if let note = try? fileStore.read(relativePath: path) {
                        refreshed.append(VaultIndexEntry.make(from: note))
                    } else if let prior = priorByPath[path] {
                        // A single unreadable file must not make the note
                        // vanish from the drawer: in an iCloud vault a
                        // download can fail transiently, so keep the last
                        // known entry instead of dropping it.
                        refreshed.append(prior)
                    }
                }

                refreshed.sort { $0.modifiedAt > $1.modifiedAt }
                return refreshed
            }
        }
    }

    // MARK: - Writing

    @discardableResult
    func create(body: String, now: Date = Date()) throws -> VaultIndexEntry {
        try withFileStore { fileStore in
            let folder = AppSettings.vaultNotesFolder
            let existing = try fileStore.existingFilenames(inSubfolder: folder)
            let filename = VaultNoteSerializer.filename(for: now, existing: existing)
            let relativePath = folder.isEmpty ? filename : "\(folder)/\(filename)"

            let text = VaultNoteSerializer.render(body: body, existing: nil, loadedBody: nil, created: now, updated: now)
            let metadata = try fileStore.write(text, to: relativePath)

            let entry = VaultIndexEntry.make(from: Self.note(from: text, path: metadata.relativePath, metadata: metadata))
            self.upsert(entry)
            self.clearError()
            return entry
        }
    }

    func read(relativePath: String) throws -> VaultNote {
        try withFileStore { fileStore in
            try fileStore.read(relativePath: relativePath)
        }
    }

    /// Saves an edit, preserving unknown frontmatter and writing a conflict
    /// copy if the file changed externally since `note` was read.
    ///
    /// The returned outcome carries the note built from the exact text that
    /// was written (at the copy's path for a conflict). Callers use it as
    /// their next baseline; re-reading the file instead could adopt a
    /// desktop write that landed in between, which the next save would then
    /// silently clobber.
    @discardableResult
    func update(note: VaultNote, body: String, now: Date = Date()) throws -> VaultSaveOutcome {
        try withFileStore { fileStore in
            let text = VaultNoteSerializer.render(
                body: body,
                existing: note.frontmatter,
                loadedBody: note.body,
                created: note.frontmatter.flatMap { fm in
                    fm.value(for: "created").flatMap(VaultNoteSerializer.iso8601.date(from:))
                } ?? now,
                updated: now
            )

            // Conflict detection compares the file's actual current content against the
            // bytes this note was read from — not mtime+size, which misses an external
            // edit landing in the same second at the same size. `originalText` empty means
            // "unknown", which compares as changed and yields a conflict copy: the
            // fail-safe direction.
            let result = try fileStore.writeChecked(
                text,
                to: note.relativePath,
                expectedText: note.originalText
            )

            let written: VaultNote
            switch result {
            case .written(let metadata):
                self.lastConflictPath = nil
                written = Self.note(from: text, path: metadata.relativePath, metadata: metadata)
            case .conflictCopy(let path, let metadata):
                self.lastConflictPath = path
                written = Self.note(from: text, path: path, metadata: metadata)
            }
            self.upsert(VaultIndexEntry.make(from: written))
            self.clearError()
            return VaultSaveOutcome(result: result, note: written)
        }
    }

    func delete(relativePath: String) throws {
        try withFileStore { fileStore in
            try fileStore.delete(relativePath: relativePath)
        }
        entries.removeAll { $0.relativePath == relativePath }
        VaultIndex.save(entries)
        clearError()
        if isLoading {
            // A refresh is in flight; make sure its result doesn't
            // resurrect this path when it's merged back in refresh().
            localChangesDuringRefresh.updateValue(nil, forKey: relativePath)
        }
    }

    /// Clears everything carried over from a previously connected vault:
    /// in-memory entries and the persisted index. Called before refreshing
    /// against a newly picked vault so its rows don't linger mixed in with
    /// the old vault's (Minor 7).
    func resetForNewVault() {
        vaultGeneration &+= 1
        entries = []
        VaultIndex.save([])
        clearError()
    }

    /// The generation a refresh pass should compare against before publishing.
    /// Exposed so the discard rule can be tested directly — the genuine race
    /// (a slow pass against the old vault finishing after the switch) can't be
    /// driven deterministically from a unit test.
    var currentGeneration: Int { vaultGeneration }

    /// False once the app has been pointed at a different vault since the pass
    /// identified by `generation` began.
    func shouldPublishRefresh(startedAtGeneration generation: Int) -> Bool {
        generation == vaultGeneration
    }

    // MARK: - Errors

    /// Records a failure surfaced to the UI. `needsReconnect` is derived
    /// from the error's actual type — a `VaultAccessError` (missing or
    /// stale bookmark) — rather than matching its message text, per Minor 4.
    /// Not private: `NotesListView`'s delete-failure handler also routes
    /// through here so a failed delete offers the same "Reconnect Vault"
    /// affordance as a failed refresh.
    func recordError(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        needsReconnect = error is VaultAccessError
    }

    private func clearError() {
        errorMessage = nil
        needsReconnect = false
    }

    // MARK: - Helpers

    /// Resolves the file store and runs `body` with its security scope held
    /// open for the duration. On a real device the vault root is a
    /// security-scoped bookmark URL; without this, every read/write against
    /// an iCloud Drive or file-provider folder fails with a permission error
    /// (a temp-directory root, as used in tests, doesn't need the scope, so
    /// `startAccessingSecurityScopedResource()` there simply returns false).
    private func withFileStore<T>(_ body: (VaultFileStore) throws -> T) throws -> T {
        let store = try storeProvider()
        return try Self.withSecurityScope(of: store, body)
    }

    /// Shared by `withFileStore` (main actor) and `performRefresh` (detached)
    /// so both open/close the same balanced security scope around file work.
    ///
    /// Minor 5: `startAccessingSecurityScopedResource()` returning `false` is
    /// deliberately NOT treated as failure on its own — a plain local temp
    /// directory (every test's root) isn't security-scoped at all and always
    /// returns `false` here, so throwing on that alone would make every
    /// vault operation fail under test. The real signal that the bookmark
    /// has gone stale is the file operation itself failing with a Cocoa
    /// permission error, so that's what gets mapped to `VaultAccessError
    /// .stale` — a message the user can act on ("Reconnect Vault in
    /// Settings") instead of a raw Cocoa error.
    private nonisolated static func withSecurityScope<T>(
        of store: VaultFileStore,
        _ body: (VaultFileStore) throws -> T
    ) throws -> T {
        let needsScope = store.root.startAccessingSecurityScopedResource()
        defer { if needsScope { store.root.stopAccessingSecurityScopedResource() } }
        do {
            return try body(store)
        } catch let error as CocoaError where error.code == .fileReadNoPermission || error.code == .fileWriteNoPermission {
            // Any NSError in NSCocoaErrorDomain — which is how Foundation's
            // file APIs report a permission-denied failure — bridges to
            // CocoaError automatically, so this single catch covers both a
            // genuinely-thrown CocoaError and a plain NSError with a
            // matching domain/code.
            throw VaultAccessError.stale
        }
    }

    /// The note exactly as `text` was written to `path`.
    private static func note(from text: String, path: String, metadata: VaultFileMetadata) -> VaultNote {
        let (frontmatter, body) = Frontmatter.parse(text)
        return VaultNote(
            relativePath: path,
            frontmatter: frontmatter,
            body: body,
            modifiedAt: metadata.modifiedAt,
            fileSize: metadata.fileSize,
            originalText: text
        )
    }

    private func upsert(_ entry: VaultIndexEntry) {
        entries.removeAll { $0.relativePath == entry.relativePath }
        entries.append(entry)
        entries.sort { $0.modifiedAt > $1.modifiedAt }
        VaultIndex.save(entries)
        if isLoading {
            // A refresh is in flight; make sure its result doesn't drop
            // this write when it's merged back in refresh().
            localChangesDuringRefresh.updateValue(entry, forKey: entry.relativePath)
        }
    }
}
