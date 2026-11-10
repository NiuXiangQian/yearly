package family.yearly.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import kotlinx.coroutines.launch
import org.json.JSONObject

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SharesScreen(model: AppModel, selection: Set<Int>, close: () -> Unit) {
    val context = LocalContext.current
    var rows by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var creating by remember { mutableStateOf(selection.isNotEmpty()) }
    var title by remember { mutableStateOf("") }
    var start by remember { mutableStateOf(LocalDate.now().toString()) }
    var end by remember { mutableStateOf(LocalDate.now().toString()) }
    var hours by remember { mutableStateOf("24") }
    var revision by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    var link by remember { mutableStateOf("") }
    var revoke by remember { mutableStateOf<JSONObject?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(revision) { model.run { rows = model.api.getArray("/shares", true) } }
    LaunchedEffect(Unit) {
        model.run {
            val bounds = model.api.getObject("/shares/bounds", true)
            bounds.text("earliest").takeIf(String::isNotBlank)?.let { start = it }
            bounds.text("latest").takeIf(String::isNotBlank)?.let { end = it }
        }
    }
    suspend fun shareLink(row: JSONObject): String {
        check(!row.optBoolean("revoked") && !row.optBoolean("expired")) { "此分享已经失效，可创建相同范围的新分享。" }
        val token =
            row.text("token").ifBlank {
                model.api.getObject("/shares/${row.getInt("id")}/link", true).getString("token")
            }
        check(Regex("[A-Za-z0-9_-]+").matches(token)) { "分享链接无效" }
        return requireNotNull(model.api.site).resolve("share/$token").toString()
    }
    Column {
        PageBar(
            "分享管理",
            close,
            actions = {
                IconButton({ revision++ }) { Icon(Icons.Outlined.Refresh, "刷新分享") }
                IconButton({ creating = true }) { Icon(Icons.Outlined.Add, "创建分享") }
            },
        )
        LazyColumn(
            contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (rows.isEmpty() && !model.busy)
                item { EmptyState("还没有分享记录", "选择日期范围，或从时间线选择影像后创建分享。") }
            items(rows, key = { it.getInt("id") }) { row ->
                val usable = !row.optBoolean("revoked") && !row.optBoolean("expired")
                Text(
                    row.text("title").ifBlank { "时光分享" },
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    if (row.text("scope") == "selection") "指定影像 · ${row.optInt("selected_count")} 项"
                    else "${row.text("start_date")} 至 ${row.text("end_date")}"
                )
                Text(
                    "${if (usable) "有效" else if (row.optBoolean("revoked")) "已撤销" else "已过期"} · 到期 ${row.text("expires_at")}",
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    "${row.optInt("visit_count")} 次访问 · ${row.optInt("visitor_count")} 位访客",
                    style = MaterialTheme.typography.labelMedium,
                )
                Row {
                    if (usable) {
                        TextButton({ model.run { link = shareLink(row) } }) { Text("查看链接") }
                        TextButton({
                            model.run {
                                val url = shareLink(row)
                                context.startActivity(
                                    Intent.createChooser(
                                        Intent(Intent.ACTION_SEND)
                                            .setType("text/plain")
                                            .putExtra(Intent.EXTRA_TEXT, url),
                                        "分享家庭时光",
                                    )
                                )
                            }
                        }) {
                            Text("分享")
                        }
                        TextButton({ revoke = row }) { Text("撤销") }
                    }
                    if (row.optBoolean("can_copy", true))
                        TextButton({
                            model.run {
                                val copied =
                                    model.api.write(
                                        "/shares/${row.getInt("id")}/copy",
                                        "POST",
                                        json("hours" to hours.toInt()),
                                    )
                                link = shareLink(copied)
                                revision++
                            }
                        }) {
                            Text("复制范围新建")
                        }
                }
                HorizontalDivider()
            }
        }
    }
    if (creating)
        ModalBottomSheet(onDismissRequest = { if (!saving) creating = false }) {
            Column(
                Modifier.padding(20.dp).imePadding().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(
                    if (selection.isEmpty()) "按日期分享" else "分享所选 ${selection.size} 项",
                    style = MaterialTheme.typography.titleLarge,
                )
                Field("分享标题", title) { title = it }
                if (selection.isEmpty()) {
                    DateField("内容开始日期", start) { start = it }
                    DateField("内容结束日期", end) { end = it }
                }
                Choice(
                    "链接有效期",
                    hours,
                    listOf(
                        "1" to "1 小时",
                        "6" to "6 小时",
                        "24" to "1 天",
                        "72" to "3 天",
                        "168" to "7 天",
                    ),
                ) {
                    hours = it
                }
                Text("访客只可阅读允许分享的预览内容。", style = MaterialTheme.typography.bodySmall)
                if (error.isNotBlank()) ErrorBanner(error)
                Button(
                    {
                        saving = true
                        error = ""
                        scope.launch {
                            try {
                                val body = json("title" to title, "hours" to hours.toInt())
                                if (selection.isNotEmpty())
                                    body.put("media_ids", org.json.JSONArray(selection.toList()))
                                else {
                                    check(start.isNotBlank() && end.isNotBlank() && start <= end) {
                                        "请选择有效的内容日期范围"
                                    }
                                    body.put("start_date", start).put("end_date", end)
                                }
                                val created = model.api.write("/shares", "POST", body)
                                if (
                                    selection.isNotEmpty() &&
                                        (created.text("scope") != "selection" ||
                                            created.optInt("selected_count") != selection.size)
                                ) {
                                    model.api.write("/shares/${created.getInt("id")}", "DELETE")
                                    error("服务端未确认指定影像范围，分享已撤销。")
                                }
                                link = shareLink(created)
                                revision++
                                creating = false
                            } catch (failure: Exception) {
                                error = failure.message.orEmpty()
                            } finally {
                                saving = false
                            }
                        }
                    },
                    Modifier.fillMaxWidth(),
                    enabled = !saving,
                ) {
                    Text(if (saving) "正在创建…" else "创建分享链接")
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    if (link.isNotBlank())
        AlertDialog(
            onDismissRequest = { link = "" },
            title = { Text("分享链接") },
            text = { Text(link) },
            confirmButton = {
                TextButton({
                    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                        .setPrimaryClip(ClipData.newPlainText("Yearly 分享", link))
                    link = ""
                }) {
                    Text("复制链接")
                }
            },
            dismissButton = {
                TextButton({ context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link))) }) {
                    Text("打开预览")
                }
            },
        )
    revoke?.let { row ->
        ConfirmDialog("撤销分享", "撤销后，访客将无法继续打开此链接。", "撤销分享", { revoke = null }) {
            revoke = null
            model.run {
                model.api.write("/shares/${row.getInt("id")}", "DELETE")
                revision++
            }
        }
    }
}
