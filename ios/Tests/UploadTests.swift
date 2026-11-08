import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

@MainActor final class MockUploadService: UploadService {
    var remoteParts: [Int: Data] = [:]
    var signed: [Int] = []
    var putCount = 0
    var completed = false
    var completionError: Error?
    var putErrors: [Error] = []
    var largestBlock = 0
    var currentPart = 0
    var expectedSize: Int64 = 0
    var discardBytes = false
    var knownParts: [RemotePart]?
    func create(body: Data, key: UUID) async throws -> UploadCreation { fatalError("not used") }
    func status(_ task: RemoteUpload) async throws -> RemoteStatus {
        RemoteStatus(status: completed ? "complete" : "uploading", parts: knownParts ?? remoteParts.sorted { $0.key < $1.key }.map { RemotePart(number: $0.key, size: Int64($0.value.count)) })
    }
    func sign(_ task: RemoteUpload, number: Int) async throws -> URL {
        signed.append(number); currentPart = number
        return URL(string: "https://oss.invalid/part?number=\(number)&generation=\(signed.count)")!
    }
    func put(_ data: Data, to url: URL) async throws {
        putCount += 1
        largestBlock = max(largestBlock, data.count)
        if !putErrors.isEmpty { throw putErrors.removeFirst() }
        if !discardBytes { remoteParts[currentPart] = data }
        expectedSize += Int64(data.count)
    }
    func complete(_ task: RemoteUpload) async throws {
        if let completionError { throw completionError }
        completed = true
    }
}

@main struct UploadTests {
    @MainActor static var assertions = 0
    @MainActor static func expect(_ condition: Bool, _ label: String) {
        assertions += 1
        guard condition else { fatalError("FAILED: \(label)") }
    }
    @MainActor static func rejects(_ label: String, operation: () async throws -> Void) async {
        do { try await operation(); fatalError("FAILED (did not reject): \(label)") }
        catch { assertions += 1 }
    }
    static func resource(_ url: URL, role: String = "original", partSize: Int = FileIntegrity.blockSize) throws -> UploadResource {
        let hash = try FileIntegrity.fingerprint(url)
        return UploadResource(role: role, filename: "SYNTHETIC.HEIC", mimeType: "image/heic", path: url.lastPathComponent,
                              size: hash.size, sha256: hash.sha256, crc64: hash.crc64,
                              task: RemoteUpload(id: UUID().uuidString, media_id: 1, sha256: hash.sha256, file_size: hash.size, file_role: role, part_size: partSize, status: "pending"))
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Yearly-synthetic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vector = root.appendingPathComponent("vector")
        try Data("123456789".utf8).write(to: vector)
        let digest = try FileIntegrity.fingerprint(vector)
        expect(digest.crc64 == "11051210869376104954", "CRC64/XZ independent check vector")
        expect(digest.sha256 == "15e2b0d3c33891ebb0f1ef609ec419420c20e320ce94c65fbc8c3312448eb225", "SHA-256 check vector")
        expect(try PhotoResourcePolicy.select(types: [5, 10, 1, 9], live: true, video: false) == .init(types: [1, 9], edited: false), "prefer unmodified Live Photo pair")
        expect(try PhotoResourcePolicy.select(types: [5, 10], live: true, video: false) == .init(types: [5, 10], edited: true), "label edited pair")
        expect(try PhotoResourcePolicy.select(types: [1, 5], live: false, video: false).types == [1], "ordinary HEIC original")
        await rejects("do not mix original and edited pair") { _ = try PhotoResourcePolicy.select(types: [1, 10], live: true, video: false) }
        await rejects("missing MOV must not become photo") { _ = try PhotoResourcePolicy.select(types: [1], live: true, video: false) }
        expect(OriginalMetadata.wallTime("2020:02:03 04:05:06") == "2020-02-03T04:05:06", "EXIF local time remains local")
        expect(OriginalMetadata.wallTime("2020-02-30T04:05:06") == nil, "invalid calendar date")
        expect(OriginalMetadata.offset("2020-01-01T12:00:00+08:00") == 480, "explicit QuickTime offset")
        expect(OriginalMetadata.offset("2020:01:01 12:00:00") == nil, "do not invent timezone")
        expect(OriginalMetadata.fields([:])["original_taken_at_local"] == nil, "do not use import time")
        expect(OriginalMetadata.fields(["DateTimeOriginal": "2020:01:02 03:04:05", "com.apple.quicktime.creationdate": "2020-01-02T03:04:05Z"])["original_offset_minutes"] == nil, "do not borrow mismatched timezone")

        // Actual synthetic HEIC, with EXIF/GPS. No private photo input or network.
        let heic = root.appendingPathComponent("synthetic.heic")
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        let properties: [String: Any] = [kCGImagePropertyExifDictionary as String: ["DateTimeOriginal": "2020:01:02 03:04:05", "OffsetTimeOriginal": "+08:00", "ExposureTime": 0.01, "FNumber": 2.0], kCGImagePropertyGPSDictionary as String: ["Latitude": 30.0, "LatitudeRef": "N", "Longitude": 120.0, "LongitudeRef": "E"]]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        expect(CGImageDestinationFinalize(destination), "create synthetic HEIC")
        let before = try FileIntegrity.fingerprint(heic)
        let metadata = try OriginalMetadata.image(heic)
        expect(metadata["DateTimeOriginal"] as? String == "2020:01:02 03:04:05", "read HEIC EXIF")
        expect(metadata["latitude"] as? Double == 30, "read HEIC GPS")
        expect(try FileIntegrity.fingerprint(heic) == before, "metadata read preserves every byte")
        let mock = MockUploadService()
        let heicResource = try resource(heic)
        var success = false
        try await MultipartUploader.upload(heicResource, file: heic, service: mock) { _, complete in success = complete }
        expect(success && mock.completed, "HEIC completes after server confirmation")
        expect(mock.remoteParts[1] == (try Data(contentsOf: heic)), "HEIC uploaded without conversion")

        let multi = root.appendingPathComponent("multipart.mov")
        let data = Data(repeating: 0xA5, count: FileIntegrity.blockSize * 2 + 17)
        try data.write(to: multi)
        let multipart = try resource(multi)
        let resumed = MockUploadService()
        resumed.remoteParts[1] = data.prefix(FileIntegrity.blockSize)
        // Expired signed URL and transient OSS conflict: get a new signature each time.
        resumed.putErrors = [UploadHTTPError(status: 403, isOSS: true), UploadHTTPError(status: 409, isOSS: true)]
        try await MultipartUploader.upload(multipart, file: multi, service: resumed) { _, _ in }
        expect(resumed.signed == [2, 2, 2, 3], "skip existing part and refresh expired signatures")
        expect(resumed.largestBlock == FileIntegrity.blockSize, "bounded multipart memory")
        expect(resumed.remoteParts.sorted { $0.key < $1.key }.reduce(Data()) { $0 + $1.value } == data, "resumed bytes exact")
        let configured = MockUploadService()
        try await MultipartUploader.upload(resource(multi, partSize: 16 * 1024 * 1024), file: multi, service: configured) { _, _ in }
        expect(configured.signed == [1] && configured.largestBlock == data.count, "honor server 16 MiB part size instead of hardcoding 4 MiB")
        let failed = MockUploadService()
        failed.completionError = UploadHTTPError(status: 409, isOSS: false)
        var reportedComplete = false
        await rejects("HEAD integrity 409 must not succeed") {
            try await MultipartUploader.upload(heicResource, file: heic, service: failed) { _, complete in reportedComplete = complete }
        }
        expect(!reportedComplete, "no success before integrity verification")
        var unverified = UploadItem(assetIdentifier: "synthetic", site: "https://yearly.invalid/", ownerID: 1, name: "pending", mediaType: "photo")
        unverified.resources = [heicResource]
        unverified.resources[0].uploadedBytes = heicResource.size
        expect(unverified.progress < 1, "100 percent reserved for verified logical media")
        let invalidParts = MockUploadService()
        invalidParts.knownParts = [RemotePart(number: 1, size: 1)]
        await rejects("malformed resume part") { try await MultipartUploader.upload(multipart, file: multi, service: invalidParts) { _, _ in } }
        let cancelled = Task { @MainActor in
            try Task.checkCancellation()
            try await MultipartUploader.upload(multipart, file: multi, service: MockUploadService()) { _, _ in }
        }
        cancelled.cancel()
        await rejects("cancellation") { try await cancelled.value }
        var retries = 0, delays: [UInt64] = []
        await rejects("network retry bounded") {
            let _: Int = try await MultipartUploader.retry(sleep: { delays.append($0) }) {
                retries += 1; throw URLError(.notConnectedToInternet)
            }
        }
        expect(retries == 3 && delays == [1_000_000_000, 2_000_000_000], "three attempts exponential backoff")
        retries = 0
        await rejects("authentication failure never retried") {
            let _: Int = try await MultipartUploader.retry(sleep: { _ in }) { retries += 1; throw UploadHTTPError(status: 401, isOSS: false) }
        }
        expect(retries == 1, "unauthorized failure is immediate")

        let store = try UploadStore(directory: root.appendingPathComponent("store"))
        var live = UploadItem(assetIdentifier: "synthetic", site: "https://yearly.invalid/", ownerID: 1, name: "Live", mediaType: "live_photo")
        var still = heicResource
        still.complete = true
        live.resources = [still, try resource(multi, role: "live_video")]
        live.phase = .uploading
        live.confirmed = true
        live.requestStarted = true
        live.childIDs = [1, 2, 3]
        live.archiveDate = "2024-01-02"
        try store.save([live])
        let recovered = try store.load()[0]
        expect(recovered.phase == .paused && recovered.id == live.id, "restart preserves stable create key and pauses")
        expect(recovered.resources[0].complete && !recovered.resources[1].complete, "restart preserves partial Live Photo completion")
        let payload = try JSONSerialization.jsonObject(with: recovered.body()) as! [String: Any]
        expect((payload["files"] as? [[String: Any]])?.count == 2, "one request contains both roles")
        expect(payload["child_ids"] as? [Int] == [1, 2, 3], "one association list for all people and pets")
        live.resources.removeLast()
        await rejects("incomplete Live Photo creation") { _ = try live.body() }
        live.resources[0].path = "../secret"
        await rejects("path escape") { _ = try store.file(live.resources[0], itemID: live.id) }
        var batch: [UploadItem] = []
        for n in 0..<100 {
            let service = MockUploadService()
            try await MultipartUploader.upload(heicResource, file: heic, service: service) { _, _ in }
            var item = UploadItem(assetIdentifier: "synthetic-\(n)", site: "https://yearly.invalid/", ownerID: 1, name: "\(n)", mediaType: n % 2 == 0 ? "photo" : "live_photo")
            item.resources = n % 2 == 0 ? [heicResource] : [heicResource, try resource(vector, role: "live_video")]
            if item.mediaType == "live_photo" {
                try await MultipartUploader.upload(item.resources[1], file: vector, service: MockUploadService()) { _, _ in }
            }
            batch.append(item)
            expect(service.largestBlock <= FileIntegrity.blockSize, "100-item batch bounded buffer \(n)")
        }
        try store.save(batch)
        expect(try store.load().map(\.id) == batch.map(\.id), "100-item order survives relaunch")
        if CommandLine.arguments.contains("--large") {
            let large = root.appendingPathComponent("synthetic-1GiB.mov")
            FileManager.default.createFile(atPath: large.path, contents: nil)
            let handle = try FileHandle(forWritingTo: large)
            try handle.truncate(atOffset: 1_073_741_824)
            try handle.close()
            let original = try resource(large)
            expect(original.size == 1_073_741_824, "1 GiB streaming fingerprint")
            // Independently checked with Python hashlib and oss2.utils.Crc64 on 256 zero blocks.
            expect(original.sha256 == "49bc20df15e412a64472421e13fe86ff1c5165e18b2afccf160d4dc19fe68a14", "1 GiB independent SHA reference")
            expect(original.crc64 == "3534425600523290380", "1 GiB independent OSS CRC reference")
            let service = MockUploadService()
            service.discardBytes = true
            try await MultipartUploader.upload(original, file: large, service: service) { _, _ in }
            expect(service.putCount == 256 && service.largestBlock == FileIntegrity.blockSize && service.expectedSize == original.size, "1 GiB upload uses 256 bounded parts")
            print("1 GiB SHA256=\(original.sha256) CRC64=\(original.crc64)")
        }
        print("Passed \(assertions) native upload assertions (synthetic files / mock service; no OSS connection).")
    }
}
