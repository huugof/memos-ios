import Foundation
import SwiftData

@Model
final class Draft {
    @Attribute(.unique) var id: UUID
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var lastSentAt: Date?
    var sendStateRaw: Int
    var lastError: String?
    var isArchived: Bool

    init(text: String = "") {
        self.id = UUID()
        self.text = text
        self.createdAt = Date()
        self.updatedAt = Date()
        self.lastSentAt = nil
        self.sendStateRaw = SendState.idle.rawValue
        self.lastError = nil
        self.isArchived = false
    }

    enum SendState: Int, CaseIterable {
        case idle = 0
        case sending = 1
        case sent = 2
        case failed = 3
        case pending = 4

        var label: String {
            switch self {
            case .idle:
                return "Unsent"
            case .pending:
                return "Pending"
            case .sending:
                return "Sending"
            case .sent:
                return "Sent"
            case .failed:
                return "Failed"
            }
        }
    }

    var sendState: SendState {
        get { SendState(rawValue: sendStateRaw) ?? .idle }
        set { sendStateRaw = newValue.rawValue }
    }

    var titleLine: String {
        let first = text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        return first.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
    }

    var isSentAndUnedited: Bool {
        guard let lastSentAt else { return false }
        return updatedAt <= lastSentAt
    }

    var hasStartedText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isBlank: Bool {
        !hasStartedText
    }

    var isTransientBlankUnsent: Bool {
        isBlank && !isArchived && lastSentAt == nil && sendState != .sending && sendState != .pending
    }

    var canSend: Bool {
        hasStartedText && !isSentAndUnedited && sendState != .sending && sendState != .pending
    }

    var displayState: SendState {
        if sendState == .sending || sendState == .failed || sendState == .pending {
            return sendState
        }
        return isSentAndUnedited ? .sent : .idle
    }
}
