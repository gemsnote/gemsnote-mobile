package com.github.gemsnote

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Only bounded titles and IDs are persisted. No bodies, credentials or network. */
object NoteWidgetStore {
    const val ACTION = "com.github.gemsnote.WIDGET_OPEN"
    fun prefs(context: Context) = context.getSharedPreferences("note_widget", Context.MODE_PRIVATE)
    @Synchronized fun activate(context: Context, account: String): Map<String, Any> {
        val p = prefs(context)
        val epoch = UUID.randomUUID().toString()
        val enabled = account.isNotEmpty() && p.getBoolean("enabled:$account", false)
        val edit = p.edit().putString("account", account).putString("epoch", epoch).putString("notes", "[]")
        if (p.getString("account", "") != account) edit.remove("pending")
        check(edit.commit()) { "Cannot save widget account" }
        NoteWidget.updateAll(context)
        return mapOf("epoch" to epoch, "enabled" to enabled)
    }
    @Synchronized fun publish(context: Context, account: String, epoch: String, values: List<*>) {
        val p = prefs(context)
        check(p.getString("account", "") == account && p.getString("epoch", "") == epoch) { "Stale widget account" }
        require(account.isNotEmpty() && values.size <= 30)
        val notes = JSONArray()
        if (p.getBoolean("enabled:$account", false)) for (value in values) {
            val map = value as Map<*, *>
            val id = map["id"] as String
            val title = map["title"] as String
            require(id.matches(Regex("[a-fA-F0-9]{24}")) && title.length <= 320 && !title.any { it.code < 32 || it.code == 127 })
            notes.put(JSONObject().put("id", id).put("title", title))
        }
        check(p.edit().putString("notes", notes.toString()).commit()) { "Cannot save widget notes" }
        NoteWidget.updateAll(context)
    }
    @Synchronized fun setEnabled(context: Context, account: String, epoch: String, enabled: Boolean) {
        val p = prefs(context)
        check(account.isNotEmpty() && p.getString("account", "") == account && p.getString("epoch", "") == epoch)
        val edit = p.edit().putBoolean("enabled:$account", enabled)
        if (!enabled) edit.putString("notes", "[]")
        check(edit.commit()) { "Cannot save widget setting" }
        NoteWidget.updateAll(context)
    }
    @Synchronized fun receive(context: Context, incoming: Intent?): Boolean {
        if (incoming?.action != ACTION) return false
        val p = prefs(context)
        val account = incoming.getStringExtra("account") ?: return false
        val epoch = incoming.getStringExtra("epoch") ?: return false
        if (p.getString("account", "") != account || p.getString("epoch", "") != epoch) return false
        val action = incoming.getStringExtra("widgetAction") ?: return false
        val id = incoming.getStringExtra("noteId") ?: ""
        if (action !in setOf("open", "create", "home")) return false
        if (action == "open") {
            if (!p.getBoolean("enabled:$account", false)) return false
            val notes = JSONArray(p.getString("notes", "[]"))
            if ((0 until notes.length()).none { notes.getJSONObject(it).getString("id") == id }) return false
        }
        val pending = JSONObject().put("id", UUID.randomUUID().toString()).put("account", account)
            .put("action", action).put("noteId", id)
        check(p.edit().putString("pending", pending.toString()).commit())
        return true
    }
    @Synchronized fun pending(context: Context): Map<String, String>? {
        val raw = prefs(context).getString("pending", null) ?: return null
        val item = JSONObject(raw)
        return listOf("id", "account", "action", "noteId").associateWith { item.getString(it) }
    }
    @Synchronized fun acknowledge(context: Context, id: String) {
        if (pending(context)?.get("id") == id) check(prefs(context).edit().remove("pending").commit())
    }
}

class NoteWidget : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == Intent.ACTION_LOCALE_CHANGED) updateAll(context)
    }
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { updateAll(context) }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: android.os.Bundle) { updateAll(context) }
    companion object {
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, NoteWidget::class.java))
            val p = NoteWidgetStore.prefs(context)
            val account = p.getString("account", "") ?: ""
            val epoch = p.getString("epoch", "") ?: ""
            val enabled = account.isNotEmpty() && p.getBoolean("enabled:$account", false)
            for (id in ids) {
                fun launch(action: String, mutable: Boolean = false): PendingIntent {
                    val intent = Intent(context, LaunchActivity::class.java).apply {
                        this.action = NoteWidgetStore.ACTION
                        data = Uri.Builder().scheme("gemsnote-widget").authority("action").appendPath("$id").appendPath(epoch).appendPath(action).build()
                        putExtra("account", account); putExtra("epoch", epoch); putExtra("widgetAction", action)
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    }
                    val mutability = if (mutable) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE
                    return PendingIntent.getActivity(context, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or mutability)
                }
                val views = RemoteViews(context.packageName, R.layout.note_widget)
                views.setTextViewText(R.id.widget_title, NativeLanguage.text(context, R.string.app_name))
                views.setContentDescription(R.id.widget_create, NativeLanguage.text(context, R.string.widget_create))
                views.setOnClickPendingIntent(R.id.widget_title, launch("home"))
                views.setOnClickPendingIntent(R.id.widget_create, launch("create"))
                views.setOnClickPendingIntent(R.id.widget_empty, launch("home"))
                views.setTextViewText(R.id.widget_empty, NativeLanguage.text(context, if (account.isEmpty()) R.string.widget_sign_in else if (!enabled) R.string.widget_private else R.string.widget_empty))
                views.setViewVisibility(R.id.widget_list, if (enabled) View.VISIBLE else View.GONE)
                views.setViewVisibility(R.id.widget_empty, if (enabled) View.GONE else View.VISIBLE)
                // Epoch changes detach the old adapter immediately on account changes.
                val service = Intent(context, NoteWidgetService::class.java).apply {
                    putExtra("account", account); putExtra("epoch", epoch)
                    data = Uri.Builder().scheme("gemsnote-widget").authority("list").appendPath("$id").appendPath(epoch).build()
                }
                views.setRemoteAdapter(R.id.widget_list, service)
                views.setEmptyView(R.id.widget_list, R.id.widget_empty)
                views.setPendingIntentTemplate(R.id.widget_list, launch("open", true))
                manager.updateAppWidget(id, views)
                @Suppress("DEPRECATION")
                manager.notifyAppWidgetViewDataChanged(id, R.id.widget_list)
            }
        }
    }
}

class NoteWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = Factory(applicationContext, intent)
    private class Factory(val context: Context, intent: Intent) : RemoteViewsFactory {
        val account = intent.getStringExtra("account") ?: ""
        val epoch = intent.getStringExtra("epoch") ?: ""
        var notes = JSONArray()
        fun valid(): Boolean {
            val p = NoteWidgetStore.prefs(context)
            return account.isNotEmpty() && p.getString("account", "") == account &&
                p.getString("epoch", "") == epoch && p.getBoolean("enabled:$account", false)
        }
        override fun onCreate() { onDataSetChanged() }
        override fun onDataSetChanged() {
            notes = try { if (valid()) JSONArray(NoteWidgetStore.prefs(context).getString("notes", "[]")) else JSONArray() } catch (_: Exception) { JSONArray() }
        }
        override fun onDestroy() { notes = JSONArray() }
        override fun getCount() = if (valid()) notes.length() else 0
        override fun getViewAt(position: Int): RemoteViews {
            val row = RemoteViews(context.packageName, R.layout.note_widget_row)
            if (!valid() || position !in 0 until notes.length()) return row
            val note = notes.getJSONObject(position)
            row.setTextViewText(R.id.widget_row, note.getString("title").ifBlank { NativeLanguage.text(context, R.string.widget_untitled) })
            row.setOnClickFillInIntent(R.id.widget_row, Intent().putExtra("noteId", note.getString("id")))
            return row
        }
        override fun getLoadingView(): RemoteViews? = null
        override fun getViewTypeCount() = 1
        override fun getItemId(position: Int) = position.toLong()
        override fun hasStableIds() = false
    }
}
