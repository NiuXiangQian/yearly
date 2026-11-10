package family.yearly.app

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
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.delay

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
    Column(Modifier.fillMaxSize()) {
        PageBar(
            "家庭时光",
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
        ModalBottomSheet(onDismissRequest = { locating = false }) {
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
                            locating = false
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
                                    locating = false
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
    ModalBottomSheet(onDismissRequest = close) {
        Column(
            Modifier.padding(horizontal = 20.dp).imePadding().verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("筛选与排序", style = MaterialTheme.typography.titleLarge)
            Field("关键词", filter.search) { filter = filter.copy(search = it) }
            Choice(
                "影像类型",
                filter.type,
                listOf("" to "全部", "photo" to "照片", "video" to "视频", "live_photo" to "动态照片"),
            ) {
                filter = filter.copy(type = it)
            }
            Choice(
                "排序依据",
                if (filter.byUpload) "upload" else "timeline",
                listOf("timeline" to "归档日期", "upload" to "上传时间"),
            ) {
                filter = filter.copy(byUpload = it == "upload")
            }
            ToggleRow("从较早日期开始", filter.ascending) { filter = filter.copy(ascending = it) }
            DateField("开始日期", filter.start) { filter = filter.copy(start = it) }
            DateField("结束日期", filter.end) { filter = filter.copy(end = it) }
            Text("人物与宠物", fontWeight = FontWeight.SemiBold)
            PeoplePicker(model.profiles, filter.people) { filter = filter.copy(people = it) }
            Choice(
                "上传人",
                filter.uploader?.toString().orEmpty(),
                listOf("" to "全部上传人") +
                    model.uploaders.map { it.getInt("id").toString() to it.text("username") },
            ) {
                filter = filter.copy(uploader = it.toIntOrNull())
            }
            if (error.isNotBlank()) Text(error, color = MaterialTheme.colorScheme.error)
            Button(
                {
                    if (
                        filter.start.isNotBlank() &&
                            filter.end.isNotBlank() &&
                            filter.start > filter.end
                    )
                        error = "结束日期不能早于开始日期"
                    else {
                        model.applyFilter(filter)
                        close()
                    }
                },
                Modifier.fillMaxWidth(),
            ) {
                Text("应用筛选")
            }
            Spacer(Modifier.height(30.dp))
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
