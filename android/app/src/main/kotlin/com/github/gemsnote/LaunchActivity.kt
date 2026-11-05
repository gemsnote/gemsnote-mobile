package com.github.gemsnote

import android.app.Activity
import android.content.Intent
import android.graphics.drawable.Animatable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.view.ViewTreeObserver
import android.widget.ImageView
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterShellArgs
import java.lang.ref.WeakReference

/** Draw a native frame before Flutter's library/asset initialization can block. */
class LaunchActivity : Activity() {
    companion object {
        private val pending = mutableListOf<WeakReference<LaunchActivity>>()
        fun finishPending() {
            val windows = pending.mapNotNull { it.get() }
            pending.clear()
            windows.forEach { it.finish() }
        }
    }
    private var forwarded = false
    private var resumed = false
    private var engineReady = false
    private var spinner: Animatable? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pending.add(WeakReference(this))
        val loader = FlutterInjector.instance().flutterLoader()
        // A background worker can initialize the loader without a foreground UI.
        if (loader.initialized() && MainActivity.hasRunningFlutterUi()) {
            engineReady = true
            return
        }
        val content = LayoutInflater.from(NativeLanguage.localized(this))
            .inflate(R.layout.startup_loading, null)
        setContentView(content)
        spinner = content.findViewById<ImageView>(R.id.startup_spinner).drawable as Animatable
        spinner?.start()
        content.viewTreeObserver.addOnDrawListener(object : ViewTreeObserver.OnDrawListener {
            private var scheduled = false
            override fun onDraw() {
                if (scheduled) return
                scheduled = true
                // Posting from onDraw lets this frame reach the renderer first.
                content.post {
                    if (content.viewTreeObserver.isAlive) content.viewTreeObserver.removeOnDrawListener(this)
                    if (isFinishing || isDestroyed) return@post
                    loader.startInitialization(applicationContext)
                    loader.ensureInitializationCompleteAsync(
                        applicationContext, FlutterShellArgs.fromIntent(intent).toArray(),
                        Handler(Looper.getMainLooper())) {
                            engineReady = true
                            openFlutter()
                        }
                }
            }
        })
    }

    private fun openFlutter() {
        if (!resumed || !engineReady || forwarded || isFinishing || isDestroyed) return
        forwarded = true
        // Copy data, MIME type, ClipData, extras and URI grants for shares/deep links/widgets.
        startActivity(Intent(intent).setClass(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        // Keep this window until Flutter actually draws. Finishing here exposes
        // a black window while MainActivity registers plugins and creates its surface.
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        if (forwarded) finish() else openFlutter()
    }

    override fun onPause() {
        resumed = false
        super.onPause()
    }

    override fun onDestroy() {
        pending.removeAll { it.get() == null || it.get() === this }
        spinner?.stop()
        spinner = null
        super.onDestroy()
    }
}
