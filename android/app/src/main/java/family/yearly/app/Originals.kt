package family.yearly.app

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import com.drew.imaging.ImageMetadataReader
import com.drew.metadata.mov.metadata.QuickTimeMetadataDirectory
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.TemporalQueries
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONObject

object FileIntegrity {
    private val table =
        LongArray(256) { index ->
            var crc = index.toLong()
            repeat(8) {
                crc = (crc ushr 1) xor if (crc and 1L != 0L) 0xC96C5795D7870F42UL.toLong() else 0L
            }
            crc
        }

    data class Fingerprint(val size: Long, val sha256: String, val crc64: String)

    fun fingerprint(input: InputStream, check: () -> Unit = {}): Fingerprint {
        val sha = MessageDigest.getInstance("SHA-256")
        var crc = -1L
        var size = 0L
        val buffer = ByteArray(1024 * 1024)
        while (true) {
            check()
            val count = input.read(buffer)
            if (count < 0) break
            sha.update(buffer, 0, count)
            for (index in 0 until count) crc =
                table[((crc xor buffer[index].toLong()) and 255).toInt()] xor (crc ushr 8)
            size += count
        }
        require(size > 0) { "原始文件为空" }
        return Fingerprint(
            size,
            sha.digest().joinToString("") { "%02x".format(it) },
            java.lang.Long.toUnsignedString(crc xor -1L),
        )
    }

    fun verify(file: File, expectedSize: Long, sha: String, crc: String) {
        val actual = file.inputStream().use { fingerprint(it) }
        check(actual.size == expectedSize && actual.sha256 == sha && actual.crc64 == crc) {
            "原件完整性校验失败，请重新选择文件。"
        }
    }
}

object OriginalMetadata {
    data class Result(val fields: JSONObject, val contentId: String?)

    data class DateValue(val local: LocalDateTime, val offsetMinutes: Int?)

    // EXIF uses wall time; Android video metadata commonly uses yyyyMMddTHHmmss.SSSZ.
    // Keep the embedded offset, and never apply today's device offset to an EXIF wall time.
    fun parseDate(value: String): DateValue? {
        var normalized = value.trim().trimEnd('\u0000')
        normalized =
            normalized
                .replace(Regex("^(\\d{4}):(\\d{2}):(\\d{2}) "), "$1-$2-$3T")
                .replace(Regex("^(\\d{4}-\\d{2}-\\d{2}) "), "$1T")
        normalized =
            normalized
                .replace(
                    Regex("^(\\d{4})(\\d{2})(\\d{2})T(\\d{2})(\\d{2})(\\d{2})"),
                    "$1-$2-$3T$4:$5:$6",
                )
                .replace(Regex("([+-]\\d{2})(\\d{2})$"), "$1:$2")
        return runCatching {
                val parsed = DateTimeFormatter.ISO_DATE_TIME.parse(normalized)
                DateValue(
                    LocalDateTime.from(parsed),
                    parsed.query(TemporalQueries.offset())?.totalSeconds?.div(60),
                )
            }
            .getOrNull()
    }

    // Query the selected provider before releasing its URI grant. Cache file timestamps
    // describe our copy, so they must never be used as dates of the user's original.
    fun sourceDates(context: Context, uri: Uri): JSONObject {
        val dates = JSONObject()
        val mediaUri =
            if (Build.VERSION.SDK_INT >= 29 && DocumentsContract.isDocumentUri(context, uri)) {
                runCatching { MediaStore.getMediaUri(context, uri) }.getOrNull()
            } else null
        for (source in listOfNotNull(mediaUri, uri).distinct()) {
            for ((column, multiplier, field) in
                listOf(
                    Triple(MediaStore.MediaColumns.DATE_TAKEN, 1L, "taken_at_ms"),
                    Triple(MediaStore.MediaColumns.DATE_MODIFIED, 1000L, "modified_at_ms"),
                    Triple(DocumentsContract.Document.COLUMN_LAST_MODIFIED, 1L, "modified_at_ms"),
                    Triple(MediaStore.MediaColumns.DATE_ADDED, 1000L, "added_at_ms"),
                )) {
                if (dates.has(field)) continue
                // Cloud and document providers may omit or reject MediaStore columns.
                runCatching {
                    context.contentResolver.query(source, arrayOf(column), null, null, null)?.use {
                        cursor ->
                        val index = cursor.getColumnIndex(column)
                        if (cursor.moveToFirst() && index >= 0 && !cursor.isNull(index)) {
                            val value = cursor.getLong(index)
                            if (value > 0) dates.put(field, value * multiplier)
                        }
                    }
                }
            }
        }
        return dates
    }

    fun archiveFallback(fields: JSONObject): Pair<String, String>? {
        if (fields.text("original_taken_at_local").isNotBlank()) return null
        val metadata = fields.optJSONObject("metadata") ?: return null
        val dates = metadata.optJSONObject("android_source_dates")
        dates
            ?.optLong("taken_at_ms")
            ?.takeIf { it > 0 }
            ?.let {
                return Instant.ofEpochMilli(it)
                    .atZone(ZoneId.systemDefault())
                    .toLocalDateTime()
                    .toString() to "相册日期"
            }
        metadata
            .text("embedded_modified_at_local")
            .takeIf { it.isNotBlank() }
            ?.let {
                return it to "文件修改时间（EXIF）"
            }
        for ((key, label) in listOf("modified_at_ms" to "源文件修改时间", "added_at_ms" to "加入相册时间")) {
            dates
                ?.optLong(key)
                ?.takeIf { it > 0 }
                ?.let {
                    return Instant.ofEpochMilli(it)
                        .atZone(ZoneId.systemDefault())
                        .toLocalDateTime()
                        .toString() to label
                }
        }
        return null
    }

    fun read(file: File, video: Boolean): Result {
        val raw =
            json(
                "source" to "android_system_picker",
                "representation" to "provider_original",
                "parser_name" to "Android ExifInterface / MediaMetadataRetriever",
                "parse_status" to "parsed",
            )
        val fields = json("time_source" to "unknown", "time_confidence" to "unknown")
        if (video) {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(file.path)
                fun value(key: Int) = retriever.extractMetadata(key)
                val date = value(MediaMetadataRetriever.METADATA_KEY_DATE)
                if (date != null) {
                    val parsed = parseDate(date)
                    if (parsed != null) {
                        fields.put("original_taken_at_local", parsed.local.toString())
                        parsed.offsetMinutes?.let { fields.put("original_offset_minutes", it) }
                        fields
                            .put("time_source", "QuickTime.CreationDate")
                            .put("time_confidence", "high")
                    }
                    raw.put("CreationDate", date)
                }
                value(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                    ?.toIntOrNull()
                    ?.takeIf { it > 0 }
                    ?.let { fields.put("width", it) }
                value(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                    ?.toIntOrNull()
                    ?.takeIf { it > 0 }
                    ?.let { fields.put("height", it) }
                value(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.let {
                    fields.put("duration_ms", it)
                }
                value(MediaMetadataRetriever.METADATA_KEY_LOCATION)?.let { location ->
                    raw.put("Location", location)
                    val match =
                        Regex("^([+-]\\d+(?:\\.\\d+)?)([+-]\\d+(?:\\.\\d+)?)").find(location)
                    match?.let {
                        fields
                            .put("latitude", it.groupValues[1].toDouble())
                            .put("longitude", it.groupValues[2].toDouble())
                    }
                }
            } catch (error: RuntimeException) {
                raw.put("parse_status", "partial").put("warning", "无法读取部分视频元数据")
            } finally {
                retriever.release()
            }
        } else {
            try {
                val exif = ExifInterface(file)
                for ((tag, offsetTag, source) in
                    listOf(
                        Triple(
                            ExifInterface.TAG_DATETIME_ORIGINAL,
                            ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
                            "EXIF.DateTimeOriginal",
                        ),
                        Triple(
                            ExifInterface.TAG_DATETIME_DIGITIZED,
                            ExifInterface.TAG_OFFSET_TIME_DIGITIZED,
                            "EXIF.CreateDate",
                        ),
                    )) {
                    val parsed = exif.getAttribute(tag)?.let(::parseDate) ?: continue
                    fields
                        .put("original_taken_at_local", parsed.local.toString())
                        .put("time_source", source)
                        .put("time_confidence", "high")
                    val offset =
                        exif.getAttribute(offsetTag)?.let {
                            runCatching { java.time.ZoneOffset.of(it).totalSeconds / 60 }
                                .getOrNull()
                        } ?: parsed.offsetMinutes
                    offset?.let { fields.put("original_offset_minutes", it) }
                    break
                }
                exif.getAttribute(ExifInterface.TAG_DATETIME)?.let(::parseDate)?.let {
                    raw.put("embedded_modified_at_local", it.local.toString())
                }
                listOf(
                        "device_make" to ExifInterface.TAG_MAKE,
                        "device_model" to ExifInterface.TAG_MODEL,
                    )
                    .forEach { (field, tag) ->
                        exif.getAttribute(tag)?.let { fields.put(field, it) }
                    }
                listOf(
                        "width" to ExifInterface.TAG_IMAGE_WIDTH,
                        "height" to ExifInterface.TAG_IMAGE_LENGTH,
                    )
                    .forEach { (field, tag) ->
                        exif
                            .getAttributeInt(tag, 0)
                            .takeIf { it > 0 }
                            ?.let { fields.put(field, it) }
                    }
                exif.latLong?.let { fields.put("latitude", it[0]).put("longitude", it[1]) }
                val altitude = exif.getAltitude(Double.NaN)
                if (altitude.isFinite()) fields.put("altitude", altitude)
                for (tag in
                    listOf(
                        ExifInterface.TAG_MAKE,
                        ExifInterface.TAG_MODEL,
                        ExifInterface.TAG_DATETIME_ORIGINAL,
                        ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
                        ExifInterface.TAG_DATETIME_DIGITIZED,
                        ExifInterface.TAG_OFFSET_TIME_DIGITIZED,
                        ExifInterface.TAG_DATETIME,
                        ExifInterface.TAG_ORIENTATION,
                        ExifInterface.TAG_F_NUMBER,
                        ExifInterface.TAG_EXPOSURE_TIME,
                        ExifInterface.TAG_FOCAL_LENGTH,
                        ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
                    )) {
                    exif.getAttribute(tag)?.let { raw.put(tag, it) }
                }
            } catch (error: java.io.IOException) {
                raw.put("parse_status", "partial").put("warning", "此格式的部分元数据无法读取")
            }
        }
        var contentId: String? = null
        try {
            val metadata = ImageMetadataReader.readMetadata(file)
            for (directory in metadata.directories) {
                // iPhone MOV files can retain their original local time and offset here,
                // while MediaMetadataRetriever exposes only the UTC movie-header date.
                if (video && directory is QuickTimeMetadataDirectory) {
                    directory.getString(QuickTimeMetadataDirectory.TAG_CREATION_DATE)?.let { date ->
                        raw.put("com.apple.quicktime.creationdate", date)
                        parseDate(date)?.let { parsed ->
                            fields
                                .put("original_taken_at_local", parsed.local.toString())
                                .put("time_source", "QuickTime.CreationDate")
                                .put("time_confidence", "high")
                            fields.remove("original_offset_minutes")
                            parsed.offsetMinutes?.let { fields.put("original_offset_minutes", it) }
                        }
                    }
                }
                for (tag in directory.tags) {
                    if (
                        tag.tagName.contains("Content Identifier", true) ||
                            (directory.name.contains("Apple", true) && tag.tagType == 17)
                    ) {
                        val value = directory.getString(tag.tagType)?.trim()
                        if (!value.isNullOrEmpty()) contentId = value
                    }
                }
            }
        } catch (error: com.drew.imaging.ImageProcessingException) {
            // The Android parsers above cover formats not recognized by metadata-extractor.
        }
        contentId?.let { raw.put("ContentIdentifier", it) }
        fields.put("metadata", raw)
        return Result(fields, contentId)
    }

    // Google/Samsung XMP Motion Photos place an intact MP4 at the end of the image.
    // Read only the XMP prefix, then stream the paired video without recompressing the photo.
    suspend fun extractMotionPhoto(file: File, output: File): Boolean {
        val prefix =
            file.inputStream().use { input ->
                val bytes = ByteArray(minOf(file.length(), 1024 * 1024L).toInt())
                val read = input.read(bytes)
                String(bytes, 0, maxOf(0, read), Charsets.ISO_8859_1)
            }
        if (!prefix.contains("MotionPhoto") && !prefix.contains("MicroVideo")) return false
        val oldOffset =
            Regex("(?:MicroVideoOffset)[=\\s]+[\"'](\\d+)[\"']")
                .find(prefix)
                ?.groupValues
                ?.get(1)
                ?.toLongOrNull()
        val videoItem =
            Regex("<[^>]*(?:Mime|Semantic)[^>]*>")
                .findAll(prefix)
                .map { it.value }
                .firstOrNull { it.contains("video/mp4") && it.contains("MotionPhoto") }
        val itemLength =
            videoItem?.let {
                Regex("(?:Item:Length|Length)=[\"'](\\d+)[\"']")
                    .find(it)
                    ?.groupValues
                    ?.get(1)
                    ?.toLongOrNull()
            }
        val offset = oldOffset ?: itemLength ?: return false
        if (offset < 12 || offset >= file.length()) return false
        RandomAccessFile(file, "r").use { source ->
            source.seek(file.length() - offset + 4)
            val signature = ByteArray(4)
            source.readFully(signature)
            if (String(signature, Charsets.US_ASCII) != "ftyp") return false
            source.seek(file.length() - offset)
            output.outputStream().use { target ->
                val buffer = ByteArray(1024 * 1024)
                var remaining = offset
                while (remaining > 0) {
                    currentCoroutineContext().ensureActive()
                    val count =
                        source.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                    check(count > 0) { "动态照片视频不完整" }
                    target.write(buffer, 0, count)
                    remaining -= count
                }
            }
        }
        return true
    }
}
