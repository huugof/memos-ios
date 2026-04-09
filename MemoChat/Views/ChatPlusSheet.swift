import SwiftUI

struct ChatPlusSheet: View {
    @Binding var isPresented: Bool
    @Binding var showTodosOnly: Bool
    @Binding var showDraftsOnly: Bool
    @Binding var showAttachmentsOnly: Bool
    @Binding var showDrafts: Bool
    var onSearch: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onPhotoPicker: () -> Void = {}
    var onFilePicker: () -> Void = {}
    var onSendAll: () -> Void = {}

    @State private var showSettings = false
    @State private var quickCaptureMode = AppSettings.quickCaptureMode
    @State private var newNoteDelay = AppSettings.newNoteDelay

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: title + refresh button
            HStack {
                Text("Quick Actions")
                    .font(.headline)
                    .padding(.leading, 20)
                Spacer()
                Button {
                    onRefresh()
                    isPresented = false
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
            .padding(.top, 64)

            // Action buttons row
            HStack(spacing: 0) {
                LargeIconButton(icon: "photo", label: "Photos", enabled: true) {
                    onPhotoPicker()
                    isPresented = false
                }
                LargeIconButton(icon: "doc", label: "Files", enabled: true) {
                    onFilePicker()
                    isPresented = false
                }
                LargeIconButton(icon: "magnifyingglass", label: "Search", enabled: true) {
                    onSearch()
                    isPresented = false
                }
                LargeIconButton(icon: "tray.and.arrow.up", label: "Send All", enabled: true) {
                    onSendAll()
                    isPresented = false
                }
                Spacer()
            }
            .padding(.top, 16)
            .padding(.horizontal, 8)

            // Filters — single pill row
            VStack(alignment: .leading, spacing: 0) {
                Text("Filters")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterPill(label: "Todos", icon: "checkmark.square", active: showTodosOnly) {
                            showTodosOnly.toggle()
                            if showTodosOnly { showDraftsOnly = false; showAttachmentsOnly = false }
                            isPresented = false
                        }
                        FilterPill(label: "Drafts", icon: "tray.full", active: showDraftsOnly) {
                            showDraftsOnly.toggle()
                            if showDraftsOnly { showTodosOnly = false; showAttachmentsOnly = false }
                            isPresented = false
                        }
                        FilterPill(label: "Attachments", icon: "paperclip", active: showAttachmentsOnly) {
                            showAttachmentsOnly.toggle()
                            if showAttachmentsOnly { showTodosOnly = false; showDraftsOnly = false }
                            isPresented = false
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }


            Divider().padding(.vertical, 12)

            Toggle(isOn: $showDrafts) {
                MenuRow(icon: "tray", label: "Show Drafts in Feed")
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
                showSettings = true
            } label: {
                MenuRow(icon: "gearshape", label: "API Settings")
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

private struct FilterPill: View {
    let label: String
    let icon: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(active ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(active ? Color.blue : Color(uiColor: .tertiarySystemBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
