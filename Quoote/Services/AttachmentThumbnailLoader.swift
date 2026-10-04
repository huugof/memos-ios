import UIKit

/// Turns a `NoteAttachment` into a small picture for the history rows and the editor's attachment strip.
///
/// Loading is lazy and off the main thread: nothing is read until a tile appears, and a tile that scrolls away
/// cancels its load. Two caches sit in front: memory (about 32 MB, shared by every row) and, for pictures that
/// come from the Memos server, a size-capped folder on disk. Every failure is silent — the tile keeps its icon.
final class AttachmentThumbnailLoader: @unchecked Sendable {

    /// The longest edge of every thumbnail, in pixels.
    static let maxPixel = ThumbnailDownsampler.maxPixel

    /// How long a failure is remembered before the same picture is tried again.
    static let failureMemory: TimeInterval = 60

    static let shared = AttachmentThumbnailLoader(environment: .live)

    /// Everything the loader takes from the app, so a test can point it at a temp vault and a stub server.
    struct Environment {
        /// What reading one picture from the vault came to.
        enum VaultRead {
            /// The file is unchanged since the picture in memory was made.
            case unchanged(path: String)
            case image(path: String, CGImage, modifiedAt: Date)
            case notDownloaded
            case missing
        }

        /// Runs `body` with the vault open, or returns `nil` when no vault is connected.
        typealias VaultAccess = @Sendable (@Sendable (VaultFileStore) -> VaultRead) -> VaultRead?

        var session: URLSession
        var endpoint: @Sendable () -> String
        var token: @Sendable () -> String
        var allowInsecureHTTP: @Sendable () -> Bool
        var vaultAccess: VaultAccess
        var attachmentsFolder: @Sendable () -> String
        var diskCache: ThumbnailDiskCache
        var now: @Sendable () -> Date = { Date() }
        var maxConcurrentLoads = 4
        var maxFetchBytes = MemosAttachmentFetcher.defaultMaxBytes
    }

    private let environment: Environment
    private let fetcher: MemosAttachmentFetcher
    private let gate: AsyncGate
    private let memory = NSCache<NSString, MemoryEntry>()
    private let state = State()

    init(environment: Environment) {
        self.environment = environment
        fetcher = MemosAttachmentFetcher(
            session: environment.session,
            configuration: {
                .init(
                    endpoint: environment.endpoint(),
                    token: environment.token(),
                    allowInsecureHTTP: environment.allowInsecureHTTP()
                )
            },
            maxBytes: environment.maxFetchBytes
        )
        gate = AsyncGate(limit: environment.maxConcurrentLoads)
        memory.totalCostLimit = 32 * 1024 * 1024
        let diskCache = environment.diskCache
        Task.detached(priority: .utility) { diskCache.trim() }
    }

    // MARK: - API

    /// The picture if it is already in memory. No I/O, so a row's first render doesn't flash its placeholder.
    func cachedImage(for attachment: NoteAttachment, notePath: String?) -> UIImage? {
        guard attachment.kind == .image else { return nil }
        return memory.object(forKey: cacheKey(for: attachment, notePath: notePath) as NSString)?.image
    }

    /// The picture, at most `maxPixel` on its longest edge, or `nil`. Only images are loaded; a file tile is an
    /// icon. `notePath` is the vault-relative path of the note that holds the attachment, when it has one.
    func thumbnail(for attachment: NoteAttachment, notePath: String?) async -> UIImage? {
        guard attachment.kind == .image else { return nil }
        let key = cacheKey(for: attachment, notePath: notePath)
        let cached = memory.object(forKey: key as NSString)
        // The picture behind a URL never changes under it. A vault file can be replaced, so it is checked again.
        if attachment.isRemote, let cached { return cached.image }
        if await state.isFailing(key, now: environment.now()) { return cached?.image }

        let loaded = await state.coalesce(key: key) { [self] in
            if attachment.isRemote { return await loadRemote(attachment, key: key) }
            return await loadVault(attachment, notePath: notePath, key: key, cached: cached)
        }
        return loaded ?? cached?.image
    }

    // MARK: - Memos pictures

    private func loadRemote(_ attachment: NoteAttachment, key: String) async -> UIImage? {
        // The plain URL names the picture on disk; the thumbnail URL is only how it is asked for.
        guard let diskKey = fetcher.candidateURLs(for: attachment.target).last?.absoluteString else {
            return await fail(key)   // not ours to fetch: another host, or no endpoint or token
        }
        do { try await gate.acquire() } catch { return nil }

        let diskCache = environment.diskCache
        var picture = await offload {
            diskCache.data(forKey: diskKey).flatMap { ThumbnailDownsampler.downsample(data: $0) }
        }
        if picture == nil, !Task.isCancelled {
            picture = await fetcher.image(for: attachment.target, maxPixel: Self.maxPixel)
            if let fetched = picture {
                await offload {
                    if let jpeg = ThumbnailDownsampler.jpegData(from: fetched) { diskCache.store(jpeg, forKey: diskKey) }
                }
            }
        }
        await gate.release()

        guard let picture else { return await fail(key) }
        let image = UIImage(cgImage: picture)
        remember(image, key: key, stamp: nil)
        await state.clearFailure(key)
        return image
    }

    // MARK: - Vault pictures

    private func loadVault(
        _ attachment: NoteAttachment, notePath: String?, key: String, cached: MemoryEntry?
    ) async -> UIImage? {
        do { try await gate.acquire() } catch { return nil }

        let known = await state.resolution(for: key)
        let folder = environment.attachmentsFolder()
        let target = attachment.target
        let cachedStamp = cached?.stamp
        let read = await offload { [vaultAccess = environment.vaultAccess] () -> Environment.VaultRead? in
            vaultAccess { store in
                // A path found before is trusted until the file disappears; then the search starts over.
                let remembered = known.flatMap { store.attachmentModificationDate(at: $0) != nil ? $0 : nil }
                guard let path = remembered
                    ?? store.locateAttachment(target, attachmentsFolder: folder, notePath: notePath)
                else { return .missing }

                if let stamp = store.attachmentModificationDate(at: path), stamp == cachedStamp {
                    return .unchanged(path: path)
                }
                switch store.attachmentThumbnail(at: path, maxPixel: AttachmentThumbnailLoader.maxPixel) {
                case .image(let picture, let modifiedAt): return .image(path: path, picture, modifiedAt: modifiedAt)
                case .notDownloaded: return .notDownloaded
                case .unreadable: return .missing
                }
            }
        }
        await gate.release()

        switch read {
        case .unchanged(let path)?:
            await state.setResolution(path, for: key)
            await state.clearFailure(key)
            return cached?.image
        case .image(let path, let picture, let modifiedAt)?:
            let image = UIImage(cgImage: picture)
            remember(image, key: key, stamp: modifiedAt)
            await state.setResolution(path, for: key)
            await state.clearFailure(key)
            return image
        case .notDownloaded?:
            return await fail(key)   // a download was requested; the next try, a minute on, may find the file
        case .missing?, nil:
            await state.forgetResolution(for: key)
            return await fail(key)
        }
    }

    // MARK: - Helpers

    private func cacheKey(for attachment: NoteAttachment, notePath: String?) -> String {
        if attachment.isRemote { return "r|\(environment.endpoint())|\(attachment.target)" }
        let noteFolder = notePath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        return "v|\(environment.attachmentsFolder())|\(noteFolder)|\(attachment.target)"
    }

    private func remember(_ image: UIImage, key: String, stamp: Date?) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        memory.setObject(MemoryEntry(image: image, stamp: stamp), forKey: key as NSString, cost: cost)
    }

    /// Remembers the failure — unless the load was only cancelled — and returns `nil`.
    private func fail(_ key: String) async -> UIImage? {
        if !Task.isCancelled { await state.recordFailure(key, at: environment.now()) }
        return nil
    }

    /// Runs blocking work (file reads, decoding) on a background queue, not on the cooperative thread pool.
    private func offload<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }

    private final class MemoryEntry: @unchecked Sendable {
        let image: UIImage
        /// The vault file's modification date when the picture was made; `nil` for a Memos picture.
        let stamp: Date?

        init(image: UIImage, stamp: Date?) {
            self.image = image
            self.stamp = stamp
        }
    }

    /// What changes while pictures load: who is waiting on what, what failed lately, where vault files were found.
    private actor State {
        private final class Flight {
            let id = UUID()
            var task: Task<UIImage?, Never>?
            var waiters = 0
        }

        private var flights: [String: Flight] = [:]
        private var failures: [String: Date] = [:]
        private var resolutions: [String: String] = [:]

        /// Runs `work` once for every caller asking for `key` at the same time. The work is cancelled when the
        /// last caller still waiting for it goes away.
        func coalesce(key: String, work: @escaping @Sendable () async -> UIImage?) async -> UIImage? {
            let flight: Flight
            if let existing = flights[key] {
                flight = existing
            } else {
                flight = Flight()
                flights[key] = flight
                let id = flight.id
                flight.task = Task(priority: .utility) { [weak self] in
                    let result = await work()
                    await self?.finish(key: key, id: id)
                    return result
                }
            }
            flight.waiters += 1
            let id = flight.id
            let task = flight.task!
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                Task { await self.waiterLeft(key: key, id: id) }
            }
        }

        private func finish(key: String, id: UUID) {
            if flights[key]?.id == id { flights[key] = nil }
        }

        private func waiterLeft(key: String, id: UUID) {
            guard let flight = flights[key], flight.id == id else { return }
            flight.waiters -= 1
            guard flight.waiters <= 0 else { return }
            // Unregistered at once, so a caller arriving now starts a fresh load instead of joining a cancelled one.
            flights[key] = nil
            flight.task?.cancel()
        }

        func isFailing(_ key: String, now: Date) -> Bool {
            guard let failedAt = failures[key] else { return false }
            return now.timeIntervalSince(failedAt) < AttachmentThumbnailLoader.failureMemory
        }

        func recordFailure(_ key: String, at date: Date) { failures[key] = date }
        func clearFailure(_ key: String) { failures[key] = nil }

        func resolution(for key: String) -> String? { resolutions[key] }
        func setResolution(_ path: String, for key: String) { resolutions[key] = path }
        func forgetResolution(for key: String) { resolutions[key] = nil }
    }
}

extension AttachmentThumbnailLoader.Environment {
    /// The app's own settings, Keychain token, connected vault and cache folder.
    static var live: Self {
        // The loader keeps its own disk cache, and the server marks private attachments `no-store` anyway.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        return Self(
            session: URLSession(configuration: configuration),
            endpoint: { AppSettings.endpointBaseURL },
            token: { KeychainTokenStore.getToken() },
            allowInsecureHTTP: { AppSettings.allowInsecureHTTP },
            vaultAccess: { body in
                try? VaultBookmarkStore.withAccess { root in body(VaultFileStore(root: root)) }
            },
            attachmentsFolder: { AppSettings.vaultAttachmentsFolder },
            diskCache: ThumbnailDiskCache(directory: ThumbnailDiskCache.defaultDirectory)
        )
    }
}
