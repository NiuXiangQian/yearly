package family.yearly.app

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import kotlin.math.roundToInt

@Composable
fun TimelineRail(
    days: List<String>,
    current: String,
    hold: (Boolean) -> Unit,
    select: (String) -> Unit,
) {
    val scale = remember(days) { TimelineScale(days) }
    var dragRatio by remember(days) { mutableStateOf<Float?>(null) }
    val currentHold by rememberUpdatedState(hold)
    val currentSelect by rememberUpdatedState(select)
    val primary = MaterialTheme.colorScheme.primary
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    Column(
        Modifier.width(48.dp).fillMaxHeight().padding(vertical = 12.dp).zIndex(1f),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Text(
            days.first().take(7).replace('-', '.'),
            fontSize = 9.sp,
            color = secondary,
            maxLines = 1,
        )
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            val ratio = dragRatio ?: scale.ratio(current).toFloat()
            val height = constraints.maxHeight.toFloat()
            val markerCount = maxOf(2, (maxHeight / 44.dp).toInt() + 1)
            val markers =
                remember(days, markerCount) {
                    (0 until markerCount)
                        .map { scale.nearest(it.toDouble() / (markerCount - 1)) }
                        .distinct()
                }
            Canvas(
                Modifier.fillMaxSize()
                    .semantics {
                        contentDescription = "拖动时间轴定位日期"
                        stateDescription = current
                        progressBarRangeInfo =
                            ProgressBarRangeInfo(
                                days.indexOf(current).coerceAtLeast(0).toFloat(),
                                0f..days.lastIndex.toFloat(),
                                (days.size - 2).coerceAtLeast(0),
                            )
                        setProgress {
                            currentSelect(days[it.roundToInt().coerceIn(days.indices)])
                            true
                        }
                    }
                    .pointerInput(days) {
                        detectTapGestures { point ->
                            currentSelect(scale.nearest((point.y / size.height).toDouble()))
                        }
                    }
                    .pointerInput(days) {
                        fun pick(y: Float) {
                            val value = (y / size.height).coerceIn(0f, 1f)
                            dragRatio = value
                            currentSelect(scale.nearest(value.toDouble()))
                        }
                        detectDragGestures(
                            onDragStart = {
                                currentHold(true)
                                pick(it.y)
                            },
                            onDragEnd = {
                                currentHold(false)
                                dragRatio = null
                            },
                            onDragCancel = {
                                currentHold(false)
                                dragRatio = null
                            },
                        ) { change, _ ->
                            change.consume()
                            pick(change.position.y)
                        }
                    }
            ) {
                val x = size.width / 2
                drawLine(
                    secondary.copy(alpha = .25f),
                    Offset(x, 0f),
                    Offset(x, size.height),
                    2.dp.toPx(),
                )
                markers.forEach { day ->
                    drawCircle(
                        primary.copy(alpha = .65f),
                        3.dp.toPx(),
                        Offset(x, scale.ratio(day).toFloat() * size.height),
                    )
                }
                val center = Offset(x, ratio * size.height)
                drawCircle(primary.copy(alpha = .16f), 12.dp.toPx(), center)
                drawCircle(primary, 7.dp.toPx(), center)
            }
            if (dragRatio != null)
                Surface(
                    modifier =
                        Modifier.offset {
                                IntOffset(
                                    44.dp.roundToPx(),
                                    (ratio * height - 18.dp.toPx()).roundToInt(),
                                )
                            }
                            .requiredWidth(124.dp),
                    shape = MaterialTheme.shapes.small,
                    tonalElevation = 6.dp,
                ) {
                    Text(
                        scale.nearest(ratio.toDouble()),
                        Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
                        fontSize = 13.sp,
                        maxLines = 1,
                    )
                }
        }
        Text(
            days.last().take(7).replace('-', '.'),
            fontSize = 9.sp,
            color = secondary,
            maxLines = 1,
        )
    }
}
