import Foundation

/// A dev server's HttpOnly cookies (its login sessions), kept on the Mac for one preview session.
/// In the phone's browser every preview port would get them (cookies ignore ports) and any port's page
/// could replace them; here they only ever go back to the server that set them.
/// Kept simple on purpose: one value per name (no Path/Domain scoping), deleted when the server expires them.
public struct PreviewCookieJar: Equatable, Sendable {
    public static let maxCookies = 50
    public static let maxValueBytes = 4096

    public private(set) var cookies: [String: String] = [:]

    public init() {}

    /// Applies one `Set-Cookie` value.
    public mutating func store(setCookie: String, now: Date = Date()) {
        let parts = setCookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let pair = parts.first, let equals = pair.firstIndex(of: "=") else { return }
        let name = String(pair[..<equals]).trimmingCharacters(in: .whitespaces)
        let value = String(pair[pair.index(after: equals)...])
        guard !name.isEmpty, !PreviewGate.isSlotCookie(name + "=") else { return }
        let attributes = parts.dropFirst().map { $0.lowercased() }
        let expired = attributes.contains { attribute in
            if attribute.hasPrefix("max-age=") { return (Int(attribute.dropFirst("max-age=".count)) ?? 1) <= 0 }
            if attribute.hasPrefix("expires=") {
                return Self.httpDate(String(attribute.dropFirst("expires=".count))).map { $0 <= now } ?? false
            }
            return false
        }
        if expired {
            cookies[name] = nil
            return
        }
        guard value.utf8.count <= Self.maxValueBytes, cookies[name] != nil || cookies.count < Self.maxCookies else { return }
        cookies[name] = value
    }

    /// The `Cookie` value for the dev server: the browser's own cookies, except slot cookies and any the jar
    /// holds (a cookie another port's page planted under the same name loses), then the jar's.
    public func cookieHeader(browser: [String]) -> String? {
        let kept = browser.filter { pair in
            let name = pair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? pair
            return !PreviewGate.isSlotCookie(pair) && cookies[name.trimmingCharacters(in: .whitespaces)] == nil
        }
        let all = kept + cookies.keys.sorted().map { "\($0)=\(cookies[$0]!)" }
        return all.isEmpty ? nil : all.joined(separator: "; ")
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
