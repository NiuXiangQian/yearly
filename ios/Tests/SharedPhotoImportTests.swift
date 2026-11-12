import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct SharedPhotoImportTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UploadStore(directory: root.appendingPathComponent("queue"))
        let file = root.appendingPathComponent("provider-with-no-extension")
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2020:02:03 12:34:56",
            kCGImagePropertyExifOffsetTimeOriginal: "+08:00",
        ]] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let site = SiteOrigin("https://share.invalid/yearly/")!
        var item = try await SharedPhotoImport.prepare(file: file, name: "../../假后缀.png", site: site, ownerID: 7, store: store)
        precondition(item.phase == .ready && !item.confirmed && !item.requestStarted)
        precondition(item.ownerID == 7 && item.site == site.url.absoluteString)
        precondition(item.name == "假后缀.jpeg" || item.name == "假后缀.jpg")
        let resource = item.resources[0]
        precondition(resource.mimeType == "image/jpeg" && resource.role == "original")
        let copy = try store.file(resource, itemID: item.id)
        let sourceBytes = try Data(contentsOf: file)
        let copiedBytes = try Data(contentsOf: copy)
        precondition(sourceBytes == copiedBytes)
        let digest = try FileIntegrity.fingerprint(file)
        precondition(resource.sha256 == digest.sha256 && resource.crc64 == digest.crc64 && resource.size == digest.size)
        precondition(item.captureDate == "2020-02-03T12:34:56")
        let fields = try JSONSerialization.jsonObject(with: item.fields) as! [String: Any]
        precondition(fields["original_offset_minutes"] as? Int == 480)
        precondition((fields["metadata"] as? [String: Any])?["representation"] as? String == "system_shared_image")
        item.childIDs = [2, 3]
        item.archiveDate = "2026-11-12"
        let body = try JSONSerialization.jsonObject(with: item.body()) as! [String: Any]
        precondition(body["child_ids"] as? [Int] == [2, 3] && body["timeline_date"] as? String == "2026-11-12")
        item.confirmed = true
        item.requestStarted = true
        item.phase = .uploading
        try store.save([item])
        let restored = try store.load()[0]
        precondition(restored.id == item.id && restored.phase == .paused && restored.requestStarted)
        precondition(restored.childIDs == [2, 3] && restored.archiveDate == item.archiveDate)
        precondition(restored.resources == item.resources)
        let invalid = root.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: invalid)
        do {
            _ = try await SharedPhotoImport.prepare(file: invalid, name: "broken.jpg", site: site, ownerID: 7, store: store)
            fatalError("Invalid image accepted")
        } catch is UploadFailure { }
        let fixture = try await SharedMediaFixtures.create(in: root.appendingPathComponent("live"))
        let video = try await SharedPhotoImport.prepare(.file(fixture.movie, name: "视频测试.mov", video: true), site: site, ownerID: 7, store: store)
        precondition(video.mediaType == "video" && video.phase == .ready && video.resources.count == 1)
        precondition(video.resources[0].mimeType == "video/quicktime")
        let videoBytes = try Data(contentsOf: store.file(video.resources[0], itemID: video.id))
        let movieBytes = try Data(contentsOf: fixture.movie)
        precondition(videoBytes == movieBytes)
        let videoFields = try JSONSerialization.jsonObject(with: video.body()) as! [String: Any]
        precondition(videoFields["media_type"] as? String == "video" && (videoFields["duration_ms"] as? Int ?? 0) > 0)
        let imageMetadata = try OriginalMetadata.image(fixture.photo)
        let movieMetadata = try await OriginalMetadata.movie(fixture.movie)
        precondition(imageMetadata["ContentIdentifier"] as? String == movieMetadata["com.apple.quicktime.content.identifier"] as? String)
        print("Shared media import: photo/video bytes, EXIF, Live Photo pair identifiers, account scope, request fields, recovery and invalid-file checks passed.")
    }
}
