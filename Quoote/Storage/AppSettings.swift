import Foundation

enum AppSettings {
    private enum Keys {
        static let endpointBaseURL = "endpointBaseURL"
        static let allowInsecureHTTP = "allowInsecureHTTP"
        static let keepTextAfterSend = "keepTextAfterSend"
        static let markSentOnSuccess = "markSentOnSuccess"
        static let clearErrorOnEdit = "clearErrorOnEdit"
        static let recentAcceptedTags = "recentAcceptedTags"
        static let newNoteAfterOption = "newNoteAfterOption"
        static let lastBackgroundAt = "lastBackgroundAt"
        static let lastActiveDraftID = "lastActiveDraftID"
        static let resumeDeadlineAt = "resumeDeadlineAt"
        static let lastRouteRaw = "lastRouteRaw"
        static let quickCaptureMode = "quickCaptureMode"
        static let vaultBookmark = "vaultBookmark"
        static let destinationKind = "destinationKind"
        static let vaultNotesFolder = "vaultNotesFolder"
        static let vaultAttachmentsFolder = "vaultAttachmentsFolder"
        static let vaultTemplatePath = "vaultTemplatePath"
        static let vaultDateFormat = "vaultDateFormat"
    }

    private static let defaults = UserDefaults.standard

    enum NewNoteDelay: String, CaseIterable, Identifiable {
        case immediately
        case seconds30
        case seconds60
        case minutes5
        case minutes15
        case minutes30
        case minutes60
        case never

        var id: String { rawValue }

        var label: String {
            switch self {
            case .immediately:
                return "Immediately"
            case .seconds30:
                return "30 sec"
            case .seconds60:
                return "60 sec"
            case .minutes5:
                return "5 min"
            case .minutes15:
                return "15 min"
            case .minutes30:
                return "30 min"
            case .minutes60:
                return "60 min"
            case .never:
                return "Never"
            }
        }

        var delaySeconds: Int? {
            switch self {
            case .immediately:
                return 0
            case .seconds30:
                return 30
            case .seconds60:
                return 60
            case .minutes5:
                return 300
            case .minutes15:
                return 900
            case .minutes30:
                return 1800
            case .minutes60:
                return 3600
            case .never:
                return nil
            }
        }
    }

    static var endpointBaseURL: String {
        get { defaults.string(forKey: Keys.endpointBaseURL) ?? "" }
        set { defaults.set(newValue, forKey: Keys.endpointBaseURL) }
    }

    static var allowInsecureHTTP: Bool {
        get { defaults.object(forKey: Keys.allowInsecureHTTP) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.allowInsecureHTTP) }
    }

    static var keepTextAfterSend: Bool {
        get { defaults.object(forKey: Keys.keepTextAfterSend) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.keepTextAfterSend) }
    }

    static var markSentOnSuccess: Bool {
        get { defaults.object(forKey: Keys.markSentOnSuccess) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.markSentOnSuccess) }
    }

    static var clearErrorOnEdit: Bool {
        get { defaults.object(forKey: Keys.clearErrorOnEdit) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.clearErrorOnEdit) }
    }

    static var recentAcceptedTags: [String] {
        get { defaults.stringArray(forKey: Keys.recentAcceptedTags) ?? [] }
        set { defaults.set(Array(newValue.prefix(100)), forKey: Keys.recentAcceptedTags) }
    }

    static var newNoteDelay: NewNoteDelay {
        get {
            if let raw = defaults.string(forKey: Keys.newNoteAfterOption),
               let value = NewNoteDelay(rawValue: raw) {
                return value
            }
            return .immediately
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.newNoteAfterOption) }
    }

    static var lastBackgroundAt: Date? {
        get {
            guard let epoch = defaults.object(forKey: Keys.lastBackgroundAt) as? Double else { return nil }
            return Date(timeIntervalSince1970: epoch)
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Keys.lastBackgroundAt)
            } else {
                defaults.removeObject(forKey: Keys.lastBackgroundAt)
            }
        }
    }

    static var lastActiveDraftID: UUID? {
        get {
            guard let raw = defaults.string(forKey: Keys.lastActiveDraftID) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.uuidString, forKey: Keys.lastActiveDraftID)
            } else {
                defaults.removeObject(forKey: Keys.lastActiveDraftID)
            }
        }
    }

    static var resumeDeadlineAt: Date? {
        get {
            guard let epoch = defaults.object(forKey: Keys.resumeDeadlineAt) as? Double else { return nil }
            return Date(timeIntervalSince1970: epoch)
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Keys.resumeDeadlineAt)
            } else {
                defaults.removeObject(forKey: Keys.resumeDeadlineAt)
            }
        }
    }

    static var quickCaptureMode: Bool {
        get { defaults.object(forKey: Keys.quickCaptureMode) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.quickCaptureMode) }
    }

    static var lastRouteRaw: String? {
        get { defaults.string(forKey: Keys.lastRouteRaw) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.lastRouteRaw)
            } else {
                defaults.removeObject(forKey: Keys.lastRouteRaw)
            }
        }
    }

    static var vaultBookmark: Data? {
        get { defaults.data(forKey: Keys.vaultBookmark) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.vaultBookmark)
            } else {
                defaults.removeObject(forKey: Keys.vaultBookmark)
            }
        }
    }

    static var destinationKind: DestinationKind {
        get {
            guard let raw = defaults.string(forKey: Keys.destinationKind),
                  let kind = DestinationKind(rawValue: raw)
            else { return .memos }
            return kind
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.destinationKind) }
    }

    /// Subfolder new notes are written into. Empty means the vault root.
    /// Stored without leading or trailing slashes so path joining stays simple.
    static var vaultNotesFolder: String {
        get { defaults.string(forKey: Keys.vaultNotesFolder) ?? "" }
        set { defaults.set(Self.normalizedFolder(newValue), forKey: Keys.vaultNotesFolder) }
    }

    static var vaultAttachmentsFolder: String {
        get { defaults.string(forKey: Keys.vaultAttachmentsFolder) ?? "attachments" }
        set { defaults.set(Self.normalizedFolder(newValue), forKey: Keys.vaultAttachmentsFolder) }
    }

    /// Vault-relative path of the Markdown file whose frontmatter seeds every
    /// new note (e.g. `Templates/Capture.md`). Empty means no template.
    static var vaultTemplatePath: String {
        get { defaults.string(forKey: Keys.vaultTemplatePath) ?? "" }
        set { defaults.set(Self.normalizedFolder(newValue), forKey: Keys.vaultTemplatePath) }
    }

    /// Moment format for the managed `date`/`modified` stamps (e.g.
    /// `YYYY-MM-DD HH:mm`). Empty defers to the template, then ISO 8601.
    static var vaultDateFormat: String {
        get { defaults.string(forKey: Keys.vaultDateFormat) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.vaultDateFormat) }
    }

    /// Splits on "/", trims whitespace/newlines from each component, and drops
    /// empty, "." and ".." components so a free-text Settings value can never
    /// escape the vault root via path traversal when later joined onto it.
    /// Note: "inbox/../notes" becomes "inbox/notes", not "notes" — ".."
    /// components are dropped, not resolved.
    private static func normalizedFolder(_ value: String) -> String {
        value.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }
}
