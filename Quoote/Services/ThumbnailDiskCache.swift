import CryptoKit
import Foundation

/// A size-capped folder of small JPEGs, one per remote image, named by the SHA-256 of the URL it came from.
///
/// It lives in Caches, so iOS may clear it whenever storage runs low — everything in it can be fetched again.
/// A hit short-circuits the network, which is what keeps thumbnails showing offline.
final class ThumbnailDiskCache: @unchecked Sendable {

    let directory: URL
    private let maxBytes: Int
    private let trimEvery: Int
    private let lock = NSLock()
    private var writesSinceTrim = 0

    init(directory: URL, maxBytes: Int = 50 * 1024 * 1024, trimEvery: Int = 20) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.trimEvery = max(1, trimEvery)
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AttachmentThumbnails", isDirectory: true)
    }

    static func fileName(forKey key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(Self.fileName(forKey: key)))
    }

    func store(_ data: Data, forKey key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName(forKey: key))
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }

        lock.lock()
        writesSinceTrim += 1
        let due = writesSinceTrim >= trimEvery
        if due { writesSinceTrim = 0 }
        lock.unlock()
        if due { trim() }
    }

    /// Deletes the oldest files until what is left fits under the cap.
    func trim() {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        var files: [(url: URL, date: Date, size: Int)] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }

        files.sort { $0.date < $1.date }
        for file in files where total > maxBytes {
            if (try? manager.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }
}
