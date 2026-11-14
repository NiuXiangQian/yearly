package family.yearly.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

class SecureSessions(context: Context) {
    private val preferences = context.getSharedPreferences("secure-sessions", Context.MODE_PRIVATE)
    private val key: SecretKey by lazy {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("yearly-session", null) as? SecretKey)
            ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                .apply {
                    init(
                        KeyGenParameterSpec.Builder(
                                "yearly-session",
                                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                            )
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .build()
                    )
                }
                .generateKey()
    }

    fun read(site: String): JSONObject? {
        val value = preferences.getString(site, null) ?: return null
        val parts = value.split('.')
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            key,
            GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)),
        )
        cipher.updateAAD(site.toByteArray())
        return JSONObject(
            String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8)
        )
    }

    fun save(site: String, token: String, expires: Long) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(site.toByteArray())
        val encrypted =
            cipher.doFinal(json("token" to token, "expires" to expires).toString().toByteArray())
        val value =
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP) +
                "." +
                Base64.encodeToString(encrypted, Base64.NO_WRAP)
        check(preferences.edit().putString(site, value).commit()) { "无法保存安全登录状态" }
    }

    fun remove(site: String) {
        check(preferences.edit().remove(site).commit()) { "无法清除安全登录状态" }
    }
}

class YearlyApi(private val context: Context, transport: OkHttpClient? = null) {
    private val preferences = context.getSharedPreferences("yearly", Context.MODE_PRIVATE)
    private val sessions = SecureSessions(context)
    private val mutableAccount = MutableStateFlow<Account?>(null)
    val account = mutableAccount.asStateFlow()
    val client =
        transport
            ?: OkHttpClient.Builder()
                .followRedirects(false)
                .followSslRedirects(false)
                .connectTimeout(20, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .writeTimeout(180, TimeUnit.SECONDS)
                .build()
    var site: HttpUrl? = null
        private set

    private var token: String? = null
    private var expires = 0L
    private var revision = 0
    var sessionMessage: String = ""
        private set

    private val cacheRoot = File(context.cacheDir, "api-v1")
    val currentSite: String
        get() = site?.toString().orEmpty()

    val scope: String
        get() = "$currentSite|${account.value?.id ?: 0}"

    val savedSite: String
        get() = preferences.getString("site", "").orEmpty()

    fun configure(value: String) {
        val url = parseSite(value, BuildConfig.DEBUG)
        if (url != site) {
            sessionMessage = ""
            token = null
            mutableAccount.value = null
            expires = 0
            revision++
        }
        site = url
        preferences.edit().putString("site", url.toString()).apply()
    }

    suspend fun restore() {
        val stored = withContext(Dispatchers.IO) { sessions.read(currentSite) } ?: return
        if (stored.getLong("expires") <= System.currentTimeMillis()) {
            sessions.remove(currentSite)
            return
        }
        token = stored.getString("token")
        expires = stored.getLong("expires")
        mutableAccount.value = Account.parse(getObject("/auth/me", refresh = true))
    }

    suspend fun captcha(): JSONObject =
        JSONObject(send("/auth/captcha", authenticated = false).first)

    suspend fun login(username: String, password: String, captcha: String, answer: String) {
        val configured = requireNotNull(site)
        val (body, cookies) =
            send(
                "/auth/login",
                "POST",
                json(
                    "username" to username,
                    "password" to password,
                    "captcha_id" to captcha,
                    "captcha" to answer,
                ),
                authenticated = false,
            )
        val parsed =
            cookies
                .mapNotNull { Cookie.parse(configured, it) }
                .firstOrNull {
                    it.name == "yearly_session" &&
                        it.hostOnly &&
                        it.domain == configured.host &&
                        it.path == configured.encodedPath &&
                        it.httpOnly &&
                        (it.secure || !configured.isHttps) &&
                        it.expiresAt > System.currentTimeMillis()
                } ?: throw ApiFailure(0, "站点未返回有效的安全会话，请检查 HTTPS 与 Cookie 路径配置。")
        val account = Account.parse(JSONObject(body))
        withContext(Dispatchers.IO) { sessions.save(currentSite, parsed.value, parsed.expiresAt) }
        token = parsed.value
        expires = parsed.expiresAt
        sessionMessage = ""
        mutableAccount.value = account
    }

    suspend fun logout() {
        try {
            if (account.value != null) write("/auth/logout", "POST", JSONObject())
        } finally {
            expire()
        }
    }

    fun expire(message: String = "") {
        val oldScope = scope
        sessionMessage = message
        token = null
        expires = 0
        mutableAccount.value = null
        revision++
        File(cacheRoot, digest(oldScope)).deleteRecursively()
        sessions.remove(currentSite)
    }

    suspend fun getObject(path: String, refresh: Boolean = false): JSONObject =
        JSONObject(get(path, refresh))

    suspend fun getArray(path: String, refresh: Boolean = false): List<JSONObject> =
        JSONArray(get(path, refresh)).objects()

    private suspend fun get(path: String, refresh: Boolean): String =
        withContext(Dispatchers.IO) {
            val requestScope = scope
            val requestRevision = revision
            val file = File(File(cacheRoot, digest(requestScope)), digest(path))
            val cacheable =
                Regex("^/(timeline|media|events|children|folders|stats|uploaders)([/?]|$)")
                    .containsMatchIn(path) && !path.contains("/url")
            requireSession()
            if (
                cacheable &&
                    !refresh &&
                    file.exists() &&
                    System.currentTimeMillis() - file.lastModified() < 300_000
            ) {
                return@withContext file.readText()
            }
            val body = send(path).first
            if (cacheable && requestRevision == revision && requestScope == scope) {
                file.parentFile?.mkdirs()
                val temporary = File(file.parentFile, file.name + ".tmp")
                temporary.writeText(body)
                temporary.renameTo(file)
            }
            body
        }

    suspend fun write(
        path: String,
        method: String = "PUT",
        body: JSONObject = JSONObject(),
        key: String? = null,
    ): JSONObject {
        val response = send(path, method, body, key).first
        invalidate()
        return if (response.isBlank()) JSONObject() else JSONObject(response)
    }

    fun invalidate() {
        revision++
        File(cacheRoot, digest(scope)).deleteRecursively()
    }

    suspend fun searchMemories(body: JSONObject): JSONObject =
        JSONObject(send("/ai-search", "POST", body).first)

    suspend fun resource(
        memory: Memory,
        file: MediaFile,
        purpose: String = "preview",
    ): MediaResource =
        MediaResource.parse(
            getObject("/media/${memory.id}/files/${file.id}/url?purpose=$purpose", true)
        )

    private fun requireSession() {
        if (token == null || expires <= System.currentTimeMillis()) {
            if (token != null) expire("登录已过期，请重新登录。未完成的上传保留在本机。")
            throw ApiFailure(401, "请登录家庭账号后继续。")
        }
    }

    private suspend fun send(
        path: String,
        method: String = "GET",
        body: JSONObject? = null,
        key: String? = null,
        authenticated: Boolean = true,
    ): Pair<String, List<String>> =
        withContext(Dispatchers.IO) {
            val configured = requireNotNull(site) { "请先配置家庭站点" }
            require(path.startsWith("/") && !path.startsWith("//"))
            val url = requireNotNull(configured.resolve("api$path"))
            check(
                url.host == configured.host &&
                    url.port == configured.port &&
                    url.scheme == configured.scheme &&
                    url.encodedPath.startsWith(configured.encodedPath + "api/")
            )
            if (authenticated) requireSession()
            val usedToken = if (authenticated) token else null
            val request =
                Request.Builder()
                    .url(url)
                    .method(
                        method,
                        if (method == "GET") null
                        else (body ?: JSONObject()).toString().toRequestBody(JSON),
                    )
            if (usedToken != null) request.header("Cookie", "yearly_session=$usedToken")
            if (method != "GET") {
                request.header(
                    "Origin",
                    configured.newBuilder().encodedPath("/").build().toString().removeSuffix("/"),
                )
                if (authenticated) account.value?.let { request.header("X-CSRF-Token", it.csrf) }
            }
            key?.let { request.header("Idempotency-Key", it) }
            val transport = when {
                path == "/ai-search" -> client.newBuilder().readTimeout(150, TimeUnit.SECONDS).build()
                path.startsWith("/faces/media/") && path.endsWith("/analyze") -> client.newBuilder().readTimeout(180, TimeUnit.SECONDS).build()
                else -> client
            }
            transport.newCall(request.build()).execute().use { response ->
                val text = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    if (response.code == 401 && authenticated && token == usedToken)
                        expire("登录已失效，请重新登录。未完成的上传保留在本机。")
                    val message = runCatching { JSONObject(text).text("detail") }.getOrDefault("")
                    throw ApiFailure(
                        response.code,
                        message.ifBlank { "请求失败（${response.code}），请重试。" }.take(500),
                    )
                }
                text to response.headers("Set-Cookie")
            }
        }

    companion object {
        val JSON = "application/json; charset=utf-8".toMediaType()

        fun digest(value: String): String =
            MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") {
                "%02x".format(it)
            }

        fun parseSite(value: String, debug: Boolean = false): HttpUrl {
            val url = value.trim().toHttpUrl()
            require(
                url.username.isEmpty() &&
                    url.password.isEmpty() &&
                    url.query == null &&
                    url.fragment == null
            ) {
                "请输入完整的家庭站点地址"
            }
            require(
                url.isHttps || (debug && url.host in listOf("127.0.0.1", "localhost", "10.0.2.2"))
            ) {
                "站点需使用 HTTPS"
            }
            require(Regex("(/[A-Za-z0-9_-]+)*/?").matches(url.encodedPath)) { "站点路径不合法" }
            return if (url.encodedPath.endsWith('/')) url
            else url.newBuilder().addPathSegment("").build()
        }

        fun query(path: String, values: List<Pair<String, String>>): String {
            val url = "https://query.invalid$path".toHttpUrl().newBuilder()
            values.forEach { (key, value) -> url.addQueryParameter(key, value) }
            val built = url.build()
            return built.encodedPath + (built.encodedQuery?.let { "?$it" } ?: "")
        }
    }
}
