import SwiftUI

enum RoundCaptureButtonContent {
    case symbol(String)
    case progress
}

struct RoundCaptureButton: View {
    let content: RoundCaptureButtonContent
    let isEnabled: Bool
    let action: () -> Void
    let accessibilityLabel: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .overlay(
                        Circle()
                            .strokeBorder(borderColor, lineWidth: 1)
                    )

                iconContent
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: shadowColor, radius: 10, x: 0, y: 4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var iconContent: some View {
        switch content {
        case .symbol(let systemName):
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(foregroundColor)
        case .progress:
            ProgressView()
                .controlSize(.small)
                .tint(foregroundColor)
        }
    }

    private var diameter: CGFloat { 58 }

    private var backgroundColor: Color {
        Color.blue
    }

    private var borderColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.20)
        }
        return Color.black.opacity(0.10)
    }

    private var foregroundColor: Color {
        Color.white
    }

    private var shadowColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.32)
        }
        return Color.black.opacity(0.18)
    }
}
