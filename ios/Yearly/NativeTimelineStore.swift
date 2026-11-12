import Foundation
import Combine

struct NativeMediaFile: Decodable, Identifiable {
    let id: Int
    let file_role: String
    let original_filename: String
    let mime_type: String
    let file_size: Int64
    let sha256: String?
    let crc64: String?
}
struct NativeMediaMetadata: Decodable {
    let parser_name: String?
    let parser_version: String?
    let parse_status: String?
}
struct NativeMediaPosition: Decodable {
    var index: Int
    var total: Int
    var day_index: Int
    var day_total: Int

    mutating func remove(_ deleted: Self, sameDay: Bool) {
        total -= 1
        if index > deleted.index { index -= 1 }
        if sameDay {
            day_total -= 1
            if day_index > deleted.day_index { day_index -= 1 }
        }
    }
}
struct NativeTimelineItem: Decodable, Identifiable {
    let id: Int
    var can_edit: Bool?
    var owner_id: Int?
    var created_by: Int?
    var owner_name: String?
    var updated_by_name: String?
    var updated_at: String?
    func editable(by account: UploadAccount?) -> Bool {
        account?.canEdit(ownerID: owner_id ?? created_by, allowed: can_edit) ?? false
    }
    var kind: String?
    var title: String?
    var batch_name: String?
    var media_type: String?
    var timeline_day: String?
    var timeline_date: String?
    var uploaded_at: String?
    var taken_at_local: String?
    var taken_offset_minutes: Int?
    var time_source: String?
    var width: Int?
    var height: Int?
    var device_make: String?
    var device_model: String?
    var metadata: NativeMediaMetadata?
    var start_at: String?
    var end_at: String?
    var content: String?
    var cover_media_id: Int?
    var media_ids: [Int]?
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
    var media_position: NativeMediaPosition?
    var stableID: String { "\(kind ?? "media")-\(id)" }
    var label: String { [title, batch_name].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "珍藏的瞬间" }
    var day: String { String((timeline_day ?? timeline_date ?? taken_at_local ?? start_at ?? "日期未知").prefix(10)) }
    var previewDateTime: String {
        if time_unknown != true, let capture = corrected_taken_at_local ?? taken_at_local,
           capture.count >= 19 {
            // Capture timestamps are local wall-clock values, not UTC instants.
            return String(capture.prefix(19)).replacingOccurrences(of: "T", with: " ")
        }
        return day
    }
    var uploadDate: Date? {
        guard let uploaded_at else { return nil }
        let utc = uploaded_at + "Z" // The server stores upload timestamps as UTC without a suffix.
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(utc))
            ?? (try? Date.ISO8601FormatStyle().parse(utc))
    }
    var primary: NativeMediaFile? { files?.first { $0.file_role == "original" } }
    var motion: NativeMediaFile? { files?.first { $0.file_role == "live_video" } }
}
struct NativeTimelinePage: Decodable {
    let items: [NativeTimelineItem]
    let total: Int
    let next_cursor: String?
    let previous_cursor: String?
    let day_sharing: [String: Bool]?
    let dates: [String]?
}
struct NativeUploader: Decodable, Identifiable {
    let id: Int
    let username: String
    var nickname: String? = nil
    var displayName: String { if let nickname, !nickname.isEmpty { return nickname }; return username }
}
struct NativeMediaResource: Decodable { let url: String?; let status: String; let message: String? }

// Calendar positions stay independent of pagination and the number of photos in each day.
struct NativeTimelineScale {
    let days: [String]
    private let positions: [Double]
    private let ratios: [String: Double]

    init(days: [String]) {
        let datedDays = days.compactMap { day in
            (try? Date.ISO8601FormatStyle().parse(day + "T00:00:00Z")).map { (day, $0.timeIntervalSinceReferenceDate) }
        }
        self.days = datedDays.map { $0.0 }
        let start = datedDays.first?.1 ?? 0
        let span = (datedDays.last?.1 ?? start) - start
        positions = datedDays.map { span == 0 ? 0 : ($0.1 - start) / span }
        ratios = Dictionary(zip(self.days, positions), uniquingKeysWith: { first, _ in first })
    }

    func ratio(for day: String) -> Double {
        ratios[day] ?? 0
    }

    func nearest(to ratio: Double) -> String? {
        guard !days.isEmpty else { return nil }
        var lower = 0
        var upper = days.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if positions[middle] < ratio { lower = middle + 1 }
            else { upper = middle }
        }
        if lower > 0 && abs(positions[lower - 1] - ratio) <= abs(positions[lower] - ratio) { lower -= 1 }
        return days[lower]
    }

    func markers(height: Double) -> [String] {
        let count = min(days.count, max(2, Int(height / 44) + 1))
        guard count > 1 else { return days }
        let sampled = Set((0..<count).compactMap { nearest(to: Double($0) / Double(count - 1)) })
        var markers = [days[0]]
        for day in days.dropFirst().dropLast() where sampled.contains(day) {
            let position = ratio(for: day)
            if (position - ratio(for: markers.last!)) * height >= 44 && (1 - position) * height >= 44 {
                markers.append(day)
            }
        }
        markers.append(days.last!)
        return markers
    }
}

@MainActor final class NativeTimelineStore: ObservableObject {
    private enum Page { case first, older, newer }
    @Published var items: [NativeTimelineItem] = [] { didSet { groupedCache = nil } }
    @Published var profiles: [UploadProfile] = []
    @Published private(set) var profilesLoading = false
    @Published private(set) var profilesError = ""
    @Published var uploaders: [NativeUploader] = []
    @Published var uploaderID: Int?
    @Published private(set) var uploadersError = ""
    @Published private(set) var uploadersLoading = false
    @Published var selected: Set<Int> = []
    @Published var search = ""
    @Published var mediaType = ""
    @Published var ascending = false
    @Published private(set) var byUpload = false { didSet { groupedCache = nil } }
    @Published var useDateRange = false
    @Published var startDate = Date()
    @Published var endDate = Date()
    @Published private(set) var uploadedMediaIDs: [Int] = [] { didSet { groupedCache = nil } }
    @Published private(set) var anchorMediaID: Int? { didSet { groupedCache = nil } }
    @Published private var dateAnchor: (day: String, filters: String)?
    @Published private(set) var dates: [String] = []
    @Published private(set) var archiveExpanded = false
    @Published private(set) var hasNewer = false
    @Published private(set) var daySharing: [String: Bool] = [:]
    var showingUploads: Bool { !uploadedMediaIDs.isEmpty }
    var usesUploadOrder: Bool { byUpload && !showingUploads && anchorMediaID == nil }
    var isFocused: Bool { showingUploads || anchorMediaID != nil }
    var anchorDay: String? { dateAnchor?.filters == filterKey ? dateAnchor?.day : nil }
    private var groupedCache: [String: [NativeTimelineItem]]?
    var groupedItems: [String: [NativeTimelineItem]] {
        if let groupedCache { return groupedCache }
        let groups = Dictionary(grouping: items, by: groupDay)
        groupedCache = groups
        return groups
    }
    var railDays: [String] {
        orderedDays(Set(dates).union(groupedItems.keys.filter { $0 != "日期未知" }))
    }
    func groupDay(_ item: NativeTimelineItem) -> String {
        guard usesUploadOrder else { return item.day }
        return item.uploadDate.map(NativeDay.string) ?? "日期未知"
    }
    func orderedDays<S: Sequence>(_ days: S) -> [String] where S.Element == String {
        days.sorted { a, b in
            if a == b || a == "日期未知" { return false }
            if b == "日期未知" { return true }
            return ascending ? a < b : a > b
        }
    }
    func mediaPages(_ items: [NativeTimelineItem]) -> [NativeTimelineItem] {
        let groups = Dictionary(grouping: items.filter { $0.kind == "media" }, by: groupDay)
        return orderedDays(groups.keys).flatMap { groups[$0] ?? [] }
    }
    private var filterKey: String {
        if showingUploads { return "uploads|\(uploadedMediaIDs)" }
        return "\(uploaderID ?? 0)|\(selected.sorted())|\(search)|\(mediaType)|\(ascending)|\(byUpload)|\(anchorMediaID ?? 0)|\(useDateRange)|\(NativeDay.string(startDate))|\(NativeDay.string(endDate))"
    }
    var queryKey: String { filterKey + "|" + (anchorDay ?? "") }
    var hasFilters: Bool { uploaderID != nil || !selected.isEmpty || !search.isEmpty || !mediaType.isEmpty || useDateRange }
    func resetFilters() { uploaderID = nil; selected = []; search = ""; mediaType = ""; useDateRange = false }

    @Published var loading = false
    @Published var error = ""
    @Published var total = 0
    @Published private(set) var cursor: String?
    private var previousCursor: String?
    private var generation = 0
    private var loadedQuery = ""
    let session: NativeSession
    init(session: NativeSession) { self.session = session }
    func focusOnUploads(_ ids: [Int]) {
        let ids = Set(ids.filter { $0 > 0 }).sorted()
        guard uploadedMediaIDs != ids || anchorMediaID != nil || anchorDay != nil else { return }
        anchorMediaID = nil
        dateAnchor = nil
        resetResults()
        loading = !ids.isEmpty
        uploadedMediaIDs = ids
    }
    private func resetResults() {
        generation += 1
        items = []; total = 0; cursor = nil; loadedQuery = ""; loading = false; error = ""
        archiveExpanded = false; hasNewer = false; previousCursor = nil
        daySharing = [:]
        dates = []
    }
    func locate(_ item: NativeTimelineItem, expandingArchive: Bool = false) {
        resetFilters()
        byUpload = false
        ascending = false
        uploadedMediaIDs = []
        anchorMediaID = item.id
        dateAnchor = nil
        resetResults()
        archiveExpanded = expandingArchive
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
        dateAnchor = nil
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
        resetResults()
        profiles = []
        uploaders = []
        uploadersError = ""
        profilesError = ""
        uploadedMediaIDs = []
        anchorMediaID = nil
        dateAnchor = nil
        byUpload = false
        resetFilters()
    }
    func loadIfNeeded() async {
        guard loadedQuery != queryKey else { return }
        await load()
    }
    func load(more: Bool = false, refresh: Bool = false) async {
        if !more, let dateAnchor, dateAnchor.filters != filterKey { self.dateAnchor = nil }
        await loadPage(more ? .older : .first, refresh: refresh)
        if !more && archiveExpanded && error.isEmpty { await loadNewer() }
    }
    func expandArchive() async {
        guard anchorMediaID != nil, !archiveExpanded, !loading, loadedQuery == queryKey else { return }
        archiveExpanded = true
        hasNewer = true
        await loadNewer()
    }
    func jump(to day: String) {
        guard !loading, railDays.contains(day) else { return }
        // Keep filters and the date index; only replace the loaded cursor window.
        dateAnchor = (day, filterKey)
        archiveExpanded = true
        previousCursor = nil
    }
    func loadNewer() async {
        guard archiveExpanded, hasNewer else { return }
        await loadPage(.newer)
    }

    private var timelineFilters: [URLQueryItem] {
        var params = [URLQueryItem(name: "group_folders", value: "false"), URLQueryItem(name: "order", value: ascending ? "asc" : "desc")]
        if usesUploadOrder {
            params.append(URLQueryItem(name: "date_basis", value: "upload"))
            params.append(URLQueryItem(name: "timezone_offset_minutes", value: String(TimeZone.current.secondsFromGMT() / 60)))
        }
        if let anchorMediaID { params.append(URLQueryItem(name: "anchor_media_id", value: String(anchorMediaID))) }
        if let anchorDay { params.append(URLQueryItem(name: "anchor_day", value: anchorDay)) }
        let queryText = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if !queryText.isEmpty { params.append(URLQueryItem(name: "q", value: queryText)) }
        if ["photo", "video", "live_photo"].contains(mediaType) { params.append(URLQueryItem(name: "media_type", value: mediaType)) }
        if let uploaderID { params.append(URLQueryItem(name: "owner_id", value: String(uploaderID))) }
        params += selected.sorted().map { URLQueryItem(name: "child_id", value: String($0)) }
        return params
    }

    private func uploadRange(_ start: Date, _ end: Date) -> [URLQueryItem] {
        let calendar = Calendar(identifier: .gregorian)
        let first = calendar.startOfDay(for: start)
        let last = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
        return [
            URLQueryItem(name: "start", value: String(first.ISO8601Format().dropLast())),
            URLQueryItem(name: "end", value: String(last.ISO8601Format().dropLast())),
        ]
    }

    func uploadDayTotal(_ day: String) async throws -> Int? {
        guard usesUploadOrder, let date = NativeDay.date(day) else { return nil }
        let request = queryKey
        var query = URLComponents()
        query.queryItems = timelineFilters + uploadRange(date, date) + [URLQueryItem(name: "page_size", value: "1")]
        let result: NativeTimelinePage = try await session.get("/timeline?" + (query.percentEncodedQuery ?? ""))
        return request == queryKey ? result.total : nil
    }

    private func loadPage(_ direction: Page, refresh: Bool = false) async {
        if direction != .first && (loading || loadedQuery != queryKey) { return }
        if direction == .older && cursor == nil { return }
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
        var params = timelineFilters + [URLQueryItem(name: "page_size", value: "40")]
        if direction == .first && !isFocused { params.append(URLQueryItem(name: "include_dates", value: "true")) }
        if !usesUploadOrder { params.append(URLQueryItem(name: "media_positions", value: "true")) }
        if useDateRange {
            if usesUploadOrder {
                params += uploadRange(startDate, endDate)
            } else {
                params.append(URLQueryItem(name: "start", value: NativeDay.string(startDate) + "T00:00:00"))
                params.append(URLQueryItem(name: "end", value: NativeDay.following(endDate) + "T00:00:00"))
            }
        }
        if direction == .newer { params.append(URLQueryItem(name: "before", value: "true")) }
        let position = direction == .newer ? previousCursor : direction == .older ? cursor : nil
        if let position { params.append(URLQueryItem(name: "cursor", value: position)) }
        query.queryItems = params
        do {
            let page: NativeTimelinePage = try await session.get("/timeline?" + (query.percentEncodedQuery ?? ""), refresh: refresh)
            guard ticket == generation, requestedQuery == queryKey, !Task.isCancelled else { return }
            let existing = Set(items.map(\.stableID))
            if direction == .first { daySharing = page.day_sharing ?? [:] }
            else { daySharing.merge(page.day_sharing ?? [:]) { _, current in current } }
            switch direction {
            case .first:
                items = page.items
                dates = page.dates ?? []
                cursor = page.next_cursor
                previousCursor = nil
                if anchorMediaID == nil { archiveExpanded = anchorDay != nil }
                hasNewer = archiveExpanded
            case .older:
                items += page.items.filter { !existing.contains($0.stableID) }
                cursor = page.next_cursor
            case .newer:
                items.insert(contentsOf: page.items.filter { !existing.contains($0.stableID) }, at: 0)
                previousCursor = page.previous_cursor
                hasNewer = previousCursor != nil
            }
            total = page.total
            loadedQuery = requestedQuery
        } catch { if ticket == generation && !Task.isCancelled { self.error = friendly(error) } }
    }

    func setDaySharing(_ day: String, allowed: Bool) async throws {
        guard session.isAdmin else { throw NativeAPIError(status: 403, message: "只有管理员可以修改当天分享设置。") }
        try await session.write("/timeline/days/\(day)/sharing", json: ["share_allowed": allowed])
        daySharing[day] = allowed
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

    func loadUploaders(refresh: Bool = false) async {
        guard !uploadersLoading, let owner = session.account?.id else { return }
        uploadersLoading = true
        uploadersError = ""
        defer { uploadersLoading = false }
        do {
            let current: [NativeUploader] = try await session.get("/uploaders", refresh: refresh)
            guard !Task.isCancelled, session.account?.id == owner else { return }
            uploaders = current
        } catch {
            if !Task.isCancelled && session.account?.id == owner { uploadersError = friendly(error) }
        }
    }

    func reorder(_ source: NativeTimelineItem, relativeTo target: NativeTimelineItem) async {
        guard !usesUploadOrder, !isFocused, source.kind == "media", target.kind == "media", source.day == target.day,
              source.folder_id == target.folder_id, !loading, source.editable(by: session.account), target.editable(by: session.account),
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


struct NativeSearchStatus: Decodable {
    let enabled: Bool
    let total: Int
    let indexed: Int
    let failed: Int
}
struct NativeSearchPage: Decodable {
    let items: [NativeTimelineItem]
    let indexed: Int
}
