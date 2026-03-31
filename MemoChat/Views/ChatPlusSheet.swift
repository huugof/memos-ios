import SwiftUI

struct ChatPlusSheet: View {
    @Binding var isPresented: Bool
    var onTagInsert: () -> Void = {}
    var onSettings: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onSearch: () -> Void = {}
    @State private var showSettings = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add")
                .font(.headline)
                .padding(.top, 4)

            LazyVGrid(columns: columns, spacing: 16) {
                PlusMenuItem(icon: "photo", label: "Image", enabled: false) {}
                PlusMenuItem(icon: "link", label: "Link", enabled: false) {}
                PlusMenuItem(icon: "arrow.clockwise", label: "Refresh", enabled: true) {
                    onRefresh()
                    isPresented = false
                }
                PlusMenuItem(icon: "number", label: "Tag", enabled: true) {
                    onTagInsert()
                    isPresented = false
                }
                PlusMenuItem(icon: "magnifyingglass", label: "Search", enabled: true) {
                    onSearch()
                    isPresented = false
                }
                PlusMenuItem(icon: "gearshape", label: "Settings", enabled: true) {
                    showSettings = true
                }
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .sheet(isPresented: $showSettings) {
            SettingsView(onBack: { showSettings = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: showSettings) { _, showing in
            if !showing { isPresented = false }
        }
    }
}

private struct PlusMenuItem: View {
    let icon: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .frame(width: 52, height: 52)
                    .background(Color(uiColor: .tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
