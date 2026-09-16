import Foundation

/// Where notes go. One destination is active at a time — the app never
/// dual-writes, so there is no reconciliation between the two.
enum DestinationKind: String, CaseIterable, Identifiable {
    case memos
    case vault

    var id: String { rawValue }

    var label: String {
        switch self {
        case .memos: return "Memos Server"
        case .vault: return "Obsidian Vault"
        }
    }
}
