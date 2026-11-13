import Foundation

@main struct MemoryReviewTests {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MemoryReviewHTTP.self]
        let session = NativeSession(site: SiteOrigin("https://example.invalid/yearly/")!, store: MemoryReviewCredentials(), transport: URLSession(configuration: config))
        await session.restore()
        let review = NativeMemoryReviewStore(session: session)
        await review.load()
        precondition(review.error.isEmpty && review.faces?.items.count == 1 && review.people.map(\.id) == [7] && review.dogs.map(\.id) == [8])
        precondition(review.faces?.items[0].frame_seconds == 2.5)
        precondition(review.subjects.count == 2, "person and pet share one list")
        precondition(Set(review.subjects.map(\.id)) == ["face-21", "pet-42-0"], "face and pet identifiers cannot collide")
        let firstFace = review.faces!.items[0]
        review.faceChoices[firstFace.id] = 7
        MemoryReviewHTTP.failWrites = true
        await review.confirm(face: firstFace, mediaID: 42)
        precondition(!review.error.isEmpty && review.faceChoices[21] == 7, "failed confirmation retains selection")
        precondition(review.autoLinkedCount == 0, "failed confirmation must not show a success alert")
        MemoryReviewHTTP.failWrites = false
        await review.confirm(face: firstFace, mediaID: 42)
        precondition(review.notice.contains("自动关联 2 张") && review.notice.contains("撤回 1 条"), "confirmation displays server-provided automatic matching counts")
        precondition(review.autoLinkedCount == 2, "each successful confirmation raises an alert only for automatic matches")
        precondition(!MemoryReviewHTTP.requests.contains { $0.url!.path.hasSuffix("/auto-link") }, "confirmation already performs automatic matching on the server")
        let confirm = MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/confirm") }!
        let assignments = MemoryReviewHTTP.body(confirm)["assignments"] as! [[String: Any]]
        precondition(confirm.httpMethod == "PUT" && assignments[0]["child_id"] as? Int == 7)
        precondition(confirm.value(forHTTPHeaderField: "X-CSRF-Token") == "synthetic-csrf")
        MemoryReviewHTTP.includeAutoCounts = false
        review.faceChoices[21] = -1; await review.confirm(face: firstFace, mediaID: 42)
        precondition(review.error.isEmpty && review.notice.contains("自动关联 0 张"), "old responses without counters still decode")
        precondition(review.autoLinkedCount == 0, "zero or missing matches must not interrupt confirmation")
        let ignored = MemoryReviewHTTP.body(MemoryReviewHTTP.requests.last { $0.httpMethod == "PUT" }!)["assignments"] as! [[String: Any]]
        precondition(ignored[0]["child_id"] is NSNull && ignored[0]["ignored"] as? Bool == true)
        let petReads = MemoryReviewHTTP.requests.filter { $0.url!.path.hasSuffix("/pets/review") }.count
        await review.page(next: true)
        precondition(MemoryReviewHTTP.requests.filter { $0.url!.path.hasSuffix("/pets/review") }.count == petReads, "finished pet pages do not repeat when faces continue")
        precondition(MemoryReviewHTTP.requests.last!.url!.query!.contains("before=21"))
        await review.page(next: false)
        precondition(!MemoryReviewHTTP.requests.last!.url!.query!.contains("before="))
        await review.autoLink(); precondition(review.notice.contains("2") && review.notice.contains("1"))
        await review.analyzeNext()
        precondition(MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("analyze-next") }!.timeoutInterval == 180)
        await review.load(reset: true)
        let dog = review.pets!.items[0].dogs[0]
        review.dogChoices["42:0"] = 8; await review.confirm(dog: dog, mediaID: 42)
        let petRequest = MemoryReviewHTTP.requests.last { $0.url!.path == "/yearly/api/pets/media/42/confirm" }!
        precondition(MemoryReviewHTTP.body(petRequest)["child_id"] as? Int == 8 && MemoryReviewHTTP.body(petRequest)["index"] as? Int == 0)
        let perMedia = NativeMemoryReviewStore(session: session, mediaID: 42)
        await perMedia.load(); precondition(MemoryReviewHTTP.requests.last!.url!.query!.contains("media_id=42"))
        await perMedia.analyzeNext(pets: true); precondition(MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/analyze") }!.url!.path == "/yearly/api/pets/media/42/analyze")
        review.tab = .memories; await review.load(reset: true); precondition(review.memories.count == 1)
        let interview = NativeMemoryInterviewStore(session: session, mediaID: 42)
        await interview.load(); precondition(interview.state?.suggestions == nil)
        await interview.prepare(); precondition(interview.tags == ["公园散步"] && interview.state?.messages.count == 1)
        precondition(MemoryReviewHTTP.requests.last!.timeoutInterval == 180)
        interview.answer = "那天是奶奶提议的。"; interview.addition = "手动编辑的小记"; interview.noteEdited = true
        interview.tags = ["我的标签"]; interview.tagsEdited = true
        MemoryReviewHTTP.failWrites = true; await interview.reply()
        precondition(!interview.error.isEmpty && interview.answer == "那天是奶奶提议的。", "failed reply keeps answer")
        MemoryReviewHTTP.failWrites = false; await interview.reply()
        precondition(interview.answer.isEmpty && interview.state?.messages.count == 3)
        precondition(interview.tags == ["我的标签"] && interview.addition == "手动编辑的小记", "follow-up does not overwrite edits")
        interview.extraTag = "手动标签"; interview.addTag(); precondition(interview.tags == ["我的标签", "手动标签"])
        MemoryReviewHTTP.failWrites = true; await interview.apply()
        precondition(interview.noteEdited && interview.addition == "手动编辑的小记")
        MemoryReviewHTTP.failWrites = false; await interview.apply()
        let applied = MemoryReviewHTTP.body(MemoryReviewHTTP.requests.last!)
        precondition(applied["remark_addition"] as? String == "手动编辑的小记" && applied["tags"] as? [String] == ["我的标签", "手动标签"])
        precondition(interview.state?.status == "completed" && !interview.noteEdited && interview.addition.isEmpty)
        review.tab = .organization; await review.load(reset: true)
        precondition(review.error.isEmpty && review.organizationQueue?.items.count == 1 && review.organizationSettings?.tags_enabled == true)
        let organizationEntry = review.organizationQueue!.items[0]
        MemoryReviewHTTP.failWrites = true
        await review.reviewOrganization(organizationEntry, action: "correct", remember: true, tags: ["公园": "户外"], childID: 0)
        precondition(!review.error.isEmpty)
        MemoryReviewHTTP.failWrites = false
        await review.reviewOrganization(organizationEntry, action: "correct", remember: true, tags: ["公园": nil], childID: 0)
        precondition(review.autoLinkedCount == 2, "review confirmation preserves automatic match alerts")
        let reviewed = MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/reviews/31") }!
        let reviewBody = MemoryReviewHTTP.body(reviewed)
        precondition(reviewBody["remember"] as? Bool == true && (reviewBody["tag_decisions"] as! [String: Any])["公园"] is NSNull)
        await review.saveOrganizationSettings(); precondition(review.error.isEmpty)
        await review.organizeBatch()
        precondition(MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/organization/run") }!.timeoutInterval == 300)
        review.organizationKind = "face"; await review.load(reset: true)
        precondition(MemoryReviewHTTP.requests.last!.url!.query!.contains("kind=face"))
        review.tab = .memories
        MemoryReviewHTTP.empty = true; await review.load(); precondition(review.memories.isEmpty && review.error.isEmpty)
        MemoryReviewHTTP.role = "member"; await session.restore()
        let count = MemoryReviewHTTP.requests.count; await review.load()
        precondition(!review.error.isEmpty && MemoryReviewHTTP.requests.count == count, "non-admin review is denied")
        print("Native AI review tests passed: face/dog confirmation and null assignment, CSRF, pagination, per-media analysis, auto-link, interview follow-up, tag/note preservation on failure and generation, apply, empty and admin access.")
    }
}
