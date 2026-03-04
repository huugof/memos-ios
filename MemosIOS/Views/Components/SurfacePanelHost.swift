import SwiftUI

enum PanelSurface: String {
    case drafts
    case settings
}

struct SheetSurfaceShellView: View {
    @Binding var surface: PanelSurface

    let currentDraftID: UUID?
    let onSelectDraft: (Draft) -> Void
    let onCreateNewDraft: () -> Void

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
                currentDraftID: currentDraftID,
                onSelectDraft: { draft in
                    onSelectDraft(draft)
                },
                onCreateNewDraft: onCreateNewDraft,
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
