package family.yearly.app

import android.app.DatePickerDialog
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable
fun Field(
    label: String,
    value: String,
    enabled: Boolean = true,
    multiline: Boolean = false,
    password: Boolean = false,
    onChange: (String) -> Unit,
) {
    OutlinedTextField(
        value,
        onChange,
        label = { Text(label) },
        enabled = enabled,
        modifier = Modifier.fillMaxWidth(),
        singleLine = !multiline,
        minLines = if (multiline) 3 else 1,
        visualTransformation =
            if (password) PasswordVisualTransformation() else VisualTransformation.None,
    )
}

@Composable
fun DateField(label: String, value: String, onChange: (String) -> Unit) {
    val context = LocalContext.current
    val date = runCatching { LocalDate.parse(value) }.getOrNull() ?: LocalDate.now()
    OutlinedTextField(
        value,
        {},
        label = { Text(label) },
        readOnly = true,
        modifier = Modifier.fillMaxWidth(),
        trailingIcon = {
            Row {
                if (value.isNotBlank())
                    IconButton({ onChange("") }) { Icon(Icons.Outlined.Close, "清除$label") }
                IconButton({
                    DatePickerDialog(
                            context,
                            { _, year, month, day ->
                                onChange(LocalDate.of(year, month + 1, day).toString())
                            },
                            date.year,
                            date.monthValue - 1,
                            date.dayOfMonth,
                        )
                        .show()
                }) {
                    Icon(Icons.Outlined.CalendarMonth, "选择$label")
                }
            }
        },
    )
}

@Composable
fun Choice(
    label: String,
    value: String,
    options: List<Pair<String, String>>,
    enabled: Boolean = true,
    onChange: (String) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Column {
        Text(
            label,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Box {
            OutlinedButton({ open = true }, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
                Text(
                    options.firstOrNull { it.first == value }?.second ?: value,
                    Modifier.weight(1f),
                )
                Icon(Icons.Outlined.ExpandMore, "选择$label")
            }
            DropdownMenu(open, { open = false }) {
                options.forEach { (key, title) ->
                    DropdownMenuItem(
                        { Text(title) },
                        {
                            onChange(key)
                            open = false
                        },
                    )
                }
            }
        }
    }
}

@Composable
fun ToggleRow(label: String, value: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .heightIn(min = 48.dp)
            .toggleable(
                value = value,
                enabled = enabled,
                role = Role.Switch,
                onValueChange = onChange,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, Modifier.weight(1f))
        Switch(value, null, enabled = enabled)
    }
}

@Composable
fun PeoplePicker(profiles: List<Profile>, selected: Set<Int>, onChange: (Set<Int>) -> Unit) {
    if (profiles.isEmpty()) Text("暂时没有家人档案", style = MaterialTheme.typography.bodySmall)
    profiles.forEach { profile ->
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Checkbox(
                profile.id in selected,
                { checked ->
                    onChange(if (checked) selected + profile.id else selected - profile.id)
                },
            )
            Column(Modifier.weight(1f)) {
                Text(profile.label)
                Text(
                    profile.summary,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
fun FormPage(
    title: String,
    close: () -> Unit,
    saveLabel: String = "保存",
    enabled: Boolean = true,
    onSave: suspend () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    var confirmingExit by remember { mutableStateOf(false) }
    BackHandler { if (!saving) confirmingExit = true }
    Column(Modifier.fillMaxSize()) {
        PageBar(title, { confirmingExit = true })
        Column(
            Modifier.weight(1f).imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            content()
            if (error.isNotBlank()) ErrorBanner(error)
            Button(
                {
                    saving = true
                    error = ""
                    scope.launch {
                        try {
                            onSave()
                        } catch (failure: CancellationException) {
                            throw failure
                        } catch (failure: Exception) {
                            error = failure.message ?: "保存失败，请重试。"
                        } finally {
                            saving = false
                        }
                    }
                },
                Modifier.fillMaxWidth().heightIn(min = 50.dp),
                enabled = enabled && !saving,
            ) {
                if (saving) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                else Text(saveLabel)
            }
            Spacer(Modifier.height(24.dp))
        }
    }
    if (confirmingExit)
        ConfirmDialog("结束编辑", "尚未保存的内容将丢失。", "放弃编辑", { confirmingExit = false }, close)
}

@Composable
fun ConfirmDialog(
    title: String,
    message: String,
    confirm: String,
    close: () -> Unit,
    action: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = close,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = { TextButton(action) { Text(confirm) } },
        dismissButton = { TextButton(close) { Text("取消") } },
    )
}

@Composable
fun SectionTitle(label: String) {
    Text(label, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
}
