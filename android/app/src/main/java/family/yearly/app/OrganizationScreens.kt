package family.yearly.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.LocalDate
import kotlinx.coroutines.launch
import org.json.JSONObject

@Composable
fun OrganizeScreen(model: AppModel, ids: Set<Int>, close: () -> Unit) {
    var batch by remember { mutableStateOf("") }
    var archive by remember { mutableStateOf("") }
    var editBatch by remember { mutableStateOf(false) }
    var editArchive by remember { mutableStateOf(false) }
    var children by remember { mutableStateOf<Set<Int>>(emptySet()) }
    var peopleMode by remember { mutableStateOf("add") }
    var day by remember {
        mutableStateOf(
            model.memories.firstOrNull { it.id in ids }?.day?.takeIf { it != "日期未知" }
                ?: LocalDate.now().toString()
        )
    }
    var folders by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var target by remember { mutableStateOf("") }
    var operation by remember { mutableStateOf("organize") }
    LaunchedEffect(day) {
        if (day.isNotBlank()) model.run { folders = model.api.getArray("/folders?day=$day", true) }
    }
    FormPage(
        "整理 ${ids.size} 项影像",
        close,
        saveLabel = "应用整理",
        onSave = {
            when (operation) {
                "organize" -> {
                    check(editBatch || editArchive) { "请选择要修改的属性" }
                    val body = json("media_ids" to ids)
                    if (editBatch) body.put("batch_name", batch)
                    if (editArchive)
                        body.put("timeline_date", archive.ifBlank { null } ?: JSONObject.NULL)
                    model.change("/media/batch-organize", "POST", body)
                }
                "children" ->
                    model.change(
                        "/media/batch-children",
                        "POST",
                        json("media_ids" to ids, "child_ids" to children, "mode" to peopleMode),
                    )
                "folder" ->
                    model.change(
                        "/folders/move-media",
                        "POST",
                        json("media_ids" to ids, "folder_id" to target.toIntOrNull()),
                    )
            }
            close()
        },
    ) {
        Choice(
            "整理内容",
            operation,
            listOf("organize" to "归档与批次", "children" to "人物与宠物", "folder" to "移动到文件夹"),
        ) {
            operation = it
        }
        when (operation) {
            "organize" -> {
                ToggleRow("修改批次名称", editBatch) { editBatch = it }
                if (editBatch) Field("批次名称（留空可清除）", batch) { batch = it }
                ToggleRow("修改归档日期", editArchive) { editArchive = it }
                if (editArchive) DateField("归档日期（留空可清除）", archive) { archive = it }
            }
            "children" -> {
                Choice(
                    "关联方式",
                    peopleMode,
                    listOf("add" to "添加", "remove" to "移除", "replace" to "替换全部"),
                ) {
                    peopleMode = it
                }
                PeoplePicker(model.profiles, children) { children = it }
            }
            "folder" -> {
                DateField("文件夹所属日期", day) {
                    day = it
                    target = ""
                }
                Choice(
                    "移入文件夹",
                    target,
                    listOf("" to "移出文件夹") +
                        folders.map { it.getInt("id").toString() to it.text("name") },
                ) {
                    target = it
                }
                Text("只能移入同一天的文件夹。可先调整归档日期，再移动影像。", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderScreen(
    model: AppModel,
    destination: Destination,
    close: () -> Unit,
    navigate: (Destination) -> Unit,
) {
    val account by model.api.account.collectAsStateWithLifecycle()
    var folders by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var selected by remember { mutableStateOf<JSONObject?>(null) }
    var editing by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var share by remember { mutableStateOf(true) }
    var deleting by remember { mutableStateOf<JSONObject?>(null) }
    var contents by remember { mutableStateOf<List<Memory>>(emptyList()) }
    var page by remember { mutableIntStateOf(1) }
    var total by remember { mutableIntStateOf(0) }
    var revision by remember { mutableIntStateOf(0) }
    LaunchedEffect(revision, model.revision) {
        model.run { folders = model.api.getArray("/folders?day=${destination.day}", true) }
    }
    LaunchedEffect(selected?.optionalInt("id"), page, revision) {
        selected?.let { folder ->
            model.run {
                val result =
                    model.api.getObject(
                        "/media?folder_id=${folder.getInt("id")}&page=$page&page_size=40",
                        true,
                    )
                contents =
                    if (page == 1) result.objects("items").map(::Memory)
                    else contents + result.objects("items").map(::Memory)
                total = result.getInt("total")
            }
        }
    }
    Column {
        PageBar(
            "${destination.day} · 文件夹",
            close,
            actions = {
                IconButton({
                    selected = null
                    name = ""
                    share = true
                    editing = true
                }) {
                    Icon(Icons.Outlined.CreateNewFolder, "新建文件夹")
                }
            },
        )
        LazyColumn(
            contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(folders, key = { it.getInt("id") }) { folder ->
                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Folder, null, tint = MaterialTheme.colorScheme.primary)
                        TextButton({
                            selected = folder
                            contents = emptyList()
                            page = 1
                        }) {
                            Text("${folder.text("name")} · ${folder.optInt("media_count")} 项")
                        }
                    }
                    if (account?.canEdit(folder) == true)
                        Row {
                            TextButton({
                                selected = folder
                                name = folder.text("name")
                                share = folder.optBoolean("share_allowed", true)
                                editing = true
                            }) {
                                Text("编辑")
                            }
                            TextButton({ deleting = folder }) { Text("解散") }
                            val index = folders.indexOf(folder)
                            if (index > 0)
                                TextButton({
                                    model.run {
                                        model.api.write(
                                            "/folders/${folder.getInt("id")}/reorder",
                                            "POST",
                                            json(
                                                "target_id" to folders[index - 1].getInt("id"),
                                                "placement" to "before",
                                            ),
                                        )
                                        revision++
                                    }
                                }) {
                                    Text("上移")
                                }
                        }
                    TextButton({
                        navigate(
                            Destination(
                                "audit",
                                raw = json("id" to folder.getInt("id")),
                                resource = "timeline_folder",
                            )
                        )
                    }) {
                        Text("修改日志")
                    }
                    HorizontalDivider()
                }
            }
            if (selected != null && !editing) {
                item { SectionTitle(selected!!.text("name")) }
                items(contents, key = { it.id }) { memory ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        PreviewImage(model.api, memory, Modifier.size(72.dp))
                        TextButton({ navigate(Destination("media", memory)) }) {
                            Text(memory.label)
                        }
                        Spacer(Modifier.weight(1f))
                        if (account?.canEdit(memory.raw) == true)
                            TextButton({
                                model.run {
                                    model.api.write(
                                        "/folders/move-media",
                                        "POST",
                                        json("media_ids" to listOf(memory.id), "folder_id" to null),
                                    )
                                    revision++
                                    page = 1
                                }
                            }) {
                                Text("移出")
                            }
                    }
                }
                if (contents.size < total) item { TextButton({ page++ }) { Text("读取更多影像") } }
            }
            if (folders.isEmpty()) item { EmptyState("这一天还没有文件夹") }
        }
    }
    if (editing) {
        var error by remember { mutableStateOf("") }
        val scope = rememberCoroutineScope()
        var busy by remember { mutableStateOf(false) }
        AlertDialog(
            onDismissRequest = { if (!busy) editing = false },
            title = { Text(if (selected == null) "新建文件夹" else "编辑文件夹") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Field("文件夹名称", name) { name = it }
                    ToggleRow("允许分享", share) { share = it }
                    if (error.isNotBlank()) Text(error, color = MaterialTheme.colorScheme.error)
                }
            },
            confirmButton = {
                TextButton(
                    {
                        busy = true
                        scope.launch {
                            try {
                                if (selected == null)
                                    model.api.write(
                                        "/folders",
                                        "POST",
                                        json("name" to name, "timeline_date" to destination.day),
                                    )
                                else
                                    model.api.write(
                                        "/folders/${selected!!.getInt("id")}",
                                        "PUT",
                                        json("name" to name, "share_allowed" to share),
                                    )
                                revision++
                                model.load()
                                editing = false
                            } catch (failure: Exception) {
                                error = failure.message.orEmpty()
                            } finally {
                                busy = false
                            }
                        }
                    },
                    enabled = !busy && name.isNotBlank(),
                ) {
                    Text("保存")
                }
            },
            dismissButton = { TextButton({ editing = false }, enabled = !busy) { Text("取消") } },
        )
    }
    deleting?.let { folder ->
        ConfirmDialog("解散文件夹", "影像会回到这一天的时间线。", "解散文件夹", { deleting = null }) {
            deleting = null
            model.run {
                model.api.write("/folders/${folder.getInt("id")}", "DELETE")
                selected = null
                revision++
                model.load()
            }
        }
    }
}
