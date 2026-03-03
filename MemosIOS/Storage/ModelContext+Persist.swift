import SwiftData

extension ModelContext {
    func saveOrAssert(_ context: StaticString = #function) {
        do {
            try save()
        } catch {
            assertionFailure("Failed to save model context in \(context): \(error)")
        }
    }
}
