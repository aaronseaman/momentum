import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum IntegrationError: Error, LocalizedError, Equatable, Sendable {
    case unauthorized(String)
    case http(Int, String)
    case notFound
    case rateLimited
    case decoding(String)
    case missingCredentials(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let service): "\(service) rejected the credentials. Reconnect it in Settings."
        case .http(let code, let message): "Request failed (\(code)). \(message)"
        case .notFound: "Not found."
        case .rateLimited: "Rate limited. Momentum will try again later."
        case .decoding(let what): "Couldn't read the response from \(what)."
        case .missingCredentials(let service): "\(service) isn't connected."
        case .unsupported(let what): "\(what) isn't supported on this device."
        }
    }
}

/// Minimal async HTTP abstraction so every client is testable with canned responses.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), http))
                } else {
                    continuation.resume(throwing: IntegrationError.http(0, "No response"))
                }
            }
            task.resume()
        }
    }
}

extension HTTPClient {
    /// Sends a request and maps common failure codes to `IntegrationError`.
    func fetch(_ request: URLRequest, service: String) async throws -> Data {
        var request = request
        if request.timeoutInterval > 30 { request.timeoutInterval = 30 }
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403:
            if response.statusCode == 403, response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                throw IntegrationError.rateLimited
            }
            throw IntegrationError.unauthorized(service)
        case 404: throw IntegrationError.notFound
        case 429: throw IntegrationError.rateLimited
        default:
            let message = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw IntegrationError.http(response.statusCode, message)
        }
    }

    func json<T: Decodable>(_ type: T.Type, _ request: URLRequest, service: String) async throws -> T {
        let data = try await fetch(request, service: service)
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw IntegrationError.decoding(service)
        }
    }
}

public enum JSONCoding {
    /// Decodes ISO-8601 dates with or without fractional seconds.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try container.decode(String.self)
            if let date = parseISO8601(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(string)")
        }
        return decoder
    }

    public static func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    public static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Lossless encoding for the local store (dates keep sub-second precision).
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var storeDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }

    /// Human-readable encoding for exports.
    public static var exportEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}

extension URLRequest {
    init(_ url: URL, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) {
        self.init(url: url)
        httpMethod = method
        httpBody = body
        for (key, value) in headers { setValue(value, forHTTPHeaderField: key) }
    }
}

extension URL {
    /// Builds a URL from a base and query items, percent-encoding safely.
    static func make(_ base: String, _ query: [(String, String)] = []) -> URL {
        var components = URLComponents(string: base)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents leaves "+" alone, which some APIs read as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }
}
