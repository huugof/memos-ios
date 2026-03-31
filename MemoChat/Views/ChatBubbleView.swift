import SwiftUI
import UIKit

struct ChatBubbleView: View {
    let text: String
    var sendState: Draft.SendState? = nil
    var isSentAndUnedited: Bool = false
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var mutableText: String
    @State private var selectionEnabled = false

    init(text: String, sendState: Draft.SendState? = nil, isSentAndUnedited: Bool = false,
         onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil) {
        self.text = text
        self.sendState = sendState
        self.isSentAndUnedited = isSentAndUnedited
        self.onEdit = onEdit
        self.onDelete = onDelete
        self._mutableText = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            bubbleContent
                .frame(maxWidth: UIScreen.main.bounds.width * 0.78, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)

            ChatStatusIndicator(sendState: sendState, isSentAndUnedited: isSentAndUnedited)
                .padding(.trailing, 4)
        }
        .onChange(of: text) { _, newText in mutableText = newText }
        .contextMenu {
            if let onEdit {
                Button { onEdit() } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }

            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                selectionEnabled = true
            } label: {
                Label("Select", systemImage: "selection.pin.in.out")
            }

            if let onDelete {
                Divider()
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if selectionEnabled {
            BubbleTextView(text: text, selectOnAppear: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemBackground))
                )
        } else {
            RenderedNoteTextView(text: $mutableText, allowsScrolling: false, shrinkToFit: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemBackground))
                )
        }
    }
}

// UITextView wrapper that immediately shows the selection marquee on appear.
private struct BubbleTextView: UIViewRepresentable {
    let text: String
    let selectOnAppear: Bool

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
        uiView.isSelectable = selectOnAppear
        if selectOnAppear && !uiView.isFirstResponder {
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
