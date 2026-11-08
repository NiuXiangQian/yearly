import Foundation
import Photos

enum NativePhotoExport {
    @MainActor static func save(_ item: NativeTimelineItem, session: NativeSession) async throws {
        guard let owner = session.account?.id, let primary = item.primary else {
            throw UploadFailure(message: "找不到可下载的原件。")
        }
        let firstType: PHAssetResourceType = item.media_type == "video" ? .video : .photo
        var originals = [(primary, firstType)]
        if item.media_type == "live_photo" {
            guard let motion = item.motion else { throw UploadFailure(message: "缺少配对资源，无法保存完整实况照片。") }
            originals.append((motion, .pairedVideo))
        }
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else {
            throw UploadFailure(message: "请在设置中允许 Yearly 添加照片。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var resources: [(url: URL, name: String, type: PHAssetResourceType)] = []
        for (file, type) in originals {
            let resource: NativeMediaResource = try await session.get("/media/\(item.id)/files/\(file.id)/url?purpose=original")
            guard let url = resource.url.flatMap(AppConfiguration.httpsURL) else {
                throw UploadFailure(message: "原件下载地址不可用。")
            }
            let (temporary, response) = try await NativeMediaNetwork.session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UploadFailure(message: "原件下载失败，请重新获取后再试。")
            }
            let name = (file.original_filename as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension
            let local = directory.appendingPathComponent(String(file.id)).appendingPathExtension(ext)
            try FileManager.default.moveItem(at: temporary, to: local)
            let size = try local.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == file.file_size else {
                throw UploadFailure(message: "下载大小与原件不符，未保存到相册。")
            }
            if let sha256 = file.sha256 {
                let hash = Task.detached(priority: .utility) { try FileIntegrity.fingerprint(local) { try Task.checkCancellation() } }
                let digest = try await withTaskCancellationHandler { try await hash.value } onCancel: { hash.cancel() }
                guard digest.sha256 == sha256 else {
                    throw UploadFailure(message: "下载校验失败，未保存到相册。")
                }
            }
            resources.append((local, name, type))
        }
        try Task.checkCancellation()
        guard session.account?.id == owner else { throw CancellationError() }
        let verified = resources
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            for resource in verified {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                options.originalFilename = resource.name
                request.addResource(with: resource.type, fileURL: resource.url, options: options)
            }
        }
    }
}
