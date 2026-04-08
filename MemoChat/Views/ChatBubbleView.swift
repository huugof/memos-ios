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
    var onCheckboxToggled: ((String) -> Void)? = nil
    var onTagTapped: ((String) -> Void)? = nil
    var suppressLocalEditsBadge: Bool = false

    @State private var mutableText: String
    @State private var showDeleteConfirmation = false
    @State private var showStatusFlags = false

    init(text: String, sendState: Draft.SendState? = nil,
         isSentAndUnedited: Bool = false, hasLocalEdits: Bool = false, isSavePending: Bool = false,
         onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil,
         onSaveToServer: (() -> Void)? = nil,
         onCheckboxToggled: ((String) -> Void)? = nil,
         onTagTapped: ((String) -> Void)? = nil,
         suppressLocalEditsBadge: Bool = false) {
        self.text = text
        self.sendState = sendState
        self.isSentAndUnedited = isSentAndUnedited
        self.hasLocalEdits = hasLocalEdits
        self.isSavePending = isSavePending
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onSaveToServer = onSaveToServer
        self.onCheckboxToggled = onCheckboxToggled
        self.onTagTapped = onTagTapped
        self.suppressLocalEditsBadge = suppressLocalEditsBadge
        let (clean, _) = Self.extractImages(from: text)
        self._mutableText = State(initialValue: clean)
    }

    // Splits a text string into (text without image markdown, [image URLs]).
    static func extractImages(from text: String) -> (cleanText: String, imageURLs: [URL]) {
        var imageURLs: [URL] = []
        var cleanLines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = trimmed.firstMatch(of: /!\[[^\]]*\]\(([^)]+)\)/) {
                let urlStr = String(match.output.1)
                if let url = URL(string: urlStr) {
                    imageURLs.append(url)
                    continue
                }
            }
            cleanLines.append(line)
        }
        let clean = cleanLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, imageURLs)
    }

    private var isLong: Bool {
        text.filter { $0 == "\n" }.count >= 4
    }

    private var isDraft: Bool {
        hasLocalEdits || isSavePending || (sendState == .idle && !isSentAndUnedited)
    }

    private var bubbleTintColor: Color {
        isDraft ? Color(uiColor: .systemGreen) : .clear
    }

    private var isSingleLine: Bool {
        !mutableText.contains("\n")
    }

    private var bubbleCornerRadius: CGFloat {
        isSingleLine ? 999 : 18
    }

    private var hasStatusContent: Bool {
        (showStatusFlags && (hasLocalEdits || isSavePending) && !suppressLocalEditsBadge) ||
        (sendState == .idle && !isSentAndUnedited)
    }

    var body: some View {
        let (cleanText, imageURLs) = Self.extractImages(from: text)
        VStack(alignment: .trailing, spacing: 5) {
            if !cleanText.isEmpty {
                bubbleContent
                    .frame(maxWidth: isLong ? .infinity : UIScreen.main.bounds.width * 0.78, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if !imageURLs.isEmpty {
                ImageStackBubble(urls: imageURLs)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contextMenu {
                        if let onEdit { Button("Edit", action: onEdit) }
                        if onDelete != nil {
                            Button("Delete", role: .destructive) { showDeleteConfirmation = true }
                        }
                    }
            }

            if hasStatusContent {
                HStack(spacing: 6) {
                    Text("• Draft")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .systemGreen))
                    ChatStatusIndicator(sendState: sendState, isSentAndUnedited: isSentAndUnedited)
                }
                .padding(.trailing, 4)
            }
        }
        .task(id: hasLocalEdits || isSavePending) {
            if hasLocalEdits || isSavePending {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { showStatusFlags = true }
            } else {
                showStatusFlags = false
            }
        }
        .alert("Delete this note?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: text) { _, newText in
            let (clean, _) = Self.extractImages(from: newText)
            mutableText = clean
        }
        .onChange(of: mutableText) { _, newText in
            let (cleanText, imageURLs) = Self.extractImages(from: text)
            guard newText != cleanText else { return }
            let imageMarkdown = imageURLs.map { "![](\($0.absoluteString))" }.joined(separator: "\n")
            let fullText = imageMarkdown.isEmpty ? newText : newText + "\n" + imageMarkdown
            onCheckboxToggled?(fullText)
        }
    }

    private var bubbleContent: some View {
        let tc = bubbleTintColor
        let previewText = mutableText
        let cr = bubbleCornerRadius
        return RenderedNoteTextView(text: $mutableText, allowsScrolling: false, shrinkToFit: true,
                                    onTagTapped: onTagTapped ?? { _ in })
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: cr, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: cr, style: .continuous)
                            .fill(tc)
                    )
            )
            .contextMenu {
                if let onEdit {
                    Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                }
                Button { UIPasteboard.general.string = text } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if let onSaveToServer {
                    Button(action: onSaveToServer) {
                        Label("Send to Server", systemImage: "icloud.and.arrow.up")
                    }
                }
                if onDelete != nil {
                    Section {
                        Button(role: .destructive) { showDeleteConfirmation = true } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } preview: {
                let lines = previewText.components(separatedBy: "\n")
                let t = lines.count > 10 ? lines.prefix(10).joined(separator: "\n") + "\n…" : previewText
                RenderedNoteTextView(text: .constant(t), allowsScrolling: false, shrinkToFit: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(width: UIScreen.main.bounds.width * 0.78)
                    .background(
                        RoundedRectangle(cornerRadius: cr, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: cr, style: .continuous)
                                    .fill(tc)
                            )
                    )
            }
    }
}

// MARK: - ImageStackBubble

private struct ImageStackBubble: View {
    let urls: [URL]

    private let cardWidth = UIScreen.main.bounds.width * 0.65
    private let cardHeight: CGFloat = 200

    @State private var showCarousel = false

    var body: some View {
        AuthenticatedImageBubble(url: urls[0], width: cardWidth, height: cardHeight)
            .overlay(alignment: .bottomTrailing) {
                if urls.count > 1 {
                    Text("1/\(urls.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.5))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(6)
                }
            }
            .onTapGesture { showCarousel = true }
            .fullScreenCover(isPresented: $showCarousel) {
                PhotoCarouselView(urls: urls, isPresented: $showCarousel)
            }
    }
}

// MARK: - PhotoCarouselView

private struct PhotoCarouselView: View {
    let urls: [URL]
    @Binding var isPresented: Bool

    @State private var selectedIndex: Int = 0
    @State private var isZoomed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedIndex) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                    ZoomablePhoto(url: url, isZoomed: $isZoomed)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: selectedIndex) { _, _ in isZoomed = false }

            VStack {
                HStack {
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(16)
                    }
                }
                Spacer()
                if urls.count > 1 {
                    Text("\(selectedIndex + 1) / \(urls.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.bottom, 30)
                }
            }
        }
    }
}

// MARK: - ZoomablePhoto

/// UIScrollView-backed photo view. isScrollEnabled is false at zoom 1 so that
/// the parent TabView's horizontal paging receives swipes unobstructed.
private struct ZoomablePhoto: UIViewRepresentable {
    let url: URL
    @Binding var isZoomed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PhotoScrollView {
        let sv = PhotoScrollView()
        sv.delegate = context.coordinator
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 5
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.backgroundColor = .clear
        sv.isScrollEnabled = false

        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.backgroundColor = .clear
        sv.addSubview(iv)
        sv.imageView = iv
        context.coordinator.imageView = iv

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(doubleTap)

        Task { await context.coordinator.loadImage() }
        return sv
    }

    func updateUIView(_ sv: PhotoScrollView, context: Context) {
        context.coordinator.parent = self
        if !isZoomed && sv.zoomScale > 1.01 {
            sv.setZoomScale(1, animated: false)
            sv.isScrollEnabled = false
        }
    }

    final class PhotoScrollView: UIScrollView {
        weak var imageView: UIImageView?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let iv = imageView, zoomScale == 1, bounds.width > 0 else { return }
            iv.frame = bounds
            contentSize = bounds.size
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomablePhoto
        weak var imageView: UIImageView?

        init(_ parent: ZoomablePhoto) { self.parent = parent }

        func viewForZooming(in sv: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ sv: UIScrollView) {
            guard let iv = imageView else { return }
            let offsetX = max((sv.bounds.width - iv.frame.width) / 2, 0)
            let offsetY = max((sv.bounds.height - iv.frame.height) / 2, 0)
            iv.frame.origin = CGPoint(x: offsetX, y: offsetY)
            let zoomed = sv.zoomScale > 1.01
            sv.isScrollEnabled = zoomed
            parent.isZoomed = zoomed
        }

        func scrollViewDidEndZooming(_ sv: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            sv.isScrollEnabled = scale > 1.01
            parent.isZoomed = scale > 1.01
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let sv = gesture.view as? UIScrollView else { return }
            if sv.zoomScale > 1 {
                sv.setZoomScale(1, animated: true)
            } else {
                let pt = gesture.location(in: imageView)
                let w = sv.bounds.width / 2.5
                let h = sv.bounds.height / 2.5
                sv.zoom(to: CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h),
                        animated: true)
            }
        }

        func loadImage() async {
            guard let image = await loadAuthenticatedImage(from: parent.url) else { return }
            await MainActor.run { imageView?.image = image }
        }
    }
}

// MARK: - AuthenticatedImageBubble

private struct AuthenticatedImageBubble: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat

    @State private var loadedImage: UIImage?
    @State private var isLoading = false

    private let cornerRadius: CGFloat = 16

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemBackground))
                    .frame(width: width, height: height * 0.6)
                    .overlay { if isLoading { ProgressView() } }
            }
        }
        .task(id: url) { await loadImage() }
    }

    private func loadImage() async {
        guard loadedImage == nil else { return }
        isLoading = true
        defer { isLoading = false }
        guard let image = await loadAuthenticatedImage(from: url) else { return }
        let displaySize = CGSize(width: width * 2, height: height * 2)
        loadedImage = image.preparingThumbnail(of: displaySize) ?? image
    }
}

// MARK: - Shared image loader

private func loadAuthenticatedImage(from url: URL) async -> UIImage? {
    var request = URLRequest(url: url)
    let token = KeychainTokenStore.getToken()
    if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          let image = UIImage(data: data) else { return nil }
    return image
}
