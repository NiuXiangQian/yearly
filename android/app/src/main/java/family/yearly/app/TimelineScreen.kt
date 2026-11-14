package family.yearly.app

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.*
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Brush
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.blur
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.isActive
import org.json.JSONArray

@Composable
fun PreviewImage(
    api: YearlyApi,
    memory: Memory,
    modifier: Modifier = Modifier,
    purpose: String = "thumbnail",
) {
    var retry by remember(memory.key) { mutableIntStateOf(0) }
    val file = memory.primary
    val resource by
        produceState<MediaResource?>(null, memory.key, api.scope, purpose, retry) {
            value = null
            if (file != null) {
                try {
                    value = api.resource(memory, file, purpose)
                } catch (failure: Exception) {
                    value = MediaResource(null, "failed", failure.message ?: "预览读取失败", "")
                }
            }
        }
    Box(
        modifier.background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        val url = resource?.url
        if (url != null) {
            AsyncImage(
                ImageRequest.Builder(LocalContext.current)
                    .data(url)
                    .diskCacheKey("${api.scope}|${memory.id}|${file?.id}|$purpose")
                    .build(),
                memory.label,
                Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
                onError = { if (retry < 1) retry++ },
            )
        } else {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    if (memory.type == "video") Icons.Outlined.Videocam else Icons.Outlined.Image,
                    null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (resource != null)
                    TextButton({ retry++ }) {
                        Text("重试预览", style = MaterialTheme.typography.labelSmall)
                    }
                else CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            }
        }
        if (memory.type == "video" || memory.type == "live_photo") {
            Surface(
                Modifier.align(Alignment.BottomStart).padding(8.dp),
                shape = RoundedCornerShape(6.dp),
                color = androidx.compose.ui.graphics.Color.Black.copy(alpha = .65f),
            ) {
                Row(Modifier.padding(5.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (memory.type == "video") Icons.Outlined.PlayArrow
                        else Icons.Outlined.MotionPhotosOn,
                        null,
                        Modifier.size(14.dp),
                        tint = androidx.compose.ui.graphics.Color.White,
                    )
                    Text(
                        if (memory.type == "video") "视频" else "LIVE",
                        color = androidx.compose.ui.graphics.Color.White,
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterial3Api::class)
@Composable
fun TimelineScreen(model: AppModel, navigate: (Destination) -> Unit, listState: LazyListState) {
    val observedAccount by model.api.account.collectAsStateWithLifecycle()
    val account = observedAccount ?: return
    var filtering by remember { mutableStateOf(false) }
    var aiSearching by remember { mutableStateOf(false) }
    var locating by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf<Set<Int>>(emptySet()) }
    var selecting by remember { mutableStateOf(false) }
    var collapsedMonths by rememberSaveable { mutableStateOf<Set<String>>(emptySet()) }
    var expandedDays by rememberSaveable { mutableStateOf<Map<String, Boolean>>(emptyMap()) }
    var expandAllDays by rememberSaveable { mutableStateOf(false) }
    var dayMenu by remember { mutableStateOf<String?>(null) }
    var deleteSelection by remember { mutableStateOf(false) }
    val listDragged by listState.interactionSource.collectIsDraggedAsState()
    val groups =
        model.memories.groupBy { memory ->
            if (model.filter.byUpload) memory.uploadedDay else memory.day
        }
    val railDays =
        remember(model.dates, model.filter.ascending) {
            model.dates.distinct().sorted().let {
                if (model.filter.ascending) it else it.reversed()
            }
        }
    var railDay by remember { mutableStateOf<String?>(null) }
    var railHeld by remember { mutableStateOf(false) }
    LaunchedEffect(listDragged) { if (listDragged) railDay = null }
    val dayIndices =
        remember(groups, collapsedMonths, expandedDays, expandAllDays, model.hasNewer) {
            buildMap<String, Int> {
                var index = if (model.hasNewer) 1 else 0
                var previousMonth = ""
                groups.forEach { (day, rows) ->
                    val month = day.take(7)
                    if (month != previousMonth) {
                        index++
                        previousMonth = month
                    }
                    if (month !in collapsedMonths) {
                        put(day, index++)
                        val count =
                            if (expandedDays[day] ?: expandAllDays) rows.size
                            else minOf(rows.size, 8)
                        index += (count + 1) / 2
                        if (rows.size > 8) index++
                    }
                }
            }
        }
    val readingDay by
        remember(dayIndices, railDays) {
            derivedStateOf {
                dayIndices.entries.lastOrNull { it.value <= listState.firstVisibleItemIndex }?.key
                    ?: dayIndices.keys.firstOrNull()
                    ?: railDays.firstOrNull().orEmpty()
            }
        }
    LaunchedEffect(railDay, railHeld, dayIndices, model.loading) {
        val day = railDay ?: return@LaunchedEffect
        if (railHeld) delay(80)
        val index = dayIndices[day]
        if (index != null) {
            listState.scrollToItem(index)
        } else if (!model.loading && model.filter.anchor != day) {
            model.applyFilter(model.filter.copy(anchor = day))
        }
    }
    LaunchedEffect(Unit) { if (model.memories.isEmpty() && !model.loading) model.load() }
    LaunchedEffect(model.filter) {
        selected = emptySet()
        selecting = false
        if (model.filter.anchor != railDay) railDay = null
    }
    if (aiSearching) {
        AISearchSheet(model, { aiSearching = false }, locate = { memory ->
            aiSearching = false
            collapsedMonths = collapsedMonths - memory.day.take(7)
            expandedDays = expandedDays + (memory.day to true)
            railDay = memory.day
            model.applyFilter(model.filter.copy(search = "", byUpload = false, start = memory.day, end = memory.day, anchor = ""))
        }) { memory ->
            aiSearching = false
            navigate(Destination("media", memory))
        }
    }
    val motionScope = rememberCoroutineScope()
    val density = LocalDensity.current
    val collapseHeight = with(density) { 160.dp.toPx() }
    var collapse by rememberSaveable { mutableFloatStateOf(0f) }
    var headerAnimation by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    val headerScroll = remember(listState, collapseHeight) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source != NestedScrollSource.Drag) return Offset.Zero
                headerAnimation?.cancel()
                if (available.y < 0 || (listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset == 0)) {
                    val previous = collapse
                    collapse = (collapse - available.y).coerceIn(0f, collapseHeight)
                    return Offset(0f, previous - collapse)
                }
                return Offset.Zero
            }
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.Drag && available.y > 0) {
                    collapse = max(-collapseHeight / 2, collapse - available.y * .5f)
                    return Offset(0f, available.y)
                }
                return Offset.Zero
            }
            override suspend fun onPreFling(available: Velocity): Velocity {
                if (collapse >= collapseHeight || collapse == 0f) return Velocity.Zero
                val target = if (collapse < 0) 0f else if (abs(available.y) > 150) {
                    if (available.y < 0) collapseHeight else 0f
                } else if (collapse > collapseHeight / 2) collapseHeight else 0f
                headerAnimation = motionScope.launch { Animatable(collapse).animateTo(target, spring(dampingRatio = .84f, stiffness = 500f)) { collapse = value } }
                return available
            }
        }
    }
    val headerProgress = (collapse / collapseHeight).coerceIn(0f, 1f)
    val headerCover = model.memories.firstOrNull { it.type != "video" && it.primary != null }
    Column(Modifier.fillMaxSize().nestedScroll(headerScroll)) {
        Box {
        if (headerCover != null && headerProgress > 0) {
            PreviewImage(model.api, headerCover, Modifier.matchParentSize().blur(18.dp).graphicsLayer { alpha = headerProgress * .3f })
        }
        TopAppBar(
            title = { Text("家庭时光", Modifier.graphicsLayer { alpha = headerProgress }, fontWeight = FontWeight.SemiBold) },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background.copy(alpha = 1 - headerProgress * .18f)),
            actions = {
                if (account.canWrite)
                    TextButton({
                        selecting = !selecting
                        selected = emptySet()
                    }) {
                        Text(if (selecting) "取消" else "选择")
                    }
                IconButton({ locating = true }) { Icon(Icons.Outlined.CalendarMonth, "定位日期") }
                IconButton({ filtering = true }) { Icon(Icons.Outlined.Tune, "筛选与排序") }
                Box {
                    IconButton({ menu = true }) { Icon(Icons.Outlined.MoreVert, "更多操作") }
                    DropdownMenu(menu, { menu = false }) {
                        if (account.canWrite)
                            DropdownMenuItem(
                                { Text("创建分享") },
                                {
                                    menu = false
                                    navigate(Destination("shares"))
                                },
                            )
                        DropdownMenuItem(
                            { Text("展开全部回忆") },
                            {
                                menu = false
                                collapsedMonths = emptySet()
                                expandAllDays = true
                                expandedDays = emptyMap()
                            },
                        )
                        DropdownMenuItem(
                            { Text("收起全部回忆") },
                            {
                                menu = false
                                railDay = null
                                collapsedMonths = railDays.map { it.take(7) }.toSet()
                                expandAllDays = false
                                expandedDays = emptyMap()
                            },
                        )
                        DropdownMenuItem(
                            { Text("刷新时间线") },
                            {
                                menu = false
                                model.refresh()
                            },
                        )
                        if (account.canWrite)
                            DropdownMenuItem(
                                { Text("写日记") },
                                {
                                    menu = false
                                    navigate(Destination("event-edit"))
                                },
                            )
                        DropdownMenuItem(
                            { Text("回收站") },
                            {
                                menu = false
                                navigate(Destination("trash"))
                            },
                        )
                    }
                }
            },
        )
        }
        Box(Modifier.fillMaxWidth().height(with(density) { (collapseHeight - collapse).toDp() }).clip(RoundedCornerShape(bottomStart = 20.dp, bottomEnd = 20.dp))) {
            if (headerCover != null) PreviewImage(model.api, headerCover, Modifier.fillMaxWidth().height(160.dp).graphicsLayer {
                translationY = -collapse * .5f
                scaleX = 1 + max(0f, -collapse) / collapseHeight; scaleY = scaleX
            })
            Box(Modifier.matchParentSize().background(Brush.verticalGradient(listOf(MaterialTheme.colorScheme.background.copy(alpha = .15f), MaterialTheme.colorScheme.background))))
            Text("家庭时光", Modifier.align(Alignment.BottomStart).padding(20.dp).graphicsLayer {
                scaleX = 1 - headerProgress * .4f; scaleY = scaleX
                alpha = 1 - headerProgress
            }, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "${model.total} 项回忆",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.weight(1f))
            TextButton({ aiSearching = true }) { Icon(Icons.Outlined.AutoAwesome, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text("智能找回忆") }
            if (model.filter != TimelineFilter())
                TextButton({ model.applyFilter(TimelineFilter()) }) { Text("清除筛选") }
        }
        if (
            model.filter.search.isNotBlank() ||
                model.filter.people.isNotEmpty() ||
                model.filter.uploader != null ||
                model.filter.type.isNotBlank() ||
                model.filter.start.isNotBlank()
        ) {
            Text(
                listOf(
                        model.filter.search,
                        model.profiles
                            .filter { it.id in model.filter.people }
                            .joinToString("、") { it.label },
                        model.uploaders
                            .firstOrNull { it.getInt("id") == model.filter.uploader }
                            ?.text("username")
                            .orEmpty(),
                        typeLabel(model.filter.type),
                        listOf(model.filter.start, model.filter.end)
                            .filter(String::isNotBlank)
                            .joinToString(" 至 "),
                    )
                    .filter(String::isNotBlank)
                    .joinToString(" · "),
                Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
            )
        }
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FilterChip(
                selected = model.filter != TimelineFilter(),
                onClick = { filtering = true },
                label = { Text("筛选") },
            )
            var uploaderMenu by remember { mutableStateOf(false) }
            Box {
                AssistChip(
                    onClick = { uploaderMenu = true },
                    label = {
                        Text(
                            model.uploaders
                                .firstOrNull { it.optInt("id") == model.filter.uploader }
                                ?.text("username") ?: "上传人"
                        )
                    },
                )
                DropdownMenu(uploaderMenu, { uploaderMenu = false }) {
                    DropdownMenuItem(
                        { Text("全部上传人") },
                        {
                            uploaderMenu = false
                            model.applyFilter(model.filter.copy(uploader = null, anchor = ""))
                        },
                    )
                    model.uploaders.forEach { uploader ->
                        DropdownMenuItem(
                            { Text(uploader.text("username")) },
                            {
                                uploaderMenu = false
                                model.applyFilter(
                                    model.filter.copy(uploader = uploader.getInt("id"), anchor = "")
                                )
                            },
                        )
                    }
                }
            }
            AssistChip(
                onClick = {
                    model.applyFilter(
                        model.filter.copy(byUpload = !model.filter.byUpload, anchor = "")
                    )
                },
                label = { Text(if (model.filter.byUpload) "上传时间" else "归档日期") },
            )
            AssistChip(
                onClick = {
                    model.applyFilter(
                        model.filter.copy(ascending = !model.filter.ascending, anchor = "")
                    )
                },
                label = { Text(if (model.filter.ascending) "从旧到新 ↑" else "从新到旧 ↓") },
            )
        }
        if (selecting) {
            Surface(color = MaterialTheme.colorScheme.primaryContainer) {
                Column(Modifier.padding(horizontal = 12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("已选 ${selected.size} / 200 项", Modifier.weight(1f))
                        TextButton({
                            selected =
                                model.memories
                                    .filter { it.kind == "media" && account.canEdit(it.raw) }
                                    .map { it.id }
                                    .take(200)
                                    .toSet()
                        }) {
                            Text("全选已加载")
                        }
                        IconButton({
                            selected = emptySet()
                            selecting = false
                        }) {
                            Icon(Icons.Outlined.Close, "取消选择")
                        }
                    }
                    Row {
                        TextButton(
                            { navigate(Destination("organize", ids = selected)) },
                            enabled = selected.isNotEmpty(),
                        ) {
                            Text("整理")
                        }
                        TextButton(
                            {
                                navigate(
                                    Destination(
                                        "event-edit",
                                        ids = selected,
                                        day =
                                            model.memories
                                                .firstOrNull { it.id in selected }
                                                ?.day
                                                .orEmpty(),
                                    )
                                )
                            },
                            enabled = selected.isNotEmpty(),
                        ) {
                            Text("写日记")
                        }
                        TextButton(
                            { navigate(Destination("shares", ids = selected)) },
                            enabled = selected.isNotEmpty(),
                        ) {
                            Text("分享")
                        }
                        TextButton({ deleteSelection = true }, enabled = selected.isNotEmpty()) {
                            Text("回收站", color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
            }
        }
        if (model.loading && model.memories.isEmpty())
            LinearProgressIndicator(Modifier.fillMaxWidth())
        Row(Modifier.weight(1f).fillMaxWidth()) {
            if (railDays.size > 1)
                TimelineRail(railDays, railDay ?: readingDay, { railHeld = it }) { day ->
                    collapsedMonths = collapsedMonths - day.take(7)
                    railDay = day
                }
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxHeight(),
                contentPadding =
                    PaddingValues(
                        start = if (railDays.size > 1) 0.dp else 16.dp,
                        end = 16.dp,
                        top = 16.dp,
                        bottom = 16.dp,
                    ),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (model.hasNewer)
                    item {
                        OutlinedButton(
                            { model.load(more = true, newer = true) },
                            Modifier.fillMaxWidth(),
                            enabled = !model.loading,
                        ) {
                            Text("加载较新的回忆")
                        }
                    }
                var previousMonth = ""
                groups.forEach { (day, memories) ->
                    val month = day.take(7)
                    if (month != previousMonth) {
                        item("month-$month") {
                            TextButton({
                                collapsedMonths =
                                    if (month in collapsedMonths) collapsedMonths - month
                                    else collapsedMonths + month
                            }) {
                                Text(
                                    month.replace("-", " 年 ") + if (month.length == 7) " 月" else "",
                                    style = MaterialTheme.typography.titleLarge,
                                    fontWeight = FontWeight.SemiBold,
                                )
                                Icon(
                                    if (month in collapsedMonths) Icons.Outlined.ExpandMore
                                    else Icons.Outlined.ExpandLess,
                                    "折叠月份",
                                )
                            }
                        }
                        previousMonth = month
                    }
                    if (month !in collapsedMonths) {
                        item("day-$day") {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    day,
                                    fontWeight = FontWeight.SemiBold,
                                    modifier = Modifier.weight(1f),
                                )
                                Text(
                                    "${memories.size} 项",
                                    style = MaterialTheme.typography.labelSmall,
                                )
                                if (account.canWrite && !model.filter.byUpload && day != "日期未知") {
                                    Box {
                                        IconButton({ dayMenu = day }) {
                                            Icon(Icons.Outlined.MoreHoriz, "$day 的操作")
                                        }
                                        DropdownMenu(dayMenu == day, { dayMenu = null }) {
                                            DropdownMenuItem(
                                                { Text("文件夹管理") },
                                                {
                                                    dayMenu = null
                                                    navigate(Destination("folder", day = day))
                                                },
                                            )
                                            DropdownMenuItem(
                                                { Text("写当天日记") },
                                                {
                                                    dayMenu = null
                                                    navigate(Destination("event-edit", day = day))
                                                },
                                            )
                                            DropdownMenuItem(
                                                { Text("恢复默认顺序") },
                                                {
                                                    dayMenu = null
                                                    model.run {
                                                        model.change(
                                                            "/media/reset-order",
                                                            "POST",
                                                            json("day" to day),
                                                        )
                                                    }
                                                },
                                            )
                                            if (account.admin)
                                                DropdownMenuItem(
                                                    {
                                                        Text(
                                                            if (model.sharing[day] == false)
                                                                "允许当天分享"
                                                            else "关闭当天分享"
                                                        )
                                                    },
                                                    {
                                                        dayMenu = null
                                                        model.run {
                                                            model.change(
                                                                "/timeline/days/$day/sharing",
                                                                "PUT",
                                                                json(
                                                                    "share_allowed" to
                                                                        (model.sharing[day] ==
                                                                            false)
                                                                ),
                                                            )
                                                        }
                                                    },
                                                )
                                        }
                                    }
                                }
                            }
                        }
                        val visible =
                            if (expandedDays[day] ?: expandAllDays) memories else memories.take(8)
                        visible.chunked(2).forEach { row ->
                            item("row-${row.first().key}") {
                                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                    row.forEach { memory ->
                                        Column(
                                            Modifier.weight(1f)
                                                .clip(RoundedCornerShape(12.dp))
                                                .combinedClickable(
                                                    onClick = {
                                                        if (
                                                            selecting &&
                                                                memory.kind == "media" &&
                                                                account.canEdit(memory.raw)
                                                        ) {
                                                            if (memory.id in selected)
                                                                selected = selected - memory.id
                                                            else if (selected.size < 200)
                                                                selected = selected + memory.id
                                                            else model.error = "一次最多选择 200 项影像"
                                                        } else
                                                            navigate(
                                                                Destination(
                                                                    if (memory.kind == "event")
                                                                        "event"
                                                                    else "media",
                                                                    memory,
                                                                )
                                                            )
                                                    },
                                                    onLongClick = {
                                                        if (
                                                            memory.kind == "media" &&
                                                                account.canEdit(memory.raw)
                                                        ) {
                                                            selecting = true
                                                            if (selected.size < 200)
                                                                selected = selected + memory.id
                                                            else model.error = "一次最多选择 200 项影像"
                                                        }
                                                    },
                                                )
                                        ) {
                                            Box {
                                                if (memory.kind == "event")
                                                    Surface(
                                                        Modifier.fillMaxWidth().aspectRatio(1f),
                                                        color =
                                                            MaterialTheme.colorScheme.surfaceVariant,
                                                    ) {
                                                        Column(
                                                            Modifier.padding(16.dp),
                                                            verticalArrangement =
                                                                Arrangement.spacedBy(8.dp),
                                                        ) {
                                                            Icon(
                                                                Icons.AutoMirrored.Outlined
                                                                    .MenuBook,
                                                                null,
                                                                tint =
                                                                    MaterialTheme.colorScheme
                                                                        .primary,
                                                            )
                                                            Text(
                                                                memory.label,
                                                                fontWeight = FontWeight.SemiBold,
                                                                maxLines = 2,
                                                            )
                                                            Text(
                                                                memory.raw.text("content"),
                                                                style =
                                                                    MaterialTheme.typography
                                                                        .bodySmall,
                                                                maxLines = 3,
                                                            )
                                                        }
                                                    }
                                                else
                                                    PreviewImage(
                                                        model.api,
                                                        memory,
                                                        Modifier.fillMaxWidth().aspectRatio(1f),
                                                    )
                                                if (memory.id in selected && memory.kind == "media")
                                                    Icon(
                                                        Icons.Outlined.CheckCircle,
                                                        "已选择",
                                                        Modifier.align(Alignment.TopEnd)
                                                            .padding(8.dp),
                                                        tint = MaterialTheme.colorScheme.primary,
                                                    )
                                            }
                                            if (memory.title.isNotBlank() && memory.kind == "media")
                                                Text(
                                                    memory.title,
                                                    Modifier.padding(top = 6.dp),
                                                    maxLines = 2,
                                                    style = MaterialTheme.typography.bodyMedium,
                                                )
                                            val ages =
                                                memory.children
                                                    .map { profile ->
                                                        "${profile.label} ${profile.age(memory.day)}"
                                                    }
                                                    .filter(String::isNotBlank)
                                            if (ages.isNotEmpty())
                                                Text(
                                                    ages.joinToString(" · "),
                                                    Modifier.padding(top = 4.dp),
                                                    style = MaterialTheme.typography.labelSmall,
                                                    color =
                                                        MaterialTheme.colorScheme.onSurfaceVariant,
                                                )
                                        }
                                    }
                                    if (row.size == 1) Spacer(Modifier.weight(1f))
                                }
                            }
                        }
                        if (memories.size > 8)
                            item("expand-$day") {
                                TextButton(
                                    {
                                        expandedDays =
                                            expandedDays +
                                                (day to !(expandedDays[day] ?: expandAllDays))
                                    },
                                    Modifier.fillMaxWidth(),
                                ) {
                                    Text(
                                        if (expandedDays[day] ?: expandAllDays) "收起当天影像"
                                        else "展开当天其余 ${memories.size - 8} 项"
                                    )
                                }
                            }
                    }
                }
                if (model.memories.isEmpty() && !model.loading)
                    item { EmptyState("还没有符合条件的回忆", "可以调整筛选，或从上传页珍藏第一张原片。") }
                if (model.nextCursor != null)
                    item {
                        val lastGroup = groups.entries.lastOrNull()
                        val canAutoLoad =
                            lastGroup == null ||
                                (lastGroup.key.take(7) !in collapsedMonths &&
                                    (lastGroup.value.size <= 8 ||
                                        (expandedDays[lastGroup.key] ?: expandAllDays)))
                        LaunchedEffect(model.nextCursor, canAutoLoad) {
                            if (canAutoLoad) model.load(more = true)
                        }
                        TextButton(
                            { model.load(more = true) },
                            Modifier.fillMaxWidth(),
                            enabled = !model.loading,
                        ) {
                            Text(if (model.loading) "正在读取…" else "加载更多回忆")
                        }
                    }
                if (model.loading && model.memories.isNotEmpty())
                    item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            }
        }
    }
    if (filtering) FilterSheet(model) { filtering = false }
    if (locating)
        MotionBottomSheet(onDismissRequest = { locating = false }) { dismissSheet ->
            Column(
                Modifier.padding(20.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("沿着日期找回忆", style = MaterialTheme.typography.titleLarge)
                if (model.dates.isEmpty()) Text("当前范围内没有可定位的日期。")
                else {
                    var position by remember { mutableFloatStateOf(0f) }
                    val scale = remember(model.dates) { TimelineScale(model.dates) }
                    val selectedDay = scale.nearest(position.toDouble())
                    Text(selectedDay, style = MaterialTheme.typography.headlineSmall)
                    Slider(position, { position = it }, valueRange = 0f..1f)
                    Button(
                        {
                            model.applyFilter(model.filter.copy(anchor = selectedDay))
                            dismissSheet {}
                        },
                        Modifier.fillMaxWidth(),
                    ) {
                        Text("前往这一天")
                    }
                    model.dates
                        .groupBy { it.take(7) }
                        .forEach { (month, days) ->
                            Text(month, fontWeight = FontWeight.SemiBold)
                            days.forEach { day ->
                                TextButton({
                                    model.applyFilter(model.filter.copy(anchor = day))
                                    dismissSheet {}
                                }) {
                                    Text(day)
                                }
                            }
                        }
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    if (deleteSelection)
        ConfirmDialog(
            "移入回收站",
            "将已选 ${selected.size} 项影像移入回收站，可在回收站恢复。",
            "移入回收站",
            { deleteSelection = false },
        ) {
            deleteSelection = false
            model.run {
                selected.forEach { model.api.write("/media/$it", "DELETE") }
                selected = emptySet()
                model.load()
            }
        }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FilterSheet(model: AppModel, close: () -> Unit) {
    var filter by remember { mutableStateOf(model.filter.copy(anchor = "")) }
    var error by remember { mutableStateOf("") }
    MotionBottomSheet(onDismissRequest = close) { dismissSheet ->
        Column(Modifier.fillMaxWidth().fillMaxHeight(.82f).padding(horizontal = 20.dp)) {
            Text("筛选与排序", style = MaterialTheme.typography.titleLarge)
            MotionSegmentPages(listOf("影像", "人物与宠物", "日期"), Modifier.weight(1f)) { page ->
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    when (page) {
                        0 -> {
                            Field("关键词", filter.search) { filter = filter.copy(search = it) }
                            Choice("影像类型", filter.type, listOf("" to "全部", "photo" to "照片", "video" to "视频", "live_photo" to "动态照片")) { filter = filter.copy(type = it) }
                            Choice("上传人", filter.uploader?.toString().orEmpty(), listOf("" to "全部上传人") + model.uploaders.map { it.getInt("id").toString() to it.text("username") }) { filter = filter.copy(uploader = it.toIntOrNull()) }
                        }
                        1 -> PeoplePicker(model.profiles, filter.people) { filter = filter.copy(people = it) }
                        else -> {
                            Choice("排序依据", if (filter.byUpload) "upload" else "timeline", listOf("timeline" to "归档日期", "upload" to "上传时间")) { filter = filter.copy(byUpload = it == "upload") }
                            ToggleRow("从较早日期开始", filter.ascending) { filter = filter.copy(ascending = it) }
                            DateField("开始日期", filter.start) { filter = filter.copy(start = it) }
                            DateField("结束日期", filter.end) { filter = filter.copy(end = it) }
                        }
                    }
                }
            }
            if (error.isNotBlank()) Text(error, color = MaterialTheme.colorScheme.error)
            Button({
                if (filter.start.isNotBlank() && filter.end.isNotBlank() && filter.start > filter.end) error = "结束日期不能早于开始日期"
                else { model.applyFilter(filter); dismissSheet {} }
            }, Modifier.fillMaxWidth()) { Text("应用筛选") }
            Spacer(Modifier.height(16.dp))
        }
    }
}

fun typeLabel(type: String) =
    when (type) {
        "photo" -> "照片"
        "video" -> "视频"
        "live_photo" -> "动态照片"
        else -> ""
    }

@Composable
fun EmptyState(title: String, detail: String = "") {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            Icons.Outlined.PhotoAlbum,
            null,
            Modifier.size(40.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(title, style = MaterialTheme.typography.titleMedium)
        if (detail.isNotBlank())
            Text(
                detail,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
    }
}


@OptIn(ExperimentalMaterial3Api::class)
private data class SearchResultPage(val searchId: String, val page: Int, val total: Int, val pageSize: Int, val items: List<Memory>) {
    val pageCount get() = (total + pageSize - 1) / pageSize
}

private fun org.json.JSONObject.searchResultPage() = SearchResultPage(
    getString("search_id"), getInt("page"), getInt("total"), getInt("page_size"), objects("items").map(::Memory)
)

@Composable
private fun AISearchSheet(model: AppModel, close: () -> Unit, locate: (Memory) -> Unit, open: (Memory) -> Unit) {
    var stage by remember { mutableStateOf("waiting") }
    var elapsed by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    val filter = remember { model.filter }
    var query by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<org.json.JSONObject?>(null) }
    var error by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<SearchResultPage?>(null) }
    var paging by remember { mutableStateOf(false) }
    fun changePage(current: SearchResultPage, page: Int) {
        if (busy || paging) return
        paging = true
        error = ""
        scope.launch {
            try { results = model.api.getObject("/ai-search/results/${current.searchId}?page=$page", refresh = true).searchResultPage() }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { error = e.message ?: "翻页失败，请重试" }
            finally { paging = false }
        }
    }
    var reload by remember { mutableIntStateOf(0) }
    LaunchedEffect(reload) {
        error = ""
        try { status = model.api.getObject("/ai-search/status", refresh = true) }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { error = e.message ?: "搜索状态读取失败" }
    }
    MotionBottomSheet(onDismissRequest = close) { dismissSheet ->
        LazyColumn(Modifier.fillMaxWidth().imePadding().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            item {
                Text("智能找回忆", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.height(10.dp))
                Text("描述一个画面，找回照片和视频里的瞬间。")
            }
            item {
                val labels = buildList {
                    addAll(model.profiles.filter { it.id in filter.people }.map { it.label })
                    if (filter.uploader != null) add("已选上传人")
                    if (filter.type.isNotBlank()) add(when(filter.type) { "video" -> "视频"; "photo" -> "照片"; else -> "Live Photo" })
                    if (filter.start.isNotBlank() || filter.end.isNotBlank()) add("归档日期 ${filter.start} 至 ${filter.end}")
                }
                if (labels.isNotEmpty()) Text("沿用当前筛选：" + labels.joinToString(" · "), style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(query, { query = it.take(200) }, Modifier.fillMaxWidth(), enabled = !busy,
                    label = { Text("描述想找的回忆") }, placeholder = { Text("例如：去年夏天在海边玩沙子") }, maxLines = 4)
            }
            item {
                Button(onClick = {
                    busy = true; error = ""; results = null; elapsed = 0; stage = "waiting"
                    val requestID = java.util.UUID.randomUUID().toString()
                    scope.launch {
                        val progressTask = launch {
                            val started = android.os.SystemClock.elapsedRealtime()
                            while (isActive) {
                                try { stage = model.api.getObject("/ai-search/progress/$requestID", refresh = true).optString("stage", "waiting") }
                                catch (e: CancellationException) { throw e }
                                catch (_: Exception) { break }
                                elapsed = ((android.os.SystemClock.elapsedRealtime() - started) / 1000).toInt()
                                delay(1000)
                            }
                        }
                        try {
                            val body = json("request_id" to requestID, "query" to query.trim(), "child_ids" to JSONArray(filter.people.toList()))
                            filter.uploader?.let { body.put("owner_id", it) }
                            if (filter.type.isNotBlank()) body.put("media_type", filter.type)
                            if (filter.start.isNotBlank()) body.put("start", filter.start + "T00:00:00")
                            if (filter.end.isNotBlank()) body.put("end", java.time.LocalDate.parse(filter.end).plusDays(1).toString() + "T00:00:00")
                            results = model.api.searchMemories(body).searchResultPage()
                        } catch (e: CancellationException) { throw e }
                        catch (e: Exception) { error = e.message ?: "搜索失败，请重试" }
                        finally { progressTask.cancel(); busy = false }
                    }
                }, enabled = !busy && !paging && query.isNotBlank() && status?.optBoolean("enabled") == true && (status?.optInt("indexed") ?: 0) > 0,
                    modifier = Modifier.fillMaxWidth()) {
                    if (busy) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Text(if (busy) "正在寻找…" else "查找回忆")
                }
            }
            if (busy) item {
                val label = when (stage) {
                    "understanding" -> "正在理解描述…"
                    "matching" -> "正在查找候选影像…"
                    "ranking" -> "正在核对画面并筛选结果…"
                    "complete" -> "正在整理结果…"
                    else -> "正在提交搜索…"
                }
                LinearProgressIndicator(Modifier.fillMaxWidth())
                Text("$label · 已等待 $elapsed 秒", style = MaterialTheme.typography.bodySmall)
            }
            item {
                val current = status
                Text(if (current == null) "正在读取搜索状态…" else if (!current.optBoolean("enabled")) "智能搜索尚未启用，请管理员配置 OpenAI API Key 并建立索引"
                    else "已分析 ${current.optInt("indexed")} / ${current.optInt("total")} 项影像", style = MaterialTheme.typography.bodySmall)
                TextButton({ reload++ }, enabled = !busy) { Text("刷新状态") }
                Text("仅搜索已分析的影像。视频按抽样画面匹配，可能遗漏短暂片段；Live Photo 按静态照片匹配。", style = MaterialTheme.typography.bodySmall)
                if (error.isNotBlank()) Text(error, color = MaterialTheme.colorScheme.error)
            }
            val currentPage = results
            if (currentPage != null) {
                val items = currentPage.items
                item { Text("${currentPage.total} 项相关回忆") }
                if (currentPage.pageCount > 1) item {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        TextButton({ changePage(currentPage, currentPage.page - 1) }, enabled = !paging && currentPage.page > 1) { Text("上一页") }
                        Text("第 ${currentPage.page} / ${currentPage.pageCount} 页")
                        TextButton({ changePage(currentPage, currentPage.page + 1) }, enabled = !paging && currentPage.page < currentPage.pageCount) { Text("下一页") }
                    }
                }
                if (items.isEmpty()) item { Text("没有找到相关影像，试试描述场景、物体或动作，或放宽时间线筛选。") }
                items(items.size, key = { items[it].id }) { index ->
                    val memory = items[index]
                    Card(onClick = { open(memory) }) {
                        PreviewImage(model.api, memory, Modifier.fillMaxWidth().height(200.dp))
                        Text(memory.day + if (memory.type == "video") " · 视频" else "", Modifier.padding(12.dp))
                        TextButton({ locate(memory) }) { Text("在时间线查看") }
                    }
                }
            } else if (!busy) item {
                Column {
                    listOf("在草地上奔跑的小狗", "吹生日蜡烛的视频", "穿黄色雨衣踩水坑").forEach { sample ->
                        TextButton({ query = sample }) { Text(sample) }
                    }
                }
            }
            item { Spacer(Modifier.height(28.dp)) }
        }
    }
}
