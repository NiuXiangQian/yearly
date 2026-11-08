import Foundation
import Combine

enum NativeDay {
    private static var formatter: DateFormatter {
        let value = DateFormatter()
        value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.dateFormat = "yyyy-MM-dd"
        value.isLenient = false
        return value
    }
    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ text: String) -> Date? {
        guard text.count == 10, let value = formatter.date(from: text), string(value) == text else { return nil }
        return value
    }
    static func following(_ date: Date) -> String {
        string(Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: date)!)
    }
}

struct NativeShare: Decodable, Identifiable {
    let id: Int
    let title: String
    let start_date: String
    let end_date: String
    let expires_at: String
    var revoked: Bool
    let expired: Bool
    let token: String?
    var expiration: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: expires_at) ?? ISO8601DateFormatter().date(from: expires_at)
    }
    var usable: Bool { !revoked && !expired && (expiration ?? .distantPast) > Date() }
    func link(site: SiteOrigin) -> URL? {
        guard usable, let token, !token.isEmpty,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return URL(string: "share/" + token, relativeTo: site.url)?.absoluteURL
    }
}

@MainActor final class NativeSharingStore: ObservableObject {
    @Published private(set) var shares: [NativeShare] = []
    @Published private(set) var created: NativeShare?
    @Published private(set) var busy = false
    @Published var error = ""
    let session: NativeSession
    init(session: NativeSession) { self.session = session }
    func load() async {
        guard !busy, session.canEdit else { return }
        busy = true
        defer { busy = false }
        do { shares = try await session.get("/shares"); error = "" }
        catch { self.error = friendly(error) }
    }
    func create(title: String, start: Date, end: Date, hours: Int) async {
        guard !busy else { return }
        guard NativeDay.string(start) <= NativeDay.string(end), (1...168).contains(hours) else {
            error = "请检查起止日期和有效期（1 至 168 小时）。"; return
        }
        busy = true; error = ""
        defer { busy = false }
        do {
            let result: NativeShare = try await session.post("/shares", json: [
                "title": String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
                "start_date": NativeDay.string(start), "end_date": NativeDay.string(end), "hours": hours
            ])
            created = result
            shares.insert(result, at: 0)
        } catch { self.error = friendly(error) }
    }
    func revoke(_ share: NativeShare) async {
        guard !busy else { return }
        busy = true; error = ""
        defer { busy = false }
        do {
            try await session.write("/shares/\(share.id)", method: "DELETE", json: [:])
            if let index = shares.firstIndex(where: { $0.id == share.id }) { shares[index].revoked = true }
            if created?.id == share.id { created?.revoked = true }
        } catch { self.error = friendly(error) }
    }
}
