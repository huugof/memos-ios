import Foundation
import SwiftData

enum ChatAppContainer {
    static func make() -> ModelContainer {
        let schema = Schema([Draft.self, ServerMemoEditDraft.self, ServerMemoDeleteTask.self])
        let configuration = ModelConfiguration()
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Persistent store failed (corrupted data, failed migration, full disk).
            // Fall back to an in-memory container so the app stays functional.
            // Local drafts will not persist until the underlying issue is resolved.
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            if let container = try? ModelContainer(for: schema, configurations: [fallback]) {
                return container
            }
            fatalError("Could not create MemoChat model container: \(error)")
        }
    }
}
