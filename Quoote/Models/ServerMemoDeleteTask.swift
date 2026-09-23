import Foundation
import SwiftData

@Model
final class ServerMemoDeleteTask {
    @Attribute(.unique) var memoID: String
    var resourceName: String
    var deleteStateRaw: Int
    var createdAt: Date
    var updatedAt: Date
    var lastError: String?

    init(
        memoID: String,
        resourceName: String,
        deleteState: DeleteState = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.memoID = memoID
        self.resourceName = resourceName
        self.deleteStateRaw = deleteState.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastError = lastError
    }

    enum DeleteState: Int, CaseIterable {
        case pending = 0
        case deleting = 1
        case resolved = 2
    }

    var deleteState: DeleteState {
        get { DeleteState(rawValue: deleteStateRaw) ?? .pending }
        set { deleteStateRaw = newValue.rawValue }
    }
}
