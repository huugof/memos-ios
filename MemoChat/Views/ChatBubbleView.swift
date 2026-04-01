import SwiftUI
import UIKit

struct ChatBubbleView: View {
    let text: String
    var sendState: Draft.SendState? = nil
    var isSentAndUnedited: Bool = false
    var hasLocalEdits: Bool = false
    var isSavePending: Bool = false
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onSaveToServer: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    var onCheckboxToggled: ((String) -> Void)? = nil
    var onTagTapped: ((String) -> Void)? = nil

    @State private var mutableText: String
    @State private var selectionEnabled = false

    init(text: String, sendState: Draft.SendState? = nil, isSentAndUnedited: Bool = false,
         hasLocalEdits: Bool = false, isSavePending: Bool = false,
         onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil,
         onSaveToServer: (() -> Void)? = nil, onDoubleTap: (() -> Void)? = nil,
         onCheckboxToggled: ((String) -> Void)? = nil,
         onTagTapped: ((String) -> Void)? = nil) {
        self.text = text
        self.sendState = sendState
        self.isSentAndUnedited = isSentAndUnedited
        self.hasLocalEdits = hasLocalEdits
        self.isSavePending = isSavePending
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onSaveToServer = onSaveToServer
        self.onDoubleTap = onDoubleTap
        self.onCheckboxToggled = onCheckboxToggled
        self.onTagTapped = onTagTapped
        self._mutableText = State(initialValue: text)
    }

    private var isLong: Bool {
        text.filter { $0 == "\n" }.count >= 4
    }

    private var hasStatusContent: Bool {
        hasLocalEdits || isSavePending || sendState != nil
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            BubbleMenuHost(
                text: text,
                mutableText: $mutableText,
                selectionEnabled: $selectionEnabled,
                onEdit: onEdit,
                onDelete: onDelete,
                onSaveToServer: onSaveToServer,
                onDoubleTap: onDoubleTap,
                onTagTapped: onTagTapped
            )
            .frame(maxWidth: isLong ? .infinity : UIScreen.main.bounds.width * 0.78, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)

            if hasStatusContent {
                HStack(spacing: 6) {
                    if hasLocalEdits {
                        Text("• Local Edits")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    if isSavePending {
                        Text("• Pending")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    ChatStatusIndicator(sendState: sendState, isSentAndUnedited: isSentAndUnedited)
                }
                .padding(.trailing, 4)
            }
        }
        .onChange(of: text) { _, newText in mutableText = newText }
        .onChange(of: mutableText) { _, newText in
            guard newText != text else { return }
            onCheckboxToggled?(newText)
        }
    }
}

// MARK: - BubbleMenuHost

private struct BubbleMenuHost: UIViewRepresentable {
    let text: String
    @Binding var mutableText: String
    @Binding var selectionEnabled: Bool
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSaveToServer: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onTagTapped: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> BubbleContainerView {
        let container = BubbleContainerView()
        container.setup(rootView: makeRootView())
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        container.addInteraction(interaction)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        container.addGestureRecognizer(doubleTap)
        context.coordinator.container = container
        return container
    }

    func updateUIView(_ uiView: BubbleContainerView, context: Context) {
        context.coordinator.parent = self
        uiView.update(rootView: makeRootView())
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BubbleContainerView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
        return uiView.hostingController?.sizeThatFits(
            in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
        )
    }

    private func makeRootView() -> AnyView {
        AnyView(bubbleBody)
    }

    @ViewBuilder private var bubbleBody: some View {
        Group {
            if selectionEnabled {
                BubbleSelectableText(text: text)
            } else {
                RenderedNoteTextView(text: $mutableText, allowsScrolling: false, shrinkToFit: true,
                                     onTagTapped: onTagTapped ?? { _ in })
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemBackground))
        )
    }

    // Renders a static (non-binding) version of the bubble for the floating preview popup.
    func makeFloatingPreview() -> AnyView {
        let t = text
        return AnyView(
            RenderedNoteTextView(text: .constant(t), allowsScrolling: false, shrinkToFit: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemBackground))
                )
        )
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var parent: BubbleMenuHost
        weak var container: BubbleContainerView?

        init(_ parent: BubbleMenuHost) { self.parent = parent }

        @objc func handleDoubleTap() {
            parent.onDoubleTap?()
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: { [weak self] in
                    guard let self else { return nil }
                    let previewView = self.parent.makeFloatingPreview()
                    let hc = UIHostingController(rootView: previewView)
                    hc.view.backgroundColor = .clear
                    // Measure the full content size so iOS scales (not clips) when it's too tall.
                    let maxWidth = UIScreen.main.bounds.width * 0.78
                    let fullSize = hc.sizeThatFits(
                        in: CGSize(width: maxWidth, height: UIView.layoutFittingExpandedSize.height)
                    )
                    hc.preferredContentSize = fullSize
                    return hc
                }
            ) { [weak self] _ in
                self?.buildMenu()
            }
        }

        // Highlight: lift the original in-place bubble with the rounded clip.
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            makeTargetedPreview(for: interaction)
        }

        // Dismiss: snap back to the original in-place bubble.
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            makeTargetedPreview(for: interaction)
        }

        private func makeTargetedPreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let view = interaction.view else { return nil }
            let params = UIPreviewParameters()
            params.backgroundColor = .clear
            params.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 18)
            return UITargetedPreview(view: view, parameters: params)
        }

        private func buildMenu() -> UIMenu {
            var items: [UIMenuElement] = []

            if let onEdit = parent.onEdit {
                items.append(UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
                    onEdit()
                })
            }

            items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = self?.parent.text
            })

            items.append(UIAction(title: "Select", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
                self?.parent.selectionEnabled = true
            })

            if let onSaveToServer = parent.onSaveToServer {
                items.append(UIAction(
                    title: "Send to Server",
                    image: UIImage(systemName: "cloud.and.arrow.up")
                ) { _ in onSaveToServer() })
            }

            if let onDelete = parent.onDelete {
                let del = UIAction(
                    title: "Delete",
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in onDelete() }
                items.append(UIMenu(title: "", options: .displayInline, children: [del]))
            }

            return UIMenu(title: "", children: items)
        }
    }
}

// MARK: - BubbleContainerView

final class BubbleContainerView: UIView {
    private(set) var hostingController: UIHostingController<AnyView>?

    func setup(rootView: AnyView) {
        let hc = UIHostingController(rootView: rootView)
        hc.view.backgroundColor = .clear
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hc.view)
        NSLayoutConstraint.activate([
            hc.view.topAnchor.constraint(equalTo: topAnchor),
            hc.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hc.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hostingController = hc
    }

    func update(rootView: AnyView) {
        hostingController?.rootView = rootView
    }
}

// MARK: - BubbleSelectableText (selection mode)

/// UITextView wrapper that immediately shows the native text selection marquee.
private struct BubbleSelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        uiView.isSelectable = true
        if !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
                uiView.selectAll(nil)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let maxWidth = proposal.width, maxWidth > 0 else { return nil }
        let rect = (uiView.attributedText ?? NSAttributedString(string: text))
            .boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}
