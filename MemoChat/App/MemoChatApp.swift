import SwiftUI
import SwiftData

@main
struct MemoChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let modelContainer = ChatAppContainer.make()

    var body: some Scene {
        WindowGroup {
            ChatRootView()
        }
        .modelContainer(modelContainer)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }
}
