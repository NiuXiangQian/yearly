package family.yearly.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import org.json.JSONObject

class MainActivity : ComponentActivity() {
    private val model: AppModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { YearlyApp(model) }
    }
}

@Composable
fun YearlyTheme(mode: String, content: @Composable () -> Unit) {
    val dark = mode == "dark" || (mode == "system" && isSystemInDarkTheme())
    val colors =
        if (dark)
            darkColorScheme(
                primary = Color(0xFFA3CAB0),
                onPrimary = Color(0xFF14291F),
                primaryContainer = Color(0xFF2D4738),
                onPrimaryContainer = Color(0xFFD1E9D6),
                secondary = Color(0xFFA3CAB0),
                secondaryContainer = Color(0xFF2D4738),
                onSecondaryContainer = Color(0xFFD1E9D6),
                background = Color(0xFF121615),
                surface = Color(0xFF191F1C),
                surfaceVariant = Color(0xFF29332D),
            )
        else
            lightColorScheme(
                primary = Color(0xFF345C4A),
                onPrimary = Color.White,
                primaryContainer = Color(0xFFDDE8DC),
                onPrimaryContainer = Color(0xFF1B3827),
                secondary = Color(0xFF345C4A),
                secondaryContainer = Color(0xFFDDE8DC),
                onSecondaryContainer = Color(0xFF1B3827),
                background = Color(0xFFF5F5F0),
                surface = Color(0xFFFFFEFA),
                surfaceVariant = Color(0xFFE5EBE3),
            )
    val activity = LocalContext.current as android.app.Activity
    SideEffect {
        activity.window.statusBarColor = colors.background.toArgb()
        activity.window.navigationBarColor = colors.background.toArgb()
        WindowCompat.getInsetsController(activity.window, activity.window.decorView).apply {
            isAppearanceLightStatusBars = !dark
            isAppearanceLightNavigationBars = !dark
        }
    }
    MaterialTheme(colorScheme = colors, content = content)
}

data class Destination(
    val page: String,
    val item: Memory? = null,
    val raw: JSONObject? = null,
    val ids: Set<Int> = emptySet(),
    val day: String = "",
    val resource: String = "",
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun YearlyApp(model: AppModel) {
    val preferences =
        model.getApplication<android.app.Application>().getSharedPreferences("appearance", 0)
    var theme by rememberSaveable {
        mutableStateOf(preferences.getString("theme", "system") ?: "system")
    }
    val account by model.api.account.collectAsStateWithLifecycle()
    val timelineState = rememberLazyListState()
    val timelineSavedState = rememberSaveableStateHolder()
    LaunchedEffect(model.filter, account?.id) { timelineState.scrollToItem(0) }
    var route by remember { mutableStateOf<Destination?>(null) }
    val lifecycle = LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) model.uploads.pauseAll()
        }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(account?.id) { route = null }
    val backdrop = remember { MotionBackdrop() }
    CompositionLocalProvider(LocalMotionBackdrop provides backdrop) {
    YearlyTheme(theme) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            if (model.restoring)
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            else if (account == null) LoginScreen(model)
            else {
                val navigate: (Destination) -> Unit = { route = it }
                val close: () -> Unit = { route = null }
                BackHandler(route != null) { close() }
                Scaffold(
                    modifier = Modifier.graphicsLayer {
                        scaleX = 1 - backdrop.progress * .08f; scaleY = scaleX
                        shape = RoundedCornerShape((24 * backdrop.progress).dp); clip = backdrop.progress > 0
                    },
                    containerColor = MaterialTheme.colorScheme.background,
                    bottomBar = {
                        if (route == null)
                            LiquidNavigation(model.tab) { model.tab = it }

                    },
                ) { padding ->
                    Column(Modifier.padding(padding).fillMaxSize()) {
                        if (model.error.isNotBlank()) ErrorBanner(model.error) { model.error = "" }
                        if (model.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                        when (val destination = route) {
                            null ->
                                when (model.tab) {
                                    0 ->
                                        timelineSavedState.SaveableStateProvider(model.api.scope) {
                                            TimelineScreen(model, navigate, timelineState)
                                        }
                                    1 ->
                                        UploadScreen(
                                            model,
                                            showRecent = {
                                                model.tab = 0
                                                model.applyFilter(TimelineFilter(byUpload = true))
                                            },
                                        ) { id ->
                                            model.tab = 0
                                            model.run {
                                                val memory =
                                                    Memory(model.api.getObject("/media/$id", true))
                                                route = Destination("media", memory)
                                            }
                                        }
                                    2 -> FamilyScreen(model, navigate)
                                    else ->
                                        SettingsScreen(
                                            model,
                                            theme,
                                            { value ->
                                                theme = value
                                                preferences.edit().putString("theme", value).apply()
                                            },
                                            navigate,
                                        )
                                }
                            else ->
                                when (destination.page) {
                                    "media" ->
                                        MediaScreen(
                                            model,
                                            requireNotNull(destination.item),
                                            close,
                                            navigate,
                                        )
                                    "media-edit" ->
                                        MediaEditor(model, requireNotNull(destination.item), close)
                                    "event",
                                    "event-edit" -> EventScreen(model, destination, close, navigate)
                                    "profile" ->
                                        ProfileEditor(model, destination.raw, close, navigate)
                                    "folder" -> FolderScreen(model, destination, close, navigate)
                                    "organize" -> OrganizeScreen(model, destination.ids, close)
                                    "shares" -> SharesScreen(model, destination.ids, close)
                                    "accounts" -> AccountsScreen(model, close, navigate)
                                    "account" -> AccountEditor(model, destination.raw, close)
                                    "audit" -> AuditScreen(model, destination, close)
                                    "trash" -> TrashScreen(model, close)
                                    "password" -> PasswordScreen(model, close)
                                }
                        }
                    }
                }
            }
        }
    }
}
}

@Composable
fun LoginScreen(model: AppModel) {
    var site by rememberSaveable { mutableStateOf(model.api.savedSite) }
    var username by rememberSaveable { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var answer by remember { mutableStateOf("") }
    var captcha by remember { mutableStateOf<JSONObject?>(null) }
    Column(
        Modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(28.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Spacer(Modifier.height(36.dp))
        Icon(
            Icons.Outlined.AutoAwesome,
            null,
            Modifier.size(40.dp),
            tint = MaterialTheme.colorScheme.primary,
        )
        Text(
            "Yearly",
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            "把日子，珍藏成时光",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            site,
            {
                site = it
                captcha = null
            },
            label = { Text("家庭站点地址") },
            placeholder = { Text("https://example.com/yearly/") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
        )
        OutlinedButton(
            onClick = {
                model.run {
                    model.api.configure(site)
                    captcha = model.api.captcha()
                    answer = ""
                }
            },
            enabled = !model.busy && site.isNotBlank(),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (captcha == null) "连接家庭站点" else "刷新验证码")
        }
        if (captcha != null) {
            OutlinedTextField(
                username,
                { username = it },
                label = { Text("用户名") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                password,
                { password = it },
                label = { Text("密码") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                val captchaBytes =
                    remember(captcha) {
                        captcha?.text("image")?.substringAfter("base64,", "")?.let {
                            android.util.Base64.decode(it, android.util.Base64.DEFAULT)
                        }
                    }
                AsyncImage(captchaBytes, "图片验证码", Modifier.width(130.dp).height(50.dp))
                OutlinedTextField(
                    answer,
                    { answer = it },
                    label = { Text("验证码") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
            }
            Button(
                onClick = {
                    model.run {
                        try {
                            model.api.login(username, password, captcha!!.getString("id"), answer)
                            password = ""
                            model.reload()
                        } catch (failure: Exception) {
                            captcha = model.api.captcha()
                            answer = ""
                            throw failure
                        }
                    }
                },
                enabled =
                    !model.busy &&
                        username.isNotBlank() &&
                        password.isNotBlank() &&
                        answer.isNotBlank(),
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) {
                Text("登录家庭时光")
            }
        }
        if (model.error.isNotBlank()) Text(model.error, color = MaterialTheme.colorScheme.error)
        if (model.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        Text(
            "原片、安全会话与未完成的上传任务，都由你掌控。",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
fun ErrorBanner(message: String, dismiss: (() -> Unit)? = null) {
    Surface(color = MaterialTheme.colorScheme.errorContainer) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                message,
                Modifier.weight(1f),
                color = MaterialTheme.colorScheme.onErrorContainer,
                style = MaterialTheme.typography.bodyMedium,
            )
            if (dismiss != null) IconButton(dismiss) { Icon(Icons.Outlined.Close, "关闭提示") }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PageBar(
    title: String,
    back: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    TopAppBar(
        title = {
            Text(
                title,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            )
        },
        navigationIcon = {
            if (back != null) IconButton(back) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回") }
        },
        actions = actions,
        colors =
            TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
    )
}
