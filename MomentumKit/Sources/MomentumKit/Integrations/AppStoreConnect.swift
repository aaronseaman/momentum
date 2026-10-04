import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct AppStoreConnectCredentials: Codable, Hashable, Sendable {
    public var issuerID: String
    public var keyID: String
    /// Contents of the .p8 private key file (PEM).
    public var privateKey: String
    /// Vendor number from Payments and Financial Reports (needed for sales).
    public var vendorNumber: String

    public init(issuerID: String, keyID: String, privateKey: String, vendorNumber: String) {
        self.issuerID = issuerID
        self.keyID = keyID
        self.privateKey = privateKey
        self.vendorNumber = vendorNumber
    }
}

public protocol ASCTokenProvider: Sendable {
    func token(now: Date) throws -> String
}

#if canImport(CryptoKit)
/// Signs short-lived ES256 JWTs on device. The private key never leaves the Keychain/app.
public struct ASCJWTSigner: ASCTokenProvider {
    let credentials: AppStoreConnectCredentials

    public init(credentials: AppStoreConnectCredentials) {
        self.credentials = credentials
    }

    public func token(now: Date) throws -> String {
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKey.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw IntegrationError.unauthorized("App Store Connect (invalid .p8 key)")
        }
        let header = ["alg": "ES256", "kid": credentials.keyID, "typ": "JWT"]
        let issuedAt = Int(now.timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": credentials.issuerID,
            "iat": issuedAt,
            "exp": issuedAt + 15 * 60,
            "aud": "appstoreconnect-v1"
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signingInput = Base64URL.encode(headerData) + "." + Base64URL.encode(payloadData)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Base64URL.encode(signature.rawRepresentation)
    }
}
#endif

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct ASCAppSnapshot: Hashable, Sendable {
    public var app: StoreApp
    public var liveVersion: String?
    public var currentVersion: StoreVersion?
    public var latestBuildAt: Date?
}

public struct SalesRow: Hashable, Sendable {
    public var productType: String
    public var units: Int
    public var proceedsPerUnit: Double
    public var currency: String
    public var appleID: String
    public var title: String
    public var sku: String
    public var parentIdentifier: String

    /// The SKU of the app this row belongs to (IAP rows point at their parent app).
    public var appSKU: String { parentIdentifier.trimmingCharacters(in: .whitespaces).isEmpty ? sku : parentIdentifier }

    public var isDownload: Bool { ["1", "1F", "1T", "F1", "1E", "1EP", "1EU"].contains(productType) }
    public var isSubscription: Bool { ["IAY", "IA9", "IAC"].contains(productType) }
}

public struct AppStoreConnectClient: Sendable {
    let tokens: ASCTokenProvider
    let vendorNumber: String
    let http: HTTPClient
    let base = "https://api.appstoreconnect.apple.com"

    public init(tokens: ASCTokenProvider, vendorNumber: String, http: HTTPClient) {
        self.tokens = tokens
        self.vendorNumber = vendorNumber
        self.http = http
    }

    func headers(now: Date, accept: String = "application/json") throws -> [String: String] {
        ["Authorization": "Bearer \(try tokens.token(now: now))", "Accept": accept]
    }

    // MARK: Apps, versions, builds

    struct Resource<A: Decodable>: Decodable {
        let id: String
        let attributes: A
    }
    struct ListResponse<A: Decodable>: Decodable {
        let data: [Resource<A>]
    }
    struct AppAttributes: Decodable { let name: String; let bundleId: String; let sku: String? }
    struct VersionAttributes: Decodable {
        let versionString: String
        let appStoreState: String?
        let appVersionState: String?
        let createdDate: Date?
    }
    struct BuildAttributes: Decodable { let version: String?; let uploadedDate: Date? }

    public func apps(now: Date) async throws -> [StoreApp] {
        let url = URL.make("\(base)/v1/apps", [("fields[apps]", "name,bundleId,sku"), ("limit", "200")])
        let list = try await http.json(ListResponse<AppAttributes>.self, URLRequest(url, headers: try headers(now: now)), service: "App Store Connect")
        return list.data.map { StoreApp(id: $0.id, name: $0.attributes.name, bundleID: $0.attributes.bundleId, sku: $0.attributes.sku) }
    }

    public func snapshot(app: StoreApp, now: Date) async throws -> ASCAppSnapshot {
        let versionsURL = URL.make("\(base)/v1/apps/\(app.id)/appStoreVersions", [
            ("fields[appStoreVersions]", "versionString,appStoreState,appVersionState,createdDate"), ("limit", "10")
        ])
        let versions = try await http.json(ListResponse<VersionAttributes>.self, URLRequest(versionsURL, headers: try headers(now: now)), service: "App Store Connect")
            .data.map { v -> StoreVersion in
                let raw = v.attributes.appVersionState ?? v.attributes.appStoreState ?? ""
                return StoreVersion(version: v.attributes.versionString, state: StoreState(appStoreConnectValue: raw), createdAt: v.attributes.createdDate)
            }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }

        let buildsURL = URL.make("\(base)/v1/builds", [
            ("filter[app]", app.id), ("sort", "-uploadedDate"), ("limit", "1"), ("fields[builds]", "version,uploadedDate")
        ])
        let build = try? await http.json(ListResponse<BuildAttributes>.self, URLRequest(buildsURL, headers: try headers(now: now)), service: "App Store Connect")

        return ASCAppSnapshot(
            app: app,
            liveVersion: versions.first { $0.state == .live }?.version,
            currentVersion: versions.first,
            latestBuildAt: build?.data.first?.attributes.uploadedDate
        )
    }

    // MARK: Sales

    /// Daily SALES/SUMMARY report rows. Returns `[]` when Apple has no sales for the day.
    public func sales(day: DayKey, now: Date) async throws -> [SalesRow] {
        for version in ["1_0", "1_1"] {
            let url = URL.make("\(base)/v1/salesReports", [
                ("filter[frequency]", "DAILY"), ("filter[reportDate]", day.rawValue), ("filter[reportSubType]", "SUMMARY"),
                ("filter[reportType]", "SALES"), ("filter[vendorNumber]", vendorNumber), ("filter[version]", version)
            ])
            do {
                let data = try await http.fetch(URLRequest(url, headers: try headers(now: now, accept: "application/a-gzip")), service: "App Store Connect")
                return SalesReportParser.parse(try Gzip.decompress(data))
            } catch IntegrationError.notFound {
                return []
            } catch IntegrationError.http(400, _) where version == "1_0" {
                continue // Apple occasionally retires report versions; try the next one.
            }
        }
        return []
    }
}

public enum SalesReportParser {
    public static func parse(_ data: Data) -> [SalesRow] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    public static func parse(_ text: String) -> [SalesRow] {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        func col(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let unitsCol = col("Units"), let proceedsCol = col("Developer Proceeds"), let typeCol = col("Product Type Identifier") else { return [] }
        let currencyCol = col("Currency of Proceeds")
        let appleIDCol = col("Apple Identifier")
        let titleCol = col("Title")
        let skuCol = col("SKU")
        let parentCol = col("Parent Identifier")

        return lines.compactMap { line in
            let fields = line.components(separatedBy: "\t")
            func field(_ i: Int?) -> String { i.flatMap { $0 < fields.count ? fields[$0] : nil }?.trimmingCharacters(in: .whitespaces) ?? "" }
            guard let units = Int(field(unitsCol)) ?? Double(field(unitsCol)).map({ Int($0) }) else { return nil }
            return SalesRow(
                productType: field(typeCol),
                units: units,
                proceedsPerUnit: Double(field(proceedsCol)) ?? 0,
                currency: field(currencyCol).isEmpty ? "USD" : field(currencyCol),
                appleID: field(appleIDCol),
                title: field(titleCol),
                sku: field(skuCol),
                parentIdentifier: field(parentCol)
            )
        }
    }

    /// Aggregates rows into per-app revenue and download entries in the base currency.
    public static func entries(_ rows: [SalesRow], day: DayKey, apps: [StoreApp], fx: FXRates) -> (revenue: [RevenueEntry], downloads: [DownloadEntry]) {
        let bySKU = Dictionary(apps.compactMap { app in app.sku.map { ($0, app) } }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        struct Key: Hashable { let app: String; let kind: RevenueKind }
        var money: [Key: (amount: Double, units: Int, name: String)] = [:]
        var downloads: [String: Int] = [:]

        for row in rows {
            let app = bySKU[row.appSKU] ?? byID[row.appleID]
            let appID = app?.id ?? row.appleID
            let name = app?.name ?? row.title
            if row.isDownload && row.units > 0 {
                downloads[appID, default: 0] += row.units
            }
            let gross = row.proceedsPerUnit * Double(row.units)
            guard gross != 0, let converted = fx.convert(gross, from: row.currency) else { continue }
            let kind: RevenueKind = row.units < 0 ? .refund : (row.isSubscription ? .subscription : .purchase)
            let key = Key(app: appID, kind: kind)
            let existing = money[key] ?? (0, 0, name)
            money[key] = (existing.amount + converted, existing.units + row.units, name)
        }

        let revenue = money.map { key, value in
            RevenueEntry(day: day, source: .appStore, kind: key.kind, amount: (value.amount * 100).rounded() / 100,
                         units: value.units, appIdentifier: key.app, appName: value.name)
        }
        .sorted { ($0.appIdentifier ?? "", $0.kind.rawValue) < ($1.appIdentifier ?? "", $1.kind.rawValue) }
        let downloadEntries = downloads.map { DownloadEntry(day: day, units: $0.value, appIdentifier: $0.key) }
            .sorted { ($0.appIdentifier ?? "") < ($1.appIdentifier ?? "") }
        return (revenue, downloadEntries)
    }
}

/// Minimal gzip support for App Store Connect reports.
public enum Gzip {
    public static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b else { return data } // Already plain text.
        guard bytes[2] == 8 else { throw IntegrationError.decoding("gzip") }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8 }
        if flags & 0x08 != 0 { while offset < bytes.count && bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0x10 != 0 { while offset < bytes.count && bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { throw IntegrationError.decoding("gzip") }
        let deflate = Data(bytes[offset..<(bytes.count - 8)])
        #if canImport(Darwin)
        do {
            return try (deflate as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw IntegrationError.decoding("gzip")
        }
        #else
        throw IntegrationError.unsupported("gzip")
        #endif
    }
}
