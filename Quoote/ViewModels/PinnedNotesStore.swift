import Foundation

/// Tracks which notes are pinned across app sessions.
/// Note IDs use the same format as UnifiedNote.id: "d-<uuid>" for local drafts, "m-<memoID>" for server memos.
final class PinnedNotesStore: ObservableObject {
    @Published private(set) var pinnedIDs: Set<String>

    private let key = "pinnedNoteIDs"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        pinnedIDs = Set(saved)
    }

    func isPinned(_ noteID: String) -> Bool {
        pinnedIDs.contains(noteID)
    }

    func pin(_ noteID: String) {
        guard !pinnedIDs.contains(noteID) else { return }
        pinnedIDs.insert(noteID)
        persist()
    }

    func unpin(_ noteID: String) {
        guard pinnedIDs.contains(noteID) else { return }
        pinnedIDs.remove(noteID)
        persist()
    }

    func toggle(_ noteID: String) {
        if isPinned(noteID) { unpin(noteID) } else { pin(noteID) }
    }

    private func persist() {
        UserDefaults.standard.set(Array(pinnedIDs), forKey: key)
    }
}
