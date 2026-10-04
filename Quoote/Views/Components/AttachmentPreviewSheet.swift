import SwiftUI
import QuickLook

/// One file in QuickLook, as the content of a sheet: a swipe down closes it.
///
/// QuickLook is the sheet's content rather than the thing presented. A `QLPreviewController` presented on its own
/// answers no swipe down — it scrolls a PDF and leaves a picture where it is — but a SwiftUI sheet's own swipe works
/// over it, from the top or the middle, on pictures and PDFs alike. The Close button is for anyone who would rather tap.
struct AttachmentPreviewSheet: UIViewControllerRepresentable {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let coordinator = context.coordinator
        coordinator.close = { dismiss() }

        let preview = QLPreviewController()
        preview.dataSource = coordinator
        preview.delegate = coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak coordinator] _ in coordinator?.close() }
        )
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL
        var close: () -> Void = {}

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }

        /// What is shown is a throwaway copy: markup saved to it would go nowhere.
        func previewController(
            _ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem
        ) -> QLPreviewItemEditingMode {
            .disabled
        }
    }
}
