import Foundation

enum VaultAccessError: LocalizedError, Equatable {
    case notConfigured
    case stale

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No vault folder has been selected yet."
        case .stale:
            return "Quoote can't access the vault folder anymore. Reconnect it in Settings."
        }
    }
}

/// Persists the user's vault folder as a security-scoped bookmark.
///
/// Bookmarks go stale after a restore-from-backup or when the folder moves, so
/// `.stale` is an expected condition the UI surfaces as "Reconnect vault" —
/// never a silent failure.
enum VaultBookmarkStore {

    static func save(url: URL) throws {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        AppSettings.vaultBookmark = data
    }

    static func resolve() throws -> URL {
        guard let data = AppSettings.vaultBookmark else {
            throw VaultAccessError.notConfigured
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            throw VaultAccessError.stale
        }

        if isStale {
            // Refresh opportunistically; if the folder is still reachable the
            // user never learns anything went wrong.
            if (try? save(url: url)) == nil {
                throw VaultAccessError.stale
            }
        }
        return url
    }

    static func clear() {
        AppSettings.vaultBookmark = nil
    }

    /// Resolves the vault and runs `body` inside a balanced security scope.
    static func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try resolve()
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
}
