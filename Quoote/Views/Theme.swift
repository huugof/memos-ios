import SwiftUI

let appAccent = Color(red: 1.0, green: 0.78, blue: 0.0)

// MARK: Liquid glass helpers

extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: Circle())
        } else {
            self.background(.regularMaterial, in: Circle())
        }
    }

    /// Use inside system nav bar toolbar items. On iOS 26 the nav bar itself is glass,
    /// so we skip the explicit glassEffect to avoid double-glass nesting.
    @ViewBuilder
    func glassToolbarCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }
}
