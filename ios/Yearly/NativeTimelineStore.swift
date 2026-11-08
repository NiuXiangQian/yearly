import Foundation
import Combine

struct NativeMediaFile: Decodable, Identifiable {
    let id: Int
    let file_role: String
    let original_filename: String
    let mime_type: String
    let file_size: Int64
}
struct NativeTimelineItem: Decodable, Identifiable {
    let id: Int
    var kind: String?
    var title: String?
    var batch_name: String?
    var media_type: String?
    var timeline_day: String?
    var timeline_date: String?
    var taken_at_local: String?
    var start_at: String?
    var content: String?
    var remark: String?
    var location_name: String?
    var files: [NativeMediaFile]?
    var children: [UploadProfile]?
    var child_ids: [Int]?
    var stableID: String { "\(kind ?? "media")-\(id)" }
    var label: String { [title, batch_name].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "珍藏的瞬间" }
    var day: String { String((timeline_day ?? timeline_date ?? taken_at_local ?? start_at ?? "日期未知").prefix(10)) }
    var primary: NativeMediaFile? { files?.first { $0.file_role == "original" } }
    var motion: NativeMediaFile? { files?.first { $0.file_role == "live_video" } }
}
struct NativeTimelinePage: Decodable { let items: [NativeTimelineItem]; let total: Int; let next_cursor: String? }
struct NativeMediaResource: Decodable { let url: String?; let status: String }

@MainActor final class NativeTimelineStore: ObservableObject {
    @Published var items: [NativeTimelineItem] = []
    @Published var profiles: [UploadProfile] = []
    @Published var selected: Set<Int> = []
    @Published var loading = false
    @Published var error = ""
    @Published var total = 0
    @Published private(set) var cursor: String?
    private var generation = 0
    let session: NativeSession
    init(session: NativeSession) { self.session = session }
    func load(more: Bool = false) async {
        if more && (loading || cursor == nil) { return }
        generation += 1
        let ticket = generation
        defer { if ticket == generation { loading = false } }
        loading = true; error = ""
        var query = URLComponents()
        var params = [URLQueryItem(name: "page_size", value: "40"), URLQueryItem(name: "group_folders", value: "false"), URLQueryItem(name: "order", value: "desc")]
        params += selected.sorted().map { URLQueryItem(name: "child_id", value: String($0)) }
        if more, let cursor { params.append(URLQueryItem(name: "cursor", value: cursor)) }
        query.queryItems = params
        do {
            let page: NativeTimelinePage = try await session.get("/timeline?" + (query.percentEncodedQuery ?? ""))
            guard ticket == generation, !Task.isCancelled else { return }
            if more {
                let existing = Set(items.map(\.stableID))
                items += page.items.filter { !existing.contains($0.stableID) }
            } else { items = page.items }
            total = page.total; cursor = page.next_cursor
        } catch { if ticket == generation && !Task.isCancelled { self.error = friendly(error) } }
    }
    func loadProfiles() async {
        do { profiles = try await session.get("/children") }
        catch { self.error = friendly(error) }
    }
}

