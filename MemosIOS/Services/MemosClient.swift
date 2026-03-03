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
        let trimmedBase = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBase.isEmpty, !trimmedToken.isEmpty else {
            throw MemosError.notConfigured
        }

        let normalizedBase = trimmedBase.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let baseURL = URL(string: normalizedBase), var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
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

        let endpoint = cleanedURL.appendingPathComponent("api/v1/memos")

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
}
