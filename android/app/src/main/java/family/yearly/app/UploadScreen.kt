package family.yearly.app

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.LocalDate

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UploadScreen(model: AppModel, showRecent: () -> Unit, showUploaded: (Int) -> Unit) {
    val account by model.api.account.collectAsStateWithLifecycle()
    val allItems by model.uploads.items.collectAsStateWithLifecycle()
    val items = allItems.filter { it.site == model.api.currentSite && it.owner == account?.id }
    var includeFinished by remember { mutableStateOf(false) }
    var showWaiting by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }
    var confirmIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var children by remember(model.api.scope) { mutableStateOf(model.uploads.rememberedChildren()) }
    var batch by remember { mutableStateOf("") }
    var archive by remember { mutableStateOf("") }
    var cancelling by remember { mutableStateOf<UploadItem?>(null) }
    var error by remember { mutableStateOf("") }
    val filesPicker =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
            if (uris.isNotEmpty()) model.run { model.uploads.select(uris) }
        }
    val photoPicker =
        rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(100)) {
            uris ->
            if (uris.isNotEmpty()) model.run { model.uploads.select(uris) }
        }
    val ready = items.filter { it.phase == "ready" }
    val active = items.filter { it.phase in listOf("preparing", "uploading") }
    val waiting = items.filter { !it.terminal && it.phase !in listOf("preparing", "uploading") }
    val completed = items.filter { it.terminal }
    Column(Modifier.fillMaxSize()) {
        PageBar(
            "珍藏原片",
            actions = {
                IconButton({ model.uploads.pauseAll() }) {
                    Icon(Icons.Outlined.PauseCircle, "暂停全部任务")
                }
            },
        )
        LazyColumn(
            Modifier.weight(1f),
            contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                Text("让每一份原片，都有归处", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.height(8.dp))
                Text(
                    "选择后先准备原始资源，检查人物、批次和日期，再确认上传。",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (account?.canWrite == true) {
                item {
                    Button(
                        {
                            photoPicker.launch(
                                PickVisualMediaRequest(
                                    ActivityResultContracts.PickVisualMedia.ImageAndVideo
                                )
                            )
                        },
                        Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Outlined.AddPhotoAlternate, null)
                        Spacer(Modifier.width(8.dp))
                        Text("从系统相册选择照片与视频")
                    }
                }
                item {
                    OutlinedButton(
                        { filesPicker.launch(arrayOf("image/*", "video/*")) },
                        Modifier.fillMaxWidth(),
                    ) {
                        Text("从文件导入原片 / 照片与 MOV")
                    }
                }
            } else item { Text("当前账户为只读访客，可浏览家庭时光。") }
            if (model.uploads.loadError.isNotBlank()) item { ErrorBanner(model.uploads.loadError) }
            if (items.isNotEmpty())
                item {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Column {
                            Text("${ready.size}", style = MaterialTheme.typography.headlineMedium)
                            Text("原片就绪")
                        }
                        Column {
                            Text(
                                byteLabel(items.filter { !it.terminal }.sumOf { it.size }),
                                style = MaterialTheme.typography.headlineSmall,
                            )
                            Text("待完成原片")
                        }
                        Column {
                            Text(
                                "${completed.count { it.phase == "complete" }}",
                                style = MaterialTheme.typography.headlineMedium,
                            )
                            Text("已完成")
                        }
                    }
                }
            val transfers =
                items.filter { it.confirmed && it.phase !in listOf("cancelled", "skipped") }
            if (transfers.isNotEmpty())
                item {
                    val total = transfers.sumOf { it.size }
                    val sent = transfers.sumOf { it.uploaded }
                    val done = transfers.count { it.phase == "complete" }
                    val finished = done == transfers.size
                    Text(
                        if (finished) "上传完成 · $done 项原件已校验"
                        else "上传总进度 · ${(sent.toDouble() / total.coerceAtLeast(1) * 100).toInt()}%",
                        style = MaterialTheme.typography.titleMedium,
                    )
                    LinearProgressIndicator(
                        progress = { (sent.toFloat() / total.coerceAtLeast(1)).coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        "${byteLabel(sent)} / ${byteLabel(total)}",
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Row {
                        if (transfers.any { it.phase == "failed" })
                            TextButton({
                                model.run {
                                    transfers
                                        .filter { it.phase == "failed" }
                                        .forEach { model.uploads.resume(it.id) }
                                }
                            }) {
                                Text("全部重试")
                            }
                        if (transfers.any { it.phase == "paused" })
                            TextButton({
                                model.run {
                                    transfers
                                        .filter { it.phase == "paused" }
                                        .forEach { model.uploads.resume(it.id) }
                                }
                            }) {
                                Text("全部继续")
                            }
                        if (done > 0) TextButton(showRecent) { Text("按上传时间查看") }
                    }
                }
            items(active + if (showWaiting) waiting else waiting.take(3), key = { it.id }) { entry
                ->
                UploadRow(
                    entry,
                    { model.uploads.pause(entry.id) },
                    { model.run { model.uploads.resume(entry.id) } },
                    { cancelling = entry },
                    showUploaded,
                )
            }
            if (waiting.size > 3)
                item {
                    TextButton({ showWaiting = !showWaiting }, Modifier.fillMaxWidth()) {
                        Text(if (showWaiting) "收起等待项" else "展开全部 ${waiting.size} 条等待项")
                    }
                }
            if (completed.isNotEmpty())
                item {
                    ToggleRow("查看已结束记录（${completed.size}）", includeFinished) {
                        includeFinished = it
                    }
                    if (includeFinished)
                        TextButton({ model.uploads.clearFinished() }) { Text("清除已结束记录") }
                }
            if (includeFinished)
                items(completed, key = { it.id }) { entry ->
                    UploadRow(entry, {}, {}, {}, showUploaded)
                }
            if (items.isEmpty()) item { EmptyState("每一天，都值得被记住", "原片、拍摄时间与元数据会一并珍藏。") }
        }
        if (ready.isNotEmpty())
            Surface(shadowElevation = 4.dp) {
                Button(
                    {
                        confirmIds = ready.map { it.id }.toSet()
                        error = ""
                        model.run {
                            model.uploads.refreshDates(confirmIds)
                            confirming = true
                        }
                    },
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                    enabled = !model.busy,
                ) {
                    Text("上传所选 ${ready.size} 项 · ${byteLabel(ready.sumOf { it.size })}")
                }
            }
    }
    if (confirming)
        ModalBottomSheet(onDismissRequest = { confirming = false }) {
            Column(
                Modifier.padding(20.dp)
                    .imePadding()
                    .verticalScroll(androidx.compose.foundation.rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                val confirmedItems = items.filter { it.id in confirmIds }
                Text("确认上传 ${confirmedItems.size} 项", style = MaterialTheme.typography.titleLarge)
                Text("原片总大小 ${byteLabel(confirmedItems.sumOf { it.size })}")
                confirmedItems.forEach { entry ->
                    Text(
                        "${entry.name} · ${typeLabel(entry.type)}",
                        style = MaterialTheme.typography.bodySmall,
                    )
                    val capture = entry.fields.text("original_taken_at_local")
                    val fallback = OriginalMetadata.archiveFallback(entry.fields)
                    if (capture.isNotBlank()) {
                        val source =
                            when (entry.fields.text("time_source")) {
                                "EXIF.CreateDate" -> "原件创建时间（EXIF）"
                                "QuickTime.CreationDate" -> "视频创建时间"
                                else -> "拍摄时间（EXIF）"
                            }
                        val offset =
                            entry.fields
                                .optionalInt("original_offset_minutes")
                                ?.let {
                                    " · UTC${if (it >= 0) "+" else "-"}${"%02d:%02d".format(kotlin.math.abs(it) / 60, kotlin.math.abs(it) % 60)}"
                                }
                                .orEmpty()
                        Text(
                            "$source ${capture.replace('T', ' ')}$offset",
                            style = MaterialTheme.typography.labelSmall,
                        )
                    } else if (fallback != null) {
                        Text(
                            "${fallback.second} ${fallback.first.replace('T', ' ')}",
                            style = MaterialTheme.typography.labelSmall,
                        )
                        Text(
                            "原件拍摄时间未知，将按此日期归档。",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else
                        Text(
                            "未读取到拍摄或源文件日期，请为本批指定归档日期。",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                }
                Field("批次名称", batch) { batch = it }
                DateField("本批归档日期（可留空）", archive) { archive = it }
                Text(
                    "留空时优先使用原件拍摄／创建日期，其次使用相册或源文件日期；填写后统一按指定日期归档。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text("关联人物与宠物", style = MaterialTheme.typography.titleMedium)
                PeoplePicker(model.profiles, children) { children = it }
                if (children.isEmpty()) Text("仅保留在家庭时光", style = MaterialTheme.typography.bodySmall)
                if (error.isNotBlank()) ErrorBanner(error)
                Button(
                    {
                        try {
                            if (archive.isNotBlank()) LocalDate.parse(archive)
                            model.uploads.confirm(confirmIds, children, batch, archive)
                            confirming = false
                        } catch (failure: Exception) {
                            error = failure.message.orEmpty()
                        }
                    },
                    Modifier.fillMaxWidth(),
                ) {
                    Text("确认上传这 ${confirmIds.size} 项")
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    cancelling?.let { entry ->
        ConfirmDialog("取消上传", "取消 ${entry.name} 并释放本机原片缓存。", "取消这项上传", { cancelling = null }) {
            cancelling = null
            model.uploads.cancel(entry.id)
        }
    }
}

@Composable
fun UploadRow(
    entry: UploadItem,
    pause: () -> Unit,
    resume: () -> Unit,
    cancel: () -> Unit,
    showUploaded: (Int) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(entry.name, style = MaterialTheme.typography.titleSmall)
        Text(
            "${entry.label} · ${if (entry.resources.isNotEmpty()) byteLabel(entry.size) else "已读取 ${byteLabel(entry.preparedBytes)}"}",
            style = MaterialTheme.typography.bodySmall,
            color =
                if (entry.phase == "failed") MaterialTheme.colorScheme.error
                else MaterialTheme.colorScheme.primary,
        )
        if (entry.phase == "preparing") LinearProgressIndicator(Modifier.fillMaxWidth())
        if (entry.phase == "uploading") {
            LinearProgressIndicator(
                progress = {
                    (entry.uploaded.toFloat() / entry.size.coerceAtLeast(1)).coerceIn(0f, 1f)
                },
                modifier = Modifier.fillMaxWidth(),
            )
            val remaining =
                if (entry.speed > 0)
                    " · 约 ${(entry.size - entry.uploaded).coerceAtLeast(0) / entry.speed} 秒"
                else ""
            Text(
                "${byteLabel(entry.uploaded)} / ${byteLabel(entry.size)}${if (entry.speed > 0) " · ${byteLabel(entry.speed)}/s$remaining" else ""}",
                style = MaterialTheme.typography.labelSmall,
            )
            if (entry.uploaded == entry.size)
                Text("正在等待服务端完整性校验…", style = MaterialTheme.typography.labelSmall)
        }
        if (entry.resources.size == 2)
            Text("动态照片 · 静态原件 + 配对视频", style = MaterialTheme.typography.labelSmall)
        if (entry.message.isNotBlank())
            Text(
                entry.message,
                style = MaterialTheme.typography.bodySmall,
                color =
                    if (entry.phase == "failed") MaterialTheme.colorScheme.error
                    else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        Row {
            if (entry.phase in listOf("selected", "preparing", "queued", "uploading"))
                TextButton(pause) { Text("暂停") }
            if (entry.phase in listOf("paused", "failed")) TextButton(resume) { Text("继续 / 重试") }
            if (!entry.terminal) TextButton(cancel) { Text("取消") }
            if (entry.terminal && entry.mediaId != null)
                TextButton({ showUploaded(entry.mediaId) }) { Text("查看影像") }
        }
        HorizontalDivider()
    }
}
