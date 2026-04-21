import Foundation

enum MemoCache {
    private static let filename = "memo_cache_v1.json"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(filename)
    }

    static func load() -> [ServerMemoSummary] {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let memos = try? decoder.decode([ServerMemoSummary].self, from: data)
        else { return [] }
        return memos
    }

    static func save(_ memos: [ServerMemoSummary]) {
        guard let url = cacheURL else { return }
        Task.detached(priority: .utility) {
            guard let data = try? encoder.encode(memos) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
