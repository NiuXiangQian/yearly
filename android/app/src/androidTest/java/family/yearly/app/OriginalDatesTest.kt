package family.yearly.app

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.ContextWrapper
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Bitmap
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OriginalDatesTest {
    @Test
    fun realExifBytesPreserveCaptureDateAndUseTheMatchingOffset() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.cacheDir, "date-fixture-${System.nanoTime()}")
        try {
            val bitmap = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888)
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }
            bitmap.recycle()
            ExifInterface(file).apply {
                setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2017:02:03 04:05:06")
                setAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL, "+08:00")
                setAttribute(ExifInterface.TAG_DATETIME_DIGITIZED, "2020:06:07 08:09:10")
                setAttribute(ExifInterface.TAG_OFFSET_TIME_DIGITIZED, "-03:30")
                saveAttributes()
            }
            var bytes = file.readBytes()
            val original = OriginalMetadata.read(file, false).fields
            assertEquals("2017-02-03T04:05:06", original.getString("original_taken_at_local"))
            assertEquals(480, original.getInt("original_offset_minutes"))
            assertEquals("EXIF.DateTimeOriginal", original.getString("time_source"))
            assertArrayEquals(bytes, file.readBytes())

            ExifInterface(file).apply {
                setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, null)
                saveAttributes()
            }
            val created = OriginalMetadata.read(file, false).fields
            assertEquals("2020-06-07T08:09:10", created.getString("original_taken_at_local"))
            assertEquals(-210, created.getInt("original_offset_minutes"))
            assertEquals("EXIF.CreateDate", created.getString("time_source"))

            ExifInterface(file).apply {
                setAttribute(ExifInterface.TAG_DATETIME_DIGITIZED, null)
                setAttribute(ExifInterface.TAG_DATETIME, "2019:05:06 07:08:09")
                saveAttributes()
            }
            bytes = file.readBytes()
            val modified = OriginalMetadata.read(file, false).fields
            assertFalse(modified.has("original_taken_at_local"))
            assertEquals(
                "2019-05-06T07:08:09" to "文件修改时间（EXIF）",
                OriginalMetadata.archiveFallback(modified),
            )
            assertArrayEquals(bytes, file.readBytes())
        } finally {
            file.delete()
        }
    }

    @Test
    fun actualMp4CreationMetadataIsReadFromAnExtensionlessCacheFile() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val file = File(instrumentation.targetContext.cacheDir, "video-date-${System.nanoTime()}")
        try {
            instrumentation.context.assets.open("metadata-creation.mp4").use { source ->
                file.outputStream().use { source.copyTo(it) }
            }
            val bytes = file.readBytes()
            val fields = OriginalMetadata.read(file, true).fields
            assertEquals("2021-07-08T13:14:15", fields.getString("original_taken_at_local"))
            assertEquals(0, fields.getInt("original_offset_minutes"))
            assertEquals("QuickTime.CreationDate", fields.getString("time_source"))
            assertTrue(fields.getJSONObject("metadata").getString("CreationDate").isNotBlank())
            assertArrayEquals(bytes, file.readBytes())

            instrumentation.context.assets.open("metadata-local.mov").use { source ->
                file.outputStream().use { source.copyTo(it) }
            }
            val local = OriginalMetadata.read(file, true).fields
            assertEquals("2021-07-08T21:14:15", local.getString("original_taken_at_local"))
            assertEquals(480, local.getInt("original_offset_minutes"))
        } finally {
            file.delete()
        }
    }

    @Test
    fun selectedProviderDateUnitsAndMissingColumnsDoNotInventCaptureDates() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var documentOnly = false
        val provider =
            object : ContentProvider() {
                override fun onCreate() = true

                override fun getType(uri: Uri) = "image/jpeg"

                override fun query(
                    uri: Uri,
                    projection: Array<out String>?,
                    selection: String?,
                    selectionArgs: Array<out String>?,
                    sortOrder: String?,
                ): Cursor {
                    val column = projection!!.single()
                    val value =
                        if (documentOnly) {
                            require(column == DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                            1_600_000_000_123L
                        } else
                            when (column) {
                                MediaStore.MediaColumns.DATE_TAKEN -> 1_500_000_000_123L
                                MediaStore.MediaColumns.DATE_MODIFIED -> 1_600_000_000L
                                MediaStore.MediaColumns.DATE_ADDED -> 1_700_000_000L
                                else -> throw IllegalArgumentException("Unsupported column")
                            }
                    return MatrixCursor(arrayOf(column)).apply { addRow(arrayOf(value)) }
                }

                override fun insert(uri: Uri, values: ContentValues?): Uri? = null

                override fun update(
                    uri: Uri,
                    values: ContentValues?,
                    selection: String?,
                    selectionArgs: Array<out String>?,
                ) = 0

                override fun delete(
                    uri: Uri,
                    selection: String?,
                    selectionArgs: Array<out String>?,
                ) = 0
            }
        val selectedContext =
            object : ContextWrapper(context) {
                override fun getContentResolver() = ContentResolver.wrap(provider)
            }
        val uri = Uri.parse("content://yearly-date-fixture/original")
        val album = OriginalMetadata.sourceDates(selectedContext, uri)
        assertEquals(1_500_000_000_123L, album.getLong("taken_at_ms"))
        assertEquals(1_600_000_000_000L, album.getLong("modified_at_ms"))
        assertEquals(1_700_000_000_000L, album.getLong("added_at_ms"))
        documentOnly = true
        val document = OriginalMetadata.sourceDates(selectedContext, uri)
        assertEquals(1_600_000_000_123L, document.getLong("modified_at_ms"))
        assertFalse(document.has("taken_at_ms"))
        assertFalse(document.has("added_at_ms"))
    }
}
