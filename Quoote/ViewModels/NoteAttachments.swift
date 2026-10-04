import Foundation

/// A picture or file attached to a note: found in the note's text, in its vault index entry, or on its memo.
struct NoteAttachment: Codable, Hashable {
    enum Kind: String, Codable {
        case image
        case file
    }

    /// Where the bytes live, as written: a vault name or path (`photo 1.jpg`, `attachments/a.png`), an absolute
    /// http(s) URL, or a Memos-relative path (`/file/attachments/{uid}/{filename}`, `/o/r/{id}/{filename}`).
    let target: String
    /// What a file tile and VoiceOver call it.
    let name: String
    let kind: Kind

    /// Two attachments with the same identity are one attachment: the URL path for a URL or Memos-relative target
    /// (so a link in a memo's text and the same file in the server's list collapse), the target otherwise.
    var identity: String { NoteAttachments.identity(of: target) }

    /// True when the bytes come from a URL or a Memos-relative path, false when they are in the vault.
    var isRemote: Bool { NoteAttachments.isRemote(target) }
}

/// What a history row shows for a note's attachments: one tile, and how many more the note holds.
struct NoteAttachmentTile: Equatable {
    let attachment: NoteAttachment
    let extra: Int
}

/// Finds a note's attachments. Pure: no I/O, so it is safe to call from a view body or the index scan.
enum NoteAttachments {

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "avif"
    ]

    // MARK: Text

    /// Every attachment embedded in `text`, in document order, duplicates collapsed to the first.
    ///
    /// Three syntaxes: `![[wikilink]]` embeds, `![alt](target)` images, and `[name](url)` links to Memos files.
    static func parse(_ text: String) -> [NoteAttachment] {
        guard text.contains("[") else { return [] }
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        // A match is blanked once claimed, so a link wrapped around an image (`[![](a.jpg)](b)`) isn't read twice.
        let masked = NSMutableString(string: text)
        var found: [(location: Int, attachment: NoteAttachment)] = []

        for match in wikilinkRegex.matches(in: text, range: whole) {
            blank(match.range, in: masked)
            if let attachment = wikilinkAttachment(source.substring(with: match.range(at: 1))) {
                found.append((match.range.location, attachment))
            }
        }
        for match in imageRegex.matches(in: text, range: whole) {
            blank(match.range, in: masked)
            if let attachment = imageAttachment(destination: source.substring(with: match.range(at: 1))) {
                found.append((match.range.location, attachment))
            }
        }
        let rest = masked as String
        let restSource = rest as NSString
        for match in linkRegex.matches(in: rest, range: whole) {
            let label = restSource.substring(with: match.range(at: 1))
            let destination = restSource.substring(with: match.range(at: 2))
            if let attachment = linkAttachment(label: label, destination: destination) {
                found.append((match.range.location, attachment))
            }
        }
        return merged(found.sorted { $0.location < $1.location }.map(\.attachment), [])
    }

    /// `first` then `second`, with later duplicates (by identity) dropped.
    static func merged(_ first: [NoteAttachment], _ second: [NoteAttachment]) -> [NoteAttachment] {
        var seen = Set<String>()
        return (first + second).filter { seen.insert($0.identity).inserted }
    }

    /// The tile for a history row: the first picture, else the first file, plus how many more there are.
    static func tile(from attachments: [NoteAttachment]) -> NoteAttachmentTile? {
        guard let first = attachments.first else { return nil }
        let shown = attachments.first(where: { $0.kind == .image }) ?? first
        return NoteAttachmentTile(attachment: shown, extra: attachments.count - 1)
    }

    /// `text` without its `[name](url)` links to Memos files — what a history excerpt shows.
    static func removingMemosFileLinks(from text: String) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in linkRegex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed()
        where isMemosFileDestination(source.substring(with: match.range(at: 2))) {
            result.deleteCharacters(in: match.range)
        }
        return result as String
    }

    // MARK: What can be shown

    /// `attachments` without those Quoote can neither show nor open: a picture or video linked from another site —
    /// a web clipping's images, a YouTube embed. Quoote asks no other site for anything, so such a link would be a
    /// tile that never fills in and can't be tapped. It stays in the text where it is; it just isn't an attachment.
    /// Files in the vault and on a Memos server are.
    static func shown(_ attachments: [NoteAttachment]) -> [NoteAttachment] {
        attachments.filter(isShown)
    }

    /// A vault file, a Memos-relative path, or an absolute URL whose path is a Memos file's — wherever the server
    /// is installed (`/file/attachments/…`, `/file/resources/…`, `/o/r/…`).
    static func isShown(_ attachment: NoteAttachment) -> Bool {
        guard attachment.isRemote, !isMemosRelative(attachment.target) else { return true }
        guard let path = urlPath(of: attachment.target) else { return false }
        return path.contains("/file/attachments/") || path.contains("/file/resources/") || path.contains("/o/r/")
    }

    // MARK: Server list

    /// The attachments a Memos server lists on a memo: `attachments`, or `resources` / `resourceList` on older
    /// servers. `nil` when the response carries no list at all, so a caller keeps what it already knew; `[]` when
    /// it carries a list with nothing usable in it.
    static func fromServerList(memo: [String: Any], fallback: [String: Any]) -> [NoteAttachment]? {
        let sources: [[String: Any]?] = [
            memo, memo["payload"] as? [String: Any], fallback, fallback["payload"] as? [String: Any]
        ]
        var sawList = false
        for key in ["attachments", "resources", "resourceList"] {
            for source in sources {
                guard let list = source?[key] as? [[String: Any]] else { continue }
                sawList = true
                let parsed = list.compactMap(serverAttachment)
                if !parsed.isEmpty { return merged(parsed, []) }
            }
        }
        return sawList ? [] : nil
    }

    private static func serverAttachment(_ element: [String: Any]) -> NoteAttachment? {
        guard let filename = (element["filename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filename.isEmpty else { return nil }
        let target: String
        if let name = (element["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            target = "/file/\(name)/\(filename)"
        } else if let id = (element["id"] as? Int) ?? (element["id"] as? String).flatMap({ Int($0) }) {
            target = "/o/r/\(id)/\(filename)"
        } else {
            return nil
        }
        let mime = (element["type"] as? String)?.lowercased() ?? ""
        let isImage = mime.hasPrefix("image/") && mime != "image/svg+xml"
        return NoteAttachment(target: target, name: filename, kind: isImage ? .image : .file)
    }

    // MARK: Targets

    static func isAbsoluteURL(_ target: String) -> Bool {
        target.range(of: "http://", options: [.anchored, .caseInsensitive]) != nil
            || target.range(of: "https://", options: [.anchored, .caseInsensitive]) != nil
    }

    static func isMemosRelative(_ target: String) -> Bool {
        target.hasPrefix("/file/") || target.hasPrefix("/o/r/")
    }

    static func isRemote(_ target: String) -> Bool {
        isAbsoluteURL(target) || isMemosRelative(target)
    }

    /// The path of an absolute URL or a Memos-relative target, percent-decoded, without query or fragment.
    /// `nil` for anything else (a vault name or path).
    static func urlPath(of target: String) -> String? {
        var path: Substring
        if isAbsoluteURL(target) {
            guard let schemeEnd = target.range(of: "://") else { return nil }
            let afterScheme = target[schemeEnd.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/") else { return "/" }
            path = afterScheme[slash...]
        } else if isMemosRelative(target) {
            path = target[...]
        } else {
            return nil
        }
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<cut] }
        let raw = String(path)
        return raw.removingPercentEncoding ?? raw
    }

    static func identity(of target: String) -> String {
        urlPath(of: target) ?? target
    }

    /// Whether a link destination points at a file a Memos server hosts (`/file/…` or `/o/r/…`), absolute or relative.
    static func isMemosFileDestination(_ destination: String) -> Bool {
        guard let path = urlPath(of: unwrapped(destination)) else { return false }
        return path.hasPrefix("/file/") || path.hasPrefix("/o/r/")
    }

    // MARK: Syntaxes

    /// A link's `(destination)` as a regex fragment whose group 1 is the destination. It runs to the first `)` that
    /// doesn't close a pair opened inside it, so `Scan (2).pdf` and `photo(1).png` stay whole: Quoote writes an
    /// uploaded file's name into the link as it is. A destination never spans lines.
    static let linkDestinationPattern = #"\(((?:[^()\n]|\([^()\n]*\))*)\)"#

    private static let wikilinkRegex = try! NSRegularExpression(pattern: #"!\[\[([^\]]*)\]\]"#)
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[[^\]]*\]"# + linkDestinationPattern)
    private static let linkRegex = try! NSRegularExpression(pattern: #"(?<!!)\[([^\]]*)\]"# + linkDestinationPattern)

    private static func blank(_ range: NSRange, in text: NSMutableString) {
        text.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
    }

    /// `![[target|size#section]]`. A note transclusion (`![[Some Note]]`, `![[Plan.md]]`) or a dotted note name
    /// (`![[Meeting 10.3]]`) isn't an attachment: it needs an extension of 1–5 letters and digits, with a letter.
    private static func wikilinkAttachment(_ inner: String) -> NoteAttachment? {
        let end = inner.firstIndex(where: { $0 == "|" || $0 == "#" }) ?? inner.endIndex
        let target = inner[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let name = lastComponent(of: target)
        guard let ext = fileExtension(of: name),
              ext.contains(where: \.isLetter),
              ext != "md", ext != "markdown" else { return nil }
        return NoteAttachment(target: target, name: name, kind: imageExtensions.contains(ext) ? .image : .file)
    }

    /// `![alt](destination)`. Written as an image, so it is one unless its extension says otherwise.
    private static func imageAttachment(destination raw: String) -> NoteAttachment? {
        let destination = firstDestination(of: raw)
        guard !destination.isEmpty else { return nil }
        // `data:`, `file:` and friends are not something to fetch or look up.
        if hasScheme(destination) && !isAbsoluteURL(destination) { return nil }
        let target = isRemote(destination) ? destination : (destination.removingPercentEncoding ?? destination)
        let name = lastComponent(of: urlPath(of: destination) ?? target)
        let ext = fileExtension(of: name)
        let isFile = ext.map { !imageExtensions.contains($0) } ?? false
        return NoteAttachment(target: target, name: name, kind: isFile ? .file : .image)
    }

    /// `[name](url)` where the url is a Memos file (how Quoote links a file it uploaded).
    private static func linkAttachment(label: String, destination raw: String) -> NoteAttachment? {
        let destination = unwrapped(raw)
        guard isMemosFileDestination(destination) else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedLabel.isEmpty ? lastComponent(of: urlPath(of: destination) ?? destination) : trimmedLabel
        let isImage = fileExtension(of: name).map { imageExtensions.contains($0) } ?? false
        return NoteAttachment(target: destination, name: name, kind: isImage ? .image : .file)
    }

    // MARK: Helpers

    private static func lastComponent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    /// The lowercased extension, when the name ends in a dot and 1–5 ASCII letters or digits.
    private static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard (1...5).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return ext.lowercased()
    }

    /// A link destination whole: trimmed, and without `<…>` if it was wrapped.
    private static func unwrapped(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        return trimmed
    }

    /// An image destination: inside `<…>`, else up to the first whitespace (what follows is a title).
    private static func firstDestination(of raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") { return unwrapped(trimmed) }
        return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    private static func hasScheme(_ destination: String) -> Bool {
        guard let colon = destination.firstIndex(of: ":"), colon != destination.startIndex else { return false }
        let scheme = destination[..<colon]
        guard scheme.first?.isLetter == true else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }
}
