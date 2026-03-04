import SwiftUI

struct BottomCaptureNavBar: View {
    struct Item {
        let systemName: String
        let accessibilityLabel: String
        let action: () -> Void
        var isEmphasized: Bool = false
    }

    @Environment(\.colorScheme) private var colorScheme

    let leftItem: Item
    let middleItem: Item
    let rightItem: Item

    var body: some View {
        HStack(spacing: 4) {
            iconButton(item: leftItem)
            iconButton(item: middleItem)
            iconButton(item: rightItem)
        }
        .padding(5)
        .frame(height: totalHeight)
        .background(
            Capsule(style: .continuous)
                .fill(groupFillColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(groupBorderColor, lineWidth: 1)
        )
    }

    private func iconButton(item: Item) -> some View {
        Button(action: item.action) {
            Image(systemName: item.systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(item.isEmphasized ? emphasizedIconColor : iconColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    Capsule(style: .continuous)
                        .fill(item.isEmphasized ? emphasizedFillColor : .clear)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.accessibilityLabel)
    }

    private var totalHeight: CGFloat { 58 }

    private var groupFillColor: Color {
        Color(uiColor: .secondarySystemBackground)
    }

    private var groupBorderColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.08)
        }
        return Color.black.opacity(0.06)
    }

    private var iconColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.86)
        }
        return Color.black.opacity(0.78)
    }

    private var emphasizedFillColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.10)
        }
        return Color.black.opacity(0.06)
    }

    private var emphasizedIconColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.96)
        }
        return Color.black.opacity(0.90)
    }
}
