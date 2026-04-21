import SwiftData
import OSLog

private let persistLogger = Logger(subsystem: "com.hugo.MemosIOS", category: "Persistence")

extension ModelContext {
    func saveOrAssert(_ context: StaticString = #function) {
        do {
            try save()
        } catch {
            persistLogger.fault("ModelContext save failed in \(context, privacy: .public): \(error, privacy: .public)")
            assertionFailure("Failed to save model context in \(context): \(error)")
        }
    }
}
