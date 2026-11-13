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
    let auto_linked: Int?
    let auto_reset: Int?
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
struct MemoryInterviewQueue: Decodable {
    let items: [NativeTimelineItem]
    let next_cursor: Int?
}
struct MemoryInterviewState: Decodable {
    struct Message: Decodable { let role: String; let content: String }
    struct IdentityQuestion: Decodable { let face_id: Int; let question: String }
    struct Tag: Decodable, Identifiable {
        let name: String
        let source: String
        let evidence: String
        var id: String { name }
        var sourceLabel: String { ["visual": "画面描述", "answer": "你的回答", "existing": "已有记录"][source] ?? source }
    }
    struct Suggestions: Decodable {
        let question: String
        let options: [String]
        let story: String
        let tags: [Tag]
    }
    let media: NativeTimelineItem
    let description: String
    let confirmed_people: [String]
    let confirmed_pets: [String]?
    let identity_questions: [IdentityQuestion]
    let faces: [MemoryReviewFace]
    let face_enabled: Bool
    let face_ready: Bool
    let messages: [Message]
    let status: String
    let outdated: Bool
    let suggestions: Suggestions?
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
    enum Tab: String, CaseIterable { case faces = "人物与宠物", memories = "智能打标签", organization = "审核记录" }
    let session: NativeSession
    let mediaID: Int?
    @Published var tab = Tab.faces
    @Published var includeReviewed = false
    @Published private(set) var faces: MemoryFaceQueue?
    @Published private(set) var pets: MemoryDogQueue?
    @Published private(set) var memories: [NativeTimelineItem] = []
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
        guard session.isAdmin else { throw NativeAPIError(status: 403, message: "AI 整理需要管理员权限。") }
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
        case .memories:
            let data: MemoryInterviewQueue = try await session.get("/memory-interviews?" + query + (before.memory.map { "&before=\($0)" } ?? ""))
            memories = data.items; nextCursor = data.next_cursor.map { MemoryReviewCursor(memory: $0) }
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
            autoLinkedCount = result.auto_linked ?? 0
            notice = "人脸确认已保存，另自动关联 \(result.auto_linked ?? 0) 张相关人脸。"
            if let reset = result.auto_reset, reset > 0 { notice += "另撤回 \(reset) 条不再明确的自动关联。" }
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

@MainActor final class NativeMemoryInterviewStore: ObservableObject {
    let session: NativeSession
    let mediaID: Int
    @Published private(set) var state: MemoryInterviewState?
    @Published private(set) var profiles: [UploadProfile] = []
    @Published private(set) var busy = false
    @Published private(set) var error = ""
    @Published private(set) var notice = ""
    @Published var answer = ""
    @Published var addition = ""
    @Published var extraTag = ""
    @Published var tags: [String] = []
    @Published var people: [Int] = []
    @Published var tagsEdited = false
    @Published var noteEdited = false
    @Published var peopleEdited = false
    var hasEdits: Bool { !answer.isEmpty || !extraTag.isEmpty || tagsEdited || noteEdited || peopleEdited }
    init(session: NativeSession, mediaID: Int) { self.session = session; self.mediaID = mediaID }
    private func accept(_ value: MemoryInterviewState, generated: Bool = false) {
        let first = state == nil
        state = value
        if !peopleEdited { people = value.media.child_ids ?? [] }
        if first || generated {
            if !tagsEdited { tags = value.suggestions?.tags.map(\.name) ?? [] }
            if !noteEdited { addition = value.suggestions?.story ?? "" }
        }
    }
    func load() async {
        busy = true; error = ""
        defer { busy = false }
        do {
            profiles = try await session.get("/children", refresh: true)
            accept(try await session.get("/memory-interviews/\(mediaID)"))
        } catch { if !Task.isCancelled { self.error = friendly(error) } }
    }
    func prepare() async {
        busy = true; error = ""; notice = ""
        defer { busy = false }
        do { accept(try await session.post("/memory-interviews/\(mediaID)/prepare", json: ["refresh": state?.outdated == true || state?.status == "completed"]), generated: true) }
        catch { self.error = friendly(error) }
    }
    func reply() async {
        busy = true; error = ""; notice = ""
        defer { busy = false }
        do {
            accept(try await session.post("/memory-interviews/\(mediaID)/reply", json: ["answer": answer]), generated: true)
            answer = ""
        } catch { self.error = friendly(error) }
    }
    func savePeople() async {
        busy = true; error = ""
        defer { busy = false }
        do {
            try await session.write("/memory-interviews/\(mediaID)/people", json: ["child_ids": people])
            peopleEdited = false
            accept(try await session.get("/memory-interviews/\(mediaID)"))
            notice = "人物关联已保存；每张脸的身份仍可单独确认。"
        } catch { self.error = friendly(error) }
    }
    func addTag() {
        let tag = extraTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tag.isEmpty && !tags.contains(tag) && !(state?.media.tags ?? []).contains(tag) { tags.append(tag) }
        extraTag = ""; tagsEdited = true
    }
    func apply() async {
        busy = true; error = ""; notice = ""
        defer { busy = false }
        do {
            let value: MemoryInterviewState = try await session.post("/memory-interviews/\(mediaID)/apply", json: ["tags": tags, "remark_addition": addition])
            accept(value); addition = ""; tags = []; tagsEdited = false; noteEdited = false
            notice = "标签和小记已保存。"
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
        ["imported": "补录现有结果", "applied": "自动写入", "pending": "待审核", "automatic": "按习惯自动通过", "approved": "已审核", "corrected": "已修改", "rejected": "已撤回", "superseded": "已有后续修改", "confirmed": "人工确认"][value] ?? value
    }
}
struct MemoryOrganizationQueue: Decodable {
    struct Failure: Decodable { let media_id: Int; let message: String }
    let items: [MemoryOrganizationEntry]
    let pending: Int
    let next_cursor: Int?
    let errors: [Failure]
}
