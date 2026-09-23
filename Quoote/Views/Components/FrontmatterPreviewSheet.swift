import SwiftUI

/// Read-only view of the frontmatter a save will write, exactly as it will
/// land in the file.
struct FrontmatterPreviewSheet: View {
    let result: Result<String, Error>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Frontmatter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case .success(let text) where text.isEmpty:
            Text("This note will be written with no frontmatter.")
                .foregroundStyle(.secondary)
        case .success(let text):
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        case .failure(let error):
            Text((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                .foregroundStyle(.secondary)
        }
    }
}
