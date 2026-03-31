import SwiftUI

struct ChatStatusIndicator: View {
    var sendState: Draft.SendState?
    var isSentAndUnedited: Bool = false

    private var displayState: Draft.SendState? {
        guard let sendState else { return nil }
        if sendState == .sending || sendState == .failed || sendState == .pending {
            return sendState
        }
        return isSentAndUnedited ? .sent : nil
    }

    var body: some View {
        if let icon = iconName {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var iconName: String? {
        switch displayState {
        case nil, .idle: return nil
        case .pending:   return "clock"
        case .sending:   return "arrow.up.circle"
        case .sent:      return "checkmark"
        case .failed:    return "exclamationmark.circle"
        }
    }
}
