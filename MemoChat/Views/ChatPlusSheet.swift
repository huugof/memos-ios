import SwiftUI

struct ChatPlusSheet: View {
    @Binding var isPresented: Bool
    @Binding var showTodosOnly: Bool
    @Binding var showDraftsOnly: Bool
    @Binding var showDrafts: Bool
    var onSearch: () -> Void = {}
    var onTagSearch: (String) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    var tags: [String] = []

    @State private var showSettings = false
    @State private var quickCaptureMode = AppSettings.quickCaptureMode
    @State private var newNoteDelay = AppSettings.newNoteDelay

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                LargeIconButton(icon: "checkmark.square", label: "Todos", enabled: true, active: showTodosOnly) {
                    showTodosOnly.toggle()
                    if showTodosOnly { showDraftsOnly = false }
                    isPresented = false
                }
                LargeIconButton(icon: "tray.full", label: "Drafts", enabled: true, active: showDraftsOnly) {
                    showDraftsOnly.toggle()
                    if showDraftsOnly { showTodosOnly = false }
                    isPresented = false
                }
                LargeIconButton(icon: "magnifyingglass", label: "Search", enabled: true) {
                    onSearch()
                    isPresented = false
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 8)

            if !tags.isEmpty {
                Divider().padding(.vertical, 12)
                TwoLineFlow(spacing: 8, alignment: .center) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            onTagSearch(tag)
                            isPresented = false
                        } label: {
                            Text("#\(tag)")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(uiColor: .tertiarySystemBackground))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }

            Divider().padding(.vertical, 12)

            Toggle(isOn: $showDrafts) {
                MenuRow(icon: "tray", label: "Show Drafts")
            }
            .tint(.blue)
            .padding(.horizontal, 20)

            Toggle(isOn: $quickCaptureMode) {
                MenuRow(icon: "bolt", label: "Quick Capture")
            }
            .tint(.blue)
            .padding(.horizontal, 20)
            .onChange(of: quickCaptureMode) { _, value in
                AppSettings.quickCaptureMode = value
            }

            DelayStepperRow(delay: $newNoteDelay, enabled: quickCaptureMode)
                .padding(.horizontal, 20)
                .onChange(of: newNoteDelay) { _, value in
                    AppSettings.newNoteDelay = value
                }

            Divider().padding(.vertical, 12)

            Button {
                onRefresh()
                isPresented = false
            } label: {
                MenuRow(icon: "arrow.clockwise", label: "Pull from Server")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)

            Button {
                showSettings = true
            } label: {
                MenuRow(icon: "gearshape", label: "API")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)

            Spacer()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onBack: { showSettings = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct TwoLineFlow: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    struct Cache {
        var rows: [[Int]]
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache(rows: [], sizes: []) }

    private func buildRows(subviews: Subviews, width: CGFloat) -> Cache {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rows: [[Int]] = []
        var currentRow: [Int] = []
        var rowWidth: CGFloat = 0

        for (i, size) in sizes.enumerated() {
            if rows.count >= 2 { break }
            let needed = currentRow.isEmpty ? size.width : rowWidth + spacing + size.width
            if needed > width && !currentRow.isEmpty {
                rows.append(currentRow)
                if rows.count >= 2 { break }
                currentRow = [i]
                rowWidth = size.width
            } else {
                currentRow.append(i)
                rowWidth = needed
            }
        }
        if !currentRow.isEmpty && rows.count < 2 { rows.append(currentRow) }
        return Cache(rows: rows, sizes: sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        cache = buildRows(subviews: subviews, width: proposal.width ?? 0)
        var height: CGFloat = 0
        for (i, row) in cache.rows.enumerated() {
            height += row.map { cache.sizes[$0].height }.max() ?? 0
            if i < cache.rows.count - 1 { height += spacing }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let visible = Set(cache.rows.flatMap { $0 })
        var y = bounds.minY
        for (i, row) in cache.rows.enumerated() {
            let rowW = row.map { cache.sizes[$0].width }.reduce(0, +) + CGFloat(max(0, row.count - 1)) * spacing
            let startX: CGFloat
            switch alignment {
            case .center:  startX = bounds.minX + (bounds.width - rowW) / 2
            case .trailing: startX = bounds.maxX - rowW
            default:       startX = bounds.minX
            }
            var x = startX
            let rowH = row.map { cache.sizes[$0].height }.max() ?? 0
            for idx in row {
                subviews[idx].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(cache.sizes[idx]))
                x += cache.sizes[idx].width + spacing
            }
            y += rowH + (i < cache.rows.count - 1 ? spacing : 0)
        }
        for i in subviews.indices where !visible.contains(i) {
            subviews[i].place(at: .zero, proposal: .zero)
        }
    }
}

private struct DelayStepperRow: View {
    @Binding var delay: AppSettings.NewNoteDelay
    var enabled: Bool = true

    private let cases = AppSettings.NewNoteDelay.allCases

    private var currentIndex: Int {
        cases.firstIndex(of: delay) ?? 0
    }

    var body: some View {
        HStack {
            Text("New Draft After")
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.leading, 42)
            Spacer()
            Text(delay.label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
            HStack(spacing: 0) {
                Button {
                    let i = currentIndex
                    if i > 0 { delay = cases[i - 1] }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(currentIndex == 0)

                Divider()
                    .frame(height: 16)

                Button {
                    let i = currentIndex
                    if i < cases.count - 1 { delay = cases[i + 1] }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(currentIndex == cases.count - 1)
            }
            .background(Color(uiColor: .tertiarySystemBackground))
            .clipShape(Capsule())
        }
        .frame(minHeight: 44)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

private struct LargeIconButton: View {
    let icon: String
    let label: String
    let enabled: Bool
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(active ? .blue : .primary)
                    .frame(width: 60, height: 60)
                    .background(Color(uiColor: .tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(active ? .blue : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct MenuRow: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 28)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44)
    }
}
