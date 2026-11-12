package family.yearly.app

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import coil.compose.AsyncImage
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request

@OptIn(
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    ExperimentalMaterial3Api::class,
)
@Composable
fun MediaScreen(
    model: AppModel,
    initial: Memory,
    close: () -> Unit,
    navigate: (Destination) -> Unit,
) {
    val account by model.api.account.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val dataset =
        remember(initial.key) {
            model.memories
                .filter { it.kind == "media" }
                .let { if (it.any { row -> row.id == initial.id }) it else listOf(initial) }
        }
    val pager =
        rememberPagerState(
            initialPage = dataset.indexOfFirst { it.id == initial.id }.coerceAtLeast(0)
        ) {
            dataset.size
        }
    val memory = dataset[pager.currentPage]
    var menu by remember { mutableStateOf(false) }
    var info by remember { mutableStateOf(false) }
    var trash by remember { mutableStateOf(false) }
    var restore by remember { mutableStateOf<MediaFile?>(null) }
    var reorder by remember { mutableStateOf(false) }
    val directoryPicker =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) model.run { exportOriginals(context, model.api, memory, uri) }
        }
    Column(Modifier.fillMaxSize().background(Color.Black)) {
        Surface(color = MaterialTheme.colorScheme.background) {
            Column {
                PageBar(
                    "${pager.currentPage + 1} / ${dataset.size}",
                    close,
                    actions = {
                        IconButton({ info = true }) { Icon(Icons.Outlined.Info, "影像信息") }
                        Box {
                            IconButton({ menu = true }, enabled = !model.busy) {
                                Icon(Icons.Outlined.MoreVert, "影像操作")
                            }
                            DropdownMenu(menu, { menu = false }) {
                                DropdownMenuItem(
                                    { Text("保存原件到相册") },
                                    {
                                        menu = false
                                        if (Build.VERSION.SDK_INT >= 29)
                                            model.run {
                                                exportToGallery(context, model.api, memory)
                                            }
                                        else directoryPicker.launch(null)
                                    },
                                )
                                DropdownMenuItem(
                                    { Text("导出原件到文件夹") },
                                    {
                                        menu = false
                                        directoryPicker.launch(null)
                                    },
                                )
                                memory.files.forEach { file ->
                                    DropdownMenuItem(
                                        { Text("查看原文件 · ${file.name}") },
                                        {
                                            menu = false
                                            model.run {
                                                val resource =
                                                    model.api.resource(memory, file, "original")
                                                if (resource.url != null)
                                                    context.startActivity(
                                                        Intent(
                                                            Intent.ACTION_VIEW,
                                                            Uri.parse(resource.url),
                                                        )
                                                    )
                                                else {
                                                    model.error = resource.message
                                                    restore = file
                                                }
                                            }
                                        },
                                    )
                                }
                                if (account?.canEdit(memory.raw) == true) {
                                    DropdownMenuItem(
                                        { Text("编辑影像") },
                                        {
                                            menu = false
                                            navigate(Destination("media-edit", memory))
                                        },
                                    )
                                    DropdownMenuItem(
                                        { Text("整理与移动") },
                                        {
                                            menu = false
                                            navigate(
                                                Destination("organize", ids = setOf(memory.id))
                                            )
                                        },
                                    )
                                    DropdownMenuItem(
                                        { Text("调整顺序") },
                                        {
                                            menu = false
                                            reorder = true
                                        },
                                    )
                                    DropdownMenuItem(
                                        { Text("分享这张影像") },
                                        {
                                            menu = false
                                            navigate(Destination("shares", ids = setOf(memory.id)))
                                        },
                                    )
                                    DropdownMenuItem(
                                        { Text("移入回收站") },
                                        {
                                            menu = false
                                            trash = true
                                        },
                                    )
                                }
                                DropdownMenuItem(
                                    { Text("修改日志") },
                                    {
                                        menu = false
                                        navigate(
                                            Destination(
                                                "audit",
                                                raw = json("id" to memory.id),
                                                resource = "media",
                                            )
                                        )
                                    },
                                )
                                DropdownMenuItem(
                                    { Text("定位到时间线日期") },
                                    {
                                        menu = false
                                        model.applyFilter(
                                            TimelineFilter(
                                                anchor =
                                                    memory.day.takeIf { it != "日期未知" }.orEmpty()
                                            )
                                        )
                                        close()
                                    },
                                )
                            }
                        }
                    },
                )
            }
        }
        HorizontalPager(pager, Modifier.weight(1f), beyondBoundsPageCount = 0) { index ->
            MediaCanvas(model.api, dataset[index], active = pager.currentPage == index)
        }
        Surface(color = MaterialTheme.colorScheme.background) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(memory.label, style = MaterialTheme.typography.titleMedium)
                Text(
                    "${memory.day} · ${typeLabel(memory.type)}",
                    style = MaterialTheme.typography.bodySmall,
                )
                if (memory.raw.text("remark").isNotBlank())
                    Text(
                        memory.raw.text("remark"),
                        maxLines = 2,
                        style = MaterialTheme.typography.bodySmall,
                    )
            }
        }
    }
    if (info)
        MotionBottomSheet(onDismissRequest = { info = false }) { dismissSheet ->
            Column(
                Modifier.padding(20.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text("影像信息", style = MaterialTheme.typography.titleLarge)
                val detail by
                    produceState<Memory?>(null, memory.id) {
                        value =
                            runCatching { Memory(model.api.getObject("/media/${memory.id}", true)) }
                                .getOrNull()
                    }
                val raw = detail?.raw ?: memory.raw
                listOf(
                        "归档日期" to memory.day,
                        "拍摄时间" to raw.text("taken_at_local"),
                        "时间来源" to raw.text("time_source"),
                        "地点" to raw.text("location_name"),
                        "纬度" to raw.text("latitude"),
                        "经度" to raw.text("longitude"),
                        "相机" to
                            listOf(raw.text("device_make"), raw.text("device_model"))
                                .joinToString(" "),
                        "尺寸" to "${raw.text("width")} × ${raw.text("height")}",
                        "上传人" to raw.text("owner_name"),
                        "修改人" to raw.text("updated_by_name"),
                        "修改时间" to raw.text("updated_at"),
                        "标签" to raw.strings("tags").joinToString("、"),
                    )
                    .filter { it.second.isNotBlank() }
                    .forEach { (label, value) ->
                        Text(
                            label,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(value)
                    }
                memory.files.forEach { file ->
                    HorizontalDivider()
                    Text(file.name)
                    Text(
                        "${byteLabel(file.size)} · ${file.mime}",
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Text(
                        "SHA-256 ${file.sha256}\nCRC64 ${file.crc64}",
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
                raw.optJSONObject("metadata")?.let {
                    Text(it.toString(2), style = MaterialTheme.typography.bodySmall)
                }
                Spacer(Modifier.height(30.dp))
            }
        }
    if (trash)
        ConfirmDialog("移入回收站", "可在回收站恢复这张影像。", "移入回收站", { trash = false }) {
            trash = false
            model.run {
                model.change("/media/${memory.id}", "DELETE")
                close()
            }
        }
    restore?.let { file ->
        ConfirmDialog("解冻原件", "原件已深度归档，解冻通常需要 48 小时，完成后可下载 1 天。", "申请解冻", { restore = null }) {
            restore = null
            model.run {
                val result = model.api.write("/media/${memory.id}/files/${file.id}/restore", "POST")
                model.error = result.text("message", "解冻申请已提交")
            }
        }
    }
    if (reorder)
        MotionBottomSheet(onDismissRequest = { reorder = false }) { dismissSheet ->
            Column(Modifier.padding(20.dp).verticalScroll(rememberScrollState())) {
                Text("移到下列影像之前", style = MaterialTheme.typography.titleLarge)
                dataset
                    .filter {
                        it.id != memory.id &&
                            it.day == memory.day &&
                            it.folder == memory.folder &&
                            account?.canEdit(it.raw) == true
                    }
                    .forEach { target ->
                        TextButton({
                            dismissSheet {}
                            model.run {
                                model.change(
                                    "/media/reorder",
                                    "POST",
                                    json(
                                        "media_ids" to listOf(memory.id),
                                        "target_id" to target.id,
                                        "placement" to "before",
                                    ),
                                )
                                close()
                            }
                        }) {
                            Text("${target.label} · #${target.id}")
                        }
                    }
                Spacer(Modifier.height(30.dp))
            }
        }
}

@Composable
fun MediaCanvas(api: YearlyApi, memory: Memory, active: Boolean) {
    var play by remember(memory.id) { mutableStateOf(memory.type == "live_photo") }
    var restart by remember(memory.id) { mutableIntStateOf(0) }
    var message by remember(memory.id) { mutableStateOf("") }
    var preview by remember(memory.id) { mutableStateOf<MediaResource?>(null) }
    var motion by remember(memory.id) { mutableStateOf<MediaResource?>(null) }
    var zoom by remember(memory.id) { mutableFloatStateOf(1f) }
    var offset by remember(memory.id) { mutableStateOf(androidx.compose.ui.geometry.Offset.Zero) }
    LaunchedEffect(memory.id, active) {
        if (!active) {
            play = false
            return@LaunchedEffect
        }
        try {
            memory.primary?.let { preview = api.resource(memory, it) }
            if (memory.type == "live_photo") play = true
        } catch (error: Exception) {
            message = error.message ?: "预览读取失败"
        }
    }
    LaunchedEffect(play, active, restart) {
        if (!play || !active) return@LaunchedEffect
        val file = if (memory.type == "live_photo") memory.motion else memory.primary
        if (file != null) {
            try {
                repeat(30) {
                    val result = api.resource(memory, file)
                    motion = result
                    if (result.url != null || result.status !in listOf("pending", "processing"))
                        return@LaunchedEffect
                    message = result.message.ifBlank { "动态预览正在准备中…" }
                    delay(2000)
                }
                play = false
            } catch (error: Exception) {
                message = error.message ?: "视频读取失败"
                play = false
            }
        }
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val image = preview
        if (image?.url != null)
            AsyncImage(
                image.url,
                memory.label,
                Modifier.fillMaxSize()
                    .pointerInput(memory.id) {
                        awaitEachGesture {
                            awaitFirstDown(requireUnconsumed = false)
                            do {
                                val event = awaitPointerEvent()
                                if (event.changes.size >= 2 || zoom > 1f) {
                                    zoom = (zoom * event.calculateZoom()).coerceIn(1f, 6f)
                                    offset =
                                        if (zoom <= 1f) androidx.compose.ui.geometry.Offset.Zero
                                        else offset + event.calculatePan()
                                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                                }
                            } while (event.changes.any { it.pressed })
                        }
                    }
                    .pointerInput(memory.id) {
                        detectTapGestures(
                            onDoubleTap = {
                                zoom = if (zoom > 1f) 1f else 2f
                                offset = androidx.compose.ui.geometry.Offset.Zero
                            },
                            onTap = {
                                if (memory.type == "live_photo") {
                                    play = true
                                    restart++
                                }
                            },
                        )
                    }
                    .graphicsLayer {
                        scaleX = zoom
                        scaleY = zoom
                        translationX = offset.x
                        translationY = offset.y
                    },
                contentScale = ContentScale.Fit,
            )
        if (play && active && motion?.url != null)
            key(memory.id, restart, motion?.url) {
                NativePlayer(
                    motion!!.url!!,
                    onEnd = { if (memory.type == "live_photo") play = false },
                    onError = {
                        message = it
                        play = false
                    },
                )
            }
        if (memory.type == "video" && !play)
            FilledIconButton(
                {
                    play = true
                    restart++
                },
                Modifier.size(64.dp),
            ) {
                Icon(Icons.Outlined.PlayArrow, "播放视频", Modifier.size(36.dp))
            }
        if (memory.type == "live_photo")
            TextButton(
                {
                    play = true
                    restart++
                },
                Modifier.align(Alignment.TopStart),
            ) {
                Text("◉ LIVE", color = Color.White)
            }
        if (message.isNotBlank() && (!play || motion?.url == null))
            Text(
                message,
                Modifier.align(Alignment.BottomCenter).padding(20.dp),
                color = Color.White,
            )
        if (image == null) CircularProgressIndicator()
    }
}

@Composable
fun NativePlayer(url: String, onEnd: () -> Unit, onError: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val currentEnd by rememberUpdatedState(onEnd)
    val currentError by rememberUpdatedState(onError)
    val player =
        remember(url) {
            ExoPlayer.Builder(context).build().apply {
                setMediaItem(MediaItem.fromUri(url))
                prepare()
                playWhenReady = true
            }
        }
    DisposableEffect(player, lifecycle) {
        val listener =
            object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) {
                    if (playbackState == Player.STATE_ENDED) currentEnd()
                }

                override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                    currentError("视频播放失败，请重新打开预览。")
                }
            }
        player.addListener(listener)
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) player.pause()
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            player.removeListener(listener)
            player.release()
        }
    }
    AndroidView(
        factory = {
            PlayerView(it).apply {
                this.player = player
                useController = true
            }
        },
        update = { it.player = player },
        modifier = Modifier.fillMaxSize(),
    )
}

suspend fun exportOriginals(context: Context, api: YearlyApi, memory: Memory, tree: Uri) =
    withContext(Dispatchers.IO) {
        val directory = requireNotNull(DocumentFile.fromTreeUri(context, tree))
        val staging = File(context.cacheDir, "exports").apply { mkdirs() }
        val temporaryFiles = mutableListOf<File>()
        val createdFiles = mutableListOf<DocumentFile>()
        try {
            for (file in memory.files) {
                val resource = api.resource(memory, file, "original")
                check(resource.url != null) { resource.message.ifBlank { "原件暂不可下载，请先解冻。" } }
                val url = resource.url.toHttpUrl()
                check(url.isHttps) { "下载地址必须使用 HTTPS" }
                val target = File(staging, "${memory.id}-${file.id}")
                temporaryFiles += target
                downloadVerified(api, file, url, target)
                val output =
                    requireNotNull(directory.createFile(file.mime, file.name)) { "无法在所选文件夹创建文件" }
                createdFiles += output
                context.contentResolver.openOutputStream(output.uri, "w")!!.use { sink ->
                    target.inputStream().use { it.copyTo(sink) }
                }
            }
        } catch (failure: Exception) {
            createdFiles.forEach { it.delete() }
            throw failure
        } finally {
            temporaryFiles.forEach { it.delete() }
        }
    }

@androidx.annotation.RequiresApi(29)
suspend fun exportToGallery(context: Context, api: YearlyApi, memory: Memory) =
    withContext(Dispatchers.IO) {
        val staging = File(context.cacheDir, "exports").apply { mkdirs() }
        val temporaryFiles = mutableListOf<File>()
        val pendingRows = mutableListOf<Uri>()
        try {
            for (file in memory.files) {
                val resource = api.resource(memory, file, "original")
                check(resource.url != null) { resource.message.ifBlank { "原件暂不可下载，请先解冻。" } }
                val url = resource.url.toHttpUrl()
                check(url.isHttps) { "下载地址必须使用 HTTPS" }
                val target = File(staging, "${memory.id}-${file.id}")
                temporaryFiles += target
                downloadVerified(api, file, url, target)
                val video = file.mime.startsWith("video/")
                val collection =
                    if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                    else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                val values =
                    ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                        put(MediaStore.MediaColumns.MIME_TYPE, file.mime)
                        put(
                            MediaStore.MediaColumns.RELATIVE_PATH,
                            if (video) "Movies/Yearly" else "Pictures/Yearly",
                        )
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                val uri =
                    requireNotNull(context.contentResolver.insert(collection, values)) {
                        "无法写入系统相册"
                    }
                pendingRows += uri
                context.contentResolver.openOutputStream(uri, "w")!!.use { sink ->
                    target.inputStream().use { it.copyTo(sink) }
                }
            }
            for (uri in pendingRows) {
                check(
                    context.contentResolver.update(
                        uri,
                        ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                        null,
                        null,
                    ) == 1
                ) {
                    "无法完成相册写入"
                }
            }
        } catch (failure: Exception) {
            pendingRows.forEach { context.contentResolver.delete(it, null, null) }
            throw failure
        } finally {
            temporaryFiles.forEach { it.delete() }
        }
    }

private fun downloadVerified(api: YearlyApi, file: MediaFile, url: okhttp3.HttpUrl, target: File) {
    api.client.newCall(Request.Builder().url(url).build()).execute().use { response ->
        check(response.isSuccessful) { "下载失败（${response.code}）" }
        response.body!!.byteStream().use { input ->
            target.outputStream().use { output -> input.copyTo(output, 1024 * 1024) }
        }
    }
    FileIntegrity.verify(target, file.size, file.sha256, file.crc64)
}
