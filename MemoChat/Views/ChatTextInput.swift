import SwiftUI
import UIKit

/// A plain-text, auto-growing UITextView wrapper for the chat input bar.
/// Grows from 1 line up to `maxLines` lines, then scrolls internally.
struct ChatTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String = "Message"
    var maxLines: Int = 4
    var onSubmit: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.showsVerticalScrollIndicator = false
        tv.autocorrectionType = .yes
        tv.autocapitalizationType = .sentences
        tv.returnKeyType = .default
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text {
            tv.text = text
        }
        context.coordinator.updatePlaceholder(in: tv, text: text, placeholder: placeholder)
        DispatchQueue.main.async {
            self.recalculateHeight(for: tv)
        }
    }

    private func recalculateHeight(for tv: UITextView) {
        let lineHeight = tv.font?.lineHeight ?? 20
        let maxHeight = lineHeight * CGFloat(maxLines) + tv.textContainerInset.top + tv.textContainerInset.bottom
        let fittingSize = tv.sizeThatFits(CGSize(width: tv.frame.width, height: .greatestFiniteMagnitude))
        let newHeight = min(fittingSize.height, maxHeight)
        let shouldScroll = fittingSize.height > maxHeight
        if abs(height - newHeight) > 0.5 { height = newHeight }
        if tv.isScrollEnabled != shouldScroll { tv.isScrollEnabled = shouldScroll }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatTextInput
        private var placeholderLabel: UILabel?

        init(_ parent: ChatTextInput) {
            self.parent = parent
        }

        func updatePlaceholder(in tv: UITextView, text: String, placeholder: String) {
            if placeholderLabel == nil {
                let label = UILabel()
                label.font = tv.font
                label.textColor = .placeholderText
                label.numberOfLines = 1
                label.translatesAutoresizingMaskIntoConstraints = false
                tv.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: tv.textContainerInset.left + tv.textContainer.lineFragmentPadding),
                    label.topAnchor.constraint(equalTo: tv.topAnchor, constant: tv.textContainerInset.top)
                ])
                placeholderLabel = label
            }
            placeholderLabel?.text = placeholder
            placeholderLabel?.isHidden = !text.isEmpty
        }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            let lineHeight = tv.font?.lineHeight ?? 20
            let maxHeight = lineHeight * CGFloat(parent.maxLines) + tv.textContainerInset.top + tv.textContainerInset.bottom
            let fittingSize = tv.sizeThatFits(CGSize(width: tv.frame.width, height: .greatestFiniteMagnitude))
            let newHeight = min(fittingSize.height, maxHeight)
            let shouldScroll = fittingSize.height > maxHeight
            if abs(parent.height - newHeight) > 0.5 { parent.height = newHeight }
            if tv.isScrollEnabled != shouldScroll { tv.isScrollEnabled = shouldScroll }
            placeholderLabel?.isHidden = !tv.text.isEmpty
        }
    }
}
