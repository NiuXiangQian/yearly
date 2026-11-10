package family.yearly.app

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.io.ByteArrayOutputStream
import java.time.LocalDateTime
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

@Composable
fun MediaEditor(model: AppModel, memory: Memory, close: () -> Unit) {
    val account by model.api.account.collectAsStateWithLifecycle()
    var detail by remember { mutableStateOf<JSONObject?>(null) }
    LaunchedEffect(memory.id) {
        model.run { detail = model.api.getObject("/media/${memory.id}", true) }
    }
    val row = detail
    if (row == null) {
        PageBar("编辑影像", close)
        return
    }
    var title by remember { mutableStateOf(row.text("title")) }
    var batch by remember { mutableStateOf(row.text("batch_name")) }
    var remark by remember { mutableStateOf(row.text("remark")) }
    var tags by remember { mutableStateOf(row.strings("tags").joinToString("，")) }
    var archive by remember { mutableStateOf(row.text("timeline_date")) }
    var corrected by remember { mutableStateOf(row.text("corrected_taken_at_local")) }
    var offset by remember { mutableStateOf(row.text("corrected_offset_minutes")) }
    var unknown by remember { mutableStateOf(row.optBoolean("time_unknown")) }
    var location by remember { mutableStateOf(row.text("location_name")) }
    var latitude by remember { mutableStateOf(row.text("latitude")) }
    var longitude by remember { mutableStateOf(row.text("longitude")) }
    var share by remember { mutableStateOf(row.optBoolean("share_allowed", true)) }
    var children by remember { mutableStateOf(row.ids("child_ids")) }
    FormPage(
        "编辑影像",
        close,
        enabled = account?.canEdit(row) == true,
        onSave = {
            if (corrected.isNotBlank()) LocalDateTime.parse(corrected)
            val body =
                json(
                    "title" to title,
                    "batch_name" to batch,
                    "remark" to remark,
                    "tags" to
                        tags.split(Regex("[,，]")).map(String::trim).filter(String::isNotBlank),
                    "timeline_date" to archive.ifBlank { null },
                    "corrected_taken_at_local" to corrected.ifBlank { null },
                    "corrected_offset_minutes" to offset.takeIf(String::isNotBlank)?.toInt(),
                    "time_unknown" to unknown,
                    "location_name" to location,
                    "latitude" to latitude.takeIf(String::isNotBlank)?.toDouble(),
                    "longitude" to longitude.takeIf(String::isNotBlank)?.toDouble(),
                    "share_allowed" to share,
                    "child_ids" to children,
                )
            model.change("/media/${memory.id}", "PUT", body)
            close()
        },
    ) {
        Field("标题", title) { title = it }
        Field("批次名称", batch) { batch = it }
        DateField("归档日期", archive) { archive = it }
        Field("备注", remark, multiline = true) { remark = it }
        Field("标签，以逗号分隔", tags) { tags = it }
        SectionTitle("拍摄信息")
        Text(
            "原始拍摄时间 ${row.text("original_taken_at_local", "未知")}",
            style = MaterialTheme.typography.bodySmall,
        )
        Field("修正时间，例如 2026-11-10T12:30:00", corrected) { corrected = it }
        Field("时区偏移分钟，例如 480", offset) { offset = it }
        ToggleRow("拍摄时间未知", unknown) { unknown = it }
        Field("地点", location) { location = it }
        Field("纬度", latitude) { latitude = it }
        Field("经度", longitude) { longitude = it }
        ToggleRow("允许分享", share) { share = it }
        SectionTitle("关联人物与宠物")
        PeoplePicker(model.profiles, children) { children = it }
    }
}

@Composable
fun EventScreen(
    model: AppModel,
    destination: Destination,
    close: () -> Unit,
    navigate: (Destination) -> Unit,
) {
    val account by model.api.account.collectAsStateWithLifecycle()
    val existing = destination.item
    var row by
        remember(existing?.id) {
            mutableStateOf<JSONObject?>(if (existing == null) JSONObject() else null)
        }
    LaunchedEffect(existing?.id) {
        if (existing != null)
            model.run { row = model.api.getObject("/events/${existing.id}", true) }
    }
    val value = row ?: return
    if (destination.page == "event") {
        Column(Modifier.fillMaxSize()) {
            PageBar(
                value.text("title", "日记"),
                close,
                actions = {
                    if (account?.canEdit(value) == true)
                        IconButton({
                            navigate(Destination("event-edit", Memory(value.put("kind", "event"))))
                        }) {
                            Icon(Icons.Outlined.Edit, "编辑日记")
                        }
                    IconButton({
                        navigate(
                            Destination(
                                "audit",
                                raw = json("id" to existing?.id),
                                resource = "timeline_event",
                            )
                        )
                    }) {
                        Icon(Icons.Outlined.History, "修改日志")
                    }
                },
            )
            LazyColumn(
                contentPadding = PaddingValues(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                item {
                    Text(
                        value.text("start_at").replace('T', ' '),
                        style = MaterialTheme.typography.labelLarge,
                    )
                }
                item { Text(value.text("content"), style = MaterialTheme.typography.bodyLarge) }
                items(value.objects("media").map(::Memory), key = { it.id }) { memory ->
                    TextButton({ navigate(Destination("media", memory)) }) { Text(memory.label) }
                    PreviewImage(
                        model.api,
                        memory,
                        Modifier.fillMaxWidth().height(240.dp),
                        "preview",
                    )
                }
            }
        }
        return
    }
    var title by remember { mutableStateOf(value.text("title")) }
    var content by remember { mutableStateOf(value.text("content")) }
    var start by remember {
        mutableStateOf(
            value.text(
                "start_at",
                destination.day.takeIf(String::isNotBlank)?.let { "${it}T12:00:00" }.orEmpty(),
            )
        )
    }
    var end by remember { mutableStateOf(value.text("end_at")) }
    var children by remember { mutableStateOf(value.ids("child_ids")) }
    var mediaIds by remember { mutableStateOf(value.ids("media_ids").ifEmpty { destination.ids }) }
    var cover by remember { mutableStateOf(value.optionalInt("cover_media_id")) }
    var share by remember { mutableStateOf(value.optBoolean("share_allowed", true)) }
    var chooser by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    FormPage(
        if (existing == null) "写日记" else "编辑日记",
        close,
        enabled = title.isNotBlank(),
        onSave = {
            if (start.isNotBlank()) LocalDateTime.parse(start)
            if (end.isNotBlank()) LocalDateTime.parse(end)
            model.change(
                existing?.let { "/events/${it.id}" } ?: "/events",
                if (existing == null) "POST" else "PUT",
                json(
                    "title" to title,
                    "content" to content,
                    "start_at" to start.ifBlank { null },
                    "end_at" to end.ifBlank { null },
                    "child_ids" to children,
                    "media_ids" to mediaIds,
                    "cover_media_id" to cover,
                    "share_allowed" to share,
                ),
            )
            close()
        },
    ) {
        Field("日记标题", title) { title = it }
        Field("写下这一天的回忆", content, multiline = true) { content = it }
        Field("开始时间，例如 2026-11-10T12:00:00", start) { start = it }
        Field("结束时间，可留空", end) { end = it }
        ToggleRow("允许分享", share) { share = it }
        SectionTitle("人物与宠物")
        PeoplePicker(model.profiles, children) { children = it }
        OutlinedButton({ chooser = true }) { Text("选择关联影像 · ${mediaIds.size} 项") }
        Choice(
            "封面影像",
            cover?.toString().orEmpty(),
            listOf("" to "不设置封面") + mediaIds.sorted().map { it.toString() to "影像 #$it" },
        ) {
            cover = it.toIntOrNull()
        }
        if (existing != null)
            TextButton({ deleting = true }) {
                Text("将日记移入回收站", color = MaterialTheme.colorScheme.error)
            }
    }
    if (chooser)
        MediaChooser(model, mediaIds, false, { chooser = false }) {
            mediaIds = it
            if (cover !in it) cover = null
            chooser = false
        }
    if (deleting)
        ConfirmDialog("移入回收站", "日记可以从回收站恢复。", "移入回收站", { deleting = false }) {
            deleting = false
            model.run {
                model.change("/events/${existing!!.id}", "DELETE")
                close()
            }
        }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MediaChooser(
    model: AppModel,
    initial: Set<Int>,
    photosOnly: Boolean,
    close: () -> Unit,
    selected: (Set<Int>) -> Unit,
) {
    var ids by remember { mutableStateOf(initial) }
    var page by remember { mutableIntStateOf(1) }
    var rows by remember { mutableStateOf<List<Memory>>(emptyList()) }
    var total by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    LaunchedEffect(page) {
        loading = true
        try {
            val result =
                model.api.getObject(
                    "/media?page=$page&page_size=30" + if (photosOnly) "&media_type=photo" else ""
                )
            rows = (rows + result.objects("items").map(::Memory)).distinctBy { it.id }
            total = result.getInt("total")
        } catch (failure: Exception) {
            error = failure.message.orEmpty()
        } finally {
            loading = false
        }
    }
    ModalBottomSheet(onDismissRequest = close) {
        Column(Modifier.fillMaxHeight(.9f).padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("选择影像", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                TextButton({ selected(ids) }) { Text("完成（${ids.size}）") }
            }
            if (error.isNotBlank()) ErrorBanner(error)
            LazyColumn(Modifier.weight(1f)) {
                items(rows, key = { it.id }) { memory ->
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        PreviewImage(model.api, memory, Modifier.size(64.dp))
                        Column(Modifier.weight(1f).padding(12.dp)) {
                            Text(memory.label)
                            Text(memory.day, style = MaterialTheme.typography.labelSmall)
                        }
                        Checkbox(
                            memory.id in ids,
                            { checked ->
                                ids =
                                    if (photosOnly) setOf(memory.id)
                                    else if (checked) ids + memory.id else ids - memory.id
                            },
                        )
                    }
                }
                if (rows.size < total)
                    item { TextButton({ page++ }, enabled = !loading) { Text("加载更多影像") } }
                if (loading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ProfileEditor(
    model: AppModel,
    existing: JSONObject?,
    close: () -> Unit,
    navigate: (Destination) -> Unit,
) {
    val context = LocalContext.current
    val row = existing ?: JSONObject()
    var name by remember { mutableStateOf(row.text("name")) }
    var nickname by remember { mutableStateOf(row.text("nickname")) }
    var type by remember { mutableStateOf(row.text("profile_type", "child")) }
    var birthday by remember { mutableStateOf(row.text("birthday")) }
    var birthTime by remember { mutableStateOf(row.text("birth_time")) }
    var gender by remember { mutableStateOf(row.text("gender")) }
    var relationship by remember { mutableStateOf(row.text("relationship")) }
    var species by remember { mutableStateOf(row.text("species")) }
    var breed by remember { mutableStateOf(row.text("breed")) }
    var description by remember { mutableStateOf(row.text("description")) }
    var color by remember { mutableStateOf(row.text("theme_color", "#bf775d")) }
    var sort by remember { mutableStateOf(row.text("sort_order", "0")) }
    var status by remember { mutableStateOf(row.text("status", "active")) }
    var growth by remember { mutableStateOf(row.optBoolean("growth_enabled", true)) }
    var avatar by remember { mutableStateOf(row.optionalInt("avatar_media_id")) }
    var avatarBytes by remember { mutableStateOf<ByteArray?>(null) }
    var chooser by remember { mutableStateOf(false) }
    val picker =
        rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
            if (uri != null)
                model.run {
                    avatarBytes =
                        withContext(Dispatchers.IO) {
                            val bitmap =
                                if (Build.VERSION.SDK_INT >= 28)
                                    ImageDecoder.decodeBitmap(
                                        ImageDecoder.createSource(context.contentResolver, uri)
                                    ) { decoder, info, _ ->
                                        val ratio = maxOf(info.size.width, info.size.height) / 1024f
                                        if (ratio > 1)
                                            decoder.setTargetSize(
                                                (info.size.width / ratio).toInt(),
                                                (info.size.height / ratio).toInt(),
                                            )
                                        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                                    }
                                else
                                    context.contentResolver.openInputStream(uri)!!.use {
                                        android.graphics.BitmapFactory.decodeStream(it)
                                    }
                            val size = minOf(bitmap.width, bitmap.height)
                            val cropped =
                                Bitmap.createBitmap(
                                    bitmap,
                                    (bitmap.width - size) / 2,
                                    (bitmap.height - size) / 2,
                                    size,
                                    size,
                                )
                            val scaled = Bitmap.createScaledBitmap(cropped, 512, 512, true)
                            ByteArrayOutputStream().use { output ->
                                scaled.compress(Bitmap.CompressFormat.JPEG, 90, output)
                                output.toByteArray()
                            }
                        }
                }
        }
    FormPage(
        if (existing == null) "添加家人或宠物" else "编辑家人资料",
        close,
        enabled = name.isNotBlank(),
        onSave = {
            var avatarId = avatar
            if (avatarBytes != null) avatarId = uploadAvatar(model.api, avatarBytes!!)
            val body =
                json(
                    "name" to name,
                    "nickname" to nickname,
                    "profile_type" to type,
                    "birthday" to birthday.ifBlank { null },
                    "birth_time" to birthTime.ifBlank { null },
                    "gender" to gender.ifBlank { null },
                    "relationship" to relationship,
                    "species" to species,
                    "breed" to breed,
                    "description" to description,
                    "theme_color" to color,
                    "sort_order" to sort.toInt(),
                    "status" to status,
                    "growth_enabled" to growth,
                    "avatar_media_id" to avatarId,
                )
            model.change(
                existing?.let { "/children/${it.getInt("id")}" } ?: "/children",
                if (existing == null) "POST" else "PUT",
                body,
            )
            model.profiles = model.api.getArray("/children", true).map(::Profile)
            close()
        },
    ) {
        if (avatarBytes != null)
            coil.compose.AsyncImage(avatarBytes, "新头像预览", Modifier.size(100.dp))
        Text(if (avatarBytes != null) "已选择新头像，保存资料时上传" else avatar?.let { "当前头像 #$it" } ?: "使用默认头像")
        FlowRow {
            TextButton({ picker.launch("image/*") }) { Text("从设备选择头像") }
            TextButton({ chooser = true }) { Text("从影像库选择") }
            TextButton({
                avatar = null
                avatarBytes = null
            }) {
                Text("清除")
            }
        }
        Field("姓名", name) { name = it }
        Field("昵称", nickname) { nickname = it }
        Choice("档案类型", type, listOf("child" to "孩子", "person" to "家人", "pet" to "宠物")) { type = it }
        DateField("出生日期", birthday) { birthday = it }
        Field("出生时间，例如 08:30:00", birthTime) { birthTime = it }
        Field("性别", gender) { gender = it }
        Field("关系", relationship) { relationship = it }
        if (type == "pet") {
            Field("物种", species) { species = it }
            Field("品种", breed) { breed = it }
        }
        ToggleRow("显示成长年龄", growth) { growth = it }
        Field("介绍", description, multiline = true) { description = it }
        Field("主题颜色，例如 #bf775d", color) { color = it }
        Field("排序", sort) { sort = it }
        Choice("档案状态", status, listOf("active" to "正常", "archived" to "已归档")) { status = it }
        if (existing != null)
            TextButton({
                navigate(
                    Destination(
                        "audit",
                        raw = json("id" to existing.getInt("id")),
                        resource = "child",
                    )
                )
            }) {
                Text("查看修改记录")
            }
    }
    if (chooser)
        MediaChooser(model, avatar?.let(::setOf).orEmpty(), true, { chooser = false }) {
            avatar = it.firstOrNull()
            avatarBytes = null
            chooser = false
        }
}

suspend fun uploadAvatar(api: YearlyApi, bytes: ByteArray): Int =
    withContext(Dispatchers.IO) {
        val fingerprint = bytes.inputStream().use { FileIntegrity.fingerprint(it) }
        val file =
            json(
                "original_filename" to "avatar.jpg",
                "mime_type" to "image/jpeg",
                "file_role" to "original",
                "file_size" to fingerprint.size,
                "sha256" to fingerprint.sha256,
                "crc64" to fingerprint.crc64,
            )
        api.getArray("/uploads", true)
        val created =
            api.write(
                "/uploads",
                "POST",
                json(
                    "purpose" to "avatar",
                    "media_type" to "photo",
                    "files" to JSONArray(listOf(file)),
                ),
                UUID.randomUUID().toString(),
            )
        for (task in created.objects("tasks")) {
            val id = task.getString("id")
            val status = api.getObject("/uploads/$id", true)
            if (status.text("status") == "complete") continue
            val signed = api.write("/uploads/$id/sign?number=1", "POST").getString("url")
            val url = signed.toHttpUrl()
            check(url.isHttps) { "头像上传地址必须使用 HTTPS" }
            val body = bytes.toRequestBody()
            api.client.newCall(okhttp3.Request.Builder().url(url).put(body).build()).execute().use {
                check(it.isSuccessful) { "头像上传失败" }
            }
            check(api.write("/uploads/$id/complete", "POST").text("status") == "complete") {
                "服务端尚未确认头像完整性"
            }
        }
        created.getInt("media_id")
    }
