import Foundation

/// Pure helpers shared by the views and covered by unit tests. Nothing here imports UIKit,
/// SwiftUI or HealthKit, so the test package can compile these files directly.
public enum Trends {
    /// Change between the first and last value of a series, ignoring gaps.
    public static func change(_ values: [Double?]) -> (delta: Double, points: Int)? {
        let points = values.compactMap { $0 }
        guard let first = points.first, let last = points.last, points.count > 1 else { return nil }
        return (last - first, points.count)
    }

    /// Calendar days between two `yyyy-MM-dd` keys. A trend reads as "over 83 days", which is
    /// what the reader wants, not "over 8 readings".
    public static func spanDays(from: String, to: String) -> Int? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: from), let end = formatter.date(from: to) else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day
    }

    /// Mean of the last `window` present values.
    public static func average(_ values: [Double?], window: Int) -> Double? {
        let points = values.suffix(window).compactMap { $0 }
        guard !points.isEmpty else { return nil }
        return points.reduce(0, +) / Double(points.count)
    }

    /// Ring completion, clamped so an over-achieved goal still reads as a full circle.
    public static func fraction(value: Double, goal: Double) -> Double {
        guard goal > 0 else { return 0 }
        return min(max(value / goal, 0), 1)
    }

    public static func percent(value: Double, goal: Double) -> Int {
        guard goal > 0 else { return 0 }
        return Int((value / goal * 100).rounded())
    }
}

/// Builds request URLs. `URL.appending(path:)` percent-encodes everything it is handed, so a
/// path carrying a query string becomes `/v1/daily%3Ffrom=…` and 404s — this keeps the query a
/// query.
public enum APIPath {
    public static func url(base: URL, pathAndQuery: String) -> URL {
        let parts = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let withPath = base.appending(path: String(parts[0]))
        guard parts.count > 1, !parts[1].isEmpty,
              var components = URLComponents(url: withPath, resolvingAgainstBaseURL: false)
        else { return withPath }
        components.percentEncodedQuery = String(parts[1])
        return components.url ?? withPath
    }
}

/// The server sends ISO 8601 with and without fractional seconds depending on the field.
public enum ISODate {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    public static func parse(_ text: String) -> Date? {
        withFraction.date(from: text) ?? plain.date(from: text)
    }
}

/// Relative Thai wording used throughout the UI.
public enum RelativeThai {
    public static func describe(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 90 { return "เมื่อครู่" }
        if seconds < 3600 { return "\(Int(seconds / 60)) นาทีที่แล้ว" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) ชม.ที่แล้ว" }
        let days = Int(seconds / 86_400)
        if days == 1 { return "เมื่อวาน" }
        if days < 30 { return "\(days) วันก่อน" }
        return nil_fallback(date)
    }

    private static func nil_fallback(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "th_TH")
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }
}
