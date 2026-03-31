import SwiftUI
import SwiftData

@main
struct MemoChatApp: App {
    private let modelContainer = ChatAppContainer.make()

    var body: some Scene {
        WindowGroup {
            ChatRootView()
        }
        .modelContainer(modelContainer)
    }
}
