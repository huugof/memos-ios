import Foundation

enum AppSettings {
    private enum Keys {
        static let endpointBaseURL = "endpointBaseURL"
        static let allowInsecureHTTP = "allowInsecureHTTP"
        static let keepTextAfterSend = "keepTextAfterSend"
        static let markSentOnSuccess = "markSentOnSuccess"
        static let clearErrorOnEdit = "clearErrorOnEdit"
        static let newNoteAfterOption = "newNoteAfterOption"
        static let newNoteDelaySecondsLegacy = "newNoteDelaySeconds"
        static let lastBackgroundAt = "lastBackgroundAt"
        static let lastActiveDraftID = "lastActiveDraftID"
        static let resumeDeadlineAt = "resumeDeadlineAt"
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

    static var newNoteDelay: NewNoteDelay {
        get {
            if let raw = defaults.string(forKey: Keys.newNoteAfterOption),
               let value = NewNoteDelay(rawValue: raw) {
                return value
            }

            // Legacy migration from earlier integer-based settings.
            if let legacy = defaults.object(forKey: Keys.newNoteDelaySecondsLegacy) as? Int {
                switch legacy {
                case 0:
                    return .immediately
                case 30:
                    return .seconds30
                case 60:
                    return .seconds60
                case 120:
                    return .seconds60
                case 300:
                    return .minutes5
                case 600:
                    return .minutes15
                default:
                    return .immediately
                }
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
}
