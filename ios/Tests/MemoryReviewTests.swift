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
        precondition(review.pendingFaceCount == 12)
        let beforeUnchangedPoll = MemoryReviewHTTP.requests.count
        await review.refreshPendingFaceCount()
        precondition(MemoryReviewHTTP.requests.count == beforeUnchangedPoll + 1, "an unchanged count does not reload the page")
        MemoryReviewHTTP.pendingFaces = 8
        MemoryReviewHTTP.failFaceCount = true
        await review.refreshPendingFaceCount()
        precondition(review.pendingFaceCount == 12 && review.error.isEmpty, "a failed check leaves the last good count visible")
        MemoryReviewHTTP.failFaceCount = false
        MemoryReviewHTTP.failPetReviews = true
        await review.refreshPendingFaceCount()
        precondition(review.pendingFaceCount == 8 && review.faces?.pending_faces == 12, "an incomplete page reload can be retried")
        MemoryReviewHTTP.failPetReviews = false
        await review.refreshPendingFaceCount()
        precondition(review.pendingFaceCount == 8 && review.faces?.pending_faces == 8, "a background change refreshes the count and list")
        MemoryReviewHTTP.pendingFaces = 12
        await review.refreshPendingFaceCount()
        let firstFace = review.faces!.items[0]
        review.faceChoices[firstFace.id] = 7
        MemoryReviewHTTP.failWrites = true
        await review.confirm(face: firstFace, mediaID: 42)
        precondition(!review.error.isEmpty && review.faceChoices[21] == 7, "failed confirmation retains selection")
        MemoryReviewHTTP.failWrites = false
        await review.confirm(face: firstFace, mediaID: 42)
        precondition(review.notice.contains("后台会继续整理"), "confirmation reflects queued matching")
        precondition(!MemoryReviewHTTP.requests.contains { $0.url!.path.hasSuffix("/auto-link") }, "confirmation already performs automatic matching on the server")
        let confirm = MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/confirm") }!
        let assignments = MemoryReviewHTTP.body(confirm)["assignments"] as! [[String: Any]]
        precondition(confirm.httpMethod == "PUT" && assignments[0]["child_id"] as? Int == 7)
        precondition(confirm.value(forHTTPHeaderField: "X-CSRF-Token") == "synthetic-csrf")
        MemoryReviewHTTP.omitMatchingQueued = true
        review.faceChoices[21] = -1; await review.confirm(face: firstFace, mediaID: 42)
        precondition(!review.error.isEmpty, "confirmation requires the current response fields")
        MemoryReviewHTTP.omitMatchingQueued = false
        let ignored = MemoryReviewHTTP.body(MemoryReviewHTTP.requests.last { $0.httpMethod == "PUT" }!)["assignments"] as! [[String: Any]]
        precondition(ignored[0]["child_id"] is NSNull && ignored[0]["ignored"] as? Bool == true)
        let rejected = await review.confirm(face: firstFace, mediaID: 42, rejecting: 7)
        precondition(rejected && review.notice.contains("已排除"))
        let rejection = MemoryReviewHTTP.body(MemoryReviewHTTP.requests.last { $0.httpMethod == "PUT" }!)["assignments"] as! [[String: Any]]
        precondition(rejection[0]["rejected_child_id"] as? Int == 7 && rejection[0]["child_id"] is NSNull)
        MemoryReviewHTTP.groupedFaces = true
        await review.load()
        precondition(review.faceGroups[21]?.map(\.id) == [21, 22])
        MemoryReviewHTTP.failWrites = true
        let failedGroup = await review.confirmFaceGroup(ids: [22], childID: 7)
        precondition(!failedGroup && !review.error.isEmpty)
        MemoryReviewHTTP.failWrites = false
        let savedGroup = await review.confirmFaceGroup(ids: [22], childID: 7)
        precondition(savedGroup && review.notice.contains("1 份影像"))
        let group = MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/confirm-group") }!
        precondition(MemoryReviewHTTP.body(group)["face_ids"] as? [Int] == [22], "only checked items are saved")
        let faceSubjects = review.subjects.filter { $0.kind == .face }
        review.toggleBatchSelection(faceSubjects[0])
        await review.page(next: true)
        precondition(review.batchSelection.map(\.id) == [faceSubjects[0].id], "paging retains the checked item")
        review.toggleBatchSelection(faceSubjects[1])
        let savedFaces = await review.confirmSelected(childID: 7)
        let facesRequest = MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/faces/review/confirm-group") }!
        precondition(savedFaces && review.batchSelection.isEmpty && MemoryReviewHTTP.body(facesRequest)["face_ids"] as? [Int] == [21, 22])
        await review.page(next: false)
        MemoryReviewHTTP.groupedFaces = false
        MemoryReviewHTTP.multiplePets = true
        await review.load()
        let petSubjects = review.subjects.filter { $0.kind == .pet }
        precondition(petSubjects.count == 2)
        for pet in petSubjects { review.toggleBatchSelection(pet) }
        if let face = review.subjects.first(where: { $0.kind == .face }) {
            precondition(!review.canToggleBatchSelection(face), "a batch has one identity type")
        }
        MemoryReviewHTTP.failWrites = true
        let failedPets = await review.confirmSelected(childID: 8)
        precondition(!failedPets && review.batchSelection.count == 2, "a failed batch preserves all checked records")
        MemoryReviewHTTP.failWrites = false
        let savedPets = await review.confirmSelected(childID: 8)
        precondition(savedPets && review.batchSelection.isEmpty && review.notice.contains("2 条宠物"))
        let petsRequest = MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/pets/review/confirm-group") }!
        let petsBody = MemoryReviewHTTP.body(petsRequest)
        let targets = petsBody["targets"] as! [[String: Any]]
        precondition(petsBody["child_id"] as? Int == 8 && targets.compactMap { $0["index"] as? Int } == [0, 1])
        precondition(targets.allSatisfy { $0["media_id"] as? Int == 42 && $0["selection_key"] is String })
        MemoryReviewHTTP.multiplePets = false
        let petReads = MemoryReviewHTTP.requests.filter { $0.url!.path.hasSuffix("/pets/review") }.count
        await review.page(next: true)
        precondition(MemoryReviewHTTP.requests.filter { $0.url!.path.hasSuffix("/pets/review") }.count == petReads, "finished pet pages do not repeat when faces continue")
        precondition(MemoryReviewHTTP.requests.last!.url!.query!.contains("before=21"))
        MemoryReviewHTTP.pendingFaces = 7
        await review.refreshPendingFaceCount()
        precondition(review.pendingFaceCount == 7 && review.history.count == 1)
        precondition(MemoryReviewHTTP.requests.last!.url!.query!.contains("before=21"), "background refresh keeps the current page")
        MemoryReviewHTTP.pendingFaces = 12
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
        review.tab = .organization; await review.load(reset: true)
        precondition(review.error.isEmpty && review.organizationQueue?.items.count == 1 && review.organizationSettings?.tags_enabled == true)
        let organizationEntry = review.organizationQueue!.items[0]
        MemoryReviewHTTP.failWrites = true
        await review.reviewOrganization(organizationEntry, action: "correct", remember: true, tags: ["公园": "户外"], childID: 0)
        precondition(!review.error.isEmpty)
        MemoryReviewHTTP.failWrites = false
        await review.reviewOrganization(organizationEntry, action: "correct", remember: true, tags: ["公园": nil], childID: 0)
        precondition(review.notice.contains("后台会继续整理"), "review acknowledges queued matching inline")
        let reviewed = MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/reviews/31") }!
        let reviewBody = MemoryReviewHTTP.body(reviewed)
        precondition(reviewBody["remember"] as? Bool == true && (reviewBody["tag_decisions"] as! [String: Any])["公园"] is NSNull)
        await review.saveOrganizationSettings(); precondition(review.error.isEmpty)
        await review.organizeBatch()
        precondition(MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/organization/run") }!.timeoutInterval == 300)
        review.organizationKind = "face"; await review.load(reset: true)
        precondition(MemoryReviewHTTP.requests.last!.url!.query!.contains("kind=face"))
        review.tab = .faces
        MemoryReviewHTTP.empty = true; await review.load(reset: true); precondition(review.subjects.isEmpty && review.error.isEmpty)
        let curation = NativeCurationStore(session: session)
        await curation.load()
        precondition(curation.error.isEmpty && curation.queue?.group_count == 1)
        precondition(MemoryReviewHTTP.requests.last!.url!.query!.contains("scope=unfiled"))
        let curationStart = MemoryReviewHTTP.requests.count
        curation.toggle([42])
        let beforeEmptyAlbumSave = MemoryReviewHTTP.requests.count
        let missingAlbumSaved = await curation.save(action: "add")
        precondition(!missingAlbumSaved && MemoryReviewHTTP.requests.count == beforeEmptyAlbumSave, "no write without an album")
        curation.selectedProfiles = [7]
        await curation.load()
        precondition(curation.selected == [42] && curation.selectedProfiles == [7], "refresh preserves in-progress selection")
        MemoryReviewHTTP.failCurationReads = true; await curation.load()
        precondition(curation.selected == [42] && curation.selectedProfiles == [7], "failed refresh preserves selection")
        MemoryReviewHTTP.failCurationReads = false
        MemoryReviewHTTP.failWrites = true; await curation.save(action: "add")
        precondition(!curation.error.isEmpty && curation.selected == [42], "failed curation retains selection")
        MemoryReviewHTTP.failWrites = false; await curation.save(action: "add")
        precondition(curation.error.isEmpty && curation.undoToken == "synthetic-batch" && curation.selected.isEmpty)
        let batchRequest = MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/curation/batch") }!
        precondition(MemoryReviewHTTP.body(batchRequest)["media_ids"] as? [Int] == [42])
        precondition(curation.selectedProfiles.isEmpty && curation.notice.contains("家人甲"), "success clears album selection and names the destination")
        await curation.undo(); precondition(curation.undoToken == nil && curation.error.isEmpty)
        curation.toggle([42]); curation.selectedProfiles = [7]
        MemoryReviewHTTP.failCurationReads = true
        let committed = await curation.save(action: "add")
        precondition(committed && curation.selected.isEmpty && curation.undoToken != nil && curation.error.contains("保存成功"), "successful write remains successful when refresh fails")
        MemoryReviewHTTP.failCurationReads = false
        await curation.load()
        for action in ["done", "ignore"] {
            curation.toggle([42]); curation.selectedProfiles = [7]
            let saved = await curation.save(action: action)
            precondition(saved)
            let request = MemoryReviewHTTP.requests.last { $0.url!.path.hasSuffix("/curation/batch") }!
            precondition(MemoryReviewHTTP.body(request)["child_ids"] as? [Int] == [], "completion and skip cannot accidentally change albums")
        }
        curation.toggle([42]); await curation.reviewQuality()
        precondition(curation.queue?.items[0].items[0].quality?.frames[0].clarity == 4 && curation.selected == [42])
        precondition(MemoryReviewHTTP.requests.last!.timeoutInterval == 180)
        precondition(MemoryReviewHTTP.requests.dropFirst(curationStart).allSatisfy { $0.url!.path.contains("/curation/") || $0.url!.path.hasSuffix("/children") }, "manual curation never calls identity review")
        let settingsStart = MemoryReviewHTTP.requests.count
        await review.loadOrganizationSettings()
        precondition(review.error.isEmpty && review.organizationSettings != nil)
        precondition(!MemoryReviewHTTP.requests.dropFirst(settingsStart).contains { $0.url!.path.hasSuffix("/organization/reviews") }, "settings load independently of review queue")
        MemoryReviewHTTP.role = "member"; await session.restore()
        let count = MemoryReviewHTTP.requests.count; await review.load()
        precondition(!review.error.isEmpty && MemoryReviewHTTP.requests.count == count, "non-admin review is denied")
        curation.selected = [42]; curation.selectedProfiles = [7]
        let denied = await curation.save(action: "add")
        precondition(!denied && MemoryReviewHTTP.requests.count == count, "non-admin curation cannot write")
        await review.loadOrganizationSettings()
        precondition(MemoryReviewHTTP.requests.count == count, "non-admin settings cannot read")
        print("Native AI review tests passed: face/dog confirmation and null assignment, CSRF, pagination, per-media analysis, auto-link, organization, curation save and undo, empty and admin access.")
    }
}
