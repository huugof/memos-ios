import Foundation

enum MemosError: LocalizedError {
    case notConfigured
    case badURL
    case insecureHTTPNotAllowed
    case networkFailure(String)
    case badResponse(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Configure endpoint URL and API token first."
        case .badURL:
            return "Endpoint URL is invalid."
        case .insecureHTTPNotAllowed:
            return "HTTP endpoints are disabled. Enable Allow insecure HTTP in Settings."
        case .networkFailure(let detail):
            return "Network error: \(detail)"
        case .badResponse(let status, let body):
            if let body, !body.isEmpty {
                return "Server error (\(status)): \(body)"
            }
            return "Server error (\(status))."
        }
    }
}

struct MemosClient {
    var session: URLSession = .shared

    func createMemo(content: String, baseURLString: String, token: String, allowInsecureHTTP: Bool) async throws {
        let (baseURL, trimmedToken) = try validatedBaseURLAndToken(
            baseURLString: baseURLString,
            token: token,
            allowInsecureHTTP: allowInsecureHTTP
        )
        let endpoint = baseURL.appendingPathComponent("api/v1/memos")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["content": content], options: [])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MemosError.badURL
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw MemosError.badResponse(http.statusCode, body)
            }
        } catch let error as MemosError {
            throw error
        } catch {
            throw MemosError.networkFailure(error.localizedDescription)
        }
    }

    func fetchTags(baseURLString: String, token: String, allowInsecureHTTP: Bool) async throws -> [String] {
        let (baseURL, trimmedToken) = try validatedBaseURLAndToken(
            baseURLString: baseURLString,
            token: token,
            allowInsecureHTTP: allowInsecureHTTP
        )

        var endpoints: [URL] = [
            baseURL.appendingPathComponent("api/v1/tags"),
            baseURL.appendingPathComponent("api/v1/memos/-/tags")
        ]
        if var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/memos"), resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "pageSize", value: "200")]
            if let memosURL = components.url {
                endpoints.append(memosURL)
            }
        }

        var collectedTags: Set<String> = []
        var didReceiveSuccess = false

        for endpoint in endpoints {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200..<300).contains(http.statusCode) else { continue }
                didReceiveSuccess = true
                collectedTags.formUnion(Self.extractTags(from: data))
            } catch {
                continue
            }
        }

        guard didReceiveSuccess else {
            throw MemosError.networkFailure("Unable to fetch tags from the server.")
        }

        return collectedTags.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func validatedBaseURLAndToken(
        baseURLString: String,
        token: String,
        allowInsecureHTTP: Bool
    ) throws -> (URL, String) {
        let trimmedBase = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, !trimmedToken.isEmpty else {
            throw MemosError.notConfigured
        }

        let normalizedBase = trimmedBase.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let baseURL = URL(string: normalizedBase),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MemosError.badURL
        }

        guard let scheme = components.scheme?.lowercased() else {
            throw MemosError.badURL
        }

        if scheme == "http" && !allowInsecureHTTP {
            throw MemosError.insecureHTTPNotAllowed
        }

        if scheme != "https" && scheme != "http" {
            throw MemosError.badURL
        }

        components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let cleanedURL = components.url else {
            throw MemosError.badURL
        }

        return (cleanedURL, trimmedToken)
    }

    private static func extractTags(from data: Data) -> Set<String> {
        guard let payload = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        if let directTagList = payload as? [String] {
            return Set(directTagList.compactMap { normalizedTag(from: $0) })
        }

        var tags: Set<String> = []
        collectTags(from: payload, into: &tags)
        return tags
    }

    private static func collectTags(from value: Any, into tags: inout Set<String>) {
        switch value {
        case let array as [Any]:
            array.forEach { collectTags(from: $0, into: &tags) }
        case let dictionary as [String: Any]:
            for (key, nestedValue) in dictionary {
                if key.lowercased().contains("tag") {
                    if let tagString = nestedValue as? String,
                       let normalized = normalizedTag(from: tagString) {
                        tags.insert(normalized)
                    }
                    if let tagArray = nestedValue as? [String] {
                        for tagString in tagArray {
                            if let normalized = normalizedTag(from: tagString) {
                                tags.insert(normalized)
                            }
                        }
                    }
                }
                collectTags(from: nestedValue, into: &tags)
            }
        case let stringValue as String:
            for tag in hashtags(in: stringValue) {
                tags.insert(tag)
            }
        default:
            break
        }
    }

    private static func hashtags(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "#([A-Za-z0-9_-]+)") else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[swiftRange])
        }
    }

    private static func normalizedTag(from raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("tags/") {
            value.removeFirst("tags/".count)
        }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard !value.isEmpty else { return nil }
        guard !value.contains(where: { $0.isWhitespace }) else { return nil }
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return value
    }
}
