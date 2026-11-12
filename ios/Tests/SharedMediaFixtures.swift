import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// Synthetic Live Photo resources; no family photos or external downloads.
enum SharedMediaFixtures {
    static func create(in directory: URL) async throws -> (photo: URL, movie: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let photo = directory.appendingPathComponent("实况测试.jpg")
        let movie = directory.appendingPathComponent("实况测试.mov")
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(image, context.makeImage()!, [kCGImagePropertyMakerAppleDictionary: ["17": identifier]] as CFDictionary)
        precondition(CGImageDestinationFinalize(image))
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let contentID = AVMutableMetadataItem()
        contentID.identifier = .quickTimeMetadataContentIdentifier
        contentID.value = identifier as NSString
        contentID.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [contentID]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(video)
        var format: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: "com.apple.metadata.datatype.int8",
            ]] as CFArray, formatDescriptionOut: &format)
        precondition(status == noErr)
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        let timed = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        writer.add(metadata)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let still = AVMutableMetadataItem()
        still.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
        still.dataType = "com.apple.metadata.datatype.int8"
        still.value = NSNumber(value: Int8(0))
        precondition(timed.append(AVTimedMetadataGroup(items: [still], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)))))
        metadata.markAsFinished()
        for frame in 0..<30 {
            while !video.isReadyForMoreMediaData {
                if let error = writer.error { throw error }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(nil, pixels.pixelBufferPool!, &buffer) == kCVReturnSuccess)
            CVPixelBufferLockBaseAddress(buffer!, [])
            CVPixelBufferGetBaseAddress(buffer!)!.initializeMemory(as: UInt8.self, repeating: UInt8(60 + frame), count: CVPixelBufferGetBytesPerRow(buffer!) * 64)
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            precondition(pixels.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        video.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? UploadFailure(message: "Synthetic movie generation failed") }
        return (photo, movie)
    }
}
