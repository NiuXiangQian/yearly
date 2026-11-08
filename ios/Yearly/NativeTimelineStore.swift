import Foundation
import Combine

struct NativeMediaFile: Decodable, Identifiable {
    let id: Int
    let file_role: String
    let original_filename: String
    let mime_type: String
    let file_size: Int64
    let sha256: String?
}
struct NativeTimelineItem: Decodable, Identifiable {
    let id: Int
    var kind: String?
    var title: String?
    var batch_name: String?
    var media_type: String?
    var timeline_day: String?
    var timeline_date: String?
    var uploaded_at: String?
    var taken_at_local: String?
    var start_at: String?
    var content: String?
    var remark: String?
    var location_name: String?
    var latitude: Double?
    var longitude: Double?
    var corrected_taken_at_local: String?
    var corrected_offset_minutes: Int?
    var time_unknown: Bool?
    var share_allowed: Bool?
    var tags: [String]?
    var folder_id: Int?
    var files: [NativeMediaFile]?
    var children: [UploadProfile]?
    var child_ids: [Int]?
    var stableID: String { "\(kind ?? "media")-\(id)" }
    var label: String { [title, batch_name].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "珍藏的瞬间" }
    var day: String { String((timeline_day ?? timeline_date ?? taken_at_local ?? start_at ?? "日期未知").prefix(10)) }
    var uploadDate: Date? {
        guard let uploaded_at else { return nil }
        let utc = uploaded_at + "Z" // The server stores upload timestamps as UTC without a suffix.
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(utc))
            ?? (try? Date.ISO8601FormatStyle().parse(utc))
    }
    var primary: NativeMediaFile? { files?.first { $0.file_role == "original" } }
    var motion: NativeMediaFile? { files?.first { $0.file_role == "live_video" } }
}
struct NativeTimelinePage: Decodable { let items: [NativeTimelineItem]; let total: Int; let next_cursor: String? }
struct NativeMediaResource: Decodable { let url: String?; let status: String }

@MainActor final class NativeTimelineStore: ObservableObject {
    @Published var items: [NativeTimelineItem] = []
    @Published var profiles: [UploadProfile] = []
    @Published private(set) var profilesLoading = false
    @Published private(set) var profilesError = ""
    @Published var selected: Set<Int> = []
    @Published var search = ""
    @Published var mediaType = ""
    @Published var ascending = false
    @Published private(set) var byUpload = false
    @Published var useDateRange = false
    @Published var startDate = Date()
    @Published var endDate = Date()
    @Published private(set) var uploadedMediaIDs: [Int] = []
    @Published private(set) var anchorMediaID: Int?
    var showingUploads: Bool { !uploadedMediaIDs.isEmpty }
    var usesUploadOrder: Bool { byUpload && !showingUploads && anchorMediaID == nil }
    var isFocused: Bool { showingUploads || anchorMediaID != nil }
    func groupDay(_ item: NativeTimelineItem) -> String {
        guard usesUploadOrder else { return item.day }
        return item.uploadDate.map(NativeDay.string) ?? "日期未知"
    }
    var queryKey: String {
        if showingUploads { return "uploads|\(uploadedMediaIDs)" }
        return "\(selected.sorted())|\(search)|\(mediaType)|\(ascending)|\(byUpload)|\(anchorMediaID ?? 0)|\(useDateRange)|\(NativeDay.string(startDate))|\(NativeDay.string(endDate))"
    }
    var hasFilters: Bool { !selected.isEmpty || !search.isEmpty || !mediaType.isEmpty || useDateRange }
    func resetFilters() { selected = []; search = ""; mediaType = ""; useDateRange = false }

    @Published var loading = false
    @Published var error = ""
    @Published var total = 0
    @Published private(set) var cursor: String?
    private var generation = 0
    private var loadedQuery = ""
    let session: NativeSession
    init(session: NativeSession) { self.session = session }
    func focusOnUploads(_ ids: [Int]) {
        let ids = Set(ids.filter { $0 > 0 }).sorted()
        guard uploadedMediaIDs != ids || anchorMediaID != nil else { return }
        anchorMediaID = nil
        resetResults()
        loading = !ids.isEmpty
        uploadedMediaIDs = ids
    }
    private func resetResults() {
        generation += 1
        items = []; total = 0; cursor = nil; loadedQuery = ""; loading = false; error = ""
    }
    func locate(_ item: NativeTimelineItem) {
        resetFilters()
        byUpload = false
        ascending = false
        uploadedMediaIDs = []
        anchorMediaID = item.id
        resetResults()
        loading = true
    }
    func showRecentUploads() {
        focusOnUploads([])
        resetFilters()
        byUpload = true
        ascending = false
        resetResults()
    }
    func setUploadOrder(_ enabled: Bool) {
        guard byUpload != enabled else { return }
        byUpload = enabled
        resetResults()
        loading = true
    }
    func showDay(_ day: String) {
        guard let date = NativeDay.date(day) else { return }
        resetFilters()
        byUpload = false
        startDate = date; endDate = date; useDateRange = true
        focusOnUploads([])
    }
    func resetForAccountChange() {
        generation += 1
        loadedQuery = ""; cursor = nil; loading = false
        items = []; profiles = []; total = 0; error = ""
        profilesError = ""
        uploadedMediaIDs = []
        anchorMediaID = nil
        byUpload = false
        resetFilters()
    }
    func loadIfNeeded() async {
        guard loadedQuery != queryKey else { return }
        await load()
    }
    func load(more: Bool = false) async {
        if more && (loading || cursor == nil || loadedQuery != queryKey) { return }
        if !showingUploads && useDateRange && NativeDay.string(startDate) > NativeDay.string(endDate) {
            error = "结束日期不能早于开始日期。"; return
        }
        generation += 1
        let ticket = generation
        let requestedQuery = queryKey
        defer { if ticket == generation { loading = false } }
        loading = true; error = ""
        if showingUploads {
            do {
                var uploads: [NativeTimelineItem] = []
                for id in uploadedMediaIDs {
                    try Task.checkCancellation()
                    do {
                        var item: NativeTimelineItem = try await session.get("/media/\(id)")
                        item.kind = "media"
                        uploads.append(item)
                    } catch let error as NativeAPIError where error.status == 404 {
                        continue
                    }
                }
                guard ticket == generation, !Task.isCancelled else { return }
                items = uploads; total = uploads.count; loadedQuery = requestedQuery
            } catch { if ticket == generation && !Task.isCancelled { self.error = friendly(error) } }
            return
        }
        var query = URLComponents()
        var params = [URLQueryItem(name: "page_size", value: "40"), URLQueryItem(name: "group_folders", value: "false"), URLQueryItem(name: "order", value: ascending ? "asc" : "desc")]
        if usesUploadOrder { params.append(URLQueryItem(name: "date_basis", value: "upload")) }
        if let anchorMediaID { params.append(URLQueryItem(name: "anchor_media_id", value: String(anchorMediaID))) }
        let queryText = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if !queryText.isEmpty { params.append(URLQueryItem(name: "q", value: queryText)) }
        if ["photo", "video", "live_photo"].contains(mediaType) { params.append(URLQueryItem(name: "media_type", value: mediaType)) }
        if useDateRange {
            if usesUploadOrder {
                let calendar = Calendar(identifier: .gregorian)
                let start = calendar.startOfDay(for: startDate)
                let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate))!
                params.append(URLQueryItem(name: "start", value: String(start.ISO8601Format().dropLast())))
                params.append(URLQueryItem(name: "end", value: String(end.ISO8601Format().dropLast())))
            } else {
                params.append(URLQueryItem(name: "start", value: NativeDay.string(startDate) + "T00:00:00"))
                params.append(URLQueryItem(name: "end", value: NativeDay.following(endDate) + "T00:00:00"))
            }
        }
        params += selected.sorted().map { URLQueryItem(name: "child_id", value: String($0)) }
        if more, let cursor { params.append(URLQueryItem(name: "cursor", value: cursor)) }
        query.queryItems = params
        do {
            let page: NativeTimelinePage = try await session.get("/timeline?" + (query.percentEncodedQuery ?? ""))
            guard ticket == generation, requestedQuery == queryKey, !Task.isCancelled else { return }
            if more {
                let existing = Set(items.map(\.stableID))
                items += page.items.filter { !existing.contains($0.stableID) }
            } else { items = page.items }
            total = page.total; cursor = page.next_cursor; loadedQuery = requestedQuery
        } catch { if ticket == generation && !Task.isCancelled { self.error = friendly(error) } }
    }
    func loadProfiles() async {
        guard !profilesLoading, let owner = session.account?.id else { return }
        profilesLoading = true
        profilesError = ""
        defer { profilesLoading = false }
        do {
            let current: [UploadProfile] = try await session.get("/children")
            guard !Task.isCancelled, session.account?.id == owner else { return }
            profiles = current
        } catch {
            if !Task.isCancelled && session.account?.id == owner { profilesError = friendly(error) }
        }
    }

    func reorder(_ source: NativeTimelineItem, relativeTo target: NativeTimelineItem) async {
        guard !usesUploadOrder, !isFocused, source.kind == "media", target.kind == "media", source.day == target.day,
              source.folder_id == target.folder_id, !loading, session.canEdit,
              let from = items.firstIndex(where: { $0.stableID == source.stableID }),
              let to = items.firstIndex(where: { $0.stableID == target.stableID }), from != to else { return }
        loading = true
        defer { loading = false }
        do {
            try await session.write("/media/reorder", method: "POST", json: [
                "media_ids": [source.id], "target_id": target.id, "placement": from < to ? "after" : "before",
            ])
            await load()
        } catch { self.error = friendly(error) }
    }
}

