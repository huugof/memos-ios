import Foundation
import SwiftData

@Model
final class ServerMemoEditDraft {
    @Attribute(.unique) var memoID: String
    var resourceName: String
    var serverContent: String
    var localContent: String
    var updatedAt: Date
    var saveStateRaw: Int
    var lastError: String?
    var lastSyncedAt: Date?

    init(
        memoID: String,
        resourceName: String,
        serverContent: String,
        localContent: String,
        updatedAt: Date = Date(),
        saveState: SaveState = .idle,
        lastError: String? = nil,
        lastSyncedAt: Date? = nil
    ) {
        self.memoID = memoID
        self.resourceName = resourceName
        self.serverContent = serverContent
        self.localContent = localContent
        self.updatedAt = updatedAt
        self.saveStateRaw = saveState.rawValue
        self.lastError = lastError
        self.lastSyncedAt = lastSyncedAt
    }

    enum SaveState: Int, CaseIterable {
        case idle = 0
        case pending = 1
        case saving = 2

        var label: String {
            switch self {
            case .idle:
                return "Saved"
            case .pending:
                return "Pending"
            case .saving:
                return "Saving"
            }
        }
    }

    var saveState: SaveState {
        get { SaveState(rawValue: saveStateRaw) ?? .idle }
        set { saveStateRaw = newValue.rawValue }
    }

    var hasLocalChanges: Bool {
        localContent != serverContent
    }
}
