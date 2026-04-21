import Combine
import SwiftUI
import UIKit

@MainActor
final class KeyboardStateObserver: ObservableObject {
    @Published private(set) var height: CGFloat = 0
    @Published private(set) var isVisible = false

    private var cancellables: Set<AnyCancellable> = []

    init(notificationCenter: NotificationCenter = .default) {
        notificationCenter.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .merge(with: notificationCenter.publisher(for: UIResponder.keyboardWillHideNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.updateKeyboardState(from: notification)
            }
            .store(in: &cancellables)
    }

    private func updateKeyboardState(from notification: Notification) {
        guard let userInfo = notification.userInfo,
              let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            withAnimation(.easeInOut(duration: 0.35)) {
                height = 0
                isVisible = false
            }
            return
        }

        let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.35

        let endFrame = frameValue.cgRectValue
        let overlap = Self.keyboardOverlapHeight(for: endFrame)

        // Drive SwiftUI changes with the same duration iOS uses for the keyboard
        // slide so the bottom bar tracks the keyboard exactly.
        withAnimation(.easeInOut(duration: duration)) {
            height = overlap
            isVisible = overlap > 0.5
        }
    }

    private static func keyboardOverlapHeight(for endFrame: CGRect) -> CGFloat {
        let screenBounds = UIScreen.main.bounds
        let rawOverlap = max(0, screenBounds.maxY - endFrame.minY)
        let safeAreaBottom = keyWindowSafeAreaBottom()
        return max(0, rawOverlap - safeAreaBottom)
    }

    private static func keyWindowSafeAreaBottom() -> CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)

        return window?.safeAreaInsets.bottom ?? 0
    }
}
