import Foundation
import SwiftData

enum NoteEditorTarget: Hashable {
    case newNote
    case localDraft(UUID)
    case serverMemo(String) // memoID
    case vaultFile(String)  // relative path inside the vault
}

enum UnifiedNote: Identifiable {
    case local(Draft)
    case server(ServerMemoSummary, editDraft: ServerMemoEditDraft?)
    case vault(VaultIndexEntry)

    var id: String {
        switch self {
        case .local(let draft): return "d-\(draft.id.uuidString)"
        case .server(let memo, _): return "m-\(memo.id)"
        case .vault(let entry): return "v-\(entry.relativePath)"
        }
    }

    var editorTarget: NoteEditorTarget {
        switch self {
        case .local(let draft): return .localDraft(draft.id)
        case .server(let memo, _): return .serverMemo(memo.id)
        case .vault(let entry): return .vaultFile(entry.relativePath)
        }
    }

    var content: String {
        switch self {
        case .local(let draft):
            return draft.text
        case .server(let memo, let editDraft):
            if let ed = editDraft, ed.hasLocalChanges {
                let local = ed.localContent.trimmingCharacters(in: .whitespacesAndNewlines)
                return local.isEmpty ? memo.preferredDisplayText : local
            }
            return memo.preferredDisplayText
        case .vault(let entry):
            // The index holds no body — only a flattened excerpt, which already
            // leads with the title line. Reading the file here would force an
            // iCloud download per row.
            return entry.preview.isEmpty ? entry.title : entry.preview
        }
    }

    var title: String {
        if case .vault(let entry) = self { return entry.title }
        let lines = content.components(separatedBy: "\n")
        let firstNonEmpty = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        var line = firstNonEmpty
        while line.hasPrefix("#") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "New Note" : line
    }

    /// The note flattened for a history row. A vault note's content is already the
    /// index's flattened excerpt.
    ///
    /// A note that is only attachments has no text. An image-only vault note shows its tile alone rather
    /// than the raw `![[x.jpg]]` its title falls back to; a note holding just a file shows the file's name.
    var excerpt: String {
        let text: String
        switch self {
        case .vault(let entry):
            let holdsAttachments = !(entry.attachments ?? []).isEmpty
            text = entry.preview.isEmpty && holdsAttachments ? "" : content
        case .local, .server:
            text = NoteExcerpt.make(from: content)
        }
        guard text.isEmpty,
              let tile = NoteAttachments.tile(from: attachments),
              tile.attachment.kind == .file else { return text }
        return tile.attachment.name
    }

    var date: Date {
        switch self {
        case .local(let draft): return draft.createdAt
        case .server(let memo, _): return memo.updatedAt ?? .distantPast
        case .vault(let entry): return entry.modifiedAt
        }
    }

    var tags: [String] {
        if case .vault(let entry) = self { return entry.tags }
        return TagExtractor.tags(in: content)
    }

    /// What the note holds, for its row's tile: embedded in its text, plus — for a Memos note — what the
    /// server lists on the memo itself (text first, duplicates dropped). A vault row has no body to read, so
    /// it takes the list from its index entry.
    var attachments: [NoteAttachment] {
        switch self {
        case .local(let draft):
            return NoteAttachments.parse(draft.text)
        case .server(let memo, _):
            return NoteAttachments.merged(NoteAttachments.parse(content), memo.attachments ?? [])
        case .vault(let entry):
            return entry.attachments ?? []
        }
    }

    /// The vault-relative path of the note, so `![[picture.png]]` can be found beside it. `nil` unless it is a vault note.
    var vaultPath: String? {
        if case .vault(let entry) = self { return entry.relativePath }
        return nil
    }

    var hasChecklists: Bool {
        content.contains("- [ ]") || content.contains("- [x]") || content.contains("- [X]")
    }

    var sendState: Draft.SendState? {
        if case .local(let draft) = self { return draft.sendState }
        return nil
    }

    var hasLocalEdits: Bool {
        if case .server(_, let editDraft) = self { return editDraft?.hasLocalChanges == true }
        return false
    }

    static func merge(
        drafts: [Draft],
        memos: [ServerMemoSummary],
        editDrafts: [ServerMemoEditDraft],
        hiddenMemoIDs: Set<String> = [],
        excludeDraftID: UUID? = nil
    ) -> [UnifiedNote] {
        let editDraftByMemoID = Dictionary(
            editDrafts.map { ($0.memoID, $0) },
            uniquingKeysWith: { f, _ in f }
        )
        var serverTexts = Set<String>()
        var notes: [UnifiedNote] = []

        for memo in memos where !hiddenMemoIDs.contains(memo.id) {
            let editDraft = editDraftByMemoID[memo.id]
            let displayText: String
            if let ed = editDraft, ed.hasLocalChanges {
                let local = ed.localContent.trimmingCharacters(in: .whitespacesAndNewlines)
                displayText = local.isEmpty
                    ? memo.preferredDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
                    : local
            } else {
                displayText = memo.preferredDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !displayText.isEmpty else { continue }
            notes.append(.server(memo, editDraft: editDraft))
            [memo.preferredDisplayText,
             editDraft?.serverContent,
             editDraft?.localContent,
             editDraft?.previousServerContent]
                .compactMap { $0 }
                .forEach { serverTexts.insert($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        for draft in drafts where !draft.isBlank && !draft.isArchived && draft.id != excludeDraftID {
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serverTexts.contains(text) else { continue }
            notes.append(.local(draft))
        }

        return notes.sorted { $0.date > $1.date }
    }

    /// Vault-mode merge: filed notes come from the index, plus any local draft
    /// that hasn't been written out yet. A draft still `.pending`/`.sending`
    /// on the Memos queue (in flight from before a destination switch) is
    /// excluded too — switching destinations migrates nothing, so it must not
    /// be shown as a vault-sendable draft while it's still owned by the other
    /// destination's queue.
    static func merge(
        vaultEntries: [VaultIndexEntry],
        drafts: [Draft],
        excludeDraftID: UUID? = nil
    ) -> [UnifiedNote] {
        var notes = vaultEntries.map { UnifiedNote.vault($0) }
        for draft in drafts
        where !draft.isBlank
            && !draft.isArchived
            && draft.id != excludeDraftID
            && draft.sendState != .pending
            && draft.sendState != .sending {
            notes.append(.local(draft))
        }
        return notes.sorted { $0.date > $1.date }
    }
}
