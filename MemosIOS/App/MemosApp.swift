import SwiftUI
import SwiftData

@main
struct MemosApp: App {
    private let modelContainer = AppModelContainer.make()

    var body: some Scene {
        WindowGroup {
            EditorRootView()
        }
        .modelContainer(modelContainer)
    }
}
