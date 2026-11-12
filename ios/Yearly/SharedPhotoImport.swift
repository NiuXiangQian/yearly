import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SharedPhotoImport {
    // Inspect the actual file format instead of trusting a provider's temporary extension.
    static func prepare(file: URL, name: String, site: SiteOrigin, ownerID: Int, store: UploadStore) throws -> UploadItem {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              let ext = type.preferredFilenameExtension,
              ["jpg", "jpeg", "png", "webp", "heic", "heif"].contains(ext.lowercased()) else {
            throw UploadFailure(message: "分享上传支持 JPEG、PNG、HEIC、HEIF 和 WebP 图片；其他格式请在 App 内导入。")
        }
        try store.checkSpace()
        var item = UploadItem(assetIdentifier: "share:" + UUID().uuidString, site: site.url.absoluteString,
                              ownerID: ownerID, name: "", mediaType: "photo")
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
            let raw = try OriginalMetadata.image(target)
            var fields = OriginalMetadata.fields(raw)
            // Photos may export an edited/converted image or omit location metadata.
            // Never describe a share-sheet representation as an unmodified PhotoKit original.
            fields["metadata"] = ["source": "ios_share_extension", "representation": "system_shared_image"]
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
