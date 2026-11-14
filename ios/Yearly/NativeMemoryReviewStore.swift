import Foundation
import Combine

struct MemoryMatchCandidate: Decodable, Identifiable {
    let child_id: Int
    let name: String
    let similarity: Double
    let reference_thumbnail: String
    var id: Int { child_id }
}
struct MemoryReviewFace: Decodable, Identifiable {
    let id: Int
    let thumbnail: String
    let child_id: Int?
    let ignored: Bool
    let frame_seconds: Double?
    let auto_assigned: Bool?
    let candidates: [MemoryMatchCandidate]
    let media: NativeTimelineItem?
    var choice: Int { ignored ? -1 : child_id ?? 0 }
}
struct MemoryFaceQueue: Decodable {
    let enabled: Bool
    let ready: Bool
    let message: String
    let items: [MemoryReviewFace]
    let next_cursor: Int?
    let pending_faces: Int
    let pending_memories: Int
    let unanalysed_photos: Int
    let auto_link_enabled: Bool?
}
struct MemoryFaceConfirmation: Decodable {
    let auto_linked: Int
    let auto_reset: Int
}
struct MemoryDog: Decodable, Identifiable {
    let index: Int
    let thumbnail: String
    let appearance: String
    let child_id: Int?
    let ignored: Bool
    let frame_seconds: Double?
    let candidates: [MemoryMatchCandidate]
    var id: Int { index }
    var choice: Int { ignored ? -1 : child_id ?? 0 }
}
struct MemoryDogGroup: Decodable, Identifiable {
    let media: NativeTimelineItem
    let dogs: [MemoryDog]
    var id: Int { media.id }
}
struct MemoryDogQueue: Decodable {
    let items: [MemoryDogGroup]
    let pending_pets: Int
    let unanalysed_media: Int
    let next_cursor: Int?
}
enum MemoryReviewSubject: Identifiable {
    case face(MemoryReviewFace, NativeTimelineItem)
    case pet(MemoryDog, NativeTimelineItem)
    var id: String { switch self { case .face(let face, _): return "face-\(face.id)"; case .pet(let dog, let media): return "pet-\(media.id)-\(dog.index)" } }
    var mediaID: Int { switch self { case .face(_, let media), .pet(_, let media): return media.id } }
}
struct MemoryReviewCursor {
    var face: Int?
    var pet: Int?
    var memory: Int?
    var facesFinished = false
    var petsFinished = false
}

@MainActor final class NativeMemoryReviewStore: ObservableObject {
    enum Tab: String, CaseIterable { case faces = "确认人物与宠物", organization = "自动整理记录" }
    let session: NativeSession
    let mediaID: Int?
    @Published var tab = Tab.faces
    @Published var includeReviewed = false
    @Published private(set) var faces: MemoryFaceQueue?
    @Published private(set) var pets: MemoryDogQueue?
    @Published private(set) var profiles: [UploadProfile] = []
    @Published private(set) var busy = false
    @Published private(set) var error = ""
    @Published private(set) var notice = ""
    @Published var autoLinkedCount = 0
    @Published private(set) var subjects: [MemoryReviewSubject] = []
    @Published private(set) var nextCursor: MemoryReviewCursor?
    @Published private(set) var history: [MemoryReviewCursor] = []
    @Published var organizationSettings: MemoryOrganizationSettings?
    @Published private(set) var organizationQueue: MemoryOrganizationQueue?
    @Published var organizationKind = ""
    @Published var faceChoices: [Int: Int] = [:]
    @Published var dogChoices: [String: Int] = [:]
    private var before = MemoryReviewCursor()
    init(session: NativeSession, mediaID: Int? = nil, tab: Tab = .faces) {
        self.session = session; self.mediaID = mediaID; self.tab = tab
    }
    var people: [UploadProfile] { profiles.filter { $0.profile_type != "pet" } }
    var dogs: [UploadProfile] { profiles.filter { $0.profile_type == "pet" && $0.species == "狗" } }
    private func fetch() async throws {
        guard session.isAdmin else { throw NativeAPIError(status: 403, message: "整理照片需要管理员权限。") }
        profiles = try await session.get("/children", refresh: true)
        let query = "scope=\(includeReviewed ? "all" : "pending")&limit=12"
        let filter = mediaID.map { "&media_id=\($0)" } ?? ""
        switch tab {
        case .faces:
            var items: [MemoryReviewSubject] = []
            var next = before
            if !before.facesFinished {
                let previous = Dictionary(uniqueKeysWithValues: (faces?.items ?? []).map { ($0.id, $0.choice) })
                let data: MemoryFaceQueue = try await session.get("/faces/review?" + query + filter + (before.face.map { "&before=\($0)" } ?? ""))
                faces = data; next.face = data.next_cursor; next.facesFinished = data.next_cursor == nil
                for face in data.items {
                    if faceChoices[face.id] == nil || faceChoices[face.id] == previous[face.id] { faceChoices[face.id] = face.choice }
                    if let media = face.media { items.append(.face(face, media)) }
                }
            }
            if !before.petsFinished {
                let previous = Dictionary(uniqueKeysWithValues: (pets?.items ?? []).flatMap { group in group.dogs.map { ("\(group.id):\($0.index)", $0.choice) } })
                let data: MemoryDogQueue = try await session.get("/pets/review?" + query + filter + (before.pet.map { "&before=\($0)" } ?? ""))
                pets = data; next.pet = data.next_cursor; next.petsFinished = data.next_cursor == nil
                for group in data.items { for dog in group.dogs where includeReviewed || (dog.child_id == nil && !dog.ignored) {
                    let key = "\(group.id):\(dog.index)"
                    if dogChoices[key] == nil || dogChoices[key] == previous[key] { dogChoices[key] = dog.choice }
                    items.append(.pet(dog, group.media))
                } }
            }
            subjects = items.sorted { $0.mediaID == $1.mediaID ? $0.id < $1.id : $0.mediaID > $1.mediaID }
            nextCursor = next.facesFinished && next.petsFinished ? nil : next
        case .organization:
            organizationSettings = try await session.get("/organization/settings", refresh: true)
            let data: MemoryOrganizationQueue = try await session.get("/organization/reviews?" + query + filter
                + (before.memory.map { "&before=\($0)" } ?? "") + (organizationKind.isEmpty ? "" : "&kind=\(organizationKind)"), refresh: true)
            organizationQueue = data; nextCursor = data.next_cursor.map { MemoryReviewCursor(memory: $0) }
        }
    }

    func load(reset: Bool = false) async {
        if reset { before = MemoryReviewCursor(); history = []; nextCursor = nil; notice = "" }
        busy = true; error = ""
        defer { busy = false }
        do { try await fetch() } catch { if !Task.isCancelled { self.error = friendly(error) } }
    }
    func page(next: Bool) async {
        let oldBefore = before, oldHistory = history
        if next { history.append(before); before = nextCursor ?? MemoryReviewCursor() }
        else { before = history.popLast() ?? MemoryReviewCursor() }
        await load()
        if !error.isEmpty { before = oldBefore; history = oldHistory }
    }
    func confirm(face: MemoryReviewFace, mediaID: Int) async {
        busy = true; error = ""; notice = ""; autoLinkedCount = 0
        defer { busy = false }
        let choice = faceChoices[face.id] ?? face.choice
        do {
            let result: MemoryFaceConfirmation = try await session.put("/faces/media/\(mediaID)/confirm", json: ["assignments": [["face_id": face.id,
                "child_id": choice > 0 ? choice as Any : NSNull(), "ignored": choice == -1]]])
            faceChoices.removeValue(forKey: face.id)
            autoLinkedCount = result.auto_linked
            notice = "人脸确认已保存，另自动关联 \(result.auto_linked) 张相关人脸。"
            if result.auto_reset > 0 { notice += "另撤回 \(result.auto_reset) 条不再明确的自动关联。" }
            try await fetch()
        } catch { self.error = friendly(error) }
    }
    func confirm(dog: MemoryDog, mediaID: Int) async {
        busy = true; error = ""; notice = ""
        defer { busy = false }
        let key = "\(mediaID):\(dog.index)", choice = dogChoices["\(mediaID):\(dog.index)"] ?? dog.choice
        do {
            try await session.write("/pets/media/\(mediaID)/confirm", json: ["index": dog.index,
                "child_id": choice > 0 ? choice as Any : NSNull(), "ignored": choice == -1])
            dogChoices.removeValue(forKey: key); notice = "宠物确认已保存，已建立后续匹配的参考样本。"
            try await fetch()
        } catch { self.error = friendly(error) }
    }
    func loadOrganizationSettings() async {
        busy = true; error = ""
        defer { busy = false }
        do {
            guard session.isAdmin else { throw NativeAPIError(status: 403, message: "整理照片需要管理员权限。") }
            profiles = try await session.get("/children", refresh: true)
            organizationSettings = try await session.get("/organization/settings", refresh: true)
        } catch { self.error = friendly(error) }
    }
    func saveOrganizationSettings() async {
        guard let settings = organizationSettings else { return }
        busy = true; error = ""; notice = ""
        defer { busy = false }
        do {
            organizationSettings = try await session.put("/organization/settings", json: settings.json)
            notice = "自动整理习惯已保存，仅影响后续处理；所有记录保留。"
        } catch { self.error = friendly(error) }
    }
    func reviewOrganization(_ entry: MemoryOrganizationEntry, action: String, remember: Bool, tags: [String: String?], childID: Int) async {
        busy = true; error = ""; notice = ""
        defer { busy = false }
        var body: [String: Any] = ["action": action, "remember": remember]
        if entry.kind == "tags" { body["tag_decisions"] = tags.mapValues { value -> Any in value.map { $0 as Any } ?? NSNull() } }
        else { body["child_id"] = childID > 0 ? childID as Any : NSNull() }
        do {
            let result: MemoryOrganizationEntry = try await session.put("/organization/reviews/\(entry.id)", json: body)
            autoLinkedCount = result.auto_linked ?? 0
            notice = "审核已保存，变更与处理习惯已记录。"
            try await fetch()
        } catch { self.error = friendly(error) }
    }
    func organizeBatch(retry: Bool = false) async {
        busy = true; error = ""; notice = ""
        defer { busy = false }
        struct Result: Decodable { let processed: Int; let busy: Bool }
        do {
            let result: Result = try await session.post("/organization/run?limit=3&retry_failed=\(retry)", json: [:])
            notice = result.busy ? "后台正在自动整理，请稍后刷新审核列表。" : "已处理 \(result.processed) 份影像，后续由后台继续整理。"
            try await fetch()
        } catch { self.error = friendly(error) }
    }
    func analyzeNext(pets: Bool = false) async {
        busy = true; error = ""; notice = ""
        defer { busy = false }
        struct Batch: Decodable {
            struct Failure: Decodable { let message: String }
            let processed: [Int]
            let failed: [Failure]?
        }
        do {
            if let mediaID {
                try await session.write("/\(pets ? "pets" : "faces")/media/\(mediaID)/analyze", method: "POST", json: [:])
                notice = "当前影像分析完成。"; try await fetch(); return
            }
            let result: Batch = try await session.post(pets ? "/pets/analyze-next" : "/faces/analyze-next?limit=5", json: [:])
            notice = "本次已分析 \(result.processed.count) 份影像。"
            try await fetch()
            error = result.failed?.map(\.message).joined(separator: "；") ?? ""
        } catch { self.error = friendly(error) }
    }
    func autoLink() async {
        busy = true; error = ""; notice = ""
        defer { busy = false }
        struct Result: Decodable { let linked_faces: Int; let reset_faces: Int? }
        do {
            let result: Result = try await session.post("/faces/auto-link", json: [:])
            notice = "已自动关联 \(result.linked_faces) 张人脸，撤回 \(result.reset_faces ?? 0) 条不再明确的关联。"
            faceChoices = [:]; before = MemoryReviewCursor(); history = []; try await fetch()
        } catch { self.error = friendly(error) }
    }
}

struct MemoryOrganizationSettings: Codable {
    struct TagRule: Codable { var target: String; var mode: String }
    var tags_enabled: Bool
    var people_enabled: Bool
    var tag_rules: [String: TagRule]
    var person_rules: [String: String]
    var json: [String: Any] {
        ["tags_enabled": tags_enabled, "people_enabled": people_enabled,
         "tag_rules": tag_rules.mapValues { ["target": $0.target, "mode": $0.mode] }, "person_rules": person_rules]
    }
}
struct MemoryOrganizationValue: Decodable {
    let tags: [String]?
    let decisions: [String: String?]?
    let child_id: Int?
    let ignored: Bool?
    let remember: Bool?
}
struct MemoryOrganizationEntry: Decodable, Identifiable {
    struct Evidence: Decodable {
        struct Tag: Decodable { let name: String; let evidence: String; let rule: String }
        let tags: [Tag]?
        let reason: String?
        let similarity: Double?
        let model: String?
        let description: String?
    }
    struct Event: Decodable { let action: String; let at: String; let actor_name: String; let value: MemoryOrganizationValue }
    let id: Int
    let kind: String
    let status: String
    let automatic: Bool
    let media: NativeTimelineItem
    let before: MemoryOrganizationValue
    let proposed: MemoryOrganizationValue
    let current: MemoryOrganizationValue
    let evidence: Evidence
    let events: [Event]
    let names: [String: String]
    let thumbnail: String
    let frame_seconds: Double?
    let created_at: String
    let updated_at: String
    let auto_linked: Int?
    let auto_reset: Int?
    var title: String { kind == "tags" ? "自动标签" : kind == "pet" ? "宠物关联" : "人物关联" }
    static func statusLabel(_ value: String) -> String {
        ["imported": "补录现有结果", "applied": "自动写入", "pending": "待审核", "automatic": "已自动确认", "approved": "已审核", "corrected": "已修改", "rejected": "已撤回", "superseded": "已有后续修改", "confirmed": "人工确认"][value] ?? value
    }
}
struct MemoryOrganizationQueue: Decodable {
    struct Failure: Decodable { let media_id: Int; let message: String }
    let items: [MemoryOrganizationEntry]
    let pending: Int
    let next_cursor: Int?
    let errors: [Failure]
}

// Manual media organization is independent of face identity review.
struct NativeCurationQuality: Decodable {
    struct Frame: Decodable, Identifiable {
        let frame: Int
        let clarity: Int
        let reason: String
        var id: Int { frame }
    }
    let frames: [Frame]
    let representative: Int
    let seconds: [Double?]
    let thumbnail: String
    var representativeSeconds: Double? { seconds.indices.contains(representative) ? seconds[representative] : nil }
}
struct NativeCurationItem: Decodable, Identifiable {
    let media: NativeTimelineItem
    var quality: NativeCurationQuality?
    var id: Int { media.id }
}
struct NativeCurationGroup: Decodable, Identifiable {
    let key: String
    let kind: String
    var items: [NativeCurationItem]
    var id: String { key }
    var label: String { kind == "duplicate" ? "完全重复内容" : kind == "capture" ? "拍摄时间接近" : items.first?.media.media_type == "video" ? "一段视频" : "一份影像" }
}
struct NativeCurationQueue: Decodable {
    var items: [NativeCurationGroup]
    let next_cursor: Int?
    let group_count: Int
    let unfiled_media: Int
    let total_media: Int
    let quality_enabled: Bool
}
@MainActor final class NativeCurationStore: ObservableObject {
    let session: NativeSession
    @Published var scope = "unfiled"
    @Published var selected: Set<Int> = []
    @Published var selectedProfiles: Set<Int> = []
    @Published private(set) var queue: NativeCurationQueue?
    @Published private(set) var profiles: [UploadProfile] = []
    @Published private(set) var busy = false
    @Published private(set) var reviewing = false
    @Published private(set) var error = ""
    @Published private(set) var notice = ""
    @Published private(set) var undoToken: String?
    @Published private(set) var history: [Int?] = []
    var stopRequested = false
    private var before: Int?
    init(session: NativeSession) { self.session = session }
    var pageIDs: [Int] { queue?.items.flatMap { $0.items.map(\.id) } ?? [] }
    var selectedAlbumNames: String { profiles.filter { selectedProfiles.contains($0.id) }.map(\.name).joined(separator: "、") }
    func toggle(_ ids: [Int]) {
        if ids.allSatisfy({ selected.contains($0) }) { selected.subtract(ids) }
        else { selected.formUnion(ids) }
    }
    private func fetch() async throws {
        guard session.isAdmin else { throw NativeAPIError(status: 403, message: "相册整理需要管理员权限。") }
        profiles = try await session.get("/children", refresh: true)
        let result: NativeCurationQueue = try await session.get("/curation/groups?scope=\(scope)&limit=24" + (before.map { "&before=\($0)" } ?? ""), refresh: true)
        queue = result
        selected.formIntersection(pageIDs)
        selectedProfiles.formIntersection(profiles.map(\.id))
    }
    func load(reset: Bool = false) async {
        if reset { before = nil; history = [] }
        busy = true; error = ""; defer { busy = false }
        do { try await fetch(); if reset { selected = []; selectedProfiles = [] } } catch { self.error = friendly(error) }
    }
    func page(next: Bool) async {
        let oldBefore = before, oldHistory = history
        if next { history.append(before); before = queue?.next_cursor }
        else { before = history.popLast() ?? nil }
        await load()
        if !error.isEmpty { before = oldBefore; history = oldHistory }
    }
    @discardableResult func save(action: String) async -> Bool {
        guard !selected.isEmpty, !busy else { return false }
        guard session.isAdmin else { error = "整理照片需要管理员权限。"; return false }
        guard ["add", "done", "ignore"].contains(action) else { return false }
        guard selected.count <= 300 else { error = "每次最多整理 300 项，请减少选择。"; return false }
        guard action != "add" || !selectedProfiles.isEmpty else { error = "请先选择要添加到的相册。"; return false }
        busy = true; error = ""; notice = ""; defer { busy = false }
        struct Result: Decodable { let count: Int; let undo_token: String }
        let albums = selectedAlbumNames
        do {
            let result: Result = try await session.post("/curation/batch", json: ["media_ids": selected.sorted(), "child_ids": action == "add" ? selectedProfiles.sorted() : [], "action": action])
            undoToken = result.undo_token
            switch action {
            case "add": notice = "已将 \(result.count) 项添加到\(albums)，并标记为已整理。"
            case "done": notice = "已将 \(result.count) 项标记为已整理，所属相册未改变。"
            default: notice = "已将 \(result.count) 项移出待整理列表，照片仍保留在时间线和原相册中。"
            }
            selected = []; selectedProfiles = []
        } catch { self.error = friendly(error); return false }
        // A committed write must not look like a failed save if the refresh fails.
        do { try await fetch() }
        catch { self.error = "保存成功，但列表刷新失败。请重新加载。" }
        return true
    }
    func undo() async {
        guard let token = undoToken, !busy else { return }
        busy = true; error = ""; defer { busy = false }
        do {
            try await session.write("/curation/undo/\(token)", method: "POST", json: [:])
            undoToken = nil; notice = "已撤销上次整理。"; try await fetch()
        } catch { self.error = error.localizedDescription }
    }
    func reviewQuality() async {
        let ids = selected.sorted()
        guard !busy, !ids.isEmpty else { return }
        guard ids.count <= 20 else { error = "每次最多检查 20 项，请减少选择。"; return }
        busy = true; reviewing = true; stopRequested = false; error = ""; notice = ""
        defer { busy = false; reviewing = false }
        var completed = 0
        do {
            for id in ids {
                if stopRequested || Task.isCancelled { break }
                let result: NativeCurationQuality = try await session.post("/curation/media/\(id)/quality", json: [:])
                if var data = queue {
                    for g in data.items.indices { for i in data.items[g].items.indices where data.items[g].items[i].id == id {
                        data.items[g].items[i].quality = result
                    } }
                    queue = data
                }
                completed += 1; notice = "已检查 \(completed)/\(ids.count) 项，可在照片下方展开清晰度结果。"
            }
        } catch { self.error = error.localizedDescription }
    }
}
