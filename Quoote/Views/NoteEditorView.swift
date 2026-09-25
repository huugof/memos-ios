import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

/// The note editor, shown on the compose sheet. A `.newNote` target is the capture
/// screen: Send hands back a blank note in place. Any other target — or a pinned
/// note — commits and closes the sheet instead. Closing the sheet any other way
/// (dragging it down) commits too, via `onDisappear`.
struct NoteEditorView: View {
    let target: NoteEditorTarget

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Draft.updatedAt, order: .reverse) private var allDrafts: [Draft]
    @Query private var allEditDrafts: [ServerMemoEditDraft]
    @EnvironmentObject private var serverMemosStore: ServerMemosStore
    @EnvironmentObject private var sendQueue: DraftSendQueueController
    @EnvironmentObject private var saveQueue: ServerMemoSaveQueueController
    @EnvironmentObject private var pinnedStore: PinnedNotesStore
    @EnvironmentObject private var vaultStore: VaultStore

    // Draft editing state
    @State private var localDraftID: UUID?
    @State private var draftText: String = ""
    @State private var isFocused = false
    @State private var focusRequestID = UUID()

    // Server memo editing state
    @State private var editDraft: ServerMemoEditDraft?
    @State private var serverMemoContent: String = ""
    @State private var isLoadingServerMemo = false
    @State private var serverMemoError: String?

    // Vault note editing state
    @State private var loadedVaultNote: VaultNote?
    @State private var vaultNoteBody: String = ""
    /// The note couldn't be loaded — nothing to edit, so this blocks the
    /// editor the same way `serverMemoError` does.
    @State private var vaultLoadError: String?
    /// A vault save conflict or write failure, or a dictation problem.
    /// Non-blocking — shown as a dismissible banner over the still-editable
    /// text, never full-screen, so it never interrupts typing.
    @State private var noticeMessage: String?

    // Attachment state
    @State private var pendingImages: [PendingImage] = []
    @State private var pendingFiles: [PendingFile] = []
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var uploadError: String?

    // Tag suggestions
    @State private var remoteTags: [String] = []
    @State private var tagSuggestions: [String] = []
    @State private var remoteTagTask: Task<Void, Never>?
    @State private var persistDebounceTask: Task<Void, Never>?
    @State private var vaultSaveTask: Task<Void, Never>?

    @State private var editorController = PlainNoteEditorController()
    @StateObject private var speech = SpeechTranscriptionService()

    @State private var showAttachMenu = false
    @State private var frontmatterPreview: Result<String, Error>?
    @State private var didTapDone = false
    /// The sheet is on its way down — losing focus now is expected, not a cue to close.
    @State private var isClosing = false
    /// Last text sent via the home Send button — gates the button and double-sends.
    @State private var lastSentText = ""

    private var currentDraft: Draft? {
        guard let id = localDraftID else { return nil }
        return allDrafts.first { $0.id == id }
    }

    /// The unified note ID used by PinnedNotesStore (matches UnifiedNote.id format).
    private var noteID: String? {
        switch target {
        case .newNote, .localDraft:
            guard let id = localDraftID else { return nil }
            return "d-\(id.uuidString)"
        case .serverMemo(let memoID):
            return "m-\(memoID)"
        case .vaultFile(let path):
            return "v-\(path)"
        }
    }

    private var isPinned: Bool {
        guard let id = noteID else { return false }
        return pinnedStore.isPinned(id)
    }

    private var editDraftFromQuery: ServerMemoEditDraft? {
        guard case .serverMemo(let memoID) = target else { return nil }
        return allEditDrafts.first { $0.memoID == memoID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let err = serverMemoError ?? vaultLoadError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                    .padding(.top, Self.topFade)
                Spacer()
            } else if isLoadingServerMemo {
                Spacer()
                ProgressView("Loading…")
                Spacer()
            } else {
                editorBody
            }
        }
        .overlay(alignment: .bottom) {
            // Floats over the text, which scrolls on under the glass.
            VStack(spacing: 0) {
                if hasPendingAttachments {
                    pendingAttachmentsBar
                }
                editorBar
            }
        }
        .overlay(alignment: .top) {
            if let message = noticeMessage {
                noticeBanner(message)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItems,
                      maxSelectionCount: nil, matching: .images)
        .onChange(of: selectedPhotoItems) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run { handleImageSelected(image) }
                    }
                }
                selectedPhotoItems = []
            }
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            handleFileSelected(url: url)
        }
        .alert("Upload Failed", isPresented: .init(
            get: { uploadError != nil },
            set: { if !$0 { uploadError = nil } }
        )) {
            Button("OK") { uploadError = nil }
        } message: {
            if let err = uploadError { Text(err) }
        }
        .sheet(isPresented: .init(
            get: { frontmatterPreview != nil },
            set: { if !$0 { frontmatterPreview = nil } }
        )) {
            if let frontmatterPreview {
                FrontmatterPreviewSheet(result: frontmatterPreview)
            }
        }
        .task { await setup() }
        .onChange(of: draftText) { _, _ in
            schedulePersist()
            // Editing after a send re-arms auto-commit so leaving captures the new text.
            if draftText != lastSentText { didTapDone = false }
        }
        .onChange(of: serverMemoContent) { _, _ in
            stageServerMemoContent()
            if serverMemoContent != lastSentText { didTapDone = false }
        }
        .onChange(of: vaultNoteBody) { _, _ in
            scheduleVaultSave()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                stopDictation()
                saveCurrentState()
            }
        }
        .onChange(of: speech.transcribedText) { _, transcript in
            editorController.updateDictation(transcript)
        }
        .onChange(of: speech.isTranscribing) { _, transcribing in
            // The recognizer can end on its own (silence, final result, error). The
            // final transcript lands in the same update, so let it apply first.
            if !transcribing { Task { @MainActor in editorController.endDictation() } }
        }
        .onChange(of: speech.error) { _, error in
            if let error { noticeMessage = error }
        }
        .onChange(of: isFocused) { _, focused in
            // The sheet only stays up with the keyboard: putting the keyboard away
            // closes it (which commits, via onDisappear) — unless something the
            // editor presented is what took the keyboard.
            if !focused, !isCoveredByPresentation { closeSheet() }
        }
        .onChange(of: isCoveredByPresentation) { _, covered in
            if !covered { focusEditor() }
        }
        .onDisappear {
            stopDictation()
            persistDebounceTask?.cancel()
            persistDraftText()  // flush any pending debounced save before committing
            if !didTapDone { commitCurrent() }
            cleanupBlankDraft()
            remoteTagTask?.cancel()
        }
    }

    // MARK: Editor body

    private var editorBody: some View {
        PlainNoteEditor(
            text: textBinding,
            isFocused: $isFocused,
            focusRequestID: focusRequestID,
            extraBottomPadding: Self.editorBarHeight + 16
                + (hasPendingAttachments ? Self.attachmentsBarHeight : 0),
            extraTopPadding: Self.topFade,
            tagSuggestions: tagSuggestions,
            onTagAccepted: { rememberTag($0) },
            controller: editorController
        )
        .padding(.horizontal, 20)
        // Text scrolling up fades out under the sheet's drag indicator.
        .mask {
            VStack(spacing: 0) {
                // Eased, and never fully transparent: text stays faintly visible right
                // up to the sheet's edge.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.2), location: 0),
                        .init(color: .black.opacity(0.45), location: 0.35),
                        .init(color: .black.opacity(0.8), location: 0.7),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: Self.topFade)
                Color.black
            }
        }
        // The sheet's content starts a little above its visible (rounded) top edge.
        .padding(.top, 12)
    }

    /// The strip at the top of the sheet that holds the drag indicator. The text starts
    /// below it, so the fade only touches text that has scrolled up into it.
    private static let topFade: CGFloat = 44

    /// Non-blocking, dismissible banner for a vault save conflict/failure or a
    /// dictation problem. Sits over the editor without hiding it — neither must
    /// ever interrupt typing.
    private func noticeBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                noticeMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .padding(.top, Self.topFade)
    }

    private var textBinding: Binding<String> {
        switch target {
        case .newNote, .localDraft:
            return $draftText
        case .serverMemo:
            return $serverMemoContent
        case .vaultFile:
            return $vaultNoteBody
        }
    }

    private var pendingAttachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(pendingImages) { p in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: p.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        if p.isUploading {
                            ProgressView()
                                .frame(width: 56, height: 56)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Button { pendingImages.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black)
                                    .font(.caption)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
                ForEach(pendingFiles) { f in
                    ZStack(alignment: .topTrailing) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.fill")
                                .font(.caption)
                            Text(f.filename)
                                .font(.caption)
                                .lineLimit(2)
                                .frame(maxWidth: 80)
                        }
                        .padding(8)
                        .frame(height: 56)
                        .background(Color(uiColor: .secondarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 8))
                        if f.isUploading {
                            ProgressView()
                                .frame(height: 56)
                                .frame(maxWidth: .infinity)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Button { pendingFiles.removeAll { $0.id == f.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black)
                                    .font(.caption)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(height: Self.attachmentsBarHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 16)
    }

    private static let attachmentsBarHeight: CGFloat = 72
    /// Button height plus the bar's vertical padding.
    private static let editorBarHeight: CGFloat = 48 + 16

    private var hasPendingAttachments: Bool {
        !pendingImages.isEmpty || !pendingFiles.isEmpty
    }

    // MARK: Editor bar

    /// Rides above the keyboard: note tools on the left, send/confirm on the right.
    private var editorBar: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    barButton("number") { editorController.insertTagMarker() }
                    barButton("paperclip") { showAttachMenu = true }
                        .confirmationDialog("Add Attachment", isPresented: $showAttachMenu) {
                            Button("Photo Library") { showPhotoPicker = true }
                            Button("Choose File") { showFilePicker = true }
                            Button("Cancel", role: .cancel) {}
                        }
                    barButton(speech.isTranscribing ? "mic.fill" : "mic",
                              highlighted: speech.isTranscribing) { toggleDictation() }
                    barButton(isPinned ? "pin.fill" : "pin", highlighted: isPinned) { togglePin() }
                        .disabled(!canPin)
                    if showsFrontmatterButton {
                        barButton("curlybraces") { showFrontmatterPreview() }
                    }
                }
                .padding(.horizontal, 4)
                .glassEffect(.regular.interactive(), in: Capsule())

                Spacer(minLength: 0)

                Button { closesOnSend ? sendAndClose() : sendHome() } label: {
                    Image(systemName: isNewCapture ? "arrow.up" : "checkmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(canSend ? Color.black : Color.secondary)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(canSend ? .regular.tint(appAccent).interactive() : .regular.interactive(),
                             in: Circle())
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func barButton(_ systemName: String, highlighted: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17))
                .foregroundStyle(highlighted ? appAccent : .primary)
                .frame(width: 44, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Vault notes only: a Memos memo has no frontmatter to show.
    private var showsFrontmatterButton: Bool {
        switch target {
        case .vaultFile: return true
        case .serverMemo: return false
        case .newNote, .localDraft: return AppSettings.destinationKind == .vault
        }
    }

    /// Renders what the next save would write, from the same inputs it would use.
    private func showFrontmatterPreview() {
        let isExisting: Bool
        if case .vaultFile = target { isExisting = true } else { isExisting = false }
        guard !isExisting || loadedVaultNote != nil else { return }
        frontmatterPreview = Result {
            try vaultStore.previewFrontmatter(
                body: isExisting ? vaultNoteBody : draftText,
                note: isExisting ? loadedVaultNote : nil
            )
        }
    }

    /// A blank capture note has nothing to keep in front yet.
    private var canPin: Bool {
        guard noteID != nil else { return false }
        if case .newNote = target { return isPinned || !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }

    private func togglePin() {
        guard let id = noteID else { return }
        pinnedStore.toggle(id)
    }

    // MARK: Dictation

    private func toggleDictation() {
        if speech.isTranscribing {
            stopDictation()
            return
        }
        Task {
            guard await SpeechTranscriptionService.requestAuthorization(),
                  await AVAudioApplication.requestRecordPermission() else {
                noticeMessage = "Allow Microphone and Speech Recognition for Quoote in Settings to dictate."
                return
            }
            editorController.beginDictation()
            speech.startTranscription()
            if !speech.isTranscribing { editorController.endDictation() }
        }
    }

    private func stopDictation() {
        guard speech.isTranscribing else { return }
        speech.stopTranscription()
        editorController.endDictation()
    }

    // MARK: Send

    private var canSend: Bool {
        let text = textBinding.wrappedValue
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && text != lastSentText
    }

    /// Home: enqueue the current draft and immediately hand back a blank note.
    /// A failed vault write leaves the draft (and its text) on screen instead —
    /// see `dispatchSend`.
    private func sendHome() {
        guard canSend, let draft = currentDraft else { return }
        stopDictation()
        persistDraftText()
        appendPendingAttachments(to: draft)
        guard dispatchSend(draft) else {
            // Vault write failed: leave text/draft exactly as they are so
            // Send can be tapped again (canSend is still true — neither
            // the text nor lastSentText changed), and don't let onDisappear
            // treat this as handled.
            return
        }
        didTapDone = true  // don't let onDisappear re-enqueue this same send
        resetToNewNote()
    }

    /// A fresh capture note is sent (↑); an existing or pinned note is confirmed (✓).
    private var isNewCapture: Bool {
        if case .newNote = target { return !isPinned }
        return false
    }

    /// An existing note, or the pinned one, is confirmed rather than sent-and-reset:
    /// commit it and close the sheet. Reopening lands on the pinned note again.
    /// A capture note closes too when Settings asks for history after sending.
    private var closesOnSend: Bool {
        !isNewCapture || AppSettings.showHistoryAfterSend
    }

    /// Commit, then close the sheet. A failed vault write for a new note keeps the
    /// sheet open with its text, as `sendHome` does.
    private func sendAndClose() {
        guard canSend else { return }
        stopDictation()
        if case .newNote = target {
            guard let draft = currentDraft else { return }
            persistDraftText()
            appendPendingAttachments(to: draft)
            guard dispatchSend(draft) else { return }
        } else {
            commitCurrent()
        }
        didTapDone = true
        lastSentText = textBinding.wrappedValue
        closeSheet()
    }

    private func closeSheet() {
        guard !isClosing else { return }
        isClosing = true
        dismiss()
    }

    private func focusEditor() {
        isFocused = true
        focusRequestID = UUID()
    }

    /// Something the editor presented is covering it — the keyboard is down because
    /// of that, and comes back when it's gone.
    private var isCoveredByPresentation: Bool {
        showAttachMenu || showPhotoPicker || showFilePicker
            || uploadError != nil || frontmatterPreview != nil
    }

    /// Swap the editor onto a fresh blank draft without rebuilding the view — the
    /// UITextView (and the keyboard with it) stays alive, so capture stays instant.
    private func resetToNewNote() {
        persistDebounceTask?.cancel()
        persistDraftText()
        let draft = DraftStore.createDraft(in: modelContext)
        localDraftID = draft.id
        draftText = ""
        lastSentText = ""
        didTapDone = false
        pendingImages = []
        pendingFiles = []
        focusEditor()
    }

    // MARK: Actions

    private func commitCurrent() {
        switch target {
        case .newNote, .localDraft:
            commitDraft()
        case .serverMemo:
            commitServerMemo()
        case .vaultFile:
            vaultSaveTask?.cancel()
            vaultSaveTask = nil
            appendPendingAttachments(toText: &vaultNoteBody)
            saveVaultNote()
        }
    }

    private func commitDraft() {
        guard let draft = currentDraft else { return }
        persistDraftText()
        appendPendingAttachments(to: draft)
        guard draft.hasStartedText else { return }
        dispatchSend(draft)
    }

    /// Sends the current draft to whichever destination is active. The Memos
    /// path keeps its queue; the vault path writes the file immediately.
    /// Returns `false` only when a vault write failed, so callers (namely
    /// `sendHome()`) know not to archive/reset — the draft and its text stay
    /// on screen, with the failure surfaced via `noticeMessage`, for a
    /// retry.
    @discardableResult
    private func dispatchSend(_ draft: Draft) -> Bool {
        switch AppSettings.destinationKind {
        case .memos:
            // Result deliberately ignored, as before this destination split:
            // the Memos path's reset-after-send behavior must stay unchanged.
            sendQueue.enqueue(draft, in: modelContext)
            return true
        case .vault:
            // A draft still in flight to the Memos queue (sent just before a
            // destination switch) must not also be written to the vault —
            // switching destinations migrates nothing. Treat it as a no-op,
            // not a failure: there is nothing wrong to report here.
            guard draft.sendState != .pending && draft.sendState != .sending else {
                return true
            }
            do {
                let entry = try vaultStore.create(body: draft.text)
                pinnedStore.migrate(fromDraft: draft.id, to: "v-\(entry.relativePath)")
                draft.isArchived = true
                draft.lastSentAt = Date()
                draft.sendState = .sent
                draft.lastError = nil
                modelContext.saveOrAssert()
                noticeMessage = nil
                return true
            } catch {
                // Leave the draft unarchived so no text is lost.
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                draft.sendState = .failed
                draft.lastError = message
                modelContext.saveOrAssert()
                // Surface on this screen (non-blocking banner) and in the
                // list's error row — a failed vault send must never be silent.
                noticeMessage = message
                vaultStore.errorMessage = message
                return false
            }
        }
    }

    private func commitServerMemo() {
        guard let ed = editDraft ?? editDraftFromQuery else { return }
        appendPendingAttachments(toText: &serverMemoContent)
        _ = ServerMemoSaveService.stageLocalContent(serverMemoContent, for: ed, in: modelContext, persist: true)
        saveQueue.enqueue(ed, in: modelContext)
    }

    private func saveCurrentState() {
        switch target {
        case .newNote, .localDraft:
            persistDraftText()
        case .serverMemo:
            if let ed = editDraft ?? editDraftFromQuery {
                _ = ServerMemoSaveService.stageLocalContent(serverMemoContent, for: ed, in: modelContext, persist: true)
            }
        case .vaultFile:
            vaultSaveTask?.cancel()
            vaultSaveTask = nil
            appendPendingAttachments(toText: &vaultNoteBody)
            saveVaultNote()
        }
    }

    private func cleanupBlankDraft() {
        guard case .newNote = target, let draft = currentDraft else { return }
        if draft.isBlank { DraftStore.delete(draft, in: modelContext) }
    }

    private func schedulePersist() {
        persistDebounceTask?.cancel()
        persistDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            persistDraftText()
        }
    }

    private func persistDraftText() {
        guard let draft = currentDraft else { return }
        if draft.text != draftText {
            draft.text = draftText
            draft.updatedAt = Date()
            modelContext.saveOrAssert()
        }
    }

    private func stageServerMemoContent() {
        guard let ed = editDraft ?? editDraftFromQuery else { return }
        _ = ServerMemoSaveService.stageLocalContent(serverMemoContent, for: ed, in: modelContext)
    }

    // MARK: Setup

    private func setup() async {
        switch target {
        case .newNote:
            let draft = DraftStore.createDraft(in: modelContext)
            localDraftID = draft.id
            draftText = ""
        case .localDraft(let id):
            localDraftID = id
            if let draft = allDrafts.first(where: { $0.id == id }) {
                draftText = draft.text
            }
        case .serverMemo(let memoID):
            await loadServerMemo(memoID: memoID)
        case .vaultFile(let path):
            loadVaultNote(path)
        }
        // Every note opens with the keyboard up — the sheet never sits without it.
        if serverMemoError == nil, vaultLoadError == nil { focusEditor() }
        fetchRemoteTagsOnce()
        refreshTagSuggestions()
    }

    private func loadServerMemo(memoID: String) async {
        guard let memo = serverMemosStore.memo(memoID: memoID) else {
            serverMemoError = "Note not found."
            return
        }

        let fullMemo: ServerMemoSummary?
        if memo.hasFullContent {
            fullMemo = memo
        } else {
            isLoadingServerMemo = true
            fullMemo = await serverMemosStore.memoForEditing(memo)
            isLoadingServerMemo = false
        }

        guard let fm = fullMemo else {
            serverMemoError = serverMemosStore.openingError(for: memoID) ?? "Could not load note."
            return
        }

        let ed = ServerMemoSaveService.upsertEditDraft(for: fm, in: modelContext)
        editDraft = ed
        serverMemoContent = ed.hasLocalChanges ? ed.localContent : fm.content
    }

    /// Loads a vault note's body on demand. The list holds only index entries —
    /// in an iCloud vault, reading bodies to draw rows would download the vault.
    private func loadVaultNote(_ relativePath: String) {
        do {
            let note = try vaultStore.read(relativePath: relativePath)
            loadedVaultNote = note
            vaultNoteBody = note.body
            vaultLoadError = nil
        } catch {
            vaultLoadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Saves the open vault note. A conflict is reported, not retried — the
    /// user's text is already safely on disk under the conflict name.
    private func saveVaultNote() {
        guard let note = loadedVaultNote else { return }
        // Nothing changed since load (or since the last save) — writing anyway
        // would bump `updated` and produce a sync diff for a note nobody edited.
        guard vaultNoteBody != note.body else { return }
        do {
            let outcome = try vaultStore.update(note: note, body: vaultNoteBody)
            // The next save's baseline is exactly what was written — never a
            // re-read, which could adopt a desktop write that landed in
            // between and let the next save silently clobber it. For a
            // conflict, the outcome's note is the copy, so further edits keep
            // going to the copy instead of spawning a new one per save.
            loadedVaultNote = outcome.note
            switch outcome.result {
            case .written:
                noticeMessage = nil
            case .conflictCopy(let path, _):
                noticeMessage = "This note changed elsewhere. Your version was saved as \(path)."
            }
        } catch {
            noticeMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func scheduleVaultSave() {
        vaultSaveTask?.cancel()
        vaultSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveVaultNote()
        }
    }

    /// Names an image after the note it's attached to. When editing an
    /// existing vault note, attachments are named after that note's file;
    /// otherwise after the timestamp the new note will get (an occasional
    /// one-minute skew is harmless — the writer never overwrites).
    private func vaultAttachmentStem() -> String {
        if case .vaultFile(let path) = target {
            return (path as NSString).lastPathComponent
        }
        return VaultNoteSerializer.filename(for: Date(), existing: [])
    }

    // MARK: Attachment upload

    private func appendPendingAttachments(to draft: Draft) {
        let uploaded = attachmentMarkdown(existingText: draft.text)
        guard !uploaded.isEmpty else {
            pendingImages.removeAll()
            pendingFiles.removeAll()
            return
        }
        let sep = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
        draft.text = draft.text + sep + uploaded.joined(separator: "\n")
        draft.updatedAt = Date()
        modelContext.saveOrAssert()
        // Keep the editor's copy in step: a later persistDraftText() would otherwise
        // write the pre-attachment text back over the markdown we just appended.
        draftText = draft.text
        pendingImages.removeAll()
        pendingFiles.removeAll()
    }

    private func appendPendingAttachments(toText content: inout String) {
        let uploaded = attachmentMarkdown(existingText: content)
        guard !uploaded.isEmpty else {
            pendingImages.removeAll()
            pendingFiles.removeAll()
            return
        }
        let sep = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
        content = content + sep + uploaded.joined(separator: "\n")
        pendingImages.removeAll()
        pendingFiles.removeAll()
    }

    private func attachmentMarkdown(existingText: String) -> [String] {
        AttachmentMarkdownBuilder.build(
            images: pendingImages,
            files: pendingFiles,
            currentDestination: AppSettings.destinationKind
        )
    }

    private func handleImageSelected(_ image: UIImage) {
        let resized = image.editorResizedToMaxEdge(1024)
        guard let data = resized.jpegData(compressionQuality: 0.75) else { return }
        let pending = PendingImage(image: resized)
        pendingImages.append(pending)
        let pendingID = pending.id
        if AppSettings.destinationKind == .vault {
            do {
                let written = try VaultBookmarkStore.withAccess { root in
                    try VaultAttachmentWriter.write(
                        data: data,
                        filename: VaultAttachmentWriter.filename(
                            forNoteNamed: vaultAttachmentStem(),
                            index: pendingImages.count,
                            fileExtension: "jpg"
                        ),
                        using: VaultFileStore(root: root),
                        folder: AppSettings.vaultAttachmentsFolder
                    )
                }
                if let idx = pendingImages.firstIndex(where: { $0.id == pendingID }) {
                    pendingImages[idx].uploadedURL = written
                    pendingImages[idx].vaultPath = written
                    pendingImages[idx].isUploading = false
                }
            } catch {
                pendingImages.removeAll { $0.id == pendingID }
                uploadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return
        }
        Task {
            do {
                let result = try await MemosClient().uploadResource(
                    imageData: data, mimeType: "image/jpeg", filename: "image.jpg",
                    baseURLString: AppSettings.endpointBaseURL,
                    token: KeychainTokenStore.getToken(),
                    allowInsecureHTTP: AppSettings.allowInsecureHTTP
                )
                let base = AppSettings.endpointBaseURL.trimmingCharacters(in: .init(charactersIn: "/"))
                let url = "\(base)\(result.fileURLPath)"
                if let idx = pendingImages.firstIndex(where: { $0.id == pendingID }) {
                    pendingImages[idx].uploadedURL = url
                    pendingImages[idx].isUploading = false
                }
            } catch {
                pendingImages.removeAll { $0.id == pendingID }
                uploadError = error.localizedDescription
            }
        }
    }

    private func handleFileSelected(url: URL) {
        if AppSettings.destinationKind == .vault {
            uploadError = "File attachments aren't supported for vault notes yet."
            return
        }
        let filename = url.lastPathComponent
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let pending = PendingFile(filename: filename)
        pendingFiles.append(pending)
        let pendingID = pending.id
        Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                await MainActor.run {
                    self.pendingFiles.removeAll { $0.id == pendingID }
                    self.uploadError = "Could not read file."
                }
                return
            }
            do {
                let result = try await MemosClient().uploadResource(
                    imageData: data, mimeType: mimeType, filename: filename,
                    baseURLString: AppSettings.endpointBaseURL,
                    token: KeychainTokenStore.getToken(),
                    allowInsecureHTTP: AppSettings.allowInsecureHTTP
                )
                let base = AppSettings.endpointBaseURL.trimmingCharacters(in: .init(charactersIn: "/"))
                let resourceURL = "\(base)\(result.fileURLPath)"
                await MainActor.run {
                    if let idx = self.pendingFiles.firstIndex(where: { $0.id == pendingID }) {
                        self.pendingFiles[idx].uploadedURL = resourceURL
                        self.pendingFiles[idx].isUploading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.pendingFiles.removeAll { $0.id == pendingID }
                    self.uploadError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Tag suggestions (ported from ServerMemoEditorView)

    private func fetchRemoteTagsOnce() {
        remoteTagTask?.cancel()
        guard AppSettings.destinationKind == .memos else { return }
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
            } catch {}
        }
    }

    private func refreshTagSuggestions() {
        let currentText = textBinding.wrappedValue
        let localTags = extractTagsFromTexts(allDrafts.map(\.text) + [currentText])
        // A vault has no tag endpoint; its index already holds every file's tags.
        let vaultTags = AppSettings.destinationKind == .vault ? vaultStore.entries.flatMap(\.tags) : []
        var canonicalByLower: [String: String] = [:]
        for tag in AppSettings.customTags + localTags + remoteTags + vaultTags {
            let key = normalizeTag(tag).lowercased()
            guard !key.isEmpty, canonicalByLower[key] == nil else { continue }
            canonicalByLower[key] = normalizeTag(tag)
        }
        let recents = Dictionary(
            uniqueKeysWithValues: AppSettings.recentAcceptedTags.enumerated().map { ($0.element.lowercased(), $0.offset) }
        )
        tagSuggestions = canonicalByLower.values.sorted {
            let l = recents[$0.lowercased()] ?? Int.max
            let r = recents[$1.lowercased()] ?? Int.max
            return l != r ? l < r : $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func rememberTag(_ tag: String) {
        let n = normalizeTag(tag)
        guard !n.isEmpty else { return }
        var current = AppSettings.recentAcceptedTags
        current.removeAll { $0.compare(n, options: .caseInsensitive) == .orderedSame }
        current.insert(n, at: 0)
        AppSettings.recentAcceptedTags = Array(current.prefix(100))
        refreshTagSuggestions()
    }

    private func extractTagsFromTexts(_ texts: [String]) -> [String] {
        TagExtractor.tags(inTexts: texts)
    }

    private func normalizeTag(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("#") { v.removeFirst() }
        return v.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}

private extension UIImage {
    func editorResizedToMaxEdge(_ maxEdge: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxEdge else { return self }
        let scale = maxEdge / longest
        let newSize = CGSize(width: (size.width * scale).rounded(),
                             height: (size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
