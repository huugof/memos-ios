import SwiftData

enum AppModelContainer {
    static func make() -> ModelContainer {
        let schema = Schema([Draft.self])
        let configuration = ModelConfiguration()

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to initialize model container: \(error)")
        }
    }
}
