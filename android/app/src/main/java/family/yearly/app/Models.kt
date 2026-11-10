package family.yearly.app

import java.time.LocalDate
import java.time.Period
import org.json.JSONArray
import org.json.JSONObject

fun JSONObject.text(key: String, fallback: String = ""): String =
    if (isNull(key)) fallback else optString(key, fallback)

fun JSONObject.optionalInt(key: String): Int? = if (isNull(key)) null else getInt(key)

fun JSONObject.objects(key: String): List<JSONObject> = optJSONArray(key)?.objects().orEmpty()

fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

fun JSONObject.ids(key: String): Set<Int> =
    optJSONArray(key)
        ?.let { array -> (0 until array.length()).map { array.getInt(it) }.toSet() }
        .orEmpty()

fun JSONObject.strings(key: String): List<String> =
    optJSONArray(key)
        ?.let { array -> (0 until array.length()).map { array.getString(it) } }
        .orEmpty()

fun json(vararg fields: Pair<String, Any?>): JSONObject =
    JSONObject().apply {
        fields.forEach { (key, value) ->
            put(
                key,
                when (value) {
                    null -> JSONObject.NULL
                    is Collection<*> -> JSONArray(value)
                    else -> value
                },
            )
        }
    }

class ApiFailure(val status: Int, message: String, val objectStore: Boolean = false) :
    Exception(message)

data class Account(val id: Int, val username: String, val role: String, val csrf: String) {
    val admin
        get() = role == "admin"

    val canWrite
        get() = role in listOf("admin", "member")

    val roleLabel
        get() =
            when (role) {
                "admin" -> "管理员"
                "member" -> "普通账户"
                else -> "只读访客"
            }

    fun canEdit(row: JSONObject): Boolean =
        admin ||
            (role == "member" &&
                if (row.has("can_edit")) row.optBoolean("can_edit")
                else (row.optionalInt("owner_id") ?: row.optionalInt("created_by")) == id)

    companion object {
        fun parse(row: JSONObject) =
            Account(
                row.getInt("id"),
                row.text("username"),
                row.getString("role"),
                row.getString("csrf_token"),
            )
    }
}

data class Profile(val raw: JSONObject) {
    val id = raw.getInt("id")
    val name = raw.getString("name")
    val label = raw.text("nickname").ifBlank { name }
    val type = raw.text("profile_type", "child")
    val description = raw.text("description")
    val birthday = raw.text("birthday")
    val avatar = raw.optionalInt("avatar_media_id")
    val summary: String
        get() =
            listOf(
                    when (type) {
                        "pet" -> "宠物"
                        "person" -> "家人"
                        else -> "孩子"
                    },
                    raw.text("relationship"),
                    raw.text("species"),
                    raw.text("breed"),
                    if (raw.text("status") == "archived") "已归档" else "",
                )
                .filter { it.isNotBlank() }
                .joinToString(" · ")

    fun age(day: String): String {
        if (!raw.optBoolean("growth_enabled", true) || birthday.isBlank() || day == "日期未知")
            return ""
        val start = runCatching { LocalDate.parse(birthday) }.getOrNull() ?: return ""
        val end = runCatching { LocalDate.parse(day) }.getOrNull() ?: return ""
        if (end < start) return ""
        val age = Period.between(start, end)
        return if (age.years > 0) "${age.years}岁${age.months}个月" else "${age.months}个月${age.days}天"
    }
}

data class MediaFile(
    val id: Int,
    val role: String,
    val name: String,
    val mime: String,
    val size: Long,
    val sha256: String,
    val crc64: String,
) {
    companion object {
        fun parse(row: JSONObject) =
            MediaFile(
                row.getInt("id"),
                row.text("file_role"),
                row.text("original_filename"),
                row.text("mime_type"),
                row.getLong("file_size"),
                row.text("sha256"),
                row.text("crc64"),
            )
    }
}

data class Memory(val raw: JSONObject) {
    val id = raw.getInt("id")
    val kind = raw.text("kind", "media")
    val key = "$kind-$id"
    val title = raw.text("title")
    val label = title.ifBlank { raw.text("batch_name").ifBlank { "珍藏的瞬间" } }
    val type = raw.text("media_type", "photo")
    val day =
        listOf("timeline_day", "timeline_date", "taken_at_local", "start_at")
            .firstNotNullOfOrNull { raw.text(it).takeIf(String::isNotBlank) }
            ?.take(10) ?: "日期未知"
    val uploadedDay =
        raw.text("uploaded_at").takeIf(String::isNotBlank)?.let { timestamp ->
            java.time.LocalDateTime.parse(timestamp.removeSuffix("Z"))
                .atOffset(java.time.ZoneOffset.UTC)
                .atZoneSameInstant(java.time.ZoneId.systemDefault())
                .toLocalDate()
                .toString()
        } ?: "日期未知"
    val files = raw.objects("files").map(MediaFile::parse)
    val primary = files.firstOrNull { it.role == "original" }
    val motion = files.firstOrNull { it.role == "live_video" }
    val children = raw.objects("children").map(::Profile)
    val childIds = raw.ids("child_ids").ifEmpty { children.map { it.id }.toSet() }
    val folder = raw.optionalInt("folder_id")
}

data class TimelinePage(
    val items: List<Memory>,
    val total: Int,
    val next: String?,
    val previous: String?,
    val dates: List<String>,
    val sharing: Map<String, Boolean>,
) {
    companion object {
        fun parse(row: JSONObject): TimelinePage {
            val sharing = row.optJSONObject("day_sharing")
            return TimelinePage(
                row.objects("items").map(::Memory),
                row.getInt("total"),
                row.text("next_cursor").ifBlank { null },
                row.text("previous_cursor").ifBlank { null },
                row.strings("dates"),
                sharing?.keys()?.asSequence()?.associateWith { sharing.getBoolean(it) }.orEmpty(),
            )
        }
    }
}

data class MediaResource(
    val url: String?,
    val status: String,
    val message: String,
    val mime: String,
) {
    companion object {
        fun parse(row: JSONObject) =
            MediaResource(
                row.text("url").ifBlank { null },
                row.text("status"),
                row.text("message"),
                row.text("mime_type"),
            )
    }
}

fun byteLabel(bytes: Long): String =
    android.text.format.Formatter.formatShortFileSize(YearlyApplication.instance, bytes)

/** Calendar spacing is independent of how many images happen to fall on a day. */
class TimelineScale(val days: List<String>) {
    private val epochs = days.map { LocalDate.parse(it).toEpochDay().toDouble() }
    private val span = (epochs.lastOrNull() ?: 0.0) - (epochs.firstOrNull() ?: 0.0)
    private val positions = epochs.map { if (span == 0.0) 0.0 else (it - epochs.first()) / span }
    private val byDay = days.zip(positions).toMap()

    fun ratio(day: String): Double = byDay[day] ?: 0.0

    fun nearest(ratio: Double): String {
        val target = ratio.coerceIn(0.0, 1.0)
        var lower = 0
        var upper = days.lastIndex
        while (lower < upper) {
            val middle = (lower + upper) / 2
            if (positions[middle] < target) lower = middle + 1 else upper = middle
        }
        if (lower > 0 && target - positions[lower - 1] <= positions[lower] - target) lower--
        return days[lower]
    }
}
