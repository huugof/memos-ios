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
        if let (icon, color) = iconAndColor {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private var iconAndColor: (String, Color)? {
        switch displayState {
        case nil, .idle: return nil
        case .pending:   return ("clock", .orange)
        case .sending:   return ("arrow.up.circle", .blue)
        case .sent:      return ("checkmark", .secondary)
        case .failed:    return ("exclamationmark.circle", .red)
        }
    }
}
