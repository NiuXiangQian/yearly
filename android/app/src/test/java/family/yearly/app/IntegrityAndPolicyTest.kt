package family.yearly.app

import java.io.ByteArrayInputStream
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class IntegrityAndPolicyTest {
    @Test
    fun mediaDatesKeepEmbeddedWallTimeAndOffsets() {
        val expected = java.time.LocalDateTime.of(2021, 7, 8, 13, 14, 15)
        for (text in listOf("20210708T131415.000Z", "2021-07-08T13:14:15Z")) {
            assertEquals(OriginalMetadata.DateValue(expected, 0), OriginalMetadata.parseDate(text))
        }
        assertEquals(
            OriginalMetadata.DateValue(expected, 480),
            OriginalMetadata.parseDate("20210708T131415+0800"),
        )
        assertEquals(
            OriginalMetadata.DateValue(expected, -210),
            OriginalMetadata.parseDate("2021-07-08T13:14:15-03:30"),
        )
        for (text in listOf("2021:07:08 13:14:15", "2021-07-08 13:14:15")) {
            assertEquals(
                OriginalMetadata.DateValue(expected, null),
                OriginalMetadata.parseDate(text),
            )
        }
        for (text in listOf("", "0000:00:00 00:00:00", "2021:02:30 13:14:15", "yesterday")) {
            assertNull(OriginalMetadata.parseDate(text))
        }
    }

    @Test
    fun fallbackDatesUseSourceRatherThanImportAndDoNotBecomeCaptureTimes() {
        val previous = java.util.TimeZone.getDefault()
        java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone("Asia/Shanghai"))
        try {
            val dates =
                json(
                    "taken_at_ms" to java.time.Instant.parse("2020-02-29T18:00:00Z").toEpochMilli(),
                    "modified_at_ms" to
                        java.time.Instant.parse("2022-01-01T00:00:00Z").toEpochMilli(),
                )
            val fields = json("metadata" to json("android_source_dates" to dates))
            assertEquals("2020-03-01T02:00" to "相册日期", OriginalMetadata.archiveFallback(fields))
            assertFalse(fields.has("original_taken_at_local"))
            fields.put("original_taken_at_local", "2018-01-02T03:04:05")
            assertNull(OriginalMetadata.archiveFallback(fields))
            fields.remove("original_taken_at_local")
            dates.remove("taken_at_ms")
            assertEquals("2022-01-01T08:00" to "源文件修改时间", OriginalMetadata.archiveFallback(fields))
            dates.remove("modified_at_ms")
            assertNull(OriginalMetadata.archiveFallback(fields))
        } finally {
            java.util.TimeZone.setDefault(previous)
        }
    }

    @Test
    fun crc64MatchesOssXzVectorAndStreamingSha() {
        val data = "123456789".toByteArray()
        val actual = FileIntegrity.fingerprint(data.inputStream())
        assertEquals(9, actual.size)
        assertEquals("11051210869376104954", actual.crc64)
        assertEquals(
            MessageDigest.getInstance("SHA-256").digest(data).joinToString("") {
                "%02x".format(it)
            },
            actual.sha256,
        )
        val large = ByteArray(3 * 1024 * 1024 + 19) { (it % 251).toByte() }
        val splitStream =
            object : ByteArrayInputStream(large) {
                override fun read(buffer: ByteArray, offset: Int, count: Int): Int =
                    super.read(buffer, offset, minOf(count, 177))
            }
        assertEquals(
            FileIntegrity.fingerprint(large.inputStream()),
            splitStream.use { FileIntegrity.fingerprint(it) },
        )
    }

    @Test
    fun invalidSiteCannotCarryCredentialsOrChangeOrigin() {
        for (value in
            listOf(
                "http://example.com",
                "https://user:password@example.com/",
                "https://example.com/?key=x",
                "https://example.com/#hash",
            )) {
            assertThrows(IllegalArgumentException::class.java) { YearlyApi.parseSite(value) }
        }
        assertEquals(
            "https://example.com/yearly/",
            YearlyApi.parseSite("https://example.com/yearly").toString(),
        )
        assertEquals(
            "http://10.0.2.2:9876/family/",
            YearlyApi.parseSite("http://10.0.2.2:9876/family", true).toString(),
        )
        assertThrows(IllegalArgumentException::class.java) {
            YearlyApi.parseSite("http://192.168.1.2", true)
        }
    }

    @Test
    fun embeddedMotionVideoIsExtractedWithoutChangingOriginalBytes() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory().toFile()
        try {
            val video =
                byteArrayOf(0, 0, 0, 16) + "ftypisom".toByteArray() + ByteArray(20) { it.toByte() }
            val source = File(directory, "motion.jpg")
            val original =
                ("JPEG <x:xmpmeta GCamera:MotionPhoto=\"1\" GCamera:MicroVideoOffset=\"${video.size}\" />"
                    .toByteArray() + video)
            source.writeBytes(original)
            val output = File(directory, "motion.mp4")
            assertTrue(OriginalMetadata.extractMotionPhoto(source, output))
            assertArrayEquals(video, output.readBytes())
            assertArrayEquals(original, source.readBytes())
            source.writeText("JPEG GCamera:MotionPhoto=\"1\" GCamera:MicroVideoOffset=\"9999999\"")
            assertFalse(OriginalMetadata.extractMotionPhoto(source, output))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun dateRailUsesCalendarDistanceInsteadOfImageCount() {
        val scale = TimelineScale(listOf("2026-11-10", "2026-11-09", "2020-01-01"))
        assertTrue(scale.ratio("2026-11-09") < 0.001)
        assertEquals("2020-01-01", scale.nearest(0.9))
        assertEquals("2026-11-10", scale.nearest(0.0))
        val oldestFirst = TimelineScale(listOf("2020-01-01", "2026-11-09", "2026-11-10"))
        assertEquals("2020-01-01", oldestFirst.nearest(0.0))
        assertEquals("2026-11-10", oldestFirst.nearest(1.0))
    }

    @Test
    fun uploadDatesMatchTheDevicesCalendarDay() {
        val previous = java.util.TimeZone.getDefault()
        java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone("Asia/Shanghai"))
        try {
            assertEquals(
                "2026-11-11",
                Memory(json("id" to 1, "uploaded_at" to "2026-11-10T18:30:00")).uploadedDay,
            )
            assertEquals(
                "2026-11-10",
                Memory(json("id" to 1, "uploaded_at" to "2026-11-10T02:30:00Z")).uploadedDay,
            )
        } finally {
            java.util.TimeZone.setDefault(previous)
        }
    }

    @Test
    fun queueRoundTripRestoresInterruptedWorkAsPaused() {
        val original =
            UploadItem(
                "id",
                "https://example.com/",
                7,
                "content://source",
                "a.jpg",
                "image/jpeg",
                phase = "uploading",
                confirmed = true,
            )
        val restored = UploadItem.parse(original.serialize())
        assertEquals("paused", restored.phase)
        assertTrue(restored.confirmed)
        assertEquals(7, restored.owner)
    }
}
