import Foundation

/// The one pinned note — the note the compose sheet opens to, instead of a blank one,
/// until it's unpinned. The ID uses UnifiedNote.id's format: "d-<uuid>" for a local
/// draft, "m-<memoID>" for a server memo, "v-<relative path>" for a vault file.
final class PinnedNotesStore: ObservableObject {
    @Published private(set) var pinnedID: String?

    private let defaults: UserDefaults
    private let key = "frontNoteID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinnedID = defaults.string(forKey: key)
    }

    func isPinned(_ noteID: String) -> Bool {
        pinnedID == noteID
    }

    func pin(_ noteID: String) {
        guard pinnedID != noteID else { return }
        pinnedID = noteID
        persist()
    }

    func unpin() {
        guard pinnedID != nil else { return }
        pinnedID = nil
        persist()
    }

    func toggle(_ noteID: String) {
        if isPinned(noteID) { unpin() } else { pin(noteID) }
    }

    /// Moves the pin from a local draft to what it became once sent, so the pinned
    /// note survives its own send. A no-op unless that draft is the pinned one.
    func migrate(fromDraft draftID: UUID, to noteID: String) {
        guard pinnedID == Self.id(for: .localDraft(draftID)) else { return }
        pin(noteID)
    }

    /// The editor target for the pinned note.
    var target: NoteEditorTarget? {
        pinnedID.flatMap(Self.target(for:))
    }

    static func id(for target: NoteEditorTarget) -> String? {
        switch target {
        case .newNote: return nil
        case .localDraft(let id): return "d-\(id.uuidString)"
        case .serverMemo(let memoID): return "m-\(memoID)"
        case .vaultFile(let path): return "v-\(path)"
        }
    }

    static func target(for noteID: String) -> NoteEditorTarget? {
        guard noteID.count > 2, noteID.dropFirst().hasPrefix("-") else { return nil }
        let value = String(noteID.dropFirst(2))
        switch noteID.first {
        case "d": return UUID(uuidString: value).map { .localDraft($0) }
        case "m": return .serverMemo(value)
        case "v": return .vaultFile(value)
        default: return nil
        }
    }

    private func persist() {
        if let pinnedID {
            defaults.set(pinnedID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
