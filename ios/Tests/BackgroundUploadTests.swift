import Foundation

// Every request, including the file-backed PUT, is intercepted. No production media,
// credentials or OSS are used. Held requests let tests expire a lease mid-transfer.
private final class BackgroundHTTP: URLProtocol {
    static let lock = NSLock()
    static var hold: String?
    static var held: [BackgroundHTTP] = []
    static var requests: [URLRequest] = []
    static var tasks: [String: [String: Any]] = [:]
    static var parts: [String: [Int]] = [:]
    static var completed: Set<String> = []
    static var rejectPUT = false
    private let state = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let waiting = request.url!.path.contains(Self.hold ?? "never-match")
        if waiting { Self.held.append(self) }
        Self.lock.unlock()
        if !waiting { respond() }
    }
    override func stopLoading() { state.lock(); stopped = true; state.unlock() }
    private func respond() {
        state.lock(); defer { state.unlock() }
        guard !stopped else { return }
        stopped = true
        Self.lock.lock()
        var body: [String: Any] = [:], status = 200
        let path = request.url!.path
        if path.hasSuffix("/auth/me") {
            body = ["id": 1, "role": "member", "csrf_token": "synthetic-csrf"]
        } else if path == "/yearly/api/uploads" {
            var payload = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    payload.append(contentsOf: buffer.prefix(count))
                }
            }
            let input = try! JSONSerialization.jsonObject(with: payload) as! [String: Any]
            let key = request.value(forHTTPHeaderField: "Idempotency-Key")!
            let files = input["files"] as! [[String: Any]]
            let tasks = files.map { file -> [String: Any] in
                let id = key + "-" + (file["file_role"] as! String)
                let task: [String: Any] = ["id": id, "media_id": 42, "sha256": file["sha256"]!,
                    "file_size": file["file_size"]!, "file_role": file["file_role"]!, "part_size": 4, "status": "pending"]
                Self.tasks[id] = task
                return task
            }
            body = ["media_id": 42, "duplicate": false, "tasks": tasks]
        } else if request.httpMethod == "PUT" {
            let id = request.url!.pathComponents[2], number = Int(request.url!.lastPathComponent)!
            if Self.rejectPUT { status = 400 }
            else { Self.parts[id, default: []].append(number) }
        } else if path.hasSuffix("/sign") {
            let number = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            let id = request.url!.pathComponents[4]
            body = ["url": "https://oss.invalid/parts/\(id)/\(number)"]
        } else if path.hasSuffix("/complete") {
            let id = request.url!.pathComponents[4]
            let size = Self.tasks[id]!["file_size"] as! Int
            precondition(Set(Self.parts[id] ?? []).count == (size + 3) / 4)
            Self.completed.insert(id)
            body = ["status": "complete"]
        } else {
            let id = request.url!.lastPathComponent, size = Self.tasks[id]!["file_size"] as! Int
            body = ["status": Self.completed.contains(id) ? "complete" : "uploading",
                    "parts": Set(Self.parts[id] ?? []).sorted().map { ["number": $0, "size": min(4, size - ($0 - 1) * 4)] }]
        }
        Self.lock.unlock()
        let data = try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func release() {
        lock.lock(); hold = nil; let values = held; held = []; lock.unlock()
        values.forEach { $0.respond() }
    }
    static func reset(hold: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.hold = hold; held = []; requests = []; tasks = [:]; parts = [:]; completed = []; rejectPUT = false
    }
    static func waiting() -> Bool { lock.lock(); defer { lock.unlock() }; return !held.isEmpty }
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

private struct SyntheticCredentials: SessionCredentialStore {
    func read(site: String) throws -> SessionCredential? { SessionCredential(value: "synthetic-session", expires: Date().addingTimeInterval(3600)) }
    func write(_ credential: SessionCredential?, site: String) throws { }
}
@MainActor private final class ExecutionLease: UploadBackgroundExecution {
    var expiration: (@MainActor () -> Void)?
    var begins = 0
    func begin(expiration: @escaping @MainActor () -> Void) { if self.expiration == nil { begins += 1; self.expiration = expiration } }
    func end() { expiration = nil }
    func expire() { let callback = expiration; end(); callback?() }
}

@main struct BackgroundUploadTests {
    @MainActor static func wait(_ description: String, until condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out: \(description)")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yearly-background-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackgroundHTTP.self]
        let http = URLSession(configuration: config)
        defer { http.invalidateAndCancel() }
        let transport = BackgroundUploadTransport(configuration: config, directory: root.appendingPathComponent("parts"))
        defer { transport.invalidate() }
        let site = SiteOrigin("https://yearly.invalid/yearly/")!
        let session = NativeSession(site: site, store: SyntheticCredentials(), transport: http, cacheDirectory: root.appendingPathComponent("lists"))
        BackgroundHTTP.reset()
        await session.restore()
        precondition(session.canEdit)

        func queue(_ name: String, live: Bool = false, count: Int = 1, execution: ExecutionLease? = nil,
                   extensionMode: Bool = false, phases: [UploadPhase] = [],
                   updates: @escaping @MainActor (UploadQueue.BackgroundUpdate) -> Void = { _ in }) throws -> UploadQueue {
            let store = try UploadStore(directory: root.appendingPathComponent(name))
            var items: [UploadItem] = []
            for number in 0..<count {
                var item = UploadItem(assetIdentifier: "synthetic-\(number)", site: site.url.absoluteString, ownerID: 1, name: name, mediaType: live ? "live_photo" : "photo")
                try FileManager.default.createDirectory(at: store.itemDirectory(item.id), withIntermediateDirectories: true)
                for role in live ? ["original", "live_video"] : ["original"] {
                    let file = store.itemDirectory(item.id).appendingPathComponent(role)
                    try Data("synthetic-\(role)-\(number)".utf8).write(to: file)
                    let hash = try FileIntegrity.fingerprint(file)
                    item.resources.append(UploadResource(role: role, filename: role, mimeType: "application/octet-stream", path: role, size: hash.size, sha256: hash.sha256, crc64: hash.crc64))
                }
                item.confirmed = true
                item.phase = phases.isEmpty ? .paused : phases[number]
                items.append(item)
            }
            try store.save(items)
            let result = UploadQueue(store: store, backgroundExecution: extensionMode ? nil : (execution ?? ExecutionLease()),
                                     backgroundTransport: transport, reportBackgroundUpdate: updates) { session, owner, background in
                UploadAPI(site: session.site, ownerID: owner, cookieProvider: { session.cookies() }, session: http, backgroundTransport: background)
            }
            result.configure(session: session)
            return result
        }

        BackgroundHTTP.reset(hold: "/parts/")
        let lease = ExecutionLease()
        var updates: [UploadQueue.BackgroundUpdate] = []
        let first = try queue("live", live: true, count: 2, execution: lease) { updates.append($0) }
        first.retryInterrupted()
        try await wait("first file-backed transfer") { BackgroundHTTP.waiting() }
        precondition(!transport.hasPendingTransfers, "foreground upload must start without waiting for the daemon")
        first.prepareForBackground()
        precondition(transport.hasPendingTransfers, "the daemon PUT must be submitted before entering the background")
        precondition(updates.isEmpty, "temporary deactivation must not post a notification")
        first.enteredBackground()
        try await wait("hand off the active foreground part to the daemon") { transport.hasPendingTransfers }
        let staged = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("parts"), includingPropertiesForKeys: nil)
        precondition(staged.count == 1 && (try! Data(contentsOf: staged[0])) == Data("synt".utf8))
        first.enteredBackground()
        first.enteredBackground() // Duplicate lifecycle delivery must preserve the running work.
        precondition(first.items[0].phase == .uploading && lease.begins == 1)
        lease.expire()
        precondition(first.items[0].phase == .uploading, "expiration cannot cancel a daemon PUT")
        BackgroundHTTP.release()
        try await wait("both Live Photo resources complete in background") { !first.running }
        precondition(first.items.allSatisfy { $0.phase == .complete && $0.resources.allSatisfy(\.complete) })
        precondition(lease.begins >= 2 && lease.expiration == nil)
        precondition(updates == [.started(2), .finished(completed: 2, interrupted: 0)],
                     "Background updates must summarize the confirmed batch once")
        let puts = BackgroundHTTP.captured().filter { $0.httpMethod == "PUT" }
        precondition(puts.count > 2)
        for put in puts {
            for header in ["Cookie", "Origin", "X-CSRF-Token", "Authorization", "Idempotency-Key"] {
                precondition(put.value(forHTTPHeaderField: header) == nil)
            }
        }
        let remainingParts = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("parts").path)
        precondition(remainingParts.isEmpty)

        BackgroundHTTP.reset(hold: "/parts/")
        let foreground = try queue("return-to-foreground")
        foreground.retryInterrupted()
        foreground.enteredBackground()
        try await wait("daemon PUT pending") { transport.hasPendingTransfers && BackgroundHTTP.waiting() }
        let requestsBeforeReturn = BackgroundHTTP.captured().filter { $0.httpMethod == "PUT" }.count
        foreground.enteredForeground()
        try await wait("foreground takes over the delayed PUT") {
            !transport.hasPendingTransfers &&
                BackgroundHTTP.captured().filter { $0.httpMethod == "PUT" }.count > requestsBeforeReturn
        }
        BackgroundHTTP.release()
        try await wait("foreground upload completes") { !foreground.running }
        precondition(foreground.items[0].phase == .complete)

        BackgroundHTTP.reset(hold: "/parts/")
        let paused = try queue("manual-pause")
        paused.retryInterrupted()
        try await wait("transfer to pause") { BackgroundHTTP.waiting() }
        paused.enteredBackground()
        try await wait("file-backed PUT to pause") { transport.hasPendingTransfers }
        paused.pauseAll()
        BackgroundHTTP.release()
        try await wait("cancelled transfer settles") { !paused.running }
        paused.enteredForeground()
        precondition(paused.items[0].phase == .paused && !paused.running)
        paused.resume(paused.items[0].id)
        try await wait("explicit resume completes") { !paused.running }
        precondition(paused.items[0].phase == .complete)

        BackgroundHTTP.reset(hold: "/parts/")
        let immediate = try queue("immediate-resume")
        immediate.retryInterrupted()
        try await wait("transfer to immediately resume") { BackgroundHTTP.waiting() }
        immediate.enteredBackground(); immediate.pauseAll(); immediate.retryInterrupted()
        BackgroundHTTP.release()
        try await wait("immediate resume settles") { !immediate.running }
        precondition(immediate.items[0].phase == .complete, "pause cleanup must not cancel the new transfer")

        BackgroundHTTP.reset(hold: "/parts/")
        let cancelled = try queue("cancel")
        cancelled.retryInterrupted()
        try await wait("transfer to cancel") { BackgroundHTTP.waiting() }
        cancelled.enteredBackground(); cancelled.cancel(cancelled.items[0].id); BackgroundHTTP.release()
        try await wait("cancellation completes") { !cancelled.running }
        cancelled.enteredForeground()
        precondition(cancelled.items[0].phase == .cancelled && !cancelled.running)
        precondition(!BackgroundHTTP.captured().contains { $0.url!.path.hasSuffix("/complete") })

        BackgroundHTTP.reset(hold: "/yearly/api/uploads")
        let shortLease = ExecutionLease(), expired = try queue("expired", execution: shortLease)
        expired.retryInterrupted()
        try await wait("control request") { BackgroundHTTP.waiting() }
        expired.enteredBackground(); shortLease.expire(); BackgroundHTTP.release()
        try await wait("control request cancellation") { !expired.running }
        precondition(expired.items[0].phase == .paused)
        expired.enteredForeground()
        try await wait("foreground recovery") { !expired.running }
        precondition(expired.items[0].phase == .complete)

        BackgroundHTTP.reset(hold: "/yearly/api/uploads")
        let extensionQueue = try queue("extension", extensionMode: true)
        extensionQueue.retryInterrupted()
        try await wait("extension control request") { BackgroundHTTP.waiting() }
        extensionQueue.enteredBackground()
        precondition(extensionQueue.items[0].phase == .uploading && !transport.hasPendingTransfers)
        BackgroundHTTP.release()
        try await wait("extension completes while its host still runs it") { !extensionQueue.running }
        precondition(extensionQueue.items[0].phase == .complete)

        BackgroundHTTP.reset()
        BackgroundHTTP.rejectPUT = true
        let failure = try queue("failure")
        failure.retryInterrupted(); failure.enteredBackground()
        try await wait("failed PUT") { !failure.running }
        precondition(failure.items[0].phase == .failed && !failure.items[0].resources[0].complete)
        precondition(!BackgroundHTTP.captured().contains { $0.url!.path.hasSuffix("/complete") })
        BackgroundHTTP.rejectPUT = false
        failure.retryInterrupted()
        try await wait("failed PUT retry") { !failure.running }
        precondition(failure.items[0].phase == .complete)
        BackgroundHTTP.reset()
        let restored = try queue("restore-confirmed", count: 3, phases: [.uploading, .paused, .failed])
        try await wait("confirmed transfer automatically resumes after relaunch") { !restored.running }
        precondition(restored.items.map(\.phase) == [.complete, .paused, .failed], "explicit interruption must remain visible after relaunch")
        restored.retryInterrupted()
        try await wait("bulk retry resumes paused and failed tasks") { !restored.running }
        precondition(restored.items.allSatisfy { $0.phase == .complete })

        BackgroundHTTP.reset(hold: "/parts/")
        let systemLease = ExecutionLease()
        var notifications: [UploadQueue.BackgroundUpdate] = []
        let continued = try queue("continued-processing", count: 2, execution: systemLease) { notifications.append($0) }
        var requests = 0
        continued.requestContinuedExecution = { [weak continued] in
            requests += 1
            continued?.setContinuedExecution(true)
        }
        continued.retryInterrupted()
        try await wait("first direct PUT while continued processing is granted") { BackgroundHTTP.waiting() }
        let continuedIDs = continued.activeConfirmedUploadIDs
        continued.prepareForBackground()
        continued.enteredBackground()
        precondition(requests == 1 && continuedIDs.count == 2)
        precondition(!transport.hasPendingTransfers && systemLease.begins == 0 && notifications.isEmpty,
                     "A continued processing task must keep direct transfers and avoid duplicate alerts")
        let initial = continued.batchProgress(for: continuedIDs)
        precondition(initial.totalBytes > 0 && initial.totalItems == 2 && initial.hasActiveUploads && !initial.succeeded)
        BackgroundHTTP.release()
        try await wait("both uploads complete during continued processing") { !continued.running }
        let done = continued.batchProgress(for: continuedIDs)
        precondition(done.completedItems == 2 && done.uploadedBytes == done.totalBytes && done.succeeded && !done.hasActiveUploads)
        print("Passed background upload checks: early daemon handoff, continued processing progress, file bytes, Live Photo multipart continuation, lease expiration/wake, credential isolation, pause/resume, relaunch recovery, background notices, extension lifetime and bulk retry.")
    }
}
