import Foundation
import Photos
import UniformTypeIdentifiers

final class LivePhotoTransfer {
    enum Failure: Error { case missingResources, invalidResource, tooLarge }

    private struct Resource {
        let url: URL
        let name: String
        let type: String
        let size: Int

        var manifest: [String: Any] { ["name": name, "type": type, "size": size] }

        init(asset: PHAssetResource, directory: URL, role: String) async throws {
            url = directory.appendingPathComponent(role)
            name = asset.originalFilename
            type = UTType(asset.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await PHAssetResourceManager.default().writeData(for: asset, toFile: url, options: options)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
                throw Failure.invalidResource
            }
            self.size = size
        }
    }

    let id = UUID()
    private let directory: URL
    private let original: Resource
    private let video: Resource

    var manifest: [String: Any] {
        ["id": id.uuidString, "original": original.manifest, "video": video.manifest]
    }

    private init(directory: URL, original: Resource, video: Resource) {
        self.directory = directory
        self.original = original
        self.video = video
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func load(from provider: NSItemProvider) async throws -> LivePhotoTransfer {
        guard provider.canLoadObject(ofClass: PHLivePhoto.self) else { throw Failure.missingResources }
        let livePhoto: PHLivePhoto = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: PHLivePhoto.self) { photo, error in
                if let photo = photo as? PHLivePhoto {
                    continuation.resume(returning: photo)
                } else {
                    continuation.resume(throwing: error ?? Failure.missingResources)
                }
            }
        }
        defer { withExtendedLifetime(livePhoto) {} }
        let resources = PHAssetResource.assetResources(for: livePhoto)
        guard let originalAsset = resources.first(where: { $0.type == .photo }),
              let videoAsset = resources.first(where: { $0.type == .pairedVideo }) else {
            throw Failure.missingResources
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let original = try await Resource(asset: originalAsset, directory: directory, role: "original")
            let video = try await Resource(asset: videoAsset, directory: directory, role: "video")
            guard original.size + video.size <= 128 * 1024 * 1024 else { throw Failure.tooLarge }
            return LivePhotoTransfer(directory: directory, original: original, video: video)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func read(role: String, offset: Int) throws -> String {
        let resource: Resource
        switch role {
        case "original": resource = original
        case "video": resource = video
        default: throw Failure.invalidResource
        }
        guard offset >= 0, offset < resource.size else { throw Failure.invalidResource }
        let file = try FileHandle(forReadingFrom: resource.url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        let length = min(512 * 1024, resource.size - offset)
        guard let data = try file.read(upToCount: length), data.count == length else { throw Failure.invalidResource }
        return data.base64EncodedString()
    }
}
