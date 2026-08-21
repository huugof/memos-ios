import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct NoteEditorView: View {
    let target: NoteEditorTarget
    /// When true, this is the compose-first home screen (its own chrome: history, send, new).
    var isHome: Bool = false
    /// Home only: true while the notes drawer covers this screen. The compose screen stays
    /// mounted underneath it, so focus has to be handed over explicitly.
    var isMenuOpen: Bool = false
    /// Invoked by the home "+" button to start a fresh note.
    var onNewNote: () -> Void = {}
    /// Invoked by the ☰ button and the home left-edge swipe to open the notes drawer.
    var onOpenMenu: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Draft.updatedAt, order: .reverse) private var allDrafts: [Draft]
    @Query private var allEditDrafts: [ServerMemoEditDraft]
    @EnvironmentObject private var serverMemosStore: ServerMemosStore
    @EnvironmentObject private var sendQueue: DraftSendQueueController
    @EnvironmentObject private var saveQueue: ServerMemoSaveQueueController
    @EnvironmentObject private var pinnedStore: PinnedNotesStore

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

    @State private var showAttachMenu = false
    @State private var didTapDone = false
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
            if let err = serverMemoError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else if isLoadingServerMemo {
                Spacer()
                ProgressView("Loading…")
                Spacer()
            } else {
                editorBody
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .background {
            if isHome {
                // Root screen: the left edge opens the notes list (the system pop
                // gesture is inert here anyway — nothing to pop back to).
                NavigationGestures(edge: .left) { onOpenMenu() }
            } else {
                NavigationGestures()
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { saveCurrentState() }
        }
        .onChange(of: isMenuOpen) { _, open in
            // Hand the keyboard to the drawer and take it back on close — this screen
            // never unmounts, so nothing else resigns first responder for us.
            if open {
                isFocused = false
            } else {
                isFocused = true
                focusRequestID = UUID()
            }
        }
        .onDisappear {
            persistDebounceTask?.cancel()
            persistDraftText()  // flush any pending debounced save before committing
            if !didTapDone { commitCurrent() }
            cleanupBlankDraft()
            remoteTagTask?.cancel()
        }
    }

    // MARK: Editor body

    private var editorBody: some View {
        ZStack(alignment: .bottom) {
            PlainNoteEditor(
                text: textBinding,
                isFocused: $isFocused,
                focusRequestID: focusRequestID,
                extraBottomPadding: pendingAttachmentsHeight + 100,
                tagSuggestions: tagSuggestions,
                onTagAccepted: { rememberTag($0) }
            )
            .padding(.horizontal, 20)

            if !pendingImages.isEmpty || !pendingFiles.isEmpty {
                pendingAttachmentsBar
            }

            // Bottom fade — inside the ZStack so it shares the extended frame
            LinearGradient(
                colors: [.clear, Color(uiColor: .systemBackground).opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .top)
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [Color(uiColor: .systemBackground).opacity(0.6), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }

    private var textBinding: Binding<String> {
        switch target {
        case .newNote, .localDraft:
            return $draftText
        case .serverMemo:
            return $serverMemoContent
        }
    }

    private var pendingAttachmentsHeight: CGFloat {
        pendingImages.isEmpty && pendingFiles.isEmpty ? 0 : 72
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
        .frame(height: 72)
        .background(.ultraThinMaterial)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isHome {
            homeToolbarContent
        } else {
            editToolbarContent
        }
    }

    @ToolbarContentBuilder
    private var homeToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { onOpenMenu() } label: {
                Image(systemName: "line.3.horizontal")
                    .fontWeight(.semibold)
            }
            .tint(.primary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 0) {
                Button { showAttachMenu = true } label: {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .tint(.primary)
                .confirmationDialog("Add Attachment", isPresented: $showAttachMenu) {
                    Button("Photo Library") { showPhotoPicker = true }
                    Button("Choose File") { showFilePicker = true }
                    Button("Cancel", role: .cancel) {}
                }

                Divider().frame(height: 16)

                Button { resetToNewNote() } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .tint(.primary)
            }
            .fixedSize()
            .glassToolbarCapsule()
        }
        sendToolbarItem { sendHome() }
    }

    /// The ↑ send button — identical on both screens so it stays in the same spot.
    @ToolbarContentBuilder
    private func sendToolbarItem(action: @escaping () -> Void) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: action) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend ? appAccent : Color.secondary)
            }
            .disabled(!canSend)
        }
    }

    @ToolbarContentBuilder
    private var editToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { handleBack() } label: {
                Image(systemName: "chevron.left")
                    .fontWeight(.semibold)
            }
            .tint(.primary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 0) {
                Button { togglePin() } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 15))
                        .foregroundStyle(isPinned ? appAccent : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .disabled(noteID == nil)

                Divider()
                    .frame(height: 16)

                Button {
                    showAttachMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .tint(.primary)
                .confirmationDialog("Add Attachment", isPresented: $showAttachMenu) {
                    Button("Photo Library") { showPhotoPicker = true }
                    Button("Choose File") { showFilePicker = true }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .fixedSize()
            .glassToolbarCapsule()
        }
        sendToolbarItem { sendEdit() }
    }

    private func togglePin() {
        guard let id = noteID else { return }
        pinnedStore.toggle(id)
    }

    // MARK: Send

    private var canSend: Bool {
        let text = textBinding.wrappedValue
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && text != lastSentText
    }

    /// Home: enqueue the current draft and immediately hand back a blank note.
    private func sendHome() {
        guard canSend, let draft = currentDraft else { return }
        persistDraftText()
        appendPendingAttachments(to: draft)
        sendQueue.enqueue(draft, in: modelContext)
        didTapDone = true  // don't let onDisappear re-enqueue this same send
        resetToNewNote()
    }

    /// Edit screen: push the change to the server, then pop back where we came from.
    private func sendEdit() {
        guard canSend else { return }
        didTapDone = true
        lastSentText = textBinding.wrappedValue
        commitCurrent()
        dismiss()
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
        isFocused = true
        focusRequestID = UUID()
    }

    // MARK: Actions

    private func handleBack() {
        didTapDone = true
        commitCurrent()
        dismiss()
    }

    private func commitCurrent() {
        switch target {
        case .newNote, .localDraft:
            commitDraft()
        case .serverMemo:
            commitServerMemo()
        }
    }

    private func commitDraft() {
        guard let draft = currentDraft else { return }
        persistDraftText()
        appendPendingAttachments(to: draft)
        guard draft.hasStartedText else { return }
        sendQueue.enqueue(draft, in: modelContext)
    }

    private func commitServerMemo() {
        guard let ed = editDraft ?? editDraftFromQuery else { return }
        appendPendingAttachmentsToServerMemo(content: &serverMemoContent)
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
            isFocused = true
            focusRequestID = UUID()
        case .localDraft(let id):
            localDraftID = id
            if let draft = allDrafts.first(where: { $0.id == id }) {
                draftText = draft.text
            }
        case .serverMemo(let memoID):
            await loadServerMemo(memoID: memoID)
        }
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

    private func appendPendingAttachmentsToServerMemo(content: inout String) {
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
        var parts: [String] = []
        for p in pendingImages where p.uploadedURL != nil {
            parts.append("![](\(p.uploadedURL!))")
        }
        for f in pendingFiles where f.uploadedURL != nil {
            parts.append("[\(f.filename)](\(f.uploadedURL!))")
        }
        return parts
    }

    private func handleImageSelected(_ image: UIImage) {
        let resized = image.editorResizedToMaxEdge(1024)
        guard let data = resized.jpegData(compressionQuality: 0.75) else { return }
        let pending = PendingImage(image: resized)
        pendingImages.append(pending)
        let pendingID = pending.id
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
        var canonicalByLower: [String: String] = [:]
        for tag in localTags + remoteTags {
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

/// Two jobs on the enclosing `UINavigationController`:
///
/// 1. Keeps the system swipe-back alive on screens that hide the back button, while
///    refusing it at the stack root (a `nil` delegate there can strand the stack).
/// 2. Optionally installs a screen-edge pan that runs `action` — the compose home uses
///    the left edge to open the notes list, the list uses the right edge to close.
///
/// The recognizer lives on the nav controller's view, so it stays attached while the
/// screen sits underneath a pushed one; `action` therefore only fires when this
/// screen is the visible one.
struct NavigationGestures: UIViewControllerRepresentable {
    var edge: UIRectEdge?
    var action: () -> Void = {}

    init(edge: UIRectEdge? = nil, action: @escaping () -> Void = {}) {
        self.edge = edge
        self.action = action
    }

    func makeUIViewController(context: Context) -> HostController {
        let controller = HostController()
        let coordinator = context.coordinator
        let edge = edge
        // viewDidAppear is the first moment the navigation controller is reachable, and
        // it fires again on every pop back — which re-claims the pop gesture's delegate.
        controller.onAppear = { [weak controller] in
            guard let controller, let nav = controller.navigationController else { return }
            coordinator.adopt(nav: nav, host: controller, edge: edge)
        }
        return controller
    }

    func updateUIViewController(_ vc: HostController, context: Context) {
        context.coordinator.action = action
        if let nav = vc.navigationController {
            context.coordinator.adopt(nav: nav, host: vc, edge: edge)
        }
    }

    static func dismantleUIViewController(_ vc: HostController, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class HostController: UIViewController {
        var onAppear: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var action: () -> Void
        private weak var navigationController: UINavigationController?
        private weak var host: UIViewController?
        private var edgeRecognizer: UIScreenEdgePanGestureRecognizer?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func adopt(nav: UINavigationController, host: UIViewController, edge: UIRectEdge?) {
            navigationController = nav
            self.host = host
            nav.interactivePopGestureRecognizer?.delegate = self

            guard let edge, edgeRecognizer == nil else { return }
            let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
            recognizer.edges = edge
            recognizer.delegate = self
            nav.view.addGestureRecognizer(recognizer)
            edgeRecognizer = recognizer
        }

        func detach() {
            if let recognizer = edgeRecognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
                edgeRecognizer = nil
            }
            if navigationController?.interactivePopGestureRecognizer?.delegate === self {
                navigationController?.interactivePopGestureRecognizer?.delegate = nil
            }
        }

        @objc private func handleEdgePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard recognizer.state == .began, isHostVisible else { return }
            action()
        }

        /// True when the screen that owns this coordinator is the one on screen — the
        /// recognizer outlives a push, and must go quiet while covered.
        private var isHostVisible: Bool {
            guard let top = navigationController?.topViewController else { return false }
            var node = host
            while let current = node {
                if current === top { return true }
                node = current.parent
            }
            return false
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            if recognizer === navigationController?.interactivePopGestureRecognizer {
                return (navigationController?.viewControllers.count ?? 0) > 1
            }
            return true
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
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
