import Foundation

enum DraftScope: String, CaseIterable, Identifiable {
    case active = "Active"
    case archive = "Archive"

    var id: String { rawValue }

    func includes(_ draft: Draft) -> Bool {
        switch self {
        case .active:
            return !draft.isArchived
        case .archive:
            return draft.isArchived
        }
    }
}
