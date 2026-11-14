package family.yearly.app

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeProtocolTest {
    @Test
    fun secureSessionCacheAndMultipartResumeUseNativeEntryPoints() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val testNamespace = "protocol-${System.nanoTime()}"
        val testDirectory = File(context.cacheDir, testNamespace).apply { mkdirs() }
        val queueContext =
            object : ContextWrapper(context) {
                override fun getNoBackupFilesDir(): File = testDirectory

                override fun getCacheDir(): File = File(testDirectory, "cache").apply { mkdirs() }

                override fun getSharedPreferences(name: String, mode: Int) =
                    super.getSharedPreferences("$testNamespace-$name", mode)
            }
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverCertificates =
            HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientCertificates =
            HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val transport =
            OkHttpClient.Builder()
                .sslSocketFactory(
                    clientCertificates.sslSocketFactory(),
                    clientCertificates.trustManager,
                )
                .followRedirects(false)
                .followSslRedirects(false)
                .build()
        val apiServer =
            MockWebServer().apply {
                useHttps(serverCertificates.sslSocketFactory(), false)
                start()
            }
        val objectServer =
            MockWebServer().apply {
                useHttps(serverCertificates.sslSocketFactory(), false)
                start()
            }
        val uploadedRequests = CopyOnWriteArrayList<RecordedRequest>()
        objectServer.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    uploadedRequests += request
                    if (request.getHeader("Content-Type") != null)
                        return MockResponse().setResponseCode(403)
                    return MockResponse().setResponseCode(200)
                }
            }
        val childrenReads = AtomicInteger(0)
        val creates = AtomicInteger(0)
        val completes = AtomicInteger(0)
        val data = "123456789-original".toByteArray()
        val fingerprint = data.inputStream().use { FileIntegrity.fingerprint(it) }
        val remote =
            json(
                "id" to "task-1",
                "media_id" to 9,
                "sha256" to fingerprint.sha256,
                "file_size" to data.size,
                "file_role" to "original",
                "part_size" to 8,
                "status" to "pending",
            )
        var lastKey: String? = null
        var lastCreation: JSONObject? = null
        apiServer.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    fun response(body: JSONObject) =
                        MockResponse()
                            .setHeader("Content-Type", "application/json")
                            .setBody(body.toString())
                    val path = request.requestUrl!!.encodedPath
                    if (path == "/family/api/auth/login")
                        return response(
                                json(
                                    "id" to 7,
                                    "username" to "test-member",
                                    "role" to "member",
                                    "csrf_token" to "test-csrf",
                                )
                            )
                            .addHeader(
                                "Set-Cookie",
                                "yearly_session=test-session; Max-Age=3600; Path=/family/; Secure; HttpOnly; SameSite=Strict",
                            )
                    if (request.getHeader("Cookie") != "yearly_session=test-session")
                        return MockResponse().setResponseCode(401)
                    if (request.method != "GET") {
                        if (
                            request.getHeader("X-CSRF-Token") != "test-csrf" ||
                                request.getHeader("Origin") !=
                                    apiServer.url("/").toString().removeSuffix("/")
                        )
                            return MockResponse().setResponseCode(403)
                    }
                    return when (path) {
                        "/family/api/auth/me" ->
                            response(
                                json(
                                    "id" to 7,
                                    "username" to "test-member",
                                    "role" to "member",
                                    "csrf_token" to "test-csrf",
                                )
                            )
                        "/family/api/children" ->
                            if (request.method == "GET") {
                                childrenReads.incrementAndGet()
                                MockResponse().setBody("[]")
                            } else response(json("ok" to true))
                        "/family/api/uploads" ->
                            if (request.method == "GET")
                                MockResponse()
                                    .setBody("[]")
                            else {
                                creates.incrementAndGet()
                                lastKey = request.getHeader("Idempotency-Key")
                                lastCreation = JSONObject(request.body.readUtf8())
                                response(
                                    json("media_id" to 9, "tasks" to JSONArray(listOf(remote)))
                                )
                            }
                        "/family/api/uploads/task-1" ->
                            response(
                                json(
                                    "status" to "uploading",
                                    "parts" to JSONArray(listOf(json("number" to 1, "size" to 8))),
                                )
                            )
                        "/family/api/uploads/task-1/sign" ->
                            response(
                                json(
                                    "url" to
                                        objectServer
                                            .url(
                                                "/part?number=${request.requestUrl!!.queryParameter("number")}"
                                            )
                                            .toString()
                                )
                            )
                        "/family/api/uploads/task-1/complete" -> {
                            completes.incrementAndGet()
                            response(json("status" to "complete"))
                        }
                        "/family/api/auth/logout" -> response(json("ok" to true))
                        else -> MockResponse().setResponseCode(404)
                    }
                }
            }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val api = YearlyApi(queueContext, transport)
        try {
            api.configure(apiServer.url("/family/").toString())
            api.login("test-member", "synthetic-password", "captcha", "1234")
            assertEquals(7, api.account.value!!.id)
            assertTrue(api.getArray("/children").isEmpty())
            assertTrue(api.getArray("/children").isEmpty())
            assertEquals(1, childrenReads.get())
            api.write("/children", "POST", json("name" to "虚拟家人"))
            api.getArray("/children")
            assertEquals(2, childrenReads.get())
            val restored = YearlyApi(queueContext, transport)
            restored.configure(api.currentSite)
            restored.restore()
            assertEquals(7, restored.account.value!!.id)
            val id = "11111111-1111-4111-8111-111111111111"
            val root = File(testDirectory, "original-queue/$id").apply { mkdirs() }
            File(root, "original").writeBytes(data)
            val resource =
                UploadResource(
                    "original",
                    "synthetic.jpg",
                    "image/jpeg",
                    "original",
                    data.size.toLong(),
                    fingerprint.sha256,
                    fingerprint.crc64,
                )
            val entry =
                UploadItem(
                    id,
                    api.currentSite,
                    7,
                    "content://synthetic",
                    "synthetic.jpg",
                    "image/jpeg",
                    "ready",
                    resources = listOf(resource),
                    fields =
                        json(
                            "metadata" to
                                json(
                                    "android_source_dates" to
                                        json(
                                            "taken_at_ms" to
                                                java.time.Instant.parse("2020-02-29T12:00:00Z")
                                                    .toEpochMilli()
                                        )
                                )
                        ),
                )
            File(testDirectory, "original-queue/queue.json")
                .writeText(JSONArray(listOf(entry.serialize())).toString())
            val queue = UploadQueue(queueContext, api, scope)
            withContext(Dispatchers.Main) { queue.confirm(setOf(id), emptySet(), "验证批次", "") }
            withTimeout(30_000) {
                while (queue.items.value.single().phase !in listOf("complete", "failed")) delay(50)
            }
            assertEquals(
                queue.items.value.single().message,
                "complete",
                queue.items.value.single().phase,
            )
            assertEquals(1, creates.get())
            assertEquals(id, lastKey)
            assertEquals(
                OriginalMetadata.archiveFallback(entry.fields)!!.first.substringBefore('T'),
                lastCreation!!.getString("timeline_date"),
            )
            assertFalse(lastCreation!!.has("original_taken_at_local"))
            assertEquals(1, completes.get())
            assertEquals(2, uploadedRequests.size)
            assertEquals(
                listOf("2", "3"),
                uploadedRequests.map { it.requestUrl!!.queryParameter("number") },
            )
            val sent =
                uploadedRequests.flatMap { it.body.clone().readByteArray().toList() }.toByteArray()
            assertArrayEquals(data.copyOfRange(8, data.size), sent)
            uploadedRequests.forEach { request ->
                listOf("Cookie", "Origin", "X-CSRF-Token", "Authorization", "Content-Type")
                    .forEach { assertNull(request.getHeader(it)) }
            }
            withContext(Dispatchers.Main) { assertFalse(File(root, "original").exists()) }

            val resumedId = "22222222-2222-4222-8222-222222222222"
            val resumedRoot = File(testDirectory, "original-queue/$resumedId").apply { mkdirs() }
            File(resumedRoot, "original").writeBytes(data)
            val interrupted =
                entry.copy(
                    id = resumedId,
                    phase = "uploading",
                    confirmed = true,
                    resources = listOf(resource.copy(task = remote, uploaded = 8)),
                )
            File(testDirectory, "original-queue/queue.json")
                .writeText(JSONArray(listOf(interrupted.serialize())).toString())
            val resumed = UploadQueue(queueContext, api, scope)
            assertEquals("paused", resumed.items.value.single().phase)
            withContext(Dispatchers.Main) { resumed.resume(resumedId) }
            withTimeout(30_000) {
                while (resumed.items.value.single().phase !in listOf("complete", "failed")) delay(
                    50
                )
            }
            assertEquals("complete", resumed.items.value.single().phase)
            assertEquals(1, creates.get())
            assertEquals(2, completes.get())
            assertEquals(4, uploadedRequests.size)

            File(resumedRoot, "original").apply {
                parentFile!!.mkdirs()
                writeText("changed-source")
            }
            File(testDirectory, "original-queue/queue.json")
                .writeText(JSONArray(listOf(interrupted.serialize())).toString())
            val corrupted = UploadQueue(queueContext, api, scope)
            withContext(Dispatchers.Main) { corrupted.resume(resumedId) }
            withTimeout(30_000) {
                while (corrupted.items.value.single().phase != "failed") delay(50)
            }
            assertEquals(2, completes.get())
            assertEquals(4, uploadedRequests.size)
            api.logout()
            assertNull(api.account.value)
            val loggedOut = YearlyApi(queueContext, transport)
            loggedOut.configure(api.currentSite)
            loggedOut.restore()
            assertNull(loggedOut.account.value)
        } finally {
            scope.cancel()
            apiServer.shutdown()
            objectServer.shutdown()
            testDirectory.deleteRecursively()
            listOf("yearly", "secure-sessions", "upload-preferences").forEach {
                context.deleteSharedPreferences("$testNamespace-$it")
            }
        }
    }
}
