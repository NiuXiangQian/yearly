package family.yearly.app

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.AtomicFile
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import okhttp3.RequestBody
import okio.BufferedSink
import org.json.JSONArray
import org.json.JSONObject

/** Manifest contains source descriptions and server task IDs, with no session or signed URLs. */
data class UploadResource(
    val path: String,
    val name: String,
    val mime: String,
    val role: String,
    val size: Long,
    val sha: String,
    val crc: String,
    val task: JSONObject? = null,
    val uploaded: Long = 0,
    val complete: Boolean = false,
) {
    fun specification() =
        json(
            "original_filename" to name,
            "mime_type" to mime,
            "file_role" to role,
            "file_size" to size,
            "sha256" to sha,
            "crc64" to crc,
        )

    fun serialize() =
        specification()
            .put("path", path)
            .put("task", task ?: JSONObject.NULL)
            .put("uploaded", uploaded)
            .put("complete", complete)

    companion object {
        fun parse(value: JSONObject) =
            UploadResource(
                value.getString("path"),
                value.getString("original_filename"),
                value.getString("mime_type"),
                value.getString("file_role"),
                value.getLong("file_size"),
                value.getString("sha256"),
                value.getString("crc64"),
                value.optJSONObject("task"),
                value.optLong("uploaded"),
                value.optBoolean("complete"),
            )
    }
}

data class UploadItem(
    val id: String,
    val site: String,
    val owner: Int,
    val source: String,
    val name: String,
    val mime: String,
    val phase: String = "selected",
    val message: String = "",
    val resources: List<UploadResource> = emptyList(),
    val fields: JSONObject = JSONObject(),
    val children: Set<Int> = emptySet(),
    val batch: String = "",
    val archive: String = "",
    val confirmed: Boolean = false,
    val mediaId: Int? = null,
    val contentId: String? = null,
    val preparedBytes: Long = 0,
    val speed: Long = 0,
) {
    val terminal
        get() = phase in listOf("complete", "cancelled", "skipped")

    val size
        get() = resources.sumOf { it.size }

    val uploaded
        get() = resources.sumOf { if (it.complete) it.size else it.uploaded }

    val type
        get() =
            if (resources.size == 2) "live_photo"
            else if (mime.startsWith("video/")) "video" else "photo"

    val label
        get() =
            when (phase) {
                "selected" -> "等待提取"
                "preparing" -> "准备原片"
                "ready" -> "待确认上传"
                "queued" -> "等待上传"
                "uploading" -> "上传中"
                "paused" -> "已暂停"
                "failed" -> "失败，可重试"
                "complete" -> "已完成"
                "cancelled" -> "已取消"
                "skipped" -> "重复已跳过"
                else -> phase
            }

    fun serialize() =
        json(
            "id" to id,
            "site" to site,
            "owner" to owner,
            "source" to source,
            "name" to name,
            "mime" to mime,
            "phase" to phase,
            "message" to message,
            "resources" to JSONArray(resources.map { it.serialize() }),
            "fields" to fields,
            "children" to children,
            "batch" to batch,
            "archive" to archive,
            "confirmed" to confirmed,
            "mediaId" to mediaId,
            "contentId" to contentId,
        )

    companion object {
        fun parse(row: JSONObject): UploadItem {
            val phase = row.text("phase")
            return UploadItem(
                row.getString("id"),
                row.getString("site"),
                row.getInt("owner"),
                row.text("source"),
                row.getString("name"),
                row.getString("mime"),
                if (phase in listOf("selected", "preparing", "queued", "uploading")) "paused"
                else phase,
                row.text("message"),
                row.objects("resources").map(UploadResource::parse),
                row.optJSONObject("fields") ?: JSONObject(),
                row.ids("children"),
                row.text("batch"),
                row.text("archive"),
                row.optBoolean("confirmed"),
                row.optionalInt("mediaId"),
                row.text("contentId").ifBlank { null },
            )
        }
    }
}

class UploadQueue(
    private val context: Context,
    private val api: YearlyApi,
    private val scope: CoroutineScope,
) {
    private val directory = File(context.noBackupFilesDir, "original-queue").apply { mkdirs() }
    private val manifest = AtomicFile(File(directory, "queue.json"))
    private val mutableItems = MutableStateFlow<List<UploadItem>>(emptyList())
    val items = mutableItems.asStateFlow()
    private val jobs = mutableMapOf<String, Job>()
    private val activeCalls = java.util.concurrent.ConcurrentHashMap<String, okhttp3.Call>()
    private val preferences =
        context.getSharedPreferences("upload-preferences", Context.MODE_PRIVATE)
    var loadError: String = ""
        private set

    init {
        if (manifest.baseFile.exists()) {
            try {
                mutableItems.value =
                    JSONArray(String(manifest.readFully())).objects().map(UploadItem::parse)
            } catch (error: Exception) {
                loadError = "上传记录读取失败，已保留本机原件。${error.message.orEmpty()}"
            }
        }
    }

    fun visible(): List<UploadItem> =
        items.value.filter { it.site == api.currentSite && it.owner == api.account.value?.id }

    fun rememberedChildren(): Set<Int> =
        preferences
            .getString(api.scope, "")
            .orEmpty()
            .split(',')
            .mapNotNull(String::toIntOrNull)
            .toSet()

    fun rememberChildren(ids: Set<Int>) {
        preferences.edit().putString(api.scope, ids.joinToString(",")).apply()
    }

    private fun save() {
        check(loadError.isBlank()) { loadError }
        val output = manifest.startWrite()
        try {
            output.write(JSONArray(items.value.map { it.serialize() }).toString().toByteArray())
            manifest.finishWrite(output)
        } catch (error: Exception) {
            manifest.failWrite(output)
            throw error
        }
    }

    private fun update(id: String, persist: Boolean = true, change: (UploadItem) -> UploadItem) {
        mutableItems.value = items.value.map { if (it.id == id) change(it) else it }
        if (persist) save()
    }

    private fun item(id: String) = items.value.first { it.id == id }

    private fun folder(id: String) = File(directory, id).apply { mkdirs() }

    private fun local(id: String, resource: UploadResource): File {
        require(
            resource.path == File(resource.path).name && resource.path !in listOf("", ".", "..")
        )
        return File(folder(id), resource.path)
    }

    fun select(uris: List<Uri>) {
        check(loadError.isBlank()) { loadError }
        val owner = requireNotNull(api.account.value).id
        val additions =
            uris.map { uri ->
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
                val name =
                    context.contentResolver
                        .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                        ?.use { if (it.moveToFirst()) it.getString(0) else null }
                        ?: "original-${UUID.randomUUID()}"
                val safeName = name.replace(Regex("[/\\\\\\x00-\\x1f]"), "_").take(255)
                UploadItem(
                    UUID.randomUUID().toString(),
                    api.currentSite,
                    owner,
                    uri.toString(),
                    safeName,
                    context.contentResolver.getType(uri) ?: mimeFor(safeName),
                )
            }
        mutableItems.value +=
            additions.filter { added ->
                visible().none { !it.terminal && it.source == added.source }
            }
        save()
        prepareNext()
    }

    private fun prepareNext() {
        if (visible().any { it.phase == "preparing" }) return
        visible().firstOrNull { it.phase == "selected" }?.let { prepare(it.id) }
    }

    private fun prepare(id: String) {
        if (jobs[id]?.isActive == true) return
        jobs[id] =
            scope.launch {
                update(id) { it.copy(phase = "preparing", message = "", preparedBytes = 0) }
                try {
                    val selected = item(id)
                    val result =
                        withContext(Dispatchers.IO) {
                            val root = folder(id)
                            root.listFiles()?.forEach { it.delete() }
                            val existingBytes =
                                directory.walkTopDown().filter(File::isFile).sumOf(File::length)
                            val target = File(root, "original")
                            val options = android.os.Bundle()
                            if (android.os.Build.VERSION.SDK_INT >= 31)
                                options.putBoolean(
                                    android.provider.MediaStore.EXTRA_ACCEPT_ORIGINAL_MEDIA_FORMAT,
                                    true,
                                )
                            context.contentResolver
                                .openTypedAssetFileDescriptor(
                                    Uri.parse(selected.source),
                                    "*/*",
                                    options,
                                )!!
                                .use { descriptor ->
                                    descriptor.createInputStream().use { source ->
                                        target.outputStream().use { output ->
                                            val buffer = ByteArray(1024 * 1024)
                                            var copied = 0L
                                            while (true) {
                                                currentCoroutineContext().ensureActive()
                                                val count = source.read(buffer)
                                                if (count < 0) break
                                                if (
                                                    directory.usableSpace < 512L * 1024 * 1024 ||
                                                        existingBytes + copied + count >
                                                            8L * 1024 * 1024 * 1024
                                                ) {
                                                    error("原片缓存达到 8 GiB 或剩余空间不足 512 MiB，请先完成已有任务。")
                                                }
                                                output.write(buffer, 0, count)
                                                copied += count
                                                withContext(Dispatchers.Main) {
                                                    update(id, false) {
                                                        it.copy(preparedBytes = copied)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            val coroutine = currentCoroutineContext()
                            fun resource(
                                file: File,
                                name: String,
                                mime: String,
                                role: String,
                            ): UploadResource {
                                val fingerprint =
                                    file.inputStream().use {
                                        FileIntegrity.fingerprint(it) { coroutine.ensureActive() }
                                    }
                                return UploadResource(
                                    file.name,
                                    name,
                                    mime,
                                    role,
                                    fingerprint.size,
                                    fingerprint.sha256,
                                    fingerprint.crc64,
                                )
                            }
                            val original =
                                resource(target, selected.name, selected.mime, "original")
                            val metadata =
                                OriginalMetadata.read(target, selected.mime.startsWith("video/"))
                            metadata.fields
                                .getJSONObject("metadata")
                                .put(
                                    "android_source_dates",
                                    OriginalMetadata.sourceDates(
                                        context,
                                        Uri.parse(selected.source),
                                    ),
                                )
                            val resources = mutableListOf(original)
                            if (
                                !selected.mime.startsWith("video/") &&
                                    OriginalMetadata.extractMotionPhoto(
                                        target,
                                        File(root, "motion"),
                                    )
                            ) {
                                resources +=
                                    resource(
                                        File(root, "motion"),
                                        selected.name.substringBeforeLast('.') + ".mp4",
                                        "video/mp4",
                                        "live_video",
                                    )
                            }
                            Triple(resources.toList(), metadata.fields, metadata.contentId)
                        }
                    update(id) {
                        it.copy(
                            resources = result.first,
                            fields = result.second,
                            contentId = result.third,
                            phase = "ready",
                            preparedBytes = 0,
                        )
                    }
                    context.contentResolver.releasePersistableUriPermission(
                        Uri.parse(selected.source),
                        android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                    pairOriginals()
                    if (items.value.none { it.id == id }) return@launch
                    val prepared = item(id)
                    val duplicate =
                        visible().firstOrNull { other ->
                            other.id != id &&
                                other.phase != "cancelled" &&
                                other.resources.isNotEmpty() &&
                                other.resources.map { it.sha to it.role }.toSet() ==
                                    prepared.resources.map { it.sha to it.role }.toSet()
                        }
                    if (duplicate != null) {
                        update(id) {
                            it.copy(
                                phase = "skipped",
                                message = "与队列中的 ${duplicate.name} 相同，已跳过重复原件。",
                            )
                        }
                        folder(id).deleteRecursively()
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    update(id) {
                        it.copy(phase = "failed", message = error.message ?: "原片读取失败，请重新选择。")
                    }
                } finally {
                    prepareNext()
                }
            }
    }

    private fun pairOriginals() {
        val ready =
            visible().filter {
                it.phase == "ready" && it.contentId != null && it.resources.size == 1
            }
        for (photo in ready.filter { !it.mime.startsWith("video/") }) {
            val video =
                ready.firstOrNull {
                    it.mime.startsWith("video/") && it.contentId == photo.contentId
                } ?: continue
            val videoResource = video.resources.single()
            val destination = File(folder(photo.id), "motion")
            check(local(video.id, videoResource).renameTo(destination)) { "配对原件整理失败" }
            update(photo.id) {
                it.copy(
                    resources =
                        it.resources + videoResource.copy(path = "motion", role = "live_video")
                )
            }
            mutableItems.value = items.value.filter { it.id != video.id }
            folder(video.id).deleteRecursively()
            save()
        }
    }

    fun confirm(ids: Set<String>, children: Set<Int>, batch: String, archive: String) {
        check(api.account.value?.canWrite == true) { "此账户没有上传权限" }
        if (archive.isNotBlank()) java.time.LocalDate.parse(archive)
        rememberChildren(children)
        for (entry in visible().filter { it.id in ids && it.phase == "ready" }) {
            update(entry.id) {
                it.copy(
                    children = children,
                    batch = batch,
                    archive =
                        archive.ifBlank {
                            OriginalMetadata.archiveFallback(it.fields)
                                ?.first
                                ?.substringBefore('T')
                                .orEmpty()
                        },
                    confirmed = true,
                    phase = "queued",
                )
            }
        }
        startNext()
    }

    private fun startNext() {
        if (visible().any { it.phase == "uploading" }) return
        visible().firstOrNull { it.phase == "queued" }?.let { upload(it.id) }
    }

    fun pause(id: String) {
        jobs[id]?.cancel()
        activeCalls.remove(id)?.cancel()
        update(id) { it.copy(phase = "paused", message = "任务保留在本机，可继续。", speed = 0) }
    }

    fun pauseAll() {
        visible()
            .filter { it.phase in listOf("selected", "preparing", "queued", "uploading") }
            .forEach { pause(it.id) }
    }

    fun resume(id: String) {
        val current = item(id)
        check(current.site == api.currentSite && current.owner == api.account.value?.id) {
            "请使用创建任务的账户登录"
        }
        if (current.resources.isEmpty()) prepare(id)
        else if (!current.confirmed) update(id) { it.copy(phase = "ready", message = "") }
        else {
            update(id) { it.copy(phase = "queued", message = "") }
            startNext()
        }
    }

    fun cancel(id: String) {
        jobs[id]?.cancel()
        activeCalls.remove(id)?.cancel()
        update(id) { it.copy(phase = "cancelled", message = "已取消，释放本机原件缓存。", speed = 0) }
        folder(id).deleteRecursively()
        startNext()
    }

    fun clearFinished() {
        val removed = visible().filter { it.terminal }.map { it.id }.toSet()
        mutableItems.value = items.value.filter { it.id !in removed }
        removed.forEach { folder(it).deleteRecursively() }
        save()
    }

    private fun upload(id: String) {
        jobs[id] =
            scope.launch {
                update(id) { it.copy(phase = "uploading", message = "", speed = 0) }
                try {
                    val current = item(id)
                    val actor = Account.parse(api.getObject("/auth/me", true))
                    check(actor.id == current.owner && actor.canWrite) { "请使用创建任务的账户继续上传" }
                    if (current.resources.any { it.task == null }) {
                        val body =
                            JSONObject(current.fields.toString()).apply {
                                put("media_type", current.type)
                                put(
                                    "files",
                                    JSONArray(current.resources.map { it.specification() }),
                                )
                                put("child_ids", JSONArray(current.children.toList()))
                                put("batch_name", current.batch)
                                put(
                                    "timeline_date",
                                    current.archive.ifBlank { null } ?: JSONObject.NULL,
                                )
                            }
                        val created = retryUpload {
                            api.write("/uploads", "POST", body, current.id)
                        }
                        if (created.optBoolean("duplicate") && created.objects("tasks").isEmpty()) {
                            update(id) {
                                it.copy(
                                    phase = "skipped",
                                    mediaId = created.getInt("media_id"),
                                    message = "站点已有相同原件，已合并关联。",
                                )
                            }
                            folder(id).deleteRecursively()
                            return@launch
                        }
                        val tasks = created.objects("tasks")
                        check(tasks.size == current.resources.size) { "服务端返回的资源数量不匹配" }
                        val resources =
                            current.resources.map { resource ->
                                val task = tasks.single { it.text("file_role") == resource.role }
                                check(
                                    task.getLong("file_size") == resource.size &&
                                        task.getString("sha256") == resource.sha &&
                                        task.getInt("part_size") in 1..(64 * 1024 * 1024)
                                ) {
                                    "上传任务与原件不匹配"
                                }
                                resource.copy(task = task)
                            }
                        update(id) {
                            it.copy(resources = resources, mediaId = created.getInt("media_id"))
                        }
                    }
                    for (resourceIndex in item(id).resources.indices) uploadResource(
                        id,
                        resourceIndex,
                    )
                    update(id) {
                        it.copy(phase = "complete", message = "所有原件均通过服务端完整性校验。", speed = 0)
                    }
                    folder(id).deleteRecursively()
                    api.invalidate()
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    update(id) {
                        it.copy(phase = "failed", message = error.message ?: "上传失败，可重试。", speed = 0)
                    }
                } finally {
                    startNext()
                }
            }
    }

    private suspend fun uploadResource(id: String, index: Int) {
        val resource = item(id).resources[index]
        if (resource.complete) return
        val task = requireNotNull(resource.task)
        val taskId = task.getString("id")
        val status = retryUpload { api.getObject("/uploads/$taskId", true) }
        fun checkpoint(bytes: Long, complete: Boolean, persist: Boolean = true, speed: Long = 0) {
            update(id, persist) { entry ->
                entry.copy(
                    resources =
                        entry.resources.mapIndexed { position, old ->
                            if (
                                index == position &&
                                    (persist || (entry.phase == "uploading" && !old.complete))
                            )
                                old.copy(
                                    uploaded = if (persist) bytes else maxOf(old.uploaded, bytes),
                                    complete = complete,
                                )
                            else old
                        },
                    speed = speed,
                )
            }
        }
        if (status.text("status") == "complete") {
            checkpoint(resource.size, true)
            return
        }
        check(status.text("status") in listOf("pending", "uploading")) { "任务已失效，请取消后重新选择原件。" }
        val file = local(id, resource)
        withContext(Dispatchers.IO) {
            FileIntegrity.verify(file, resource.size, resource.sha, resource.crc)
        }
        val partSize = task.getInt("part_size").toLong()
        val count = ((resource.size + partSize - 1) / partSize).toInt()
        check(count in 1..10000) { "分片数量超出上传协议限制" }
        val parts = status.objects("parts")
        val numbers = parts.map { it.getInt("number") }.toSet()
        check(
            numbers.size == parts.size &&
                parts.all { part ->
                    val number = part.getInt("number")
                    number in 1..count &&
                        part.getLong("size") ==
                            minOf(partSize, resource.size - (number - 1) * partSize)
                }
        ) {
            "服务端分片记录不匹配"
        }
        var completed = parts.sumOf { it.getLong("size") }
        checkpoint(completed, false)
        for (number in 1..count) {
            if (number in numbers) continue
            currentCoroutineContext().ensureActive()
            val length = minOf(partSize, resource.size - (number - 1) * partSize)
            retryUpload {
                val signed =
                    api.write("/uploads/$taskId/sign?number=$number", "POST").getString("url")
                val completedBefore = completed
                val started = System.nanoTime()
                withContext(Dispatchers.IO) {
                    val coroutine = currentCoroutineContext()
                    val requestBody =
                        object : RequestBody() {
                            // OSS signs an empty Content-Type for multipart PUTs.
                            override fun contentType(): okhttp3.MediaType? = null

                            override fun contentLength() = length

                            override fun writeTo(sink: BufferedSink) {
                                RandomAccessFile(file, "r").use { source ->
                                    source.seek((number - 1) * partSize)
                                    val buffer = ByteArray(256 * 1024)
                                    var sent = 0L
                                    var lastReport = 0L
                                    while (sent < length) {
                                        coroutine.ensureActive()
                                        val read =
                                            source.read(
                                                buffer,
                                                0,
                                                minOf(buffer.size.toLong(), length - sent).toInt(),
                                            )
                                        check(read > 0) { "本机原件缓存不完整" }
                                        sink.write(buffer, 0, read)
                                        sent += read
                                        val now = System.nanoTime()
                                        if (now - lastReport > 250_000_000) {
                                            val bytes = sent
                                            val speed =
                                                (sent * 1_000_000_000.0 / (now - started)).toLong()
                                            scope.launch {
                                                checkpoint(
                                                    completedBefore + bytes,
                                                    false,
                                                    false,
                                                    speed,
                                                )
                                            }
                                            lastReport = now
                                        }
                                    }
                                }
                            }
                        }
                    val url = signed.toHttpUrl()
                    check(url.isHttps) { "上传地址必须使用 HTTPS" }
                    val call =
                        api.client.newCall(Request.Builder().url(url).put(requestBody).build())
                    activeCalls[id] = call
                    try {
                        call.execute().use { response ->
                            if (!response.isSuccessful) {
                                val code =
                                    Regex("<Code>([A-Za-z0-9]+)</Code>")
                                        .find(response.peekBody(4096).string())
                                        ?.groupValues
                                        ?.get(1)
                                throw ApiFailure(
                                    response.code,
                                    "原件上传失败（${response.code}${code?.let { "/$it" }.orEmpty()}），已保留分片，可重试。",
                                    objectStore = true,
                                )
                            }
                        }
                    } finally {
                        activeCalls.remove(id, call)
                    }
                }
            }
            completed += length
            checkpoint(completed, false)
        }
        val completion = retryUpload { api.write("/uploads/$taskId/complete", "POST") }
        check(completion.text("status") == "complete") { "服务端尚未确认原件完整性，请重试。" }
        checkpoint(resource.size, true)
    }

    companion object {
        fun mimeFor(name: String): String =
            when (name.substringAfterLast('.').lowercase()) {
                "mov" -> "video/quicktime"
                "mp4",
                "m4v" -> "video/mp4"
                "heic",
                "heif" -> "image/heic"
                "png" -> "image/png"
                "webp" -> "image/webp"
                else -> "image/jpeg"
            }
    }
}

suspend fun <T> retryUpload(operation: suspend () -> T): T {
    repeat(3) { attempt ->
        try {
            return operation()
        } catch (failure: CancellationException) {
            throw failure
        } catch (failure: Exception) {
            val transient =
                failure is java.io.IOException ||
                    (failure is ApiFailure &&
                        (failure.status >= 500 ||
                            failure.status == 429 ||
                            (failure.objectStore && failure.status in listOf(403, 409))))
            if (!transient || attempt == 2) throw failure
            delay(1000L shl attempt)
        }
    }
    error("上传重试未完成")
}
