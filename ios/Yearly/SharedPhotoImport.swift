import Foundation
import ImageIO
import UniformTypeIdentifiers
import Photos

enum SharedPhotoImport {
    enum Source {
        case file(URL, name: String, video: Bool)
        case livePhoto(PHLivePhoto)
    }
    static func prepare(_ source: Source, site: SiteOrigin, ownerID: Int, store: UploadStore) async throws -> UploadItem {
        switch source {
        case .file(let file, let name, let video):
            return try await prepare(file: file, name: name, site: site, ownerID: ownerID, store: store, video: video)
        case .livePhoto(let livePhoto):
            return try await PhotoOriginals.prepare(livePhoto: livePhoto, site: site, ownerID: ownerID, store: store)
        }
    }
    // Inspect the actual file format instead of trusting a provider's temporary extension.
    static func prepare(file: URL, name: String, site: SiteOrigin, ownerID: Int, store: UploadStore, video: Bool = false) async throws -> UploadItem {
        let type: UTType
        let raw: [String: Any]
        if video {
            guard ["mov", "mp4"].contains(file.pathExtension.lowercased()), let movieType = UTType(filenameExtension: file.pathExtension) else {
                throw UploadFailure(message: "无法识别分享的视频文件。")
            }
            raw = try await OriginalMetadata.movie(file)
            guard raw["ImageWidth"] != nil else { throw UploadFailure(message: "视频没有可读取的影像轨道。") }
            type = movieType
        } else {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, let identifier = CGImageSourceGetType(source),
                  let imageType = UTType(identifier as String) else {
                throw UploadFailure(message: "无法识别分享的照片文件。")
            }
            type = imageType
            raw = try OriginalMetadata.image(file)
        }
        guard let ext = type.preferredFilenameExtension,
              ["jpg", "jpeg", "png", "webp", "heic", "heif", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "mp4", "mov"].contains(ext.lowercased()) else {
            throw UploadFailure(message: "无法识别分享的媒体格式。")
        }
        try store.checkSpace()
        var item = UploadItem(assetIdentifier: "share:" + UUID().uuidString, site: site.url.absoluteString,
                              ownerID: ownerID, name: "", mediaType: video ? "video" : "photo")
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        item.name = String((stem.isEmpty ? "照片" : stem).prefix(200)) + "." + ext
        let directory = store.itemDirectory(item.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let path = "original." + ext
            let target = directory.appendingPathComponent(path)
            try FileManager.default.copyItem(at: file, to: target)
            let digest = try FileIntegrity.fingerprint(target) { try Task.checkCancellation() }
            try store.checkSpace()
            item.resources = [UploadResource(role: "original", filename: item.name,
                mimeType: type.preferredMIMEType ?? "application/octet-stream", path: path,
                size: digest.size, sha256: digest.sha256, crc64: digest.crc64)]
            var fields = OriginalMetadata.fields(raw)
            // Photos may export an edited/converted image or omit location metadata.
            // Never describe a share-sheet representation as an unmodified PhotoKit original.
            fields["metadata"] = ["source": "ios_share_extension", "representation": video ? "system_shared_video" : "system_shared_image"]
            item.captureDate = fields["original_taken_at_local"] as? String
            item.fields = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            item.warning = item.captureDate == nil ? "无拍摄日期，可指定归档日期。" : ""
            item.phase = .ready
            return item
        } catch {
            try? store.removeFiles(item.id)
            throw error
        }
    }
}
