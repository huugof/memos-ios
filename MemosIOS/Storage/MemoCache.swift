import Foundation

enum MemoCache {
    private static let key = "cachedMemoSummaries_v1"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func load() -> [ServerMemoSummary] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let memos = try? decoder.decode([ServerMemoSummary].self, from: data)
        else { return [] }
        return memos
    }

    static func save(_ memos: [ServerMemoSummary]) {
        guard let data = try? encoder.encode(memos) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
