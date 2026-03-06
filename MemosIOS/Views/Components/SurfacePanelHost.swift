import SwiftUI

enum PanelSurface: String {
    case drafts
    case settings
}

struct SheetSurfaceShellView: View {
    @Binding var surface: PanelSurface
    @Binding var selectedDraftMenuTab: DraftMenuTab

    let currentDraftID: UUID?
    let onSelectDraft: (Draft) -> Void
    let onCreateNewDraft: () -> Void
    let onSendDraft: (Draft) -> Void
    let onSelectServerMemo: (ServerMemoSummary) -> Void

    var body: some View {
        surfaceContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeInOut(duration: 0.18), value: surface)
    }

    @ViewBuilder
    private var surfaceContent: some View {
        switch surface {
        case .drafts:
            DraftMenuView(
                tab: $selectedDraftMenuTab,
                currentDraftID: currentDraftID,
                onSelectDraft: { draft in
                    onSelectDraft(draft)
                },
                onCreateNewDraft: onCreateNewDraft,
                onSendDraft: onSendDraft,
                onSelectServerMemo: onSelectServerMemo,
                onOpenSettings: {
                    surface = .settings
                }
            )
        case .settings:
            SettingsView(onBack: {
                surface = .drafts
            })
        }
    }
}
