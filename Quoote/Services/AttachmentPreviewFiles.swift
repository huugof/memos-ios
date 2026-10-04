import Foundation

/// Gets a local file for an attachment, so the system previewer (QuickLook) can open it.
///
/// QuickLook reads from another process, and the vault is only open while Quoote holds its access, so a vault file
/// is copied into a folder of its own under the temporary directory. The caller deletes that folder when the
/// preview closes (`discard`); any a run never got to are swept the next time one of these is made.
final class AttachmentPreviewFiles: Sendable {

    /// What asking for a file came to.
    enum Outcome: Equatable {
        case ready(URL)
        /// Not found in the vault.
        case missing
        /// No vault is connected, or Quoote's access to it has lapsed.
        case vaultUnavailable
        /// iCloud hasn't delivered the file yet. The download carries on in the background.
        case timedOut
        /// Found, but copying it failed.
        case failed
        /// Not a vault file: Memos attachments aren't previewed yet.
        case unsupported
        /// The caller stopped waiting.
        case cancelled
    }

    /// Everything the service takes from the app, so a test can point it at a temp vault and a clock it moves by hand.
    struct Environment: Sendable {
        /// What one try at copying the file came to.
        enum Attempt: Equatable {
            case copied(URL)
            /// iCloud has the file but not on this device; a download was requested.
            case notDownloaded(path: String)
            case missing
            case unreadable
        }

        /// Runs `body` with the vault open, or returns `nil` when no vault is connected.
        typealias VaultAccess = @Sendable (@Sendable (VaultFileStore) -> Attempt) -> Attempt?

        var vaultAccess: VaultAccess
        var attachmentsFolder: @Sendable () -> String
        /// Where the copies go, a folder each.
        var directory: URL
        /// How long a tap waits for iCloud to deliver an evicted file.
        var downloadTimeout: TimeInterval = 30
        var pollInterval: Duration = .milliseconds(500)
        var now: @Sendable () -> Date = { Date() }
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    static let shared = AttachmentPreviewFiles(environment: .live)

    /// A copy this old belongs to a run that ended with a preview open.
    private static let staleAge: TimeInterval = 3600

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
        Task.detached(priority: .utility) { [self] in removeStaleCopies(olderThan: Self.staleAge) }
    }

    // MARK: - API

    /// A file the previewer can open, for `attachment`. `notePath` is the vault-relative path of the note that holds
    /// it, when it has one: `![[a.pdf]]` may name a file that sits beside the note.
    ///
    /// An evicted iCloud file is asked for and waited on, up to `downloadTimeout`; cancelling the calling task
    /// stops the wait. Whatever isn't `.ready` leaves nothing behind.
    func localFile(for attachment: NoteAttachment, notePath: String?) async -> Outcome {
        guard !attachment.isRemote else { return .unsupported }

        let folder = environment.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outcome = await copy(attachment, notePath: notePath, into: folder)
        if case .ready = outcome { return outcome }
        try? FileManager.default.removeItem(at: folder)
        return outcome
    }

    /// Deletes the folder holding the copy at `url`, and nothing else: a URL that isn't a copy made here is left alone.
    func discard(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path
                == environment.directory.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes the copies made more than `age` seconds ago.
    func removeStaleCopies(olderThan age: TimeInterval) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: environment.directory, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let cutoff = environment.now().addingTimeInterval(-age)
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? manager.removeItem(at: entry) }
        }
    }

    // MARK: - Copying

    private func copy(_ attachment: NoteAttachment, notePath: String?, into folder: URL) async -> Outcome {
        let attachmentsFolder = environment.attachmentsFolder()
        let target = attachment.target
        let deadline = environment.now().addingTimeInterval(environment.downloadTimeout)
        var known: String?

        while true {
            if Task.isCancelled { return .cancelled }
            let attempt = await offload { [vaultAccess = environment.vaultAccess, known] () -> Environment.Attempt? in
                vaultAccess { store in
                    // Where the file lives is worked out once; the tries after it only look again at that path.
                    guard let path = known ?? store.locateAttachment(
                        target, attachmentsFolder: attachmentsFolder, notePath: notePath
                    ) else { return .missing }

                    switch store.copyAttachment(at: path, into: folder) {
                    case .copied(let url): return .copied(url)
                    case .notDownloaded: return .notDownloaded(path: path)
                    case .unreadable: return .unreadable
                    }
                }
            }
            if Task.isCancelled { return .cancelled }

            switch attempt {
            case nil: return .vaultUnavailable
            case .copied(let url)?: return .ready(url)
            case .notDownloaded(let path)?: known = path
            case .missing?: if known == nil { return .missing }
            case .unreadable?: if known == nil { return .failed }
            }

            // Only here while waiting on iCloud. Once the file has been seen evicted, one that then seems to vanish
            // or fail to copy is more likely mid-swap (placeholder gone, real file not there yet) than gone for good.
            guard environment.now() < deadline else { return .timedOut }
            do { try await environment.sleep(environment.pollInterval) } catch { return .cancelled }
        }
    }

    /// Runs blocking work (file access, a coordinated copy) on a background queue, not on the cooperative thread pool.
    private func offload<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

extension AttachmentPreviewFiles.Environment {
    /// The connected vault, its attachments folder setting, and the app's temporary directory.
    static var live: Self {
        Self(
            vaultAccess: { body in
                try? VaultBookmarkStore.withAccess { root in body(VaultFileStore(root: root)) }
            },
            attachmentsFolder: { AppSettings.vaultAttachmentsFolder },
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentPreviews", isDirectory: true)
        )
    }
}
