package family.yearly.app

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.nestedscroll.*
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch
import kotlin.math.*

private fun <T> motionSpring() = spring<T>(dampingRatio = .84f, stiffness = 500f)
class MotionBackdrop {
    val sheets = mutableStateMapOf<Any, Float>()
    val progress: Float get() = sheets.values.maxOrNull() ?: 0f
}
val LocalMotionBackdrop = staticCompositionLocalOf { MotionBackdrop() }

@Composable
fun LiquidNavigation(selected: Int, select: (Int) -> Unit) {
    val left = remember { Animatable(selected.toFloat()) }
    val right = remember { Animatable(selected.toFloat()) }
    LaunchedEffect(selected) {
        val forward = selected >= (left.value + right.value) / 2
        launch { (if (forward) right else left).animateTo(selected.toFloat(), motionSpring()) }
        launch { kotlinx.coroutines.delay(55); (if (forward) left else right).animateTo(selected.toFloat(), motionSpring()) }
    }
    val color = MaterialTheme.colorScheme.primaryContainer
    Surface(tonalElevation = 2.dp) {
        Box(Modifier.navigationBarsPadding().fillMaxWidth().height(64.dp)) {
            Canvas(Modifier.matchParentSize()) {
                val cell = size.width / 4
                val flatten = min(10.dp.toPx(), abs(right.value - left.value) * 8.dp.toPx())
                drawRoundRect(color, Offset(min(left.value, right.value) * cell + 5.dp.toPx(), 5.dp.toPx() + flatten / 2),
                    Size((1 + abs(right.value - left.value)) * cell - 10.dp.toPx(), 54.dp.toPx() - flatten), CornerRadius(28.dp.toPx()))
            }
            Row(Modifier.fillMaxSize()) {
                val titles = listOf("时间线", "上传", "家人", "我的")
                val icons = listOf(Icons.Outlined.PhotoLibrary, Icons.Outlined.CloudUpload, Icons.Outlined.People, Icons.Outlined.Person)
                titles.forEachIndexed { index, title ->
                    val tint by animateColorAsState(if (selected == index) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, tween(400), label = "tab label")
                    val scale = remember { Animatable(1f) }
                    LaunchedEffect(selected == index) {
                        if (selected == index) { scale.animateTo(.78f, tween(75)); scale.animateTo(1f, motionSpring()) }
                    }
                    Column(Modifier.weight(1f).fillMaxHeight().semantics { this.selected = selected == index }
                        .clickable(role = Role.Tab) { select(index) }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                        Icon(icons[index], null, Modifier.size(22.dp).graphicsLayer { scaleX = scale.value; scaleY = scale.value }, tint = tint)
                        Spacer(Modifier.height(4.dp))
                        Text(title, color = tint, style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun MotionSegmentPages(titles: List<String>, modifier: Modifier = Modifier, content: @Composable (Int) -> Unit) {
    val pager = rememberPagerState(pageCount = { titles.size })
    val scope = rememberCoroutineScope()
    val position = pager.currentPage + pager.currentPageOffsetFraction
    val color = MaterialTheme.colorScheme.primary
    Column(modifier) {
        Box {
            Row(Modifier.fillMaxWidth()) {
                titles.forEachIndexed { index, title ->
                    val emphasis = (1 - abs(position - index)).coerceIn(0f, 1f)
                    TextButton({ scope.launch { pager.animateScrollToPage(index, animationSpec = motionSpring()) } }, Modifier.weight(1f)
                        .semantics { selected = pager.settledPage == index }) {
                        Text(title, color = lerp(MaterialTheme.colorScheme.onSurfaceVariant, color, emphasis),
                            fontWeight = FontWeight((400 + emphasis * 250).roundToInt()))
                    }
                }
            }
            Canvas(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp)) {
                val base = floor(position); val fraction = position - base; val width = size.width / titles.size
                val start = (base + fraction * fraction) * width + 10.dp.toPx()
                val end = (base + 2 - (1 - fraction).pow(2)) * width - 10.dp.toPx()
                drawRoundRect(color, Offset(start, 0f), Size(max(0f, end - start), size.height), CornerRadius(size.height))
            }
        }
        HorizontalPager(pager, Modifier.fillMaxWidth().weight(1f), verticalAlignment = Alignment.Top) { page -> content(page) }
    }
}

@Composable
fun MotionBottomSheet(onDismissRequest: () -> Unit, dismissible: Boolean = true, content: @Composable ColumnScope.(dismiss: (() -> Unit) -> Unit) -> Unit) {
    val scope = rememberCoroutineScope()
    val backdrop = LocalMotionBackdrop.current
    val token = remember { Any() }
    val offset = remember { Animatable(3000f) }
    var height by remember { mutableFloatStateOf(0f) }
    var closing by remember { mutableStateOf(false) }
    fun close(after: () -> Unit = {}) {
        if (closing) return
        closing = true
        scope.launch { offset.animateTo(height, motionSpring()); onDismissRequest(); after() }
    }
    fun settle(velocity: Float) {
        if (dismissible && (offset.value > height / 3 || (offset.value > 12 && velocity > 800))) close()
        else scope.launch { offset.animateTo(0f, motionSpring()) }
    }
    val progress = if (height > 0) (1 - offset.value / height).coerceIn(0f, 1f) else 0f
    SideEffect { backdrop.sheets[token] = progress }
    DisposableEffect(Unit) { onDispose { backdrop.sheets.remove(token) } }
    LaunchedEffect(height > 0) { if (height > 0) { offset.snapTo(height); offset.animateTo(0f, motionSpring()) } }
    val nested = remember(dismissible, height) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.Drag && offset.value > 0 && available.y < 0) {
                    val delta = max(available.y, -offset.value)
                    scope.launch { offset.snapTo(offset.value + delta) }; return Offset(0f, delta)
                }
                return Offset.Zero
            }
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (dismissible && source == NestedScrollSource.Drag && available.y > 0) {
                    scope.launch { offset.snapTo(offset.value + available.y) }; return Offset(0f, available.y)
                }
                return Offset.Zero
            }
            override suspend fun onPreFling(available: Velocity): Velocity {
                if (offset.value > 0) { settle(available.y); return available }
                return Velocity.Zero
            }
        }
    }
    Dialog(onDismissRequest = { if (dismissible) close() }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false, dismissOnBackPress = dismissible)) {
        val dialogWindow = (LocalView.current.parent as? DialogWindowProvider)?.window
        SideEffect { dialogWindow?.setDimAmount(0f) }
        BoxWithConstraints(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .26f * progress)).clickable(enabled = dismissible, onClick = { close() }))
            Surface(Modifier.align(Alignment.BottomCenter).fillMaxWidth().heightIn(max = maxHeight - 48.dp)
                .onSizeChanged { height = it.height.toFloat() }
                .graphicsLayer { translationY = offset.value }
                .nestedScroll(nested), shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp), color = MaterialTheme.colorScheme.surface) {
                Column(Modifier.navigationBarsPadding().imePadding()) {
                    Box(Modifier.fillMaxWidth().height(28.dp).draggable(
                        state = rememberDraggableState { delta -> if (dismissible) scope.launch { offset.snapTo(max(-30f, offset.value + if (offset.value < 0) delta * .15f else delta)) } },
                        orientation = Orientation.Vertical, onDragStopped = { settle(it) }), contentAlignment = Alignment.Center) {
                        Box(Modifier.size(36.dp, 4.dp).clip(RoundedCornerShape(2.dp)).background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .4f)))
                    }
                    content { after -> close(after) }
                }
            }
        }
    }
}
