import Foundation
import SwiftData

enum NoteEditorTarget: Hashable {
    case newNote
    case localDraft(UUID)
    case serverMemo(String) // memoID
}

enum UnifiedNote: Identifiable {
    case local(Draft)
    case server(ServerMemoSummary, editDraft: ServerMemoEditDraft?)

    var id: String {
        switch self {
        case .local(let draft): return "d-\(draft.id.uuidString)"
        case .server(let memo, _): return "m-\(memo.id)"
        }
    }

    var editorTarget: NoteEditorTarget {
        switch self {
        case .local(let draft): return .localDraft(draft.id)
        case .server(let memo, _): return .serverMemo(memo.id)
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
        }
    }

    var title: String {
        let lines = content.components(separatedBy: "\n")
        let firstNonEmpty = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        var line = firstNonEmpty
        while line.hasPrefix("#") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "New Note" : line
    }

    var preview: String {
        let lines = content.components(separatedBy: "\n")
        var pastTitle = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !pastTitle {
                if !trimmed.isEmpty { pastTitle = true }
                continue
            }
            if !trimmed.isEmpty { return trimmed }
        }
        return "No additional text"
    }

    var date: Date {
        switch self {
        case .local(let draft): return draft.createdAt
        case .server(let memo, _): return memo.updatedAt ?? .distantPast
        }
    }

    var tags: [String] {
        TagExtractor.tags(in: content)
    }

    var hasAttachments: Bool {
        switch self {
        case .local(let draft): return draft.text.contains("![")
        case .server(let memo, _): return memo.hasAttachments || memo.content.contains("![")
        }
    }

    var hasImages: Bool {
        content.contains("![")
    }

    var hasFiles: Bool {
        switch self {
        case .local: return false
        case .server(let memo, _): return memo.attachmentCount > 0
        }
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
}
