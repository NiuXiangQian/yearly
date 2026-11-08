import Foundation
import ImageIO
import AVFoundation
#if canImport(Photos)
import Photos
#endif

enum OriginalMetadata {
    // Preserve wall time; never apply the phone's current timezone to a timezone-less EXIF value.
    static func wallTime(_ text: String?) -> String? {
        guard let text,
              let regex = try? NSRegularExpression(pattern: #"^(\d{4})[:-](\d{2})[:-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let parts = (1...6).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        guard parts.count == 6 else { return nil }
        let value = "\(parts[0])-\(parts[1])-\(parts[2])T\(parts[3]):\(parts[4]):\(parts[5])"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return value
    }
    static func offset(_ text: String?) -> Int? {
        guard let text else { return nil }
        if text.hasSuffix("Z") { return 0 }
        guard let regex = try? NSRegularExpression(pattern: #"([+-])(\d{2}):?(\d{2})$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func part(_ n: Int) -> String { String(text[Range(match.range(at: n), in: text)!]) }
        let hours = Int(part(2)) ?? 99, minutes = Int(part(3)) ?? 99
        guard hours <= 14, minutes < 60, hours != 14 || minutes == 0 else { return nil }
        return (part(1) == "-" ? -1 : 1) * (hours * 60 + minutes)
    }
    private static func safe(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 12 else { return "[metadata depth limit]" }
        if let dict = value as? [String: Any] { return dict.mapValues { safe($0, depth: depth + 1) } }
        if let values = value as? [Any] { return values.prefix(4096).map { safe($0, depth: depth + 1) } }
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number : NSNull() }
        if let string = value as? String { return String(string.prefix(65536)) }
        if let bytes = value as? Data { return bytes.count <= 65536 ? bytes.base64EncodedString() : "[binary metadata retained in original]" }
        return String(describing: value).prefix(1024).description
    }
    static func image(_ url: URL) throws -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw UploadFailure(message: "此图片的元数据暂无法解析；原文件仍完整保留。")
        }
        var raw = safe(properties) as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        for key in ["DateTimeOriginal", "OffsetTimeOriginal", "LensMake", "LensModel", "ExposureTime", "FNumber", "ISOSpeedRatings", "FocalLength"] {
            if let value = exif[key] { raw[key] = safe(value) }
        }
        raw["CreateDate"] = exif["DateTimeDigitized"]
        raw["OffsetTimeDigitized"] = exif["OffsetTimeDigitized"]
        raw["Make"] = tiff["Make"]
        raw["Model"] = tiff["Model"]
        raw["ImageWidth"] = properties[kCGImagePropertyPixelWidth as String]
        raw["ImageHeight"] = properties[kCGImagePropertyPixelHeight as String]
        raw["Orientation"] = properties[kCGImagePropertyOrientation as String]
        if let latitude = gps["Latitude"] as? NSNumber { raw["latitude"] = latitude.doubleValue * ((gps["LatitudeRef"] as? String) == "S" ? -1 : 1) }
        if let longitude = gps["Longitude"] as? NSNumber { raw["longitude"] = longitude.doubleValue * ((gps["LongitudeRef"] as? String) == "W" ? -1 : 1) }
        if let altitude = gps["Altitude"] as? NSNumber { raw["altitude"] = altitude.doubleValue * ((gps["AltitudeRef"] as? NSNumber)?.intValue == 1 ? -1 : 1) }
        if let apple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] {
            raw["ContentIdentifier"] = apple["17"] as? String
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil), let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
            var xmp: [String: Any] = [:]
            for tag in tags.prefix(4096) {
                if let name = CGImageMetadataTagCopyName(tag), let value = CGImageMetadataTagCopyValue(tag) {
                    let prefix = CGImageMetadataTagCopyPrefix(tag).map { $0 as String } ?? ""
                    xmp[prefix + ":" + (name as String)] = safe(value)
                    if (name as String) == "ContentIdentifier", raw["ContentIdentifier"] == nil { raw["ContentIdentifier"] = value as? String }
                }
            }
            raw["XMP"] = xmp
        }
        return raw
    }
    static func movie(_ url: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var raw: [String: Any] = [:]
        let formats = try await asset.load(.availableMetadataFormats)
        for format in formats {
            for item in try await asset.loadMetadata(for: format).prefix(4096) {
                try Task.checkCancellation()
                let key = (item.key as? String) ?? item.identifier?.rawValue ?? ""
                if let value = try await item.load(.stringValue) { raw[key] = String(value.prefix(65536)) }
            }
        }
        let duration = try await asset.load(.duration).seconds
        if duration.isFinite && duration >= 0 { raw["Duration"] = duration }
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            raw["ImageWidth"] = Int(abs(rect.width))
            raw["ImageHeight"] = Int(abs(rect.height))
            raw["PreferredTransform"] = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
        }
        return raw
    }
    static func fields(_ raw: [String: Any]) -> [String: Any] {
        let exifDate = wallTime(raw["DateTimeOriginal"] as? String)
        let createDate = wallTime(raw["CreateDate"] as? String)
        let quickDate = (raw["com.apple.quicktime.creationdate"] ?? raw["CreationDate"]) as? String
        let taken = exifDate ?? createDate ?? wallTime(quickDate)
        var fields: [String: Any] = ["time_source": exifDate != nil ? "EXIF.DateTimeOriginal" : createDate != nil ? "EXIF.CreateDate" : taken != nil ? "QuickTime.CreationDate" : "unknown", "time_confidence": taken == nil ? "unknown" : "high"]
        fields["original_taken_at_local"] = taken
        // Do not borrow a video offset for an EXIF date when no matching EXIF offset exists.
        fields["original_offset_minutes"] = offset(exifDate != nil ? raw["OffsetTimeOriginal"] as? String : createDate != nil ? raw["OffsetTimeDigitized"] as? String : quickDate)
        for (field, key) in [("latitude", "latitude"), ("longitude", "longitude"), ("altitude", "altitude"), ("width", "ImageWidth"), ("height", "ImageHeight")] { fields[field] = raw[key] }
        fields["device_make"] = raw["Make"] ?? raw["com.apple.quicktime.make"]
        fields["device_model"] = raw["Model"] ?? raw["com.apple.quicktime.model"]
        if let duration = raw["Duration"] as? Double { fields["duration_ms"] = Int64((duration * 1000).rounded()) }
        if let coordinate = raw["com.apple.quicktime.location.ISO6709"] as? String,
           let regex = try? NSRegularExpression(pattern: #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?"#),
           let match = regex.firstMatch(in: coordinate, range: NSRange(coordinate.startIndex..., in: coordinate)) {
            for (index, name) in [(1, "latitude"), (2, "longitude"), (3, "altitude")] {
                if let range = Range(match.range(at: index), in: coordinate) { fields[name] = Double(coordinate[range]) }
            }
        }
        return fields
    }
    #if canImport(Photos)
    static func inspect(_ resources: [UploadResource], directory: URL, asset: PHAsset, edited: Bool) async throws -> [String: Any] {
        var metadata: [String: Any] = ["source": "ios_photokit", "parse_status": "parsed", "representation": edited ? "edited_full_size" : "unmodified_original"]
        var originals: [String: Any] = [:], pairIDs: [String] = [], warnings: [String] = []
        for resource in resources {
            let url = directory.appendingPathComponent(resource.path)
            var raw: [String: Any]
            do {
                raw = ["mov", "mp4"].contains(url.pathExtension.lowercased()) ? try await movie(url) : try image(url)
                raw["parse_status"] = "parsed"
            } catch {
                if error is CancellationError { throw error }
                raw = ["parse_status": "partial", "parse_error": "系统解析器未能读取全部元数据；原件未修改。"]
                metadata["parse_status"] = "partial"
            }
            raw["OriginalFilename"] = resource.filename
            raw["FileSize"] = resource.size
            raw["MIME"] = resource.mimeType
            metadata[resource.role] = raw
            if resource.role == "original" { originals = raw }
            if let id = (raw["ContentIdentifier"] ?? raw["com.apple.quicktime.content.identifier"]) as? String { pairIDs.append(id) }
        }
        if resources.count == 2 {
            if pairIDs.count == 2 && pairIDs[0] != pairIDs[1] { throw UploadFailure(message: "Live Photo 图片与 MOV 的 ContentIdentifier 不匹配，未创建上传。") }
            metadata["pairing_source"] = pairIDs.count == 2 ? "ContentIdentifier" : "PHAssetResource.sameAsset"
            if pairIDs.count != 2 { warnings.append("系统未解析出两份 ContentIdentifier；配对依据为 PhotoKit 同一 Live Photo 资源组。") }
        }
        var auxiliary: [String: Any] = ["pixelWidth": asset.pixelWidth, "pixelHeight": asset.pixelHeight, "duration": asset.duration]
        if let date = asset.creationDate { auxiliary["creationDateUTC"] = ISO8601DateFormatter().string(from: date) }
        if let location = asset.location { auxiliary["location"] = ["latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude, "altitude": location.altitude] }
        metadata["photokit_auxiliary"] = auxiliary
        // Metadata is bounded separately from file bytes; oversized raw fields stay in the untouched original.
        if try JSONSerialization.data(withJSONObject: metadata).count > 900_000 {
            metadata = ["source": "ios_photokit", "parse_status": "partial", "parse_error": "元数据超过 JSON 预算，完整信息保留在原件中。", "photokit_auxiliary": auxiliary, "representation": edited ? "edited_full_size" : "unmodified_original"]
            warnings.append("元数据较大，数据库只保存常用字段；完整 EXIF/XMP/IPTC 保留在原件。")
        }
        var result = fields(originals)
        result["metadata"] = metadata
        if result["original_taken_at_local"] == nil {
            warnings.append(asset.creationDate == nil
                ? "原件和相册都没有可用日期。"
                : "原件拍摄时间未知，可用相册日期归档。")
        }
        result["client_warning"] = warnings.joined(separator: "\n")
        return result
    }
    #endif
}
