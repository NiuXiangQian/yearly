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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.json.JSONObject

@Composable
fun FamilyScreen(model: AppModel, navigate: (Destination) -> Unit) {
    val account by model.api.account.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) {
        model.run { model.profiles = model.api.getArray("/children").map(::Profile) }
    }
    var milestones by remember { mutableStateOf<Profile?>(null) }
    Column {
        PageBar(
            "家人与宠物",
            actions = {
                if (account?.canWrite == true)
                    IconButton({ navigate(Destination("profile")) }) {
                        Icon(Icons.Outlined.PersonAdd, "添加家人或宠物")
                    }
                IconButton({
                    model.run {
                        model.profiles = model.api.getArray("/children", true).map(::Profile)
                    }
                }) {
                    Icon(Icons.Outlined.Refresh, "刷新家人资料")
                }
            },
        )
        LazyColumn(
            contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            if (model.profiles.isEmpty()) item { EmptyState("还没有家人或宠物资料") }
            items(model.profiles, key = { it.id }) { profile ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Surface(
                        Modifier.size(56.dp),
                        shape = androidx.compose.foundation.shape.CircleShape,
                        color = MaterialTheme.colorScheme.primaryContainer,
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Text(profile.label.take(1), style = MaterialTheme.typography.titleLarge)
                            profile.avatar?.let { id ->
                                val avatar by
                                    produceState<Memory?>(null, id, model.revision) {
                                        value =
                                            runCatching {
                                                    Memory(model.api.getObject("/media/$id"))
                                                }
                                                .getOrNull()
                                    }
                                avatar?.let { PreviewImage(model.api, it, Modifier.fillMaxSize()) }
                            }
                        }
                    }
                    Column(Modifier.weight(1f).padding(start = 16.dp)) {
                        Text(
                            profile.label,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            profile.summary,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        if (profile.birthday.isNotBlank())
                            Text(
                                "${profile.birthday} · ${profile.age(java.time.LocalDate.now().toString())}",
                                style = MaterialTheme.typography.bodySmall,
                            )
                    }
                    IconButton({
                        model.tab = 0
                        model.applyFilter(TimelineFilter(people = setOf(profile.id)))
                    }) {
                        Icon(Icons.Outlined.ChevronRight, "查看${profile.label}的时间线")
                    }
                }
                if (profile.description.isNotBlank()) Text(profile.description, maxLines = 3)
                Row {
                    if (account?.canEdit(profile.raw) == true)
                        TextButton({ navigate(Destination("profile", raw = profile.raw)) }) {
                            Text("编辑资料")
                        }
                    if (profile.raw.optBoolean("growth_enabled", true))
                        TextButton({ milestones = profile }) { Text("成长里程碑") }
                    TextButton({
                        navigate(
                            Destination("audit", raw = json("id" to profile.id), resource = "child")
                        )
                    }) {
                        Text("修改记录")
                    }
                }
                HorizontalDivider()
            }
        }
    }
    milestones?.let { profile -> MilestoneDialog(model, profile) { milestones = null } }
}

@Composable
fun MilestoneDialog(model: AppModel, profile: Profile, close: () -> Unit) {
    var rows by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var error by remember { mutableStateOf("") }
    LaunchedEffect(profile.id) {
        try {
            rows = model.api.getArray("/children/${profile.id}/milestones")
        } catch (failure: Exception) {
            error = failure.message.orEmpty()
        }
    }
    AlertDialog(
        onDismissRequest = close,
        title = { Text("${profile.label}的里程碑") },
        text = {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (error.isNotBlank())
                    item { Text(error, color = MaterialTheme.colorScheme.error) }
                items(rows) { milestone ->
                    TextButton({
                        model.tab = 0
                        model.applyFilter(
                            TimelineFilter(
                                people = setOf(profile.id),
                                anchor = milestone.text("date"),
                            )
                        )
                        close()
                    }) {
                        Text("${milestone.text("title")} · ${milestone.text("date")}")
                    }
                }
            }
        },
        confirmButton = { TextButton(close) { Text("完成") } },
    )
}

@OptIn(coil.annotation.ExperimentalCoilApi::class)
@Composable
fun SettingsScreen(
    model: AppModel,
    theme: String,
    changeTheme: (String) -> Unit,
    navigate: (Destination) -> Unit,
) {
    val observedAccount by model.api.account.collectAsStateWithLifecycle()
    val account = observedAccount ?: return
    var stats by remember { mutableStateOf<JSONObject?>(null) }
    var logout by remember { mutableStateOf(false) }
    LaunchedEffect(model.revision) {
        stats = runCatching { model.api.getObject("/stats") }.getOrNull()
    }
    Column {
        PageBar("我的家庭时光")
        LazyColumn(
            contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                Text(
                    account.username,
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(account.roleLabel, color = MaterialTheme.colorScheme.primary)
                Text(
                    model.api.currentSite,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            stats?.let { data ->
                item {
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(
                                data.text("media", "0"),
                                style = MaterialTheme.typography.headlineMedium,
                            )
                            Text("珍藏影像")
                        }
                        Column(Modifier.weight(1f)) {
                            Text(
                                data.text("events", "0"),
                                style = MaterialTheme.typography.headlineMedium,
                            )
                            Text("生活日记")
                        }
                        Column(Modifier.weight(1f)) {
                            Text(
                                data.text("children", "0"),
                                style = MaterialTheme.typography.headlineMedium,
                            )
                            Text("成长档案")
                        }
                    }
                }
            }
            item { HorizontalDivider() }
            item {
                SettingsAction("修改密码", "更新当前账号的登录密码", Icons.Outlined.Lock) {
                    navigate(Destination("password"))
                }
            }
            if (account.canWrite)
                item {
                    SettingsAction("分享管理", "日期范围、指定影像与访问记录", Icons.Outlined.Share) {
                        navigate(Destination("shares"))
                    }
                }
            if (account.admin)
                item {
                    SettingsAction("账户管理", "创建账户、角色、启停与密码重置", Icons.Outlined.ManageAccounts) {
                        navigate(Destination("accounts"))
                    }
                }
            item {
                SettingsAction("修改日志", "查看与你有关的修改记录", Icons.Outlined.History) {
                    navigate(Destination("audit"))
                }
            }
            item {
                SettingsAction("回收站", "恢复删除的影像与日记", Icons.Outlined.DeleteOutline) {
                    navigate(Destination("trash"))
                }
            }
            item {
                Choice(
                    "外观",
                    theme,
                    listOf("system" to "跟随系统", "light" to "浅色", "dark" to "深色"),
                    onChange = changeTheme,
                )
            }
            item {
                SettingsAction("清理浏览缓存", "重新读取列表与预览", Icons.Outlined.CleaningServices) {
                    model.run {
                        model.api.invalidate()
                        coil.Coil.imageLoader(model.getApplication()).memoryCache?.clear()
                        coil.Coil.imageLoader(model.getApplication()).diskCache?.clear()
                        model.reload()
                    }
                }
            }
            item {
                Text(
                    "Yearly Android ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            item {
                OutlinedButton({ logout = true }, Modifier.fillMaxWidth()) { Text("退出登录 / 切换站点") }
            }
        }
    }
    if (logout)
        ConfirmDialog("退出登录", "未完成的上传任务将暂停并保留在本机。", "退出登录", { logout = false }) {
            logout = false
            model.run {
                model.uploads.pauseAll()
                model.api.logout()
            }
        }
}

@Composable
fun SettingsAction(
    title: String,
    detail: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    action: () -> Unit,
) {
    TextButton(
        action,
        contentPadding = PaddingValues(vertical = 10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Icon(icon, null, Modifier.size(28.dp))
        Column(Modifier.weight(1f).padding(horizontal = 14.dp)) {
            Text(
                title,
                color = MaterialTheme.colorScheme.onSurface,
                style = MaterialTheme.typography.titleMedium,
            )
            Text(
                detail,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
        }
        Icon(Icons.Outlined.ChevronRight, null)
    }
}

@Composable
fun AccountsScreen(model: AppModel, close: () -> Unit, navigate: (Destination) -> Unit) {
    var users by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    LaunchedEffect(model.revision) { model.run { users = model.api.getArray("/users", true) } }
    Column {
        PageBar(
            "账户管理",
            close,
            actions = {
                IconButton({ navigate(Destination("account")) }) {
                    Icon(Icons.Outlined.PersonAdd, "新建账户")
                }
            },
        )
        LazyColumn(
            contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            items(users, key = { it.getInt("id") }) { user ->
                ListItem(
                    headlineContent = { Text(user.text("username")) },
                    supportingContent = {
                        Text(
                            "${when (user.text("role")) { "admin" -> "管理员"
 "member" -> "普通账户"
 else -> "只读访客" }} · ${if (user.optBoolean("active")) "已启用" else "已停用"}"
                        )
                    },
                    trailingContent = {
                        TextButton({ navigate(Destination("account", raw = user)) }) { Text("管理") }
                    },
                )
                HorizontalDivider()
            }
        }
    }
}

@Composable
fun AccountEditor(model: AppModel, existing: JSONObject?, close: () -> Unit) {
    val account by model.api.account.collectAsStateWithLifecycle()
    var username by remember { mutableStateOf(existing?.text("username").orEmpty()) }
    var password by remember { mutableStateOf("") }
    var role by remember { mutableStateOf(existing?.text("role") ?: "member") }
    var active by remember { mutableStateOf(existing?.optBoolean("active") ?: true) }
    val self = existing?.getInt("id") == account?.id
    FormPage(
        if (existing == null) "新建账户" else "管理账户",
        close,
        enabled = username.isNotBlank(),
        onSave = {
            if (existing == null)
                model.change(
                    "/users",
                    "POST",
                    json("username" to username, "password" to password, "role" to role),
                )
            else {
                val result =
                    model.change(
                        "/users/${existing.getInt("id")}",
                        "PUT",
                        json(
                            "username" to username,
                            "password" to password.ifBlank { null },
                            "role" to role,
                            "active" to active,
                        ),
                    )
                if (result.optBoolean("reauthenticate")) model.api.expire()
            }
            password = ""
            close()
        },
    ) {
        Field("用户名", username) { username = it }
        Field(if (existing == null) "密码（至少 12 位）" else "新密码（留空保留当前密码）", password, password = true) {
            password = it
        }
        Choice(
            "角色",
            role,
            listOf("member" to "普通账户", "admin" to "管理员") +
                if (existing?.text("role") == "viewer") listOf("viewer" to "只读访客") else emptyList(),
            enabled = !self,
        ) {
            role = it
        }
        if (existing != null) ToggleRow("启用账户", active, enabled = !self) { active = it }
        Text("修改用户名、角色或密码，以及停用账户，会使该账户的已有登录失效。", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
fun PasswordScreen(model: AppModel, close: () -> Unit) {
    var old by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    FormPage(
        "修改密码",
        close,
        onSave = {
            check(password == confirmation) { "两次输入的新密码不一致" }
            model.api.write(
                "/auth/password",
                "POST",
                json("old_password" to old, "new_password" to password),
            )
            old = ""
            password = ""
            confirmation = ""
            model.api.expire()
            close()
        },
    ) {
        Field("当前密码", old, password = true) { old = it }
        Field("新密码（至少 12 位）", password, password = true) { password = it }
        Field("再次输入新密码", confirmation, password = true) { confirmation = it }
    }
}

val resourceLabels =
    linkedMapOf(
        "" to "全部类型",
        "media" to "文件",
        "timeline_folder" to "文件夹",
        "child" to "档案",
        "timeline_event" to "日记",
        "timeline_day" to "日期设置",
        "timeline_share" to "分享",
        "sys_user" to "账户",
    )
val fieldLabels =
    mapOf(
        "title" to "标题",
        "name" to "名称",
        "username" to "用户名",
        "role" to "角色",
        "active" to "启用账户",
        "password" to "密码",
        "status" to "状态",
        "share_allowed" to "允许分享",
        "child_ids" to "人物与宠物",
        "faces" to "人脸确认",
        "media_ids" to "关联影像",
        "folder_id" to "文件夹",
        "timeline_date" to "归档日期",
        "batch_name" to "批次名称",
        "remark" to "备注",
        "content" to "日记内容",
        "sort_order" to "顺序",
        "location_name" to "地点",
        "expires_at" to "有效期",
        "revoked" to "撤销分享",
    )

@Composable
fun AuditScreen(model: AppModel, destination: Destination, close: () -> Unit) {
    var type by remember { mutableStateOf(destination.resource) }
    var page by remember { mutableIntStateOf(1) }
    var rows by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var total by remember { mutableIntStateOf(0) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    LaunchedEffect(type, page) {
        loading = true
        error = ""
        try {
            val params = mutableListOf("page" to page.toString())
            if (type.isNotBlank()) params += "resource_type" to type
            destination.raw?.optionalInt("id")?.let { params += "resource_id" to it.toString() }
            val result = model.api.getObject(YearlyApi.query("/audit-logs", params), true)
            rows = if (page == 1) result.objects("items") else rows + result.objects("items")
            total = result.getInt("total")
        } catch (failure: Exception) {
            error = failure.message.orEmpty()
        } finally {
            loading = false
        }
    }
    Column {
        PageBar("修改日志", close)
        if (destination.resource.isBlank())
            Box(Modifier.padding(horizontal = 20.dp)) {
                Choice("内容类型", type, resourceLabels.toList()) {
                    type = it
                    page = 1
                    rows = emptyList()
                }
            }
        if (error.isNotBlank()) ErrorBanner(error)
        LazyColumn(
            contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (rows.isEmpty() && !loading) item { EmptyState("暂无修改记录") }
            items(rows, key = { it.getInt("id") }) { log ->
                Text(
                    "${log.text("actor_name")} · ${resourceLabels[log.text("resource_type")] ?: log.text("resource_type")} #${log.text("resource_id")}",
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "${when (log.text("action")) { "create" -> "创建"
 "delete" -> "删除"
 else -> "修改" }} · ${log.text("created_at")}",
                    style = MaterialTheme.typography.labelSmall,
                )
                val changes = log.optJSONObject("changes") ?: JSONObject()
                changes.keys().forEach { key ->
                    val change = changes.optJSONObject(key) ?: JSONObject()
                    Text(
                        fieldLabels[key] ?: key,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    if (change.optBoolean("changed") && !change.has("after")) Text("已更新")
                    else
                        Text(
                            "${auditValue(change.opt("before"))} → ${auditValue(change.opt("after"))}",
                            style = MaterialTheme.typography.bodySmall,
                        )
                }
                HorizontalDivider()
            }
            if (rows.size < total)
                item {
                    TextButton({ page++ }, Modifier.fillMaxWidth(), enabled = !loading) {
                        Text("加载更多日志")
                    }
                }
            if (loading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        }
    }
}

fun auditValue(value: Any?): String =
    when (value) {
        null,
        JSONObject.NULL -> "空"
        true -> "是"
        false -> "否"
        else -> value.toString().ifBlank { "空" }
    }

@Composable
fun TrashScreen(model: AppModel, close: () -> Unit) {
    val account by model.api.account.collectAsStateWithLifecycle()
    var rows by remember { mutableStateOf<List<Memory>>(emptyList()) }
    var cursor by remember { mutableStateOf<String?>(null) }
    var total by remember { mutableIntStateOf(0) }
    var page by remember { mutableIntStateOf(0) }
    LaunchedEffect(page, model.revision) {
        model.run {
            val params = model.filter.copy(trash = true, anchor = "").parameters()
            if (page > 0) cursor?.let { params += "cursor" to it }
            val result =
                TimelinePage.parse(model.api.getObject(YearlyApi.query("/timeline", params), true))
            rows = if (page == 0) result.items else (rows + result.items).distinctBy { it.key }
            cursor = result.next
            total = result.total
        }
    }
    Column {
        PageBar("回收站 · $total 项", close)
        LazyColumn(
            contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (rows.isEmpty()) item { EmptyState("回收站是空的") }
            items(rows, key = { it.key }) { memory ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(memory.label)
                        Text(
                            "${memory.day} · ${if (memory.kind == "event") "日记" else typeLabel(memory.type)}",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    if (account?.canEdit(memory.raw) == true)
                        TextButton({
                            model.run {
                                model.api.write(
                                    "/${if (memory.kind == "event") "events" else "media"}/${memory.id}/restore",
                                    "POST",
                                )
                                rows = rows.filter { it.key != memory.key }
                                total--
                                model.load()
                            }
                        }) {
                            Text("恢复")
                        }
                }
                HorizontalDivider()
            }
            if (cursor != null)
                item { TextButton({ page++ }, enabled = !model.busy) { Text("加载更多") } }
        }
    }
}
