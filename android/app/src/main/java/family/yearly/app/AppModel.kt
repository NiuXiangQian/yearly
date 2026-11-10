package family.yearly.app

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONObject

class YearlyApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    companion object {
        lateinit var instance: YearlyApplication
            private set
    }
}

data class TimelineFilter(
    val search: String = "",
    val type: String = "",
    val people: Set<Int> = emptySet(),
    val uploader: Int? = null,
    val start: String = "",
    val end: String = "",
    val ascending: Boolean = false,
    val byUpload: Boolean = false,
    val anchor: String = "",
    val trash: Boolean = false,
) {
    fun parameters(): MutableList<Pair<String, String>> {
        val values =
            mutableListOf(
                "group_folders" to "false",
                "page_size" to "40",
                "order" to if (ascending) "asc" else "desc",
                "media_positions" to "true",
                "status" to if (trash) "deleted" else "active",
            )
        if (search.isNotBlank()) values += "q" to search.trim().take(200)
        if (type.isNotBlank()) values += "media_type" to type
        uploader?.let { values += "owner_id" to it.toString() }
        people.sorted().forEach { values += "child_id" to it.toString() }
        fun boundary(value: String, following: Boolean): String {
            val day = LocalDate.parse(value).plusDays(if (following) 1 else 0)
            return if (byUpload)
                day.atStartOfDay(ZoneId.systemDefault()).toInstant().toString().removeSuffix("Z")
            else "${day}T00:00:00"
        }
        if (start.isNotBlank()) values += "start" to boundary(start, false)
        if (end.isNotBlank()) values += "end" to boundary(end, true)
        if (byUpload) {
            values += "date_basis" to "upload"
            values +=
                "timezone_offset_minutes" to
                    (java.time.OffsetDateTime.now().offset.totalSeconds / 60).toString()
        }
        if (anchor.isNotBlank()) values += "anchor_day" to anchor
        return values
    }
}

class AppModel(application: Application) : AndroidViewModel(application) {
    val api = YearlyApi(application)
    val uploads = UploadQueue(application, api, viewModelScope)
    var restoring by mutableStateOf(true)
    private var operations by mutableIntStateOf(0)
    val busy: Boolean
        get() = operations > 0

    var error by mutableStateOf("")
    var tab by mutableStateOf(0)
    var memories by mutableStateOf<List<Memory>>(emptyList())
    var profiles by mutableStateOf<List<Profile>>(emptyList())
    var uploaders by mutableStateOf<List<JSONObject>>(emptyList())
    var total by mutableStateOf(0)
    var dates by mutableStateOf<List<String>>(emptyList())
    var sharing by mutableStateOf<Map<String, Boolean>>(emptyMap())
    var filter by mutableStateOf(TimelineFilter())
        private set

    var loading by mutableStateOf(false)
    var nextCursor by mutableStateOf<String?>(null)
    var previousCursor by mutableStateOf<String?>(null)
    var hasNewer by mutableStateOf(false)
    var revision by mutableStateOf(0)
    private var loadJob: Job? = null
    private var loadGeneration = 0

    init {
        viewModelScope.launch {
            try {
                if (api.savedSite.isNotBlank()) {
                    api.configure(api.savedSite)
                    api.restore()
                }
                if (api.account.value != null) reload()
            } catch (failure: Exception) {
                error = failure.message ?: "无法恢复登录状态"
            } finally {
                restoring = false
            }
        }
        viewModelScope.launch {
            var previous: Int? = null
            api.account.collect { account ->
                if (account == null && previous != null) {
                    if (api.sessionMessage.isNotBlank()) error = api.sessionMessage
                    uploads.pauseAll()
                    memories = emptyList()
                    profiles = emptyList()
                    uploaders = emptyList()
                    loadJob?.cancel()
                    filter = TimelineFilter()
                }
                previous = account?.id
            }
        }
    }

    fun run(action: suspend () -> Unit) {
        operations++
        error = ""
        viewModelScope.launch {
            try {
                action()
            } catch (failure: CancellationException) {
                throw failure
            } catch (failure: Exception) {
                error = failure.message ?: "操作失败，请重试。"
            } finally {
                operations--
            }
        }
    }

    suspend fun reload() {
        profiles = api.getArray("/children").map(::Profile)
        uploaders = api.getArray("/uploaders")
        load()
    }

    fun applyFilter(value: TimelineFilter) {
        filter = value
        load()
    }

    fun refresh() {
        api.invalidate()
        run { reload() }
    }

    fun load(more: Boolean = false, newer: Boolean = false) {
        if (more && loading) return
        if (more && !newer && nextCursor == null) return
        if (!more) loadJob?.cancel()
        val ticket = ++loadGeneration
        val requested = filter
        val account = api.account.value?.id ?: return
        loadJob =
            viewModelScope.launch {
                loading = true
                error = ""
                try {
                    val params = requested.parameters()
                    if (more) {
                        (if (newer) previousCursor else nextCursor)?.let {
                            params += "cursor" to it
                        }
                        if (newer) params += "before" to "true"
                    } else params += "include_dates" to "true"
                    val page =
                        TimelinePage.parse(api.getObject(YearlyApi.query("/timeline", params)))
                    if (
                        ticket != loadGeneration ||
                            requested != filter ||
                            account != api.account.value?.id
                    )
                        return@launch
                    memories =
                        when {
                            !more -> page.items
                            newer -> (page.items + memories).distinctBy { it.key }
                            else -> (memories + page.items).distinctBy { it.key }
                        }
                    total = page.total
                    sharing = if (more) sharing + page.sharing else page.sharing
                    if (!more) {
                        dates = page.dates
                        nextCursor = page.next
                        previousCursor = null
                        hasNewer = requested.anchor.isNotBlank()
                    } else if (newer) {
                        previousCursor = page.previous
                        hasNewer = page.previous != null
                    } else nextCursor = page.next
                } catch (failure: CancellationException) {
                    throw failure
                } catch (failure: Exception) {
                    error = failure.message ?: "时间线加载失败"
                } finally {
                    if (ticket == loadGeneration) loading = false
                }
            }
    }

    suspend fun change(path: String, method: String, body: JSONObject = JSONObject()): JSONObject {
        val result = api.write(path, method, body)
        revision++
        load()
        return result
    }
}
