import Foundation

/// What tapping an attachment in the editor's strip does: gets a local copy of the file and hands it to the system
/// previewer (QuickLook), which shows it over the editor.
///
/// Only the last tap counts: tapping another attachment while one is still loading drops the first. A failure goes
/// to the caller's notice rather than an alert, so it never interrupts typing.
@MainActor
final class AttachmentPreviewer: ObservableObject {

    /// The copy being shown. Bound to `.quickLookPreview`, which sets it back to `nil` when the preview closes.
    /// A copy that is closed or replaced is deleted.
    @Published var previewURL: URL? {
        didSet {
            if let old = oldValue, old != previewURL { files.discard(old) }
        }
    }

    /// The attachment being fetched, once that has taken longer than `graceDelay`: the one to show a spinner on.
    /// A file already on the device opens before the spinner would have appeared.
    @Published private(set) var loadingIdentity: String?

    private struct Opening {
        /// Tells this tap's load from an earlier tap's load of the same attachment.
        let token = UUID()
        let identity: String
        var task: Task<Void, Never>?
    }

    private let files: AttachmentPreviewFiles
    private let graceDelay: Duration
    private var opening: Opening?

    init(files: AttachmentPreviewFiles = .shared, graceDelay: Duration = .milliseconds(250)) {
        self.files = files
        self.graceDelay = graceDelay
    }

    /// Whether tapping `attachment` can open a preview. Vault files only, for now.
    static func canPreview(_ attachment: NoteAttachment) -> Bool {
        !attachment.isRemote
    }

    /// Starts opening `attachment`. `notePath` is the vault-relative path of the note that holds it, when it has one.
    /// `onFailure` gets a sentence for the reader if it can't be opened.
    func open(_ attachment: NoteAttachment, notePath: String?, onFailure: @escaping @MainActor (String) -> Void) {
        guard Self.canPreview(attachment) else { return }
        let identity = attachment.identity
        if opening?.identity == identity { return }

        opening?.task?.cancel()
        loadingIdentity = nil

        var current = Opening(identity: identity)
        let token = current.token
        let files = files
        let graceDelay = graceDelay
        current.task = Task { [weak self] in
            let spinner = Task { [weak self] in
                try? await Task.sleep(for: graceDelay)
                guard !Task.isCancelled else { return }
                self?.showSpinner(token: token, identity: identity)
            }
            let outcome = await files.localFile(for: attachment, notePath: notePath)
            spinner.cancel()
            guard let self else {
                if case .ready(let url) = outcome { files.discard(url) }
                return
            }
            self.finish(token: token, attachment: attachment, outcome: outcome, onFailure: onFailure)
        }
        opening = current
    }

    // MARK: - Helpers

    private func showSpinner(token: UUID, identity: String) {
        guard opening?.token == token else { return }
        loadingIdentity = identity
    }

    private func finish(
        token: UUID,
        attachment: NoteAttachment,
        outcome: AttachmentPreviewFiles.Outcome,
        onFailure: @MainActor (String) -> Void
    ) {
        guard opening?.token == token else {
            // Another tap took over: this copy, if one was made, is nobody's.
            if case .ready(let url) = outcome { files.discard(url) }
            return
        }
        opening = nil
        loadingIdentity = nil

        if case .ready(let url) = outcome {
            previewURL = url
        } else if let message = Self.message(for: outcome, name: attachment.name) {
            onFailure(message)
        }
    }

    /// What to tell the reader, or `nil` when there is nothing to say (it worked, or the tap was dropped).
    private static func message(for outcome: AttachmentPreviewFiles.Outcome, name: String) -> String? {
        switch outcome {
        case .missing: return "Couldn't find \"\(name)\" in your vault."
        case .vaultUnavailable: return "Quoote can't reach your vault. Reconnect it in Settings."
        case .timedOut: return "\"\(name)\" hasn't finished downloading from iCloud. Try again in a moment."
        case .failed: return "Couldn't open \"\(name)\"."
        case .ready, .unsupported, .cancelled: return nil
        }
    }
}
