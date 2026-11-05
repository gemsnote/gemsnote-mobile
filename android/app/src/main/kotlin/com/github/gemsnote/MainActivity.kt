package com.github.gemsnote

import android.content.Intent
import android.os.Bundle
import android.graphics.drawable.Animatable
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.IntentCompat
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import android.widget.Toast
import android.widget.ImageView
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.io.File

class MainActivity : FlutterFragmentActivity(), FlutterUiDisplayListener {
    companion object {
        private val readers = Executors.newFixedThreadPool(2)
        private val timeouts = Executors.newSingleThreadScheduledExecutor()
        private val activeReaders = AtomicInteger(0)
        private var activeActivity = WeakReference<MainActivity>(null)
        fun hasRunningFlutterUi(): Boolean = activeActivity.get()?.let {
            it.flutterDisplayed && !it.isFinishing && !it.isDestroyed
        } ?: false
        private val textTypes = setOf("text/plain", "text/markdown")
        private var resourceStore: SharedResourceStore? = null
    }

    private data class TextInput(val title: String, val text: String,
        val id: String = UUID.randomUUID().toString().replace("-", "").take(24),
        val kind: String = "", val size: Long = 0)
    private var shareChannel: MethodChannel? = null
    private var widgetChannel: MethodChannel? = null
    private var cameraChannel: MethodChannel? = null
    private var startupLoading: View? = null
    private var flutterDisplayed = false

    override fun createFlutterFragment(): FlutterFragment = StartupFlutterFragment().apply {
        // Retain Flutter's entrypoint, engine, route and back-navigation options.
        arguments = this@MainActivity.defaultFragmentArguments()
    }

    private fun defaultFragmentArguments(): Bundle? = super.createFlutterFragment().arguments

    override fun onFlutterUiDisplayed() {
        flutterDisplayed = true
        (startupLoading?.findViewById<ImageView>(R.id.startup_spinner)?.drawable as? Animatable)?.stop()
        startupLoading?.let { (it.parent as? ViewGroup)?.removeView(it) }
        startupLoading = null
        LaunchActivity.finishPending()
    }

    override fun onFlutterUiNoLongerDisplayed() {
        // Returning from background must not cover an existing Flutter session.
    }
    private val avatarCamera by lazy { AvatarCamera(this) }
    private val prefs by lazy { getSharedPreferences("shared_text_inbox", MODE_PRIVATE) }
    private fun resources(): SharedResourceStore = synchronized(MainActivity::class.java) {
        resourceStore ?: SharedResourceStore(File(applicationContext.filesDir, "shared_resources")).also { resourceStore = it }
    }

    private fun pruneResources(queue: JSONArray) {
        resources().prune((0 until queue.length()).map { queue.getJSONObject(it).getString("id") }.toSet())
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gemsnote/app_language").setMethodCallHandler { call, result ->
            if (call.method != "setLanguage") result.notImplemented()
            else try {
                NativeLanguage.set(this, call.argument<String>("language") ?: "system")
                result.success(null)
            } catch (error: Exception) { result.error("language", NativeLanguage.errorMessage(this, error), null) }
        }
        avatarCamera.clearAbandonedCapture()
        cameraChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gemsnote/avatar_camera")
        cameraChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "capture") avatarCamera.capture(result) else result.notImplemented()
        }
        widgetChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gemsnote/home_widget")
        widgetChannel!!.setMethodCallHandler { call, result ->
            try {
                val account = call.argument<String>("account") ?: ""
                val epoch = call.argument<String>("epoch") ?: ""
                when (call.method) {
                    "activate" -> result.success(NoteWidgetStore.activate(this, account))
                    "publish" -> {
                        NoteWidgetStore.publish(this, account, epoch, call.argument<List<*>>("notes") ?: emptyList<Any>())
                        result.success(null)
                    }
                    "setEnabled" -> {
                        NoteWidgetStore.setEnabled(this, account, epoch, call.argument<Boolean>("enabled") == true)
                        result.success(null)
                    }
                    "peek" -> result.success(NoteWidgetStore.pending(this))
                    "acknowledge" -> {
                        NoteWidgetStore.acknowledge(this, call.argument<String>("id") ?: "")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) { result.error("homeWidget", NativeLanguage.errorMessage(this, error), null) }
        }
        activeActivity = WeakReference(this)
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gemsnote/shared_text")
        try { pruneResources(JSONArray(prefs.getString("queue", "[]"))) } catch (error: Exception) { showShareError(error) }
        shareChannel!!.setMethodCallHandler { call, result ->
            try {
                val queue = JSONArray(prefs.getString("queue", "[]"))
                when (call.method) {
                    "peek" -> {
                        if (queue.length() == 0) result.success(null)
                        else {
                            val item = queue.getJSONObject(0)
                            result.success(mapOf(
                                "id" to item.getString("id"),
                                "title" to item.getString("title"),
                                "text" to item.getString("text"),
                                "resourceKind" to item.optString("resourceKind", ""),
                                "resourceName" to item.optString("resourceName", ""),
                                "resourceSize" to item.optLong("resourceSize", 0),
                                "accountKey" to item.optString("accountKey", "")
                            ))
                        }
                    }
                    "claim" -> {
                        val id = call.argument<String>("id")
                        val account = call.argument<String>("accountKey")
                        val item = (0 until queue.length()).map { queue.getJSONObject(it) }
                            .firstOrNull { it.getString("id") == id }
                            ?: error(NativeLanguage.text(this, R.string.native_0))
                        require(!account.isNullOrBlank())
                        val previous = item.optString("accountKey", "")
                        check(previous.isEmpty() || previous == account) { NativeLanguage.text(this, R.string.native_1) }
                        item.put("accountKey", account)
                        check(prefs.edit().putString("queue", queue.toString()).commit()) { NativeLanguage.text(this, R.string.native_2) }
                        result.success(null)
                    }
                    "acknowledge" -> {
                        val id = call.argument<String>("id")
                        require(!id.isNullOrBlank())
                        val remaining = JSONArray()
                        for (i in 0 until queue.length()) {
                            val item = queue.getJSONObject(i)
                            if (item.getString("id") != id) remaining.put(item)
                        }
                        check(prefs.edit().putString("queue", remaining.toString()).commit()) { NativeLanguage.text(this, R.string.native_3) }
                        resources().delete(id)
                        result.success(null)
                    }
                    "readResource" -> {
                        val id = call.argument<String>("id")
                        val account = call.argument<String>("accountKey")
                        val item = (0 until queue.length()).map { queue.getJSONObject(it) }
                            .firstOrNull { it.getString("id") == id } ?: error(NativeLanguage.text(this, R.string.native_0))
                        require(!account.isNullOrBlank() && item.optString("accountKey") == account) { NativeLanguage.text(this, R.string.native_4) }
                        require(item.optString("resourceKind").isNotEmpty()) { NativeLanguage.text(this, R.string.native_5) }
                        val size = item.getLong("resourceSize")
                        readers.execute {
                            try {
                                val bytes = resources().read(id, size)
                                runOnUiThread { result.success(bytes) }
                            } catch (error: Exception) {
                                runOnUiThread { result.error("shareResource", NativeLanguage.errorMessage(this, error), null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("shareInbox", NativeLanguage.errorMessage(this, error), null)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!flutterDisplayed) {
            startupLoading = LayoutInflater.from(NativeLanguage.localized(this))
                .inflate(R.layout.startup_loading, null)
            addContentView(startupLoading, ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            (startupLoading?.findViewById<ImageView>(R.id.startup_spinner)?.drawable as? Animatable)?.start()
        }
        if (savedInstanceState == null) receiveWidget(intent)
        if (savedInstanceState == null) receiveText(intent)
    }

    override fun onDestroy() {
        (startupLoading?.findViewById<ImageView>(R.id.startup_spinner)?.drawable as? Animatable)?.stop()
        startupLoading?.let { (it.parent as? ViewGroup)?.removeView(it) }
        startupLoading = null
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (flutterDisplayed) LaunchActivity.finishPending()
        receiveWidget(intent)
        receiveText(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!avatarCamera.result(requestCode, resultCode)) super.onActivityResult(requestCode, resultCode, data)
    }

    private fun receiveWidget(incoming: Intent?) {
        try {
            if (NoteWidgetStore.receive(this, incoming)) widgetChannel?.invokeMethod("changed", null)
        } catch (error: Exception) { showShareError(error) }
    }

    private fun receiveText(incoming: Intent?) {
        if (incoming == null || incoming.action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return
        try {
            require(incoming.type?.contains('/') == true) { NativeLanguage.text(this, R.string.native_6) }
            val multiple = incoming.action == Intent.ACTION_SEND_MULTIPLE
            val streams = if (multiple) {
                IntentCompat.getParcelableArrayListExtra(incoming, Intent.EXTRA_STREAM, Uri::class.java)?.toList()
                    ?: emptyList()
            } else {
                listOfNotNull(IntentCompat.getParcelableExtra(incoming, Intent.EXTRA_STREAM, Uri::class.java))
            }
            val clip = incoming.clipData
            require(clip == null || clip.itemCount <= 8) { NativeLanguage.text(this, R.string.native_7) }
            val clipUris = if (clip == null) emptyList() else
                (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
            val uris = if (streams.isNotEmpty()) streams else clipUris
            val subject = SharedTextDecoder.title(incoming.getStringExtra(Intent.EXTRA_SUBJECT))
            @Suppress("DEPRECATION")
            val extraText = incoming.extras?.get(Intent.EXTRA_TEXT)
            val values = when (extraText) {
                null -> emptyList()
                is CharSequence -> listOf(extraText.toString())
                is ArrayList<*> -> extraText.map {
                    require(it is CharSequence) { NativeLanguage.text(this, R.string.native_8) }
                    it.toString()
                }
                else -> error(NativeLanguage.text(this, R.string.native_8))
            }
            require(values.size <= 8) { NativeLanguage.text(this, R.string.native_7) }
            val texts = values.map { TextInput(subject, SharedTextDecoder.validate(it)) }
            require(multiple || uris.size <= 1 && texts.size <= 1) { NativeLanguage.text(this, R.string.native_9) }
            require(uris.size + texts.size in 1..8) { NativeLanguage.text(this, R.string.native_10) }
            if (uris.isNotEmpty()) {
                require(multiple || uris.size == 1) { NativeLanguage.text(this, R.string.native_11) }
                require(uris.size <= 8) { NativeLanguage.text(this, R.string.native_7) }
                require(clipUris.all { it in uris }) { NativeLanguage.text(this, R.string.native_12) }
                readTextFiles(uris, subject, texts, incoming.type!!)
            } else {
                require(!incoming.hasExtra(Intent.EXTRA_STREAM)) { NativeLanguage.text(this, R.string.native_13) }
                enqueue(texts)
            }
        } catch (error: Exception) {
            showShareError(error)
        } finally {
            // The durable inbox owns accepted content, not the Activity intent.
            setIntent(Intent(this, MainActivity::class.java).setAction(Intent.ACTION_MAIN))
        }
    }

    private fun readTextFiles(uris: List<Uri>, subject: String, captions: List<TextInput>, declaredType: String) {
        check(activeReaders.incrementAndGet() <= 2) {
            activeReaders.decrementAndGet()
            NativeLanguage.text(this, R.string.native_14)
        }
        val completed = AtomicBoolean(false)
        val timeout = AtomicReference<ScheduledFuture<*>?>()
        readers.execute {
            val staged = mutableListOf<String>()
            try {
                val inputs = uris.map { uri ->
                    check(!completed.get()) { NativeLanguage.text(this, R.string.native_15) }
                    require(uri.scheme == "content" && !uri.authority.isNullOrEmpty()) {
                        NativeLanguage.text(this, R.string.native_16)
                    }
                    val provider = packageManager.resolveContentProvider(uri.authority!!, 0)
                    require(provider?.applicationInfo?.uid != applicationInfo.uid) {
                        NativeLanguage.text(this, R.string.native_17)
                    }
                    val mime = contentResolver.getType(uri) ?: declaredType
                    var name = subject
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (column >= 0) name = SharedTextDecoder.title(cursor.getString(column))
                        }
                    }
                    if (mime in textTypes) {
                        val text = contentResolver.openInputStream(uri)?.use { SharedTextDecoder.read(it) }
                            ?: error(NativeLanguage.text(this, R.string.native_18))
                        TextInput(name, text)
                    } else {
                        name = name.replace('\\', '/').substringAfterLast('/').ifBlank { "shared-file" }
                        name = name.replace(Regex("[\\x00-\\x1f\\x7f]"), "").ifBlank { "shared-file" }
                        name = name.substring(0, name.offsetByCodePoints(0, minOf(120, name.codePointCount(0, name.length))))
                        if (name == "." || name == "..") name = "shared-file"
                        val input = TextInput(name, NativeLanguage.text(this, R.string.native_shared_file, name), kind = if (mime in setOf("image/png", "image/jpeg")) "image" else "attachment")
                        val size = contentResolver.openInputStream(uri)?.use { resources().write(input.id, it) { completed.get() } }
                            ?: error(NativeLanguage.text(this, R.string.native_18))
                        staged.add(input.id)
                        input.copy(size = size)
                    }
                } + captions
                runOnUiThread {
                    if (completed.compareAndSet(false, true)) {
                        timeout.get()?.cancel(false)
                        try {
                            enqueue(inputs)
                            staged.forEach { resources().release(it) }
                        } catch (error: Exception) {
                            // SharedPreferences can update memory before a disk
                            // commit reports failure. Keep any referenced bytes.
                            staged.forEach { resources().release(it) }
                            runCatching { pruneResources(JSONArray(prefs.getString("queue", "[]"))) }
                            showShareError(error)
                        }
                    } else {
                        staged.forEach { runCatching { resources().delete(it) } }
                    }
                }
            } catch (error: Exception) {
                staged.forEach { runCatching { resources().delete(it) } }
                runOnUiThread {
                    if (completed.compareAndSet(false, true)) {
                        timeout.get()?.cancel(false)
                        showShareError(error)
                    }
                }
            } finally {
                activeReaders.decrementAndGet()
            }
        }
        timeout.set(timeouts.schedule({
            if (completed.compareAndSet(false, true)) {
                runOnUiThread { showShareError(IllegalStateException(NativeLanguage.text(this, R.string.native_19))) }
            }
        }, 15, TimeUnit.SECONDS))
        if (completed.get()) timeout.get()?.cancel(false)
        // A provider may ignore cancellation. Keep its worker slot occupied
        // until I/O returns; timed-out results can never enter the inbox.
    }

    // Queue mutation and Flutter callbacks run on the main thread, including
    // file batches. Read the latest queue after I/O to preserve concurrent claims.
    private fun enqueue(inputs: List<TextInput>) {
        val queue = JSONArray(prefs.getString("queue", "[]"))
        pruneResources(queue)
        check(queue.length() + inputs.size <= 8) { NativeLanguage.text(this, R.string.native_20) }
        for (input in inputs) {
            queue.put(JSONObject().put("id", input.id)
                .put("title", input.title).put("text", input.text)
                .put("resourceKind", input.kind).put("resourceName", if (input.kind.isEmpty()) "" else input.title)
                .put("resourceSize", input.size))
        }
        check(prefs.edit().putString("queue", queue.toString()).commit()) { NativeLanguage.text(this, R.string.native_21) }
        // Persistence already succeeded. A detached engine or toast failure
        // must not cause callers to delete the newly committed originals.
        runCatching { activeActivity.get()?.shareChannel?.invokeMethod("changed", null) }
        runCatching { Toast.makeText(applicationContext, NativeLanguage.text(this, R.string.native_share_received, inputs.size), Toast.LENGTH_LONG).show() }
    }

    private fun showShareError(error: Exception) {
        Toast.makeText(applicationContext, NativeLanguage.errorMessage(this, error) ?: NativeLanguage.text(this, R.string.native_22), Toast.LENGTH_LONG).show()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        cameraChannel?.setMethodCallHandler(null)
        cameraChannel = null
        widgetChannel?.setMethodCallHandler(null)
        widgetChannel = null
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        if (activeActivity.get() === this) activeActivity.clear()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
