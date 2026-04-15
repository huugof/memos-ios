import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

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

    // Draft editing state
    @State private var localDraftID: UUID?
    @State private var draftText: String = ""
    @State private var isFocused = true
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

    @State private var showAttachMenu = false
    @State private var didTapDone = false

    private var currentDraft: Draft? {
        guard let id = localDraftID else { return nil }
        return allDrafts.first { $0.id == id }
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
        .onChange(of: draftText) { _, _ in persistDraftText() }
        .onChange(of: serverMemoContent) { _, _ in stageServerMemoContent() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { saveCurrentState() }
        }
        .onDisappear {
            if !didTapDone { saveCurrentState() }
            cleanupBlankDraft()
            remoteTagTask?.cancel()
        }
    }

    // MARK: Editor body

    private var editorBody: some View {
        ZStack(alignment: .bottom) {
            EditableNoteTextView(
                text: textBinding,
                isFocused: $isFocused,
                focusRequestID: focusRequestID,
                extraBottomScrollPadding: pendingAttachmentsHeight + 20,
                tagSuggestions: tagSuggestions,
                onTagAccepted: { rememberTag($0) },
                onTagTapped: { _ in }
            )
            .padding(.horizontal, 20)
            .padding(.top, 8)

            if !pendingImages.isEmpty || !pendingFiles.isEmpty {
                pendingAttachmentsBar
            }
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
        ToolbarItem(placement: .topBarLeading) {
            Button { handleBack() } label: {
                Image(systemName: "chevron.left")
                    .fontWeight(.semibold)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showAttachMenu = true
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .confirmationDialog("Add Attachment", isPresented: $showAttachMenu) {
                Button("Photo Library") { showPhotoPicker = true }
                Button("Choose File") { showFilePicker = true }
                Button("Cancel", role: .cancel) {}
            }

            Button { handleDone() } label: {
                ZStack {
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
        }
    }

    // MARK: Actions

    private func handleBack() {
        saveCurrentState()
        dismiss()
    }

    private func handleDone() {
        didTapDone = true
        switch target {
        case .newNote, .localDraft:
            commitDraft()
        case .serverMemo:
            commitServerMemo()
        }
        dismiss()
    }

    private func commitDraft() {
        guard let draft = currentDraft else { return }
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
        guard !didTapDone, case .newNote = target, let draft = currentDraft else { return }
        if draft.isBlank {
            DraftStore.delete(draft, in: modelContext)
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
        for p in pendingImages where p.uploadedURL != nil {
            let sep = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
            draft.text += sep + "![](\(p.uploadedURL!))"
        }
        for f in pendingFiles where f.uploadedURL != nil {
            let sep = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
            draft.text += sep + "[\(f.filename)](\(f.uploadedURL!))"
        }
        if !pendingImages.isEmpty || !pendingFiles.isEmpty {
            draft.updatedAt = Date()
            modelContext.saveOrAssert()
        }
        pendingImages.removeAll()
        pendingFiles.removeAll()
    }

    private func appendPendingAttachmentsToServerMemo(content: inout String) {
        for p in pendingImages where p.uploadedURL != nil {
            let sep = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
            content += sep + "![](\(p.uploadedURL!))"
        }
        for f in pendingFiles where f.uploadedURL != nil {
            let sep = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
            content += sep + "[\(f.filename)](\(f.uploadedURL!))"
        }
        pendingImages.removeAll()
        pendingFiles.removeAll()
    }

    private func handleImageSelected(_ image: UIImage) {
        let resized = image.editorResizedToMaxEdge(1024)
        guard let data = resized.jpegData(compressionQuality: 0.75) else { return }
        var pending = PendingImage(image: resized)
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
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            uploadError = "Could not read file."
            return
        }
        let filename = url.lastPathComponent
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var pending = PendingFile(filename: filename)
        pendingFiles.append(pending)
        let pendingID = pending.id
        Task {
            do {
                let result = try await MemosClient().uploadResource(
                    imageData: data, mimeType: mimeType, filename: filename,
                    baseURLString: AppSettings.endpointBaseURL,
                    token: KeychainTokenStore.getToken(),
                    allowInsecureHTTP: AppSettings.allowInsecureHTTP
                )
                let base = AppSettings.endpointBaseURL.trimmingCharacters(in: .init(charactersIn: "/"))
                let resourceURL = "\(base)\(result.fileURLPath)"
                if let idx = pendingFiles.firstIndex(where: { $0.id == pendingID }) {
                    pendingFiles[idx].uploadedURL = resourceURL
                    pendingFiles[idx].isUploading = false
                }
            } catch {
                pendingFiles.removeAll { $0.id == pendingID }
                uploadError = error.localizedDescription
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
        guard let regex = try? NSRegularExpression(pattern: #"#([A-Za-z0-9_-]+)"#) else { return [] }
        var results: [String] = []
        for text in texts {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { continue }
                results.append(String(text[r]))
            }
        }
        return results
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
