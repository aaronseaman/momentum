import Foundation

/// A calendar day ("yyyy-MM-dd"), independent of time of day. Sorts lexicographically.
public struct DayKey: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ rawValue: String) {
        let parts = rawValue.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        self.rawValue = rawValue
    }

    public init(_ date: Date, timeZone: TimeZone = .current) {
        let comps = DayKey.calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        rawValue = String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let key = DayKey(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid day: \(raw)")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Midnight at the start of this day in the given time zone.
    public func date(timeZone: TimeZone = .current) -> Date {
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return DayKey.calendar(timeZone).date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    public func adding(days: Int, timeZone: TimeZone = .current) -> DayKey {
        let cal = DayKey.calendar(timeZone)
        let shifted = cal.date(byAdding: .day, value: days, to: date(timeZone: timeZone).addingTimeInterval(12 * 3600))!
        return DayKey(shifted, timeZone: timeZone)
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    public func days(to other: DayKey) -> Int {
        let utc = TimeZone(identifier: "UTC")!
        let interval = other.date(timeZone: utc).timeIntervalSince(date(timeZone: utc))
        return Int((interval / 86_400).rounded())
    }

    public var month: String { String(rawValue.prefix(7)) }

    public static func range(from start: DayKey, through end: DayKey) -> [DayKey] {
        guard start <= end else { return [] }
        var result: [DayKey] = []
        var day = start
        while day <= end {
            result.append(day)
            day = day.adding(days: 1, timeZone: TimeZone(identifier: "UTC")!)
        }
        return result
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }
}

public extension Date {
    func days(since other: Date) -> Double { timeIntervalSince(other) / 86_400 }
}
