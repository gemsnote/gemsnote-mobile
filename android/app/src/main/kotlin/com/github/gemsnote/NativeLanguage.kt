package com.github.gemsnote

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/** Mirrors the app preference for native entry points without restarting editors. */
object NativeLanguage {
    private fun prefs(context: Context) = context.getSharedPreferences("app_language", Context.MODE_PRIVATE)
    fun set(context: Context, value: String) {
        require(value in setOf("system", "zh", "en"))
        check(prefs(context).edit().putString("language", value).commit()) { "Cannot save native language" }
        NoteWidget.updateAll(context)
    }
    fun localized(context: Context): Context {
        val value = prefs(context).getString("language", "system")
        val configuration = Configuration(context.resources.configuration)
        val language = if (value == "zh" || value == "en") value
            else if (configuration.locales[0].language == "zh") "zh" else "en"
        configuration.setLocale(Locale.forLanguageTag(language))
        return context.createConfigurationContext(configuration)
    }
    fun text(context: Context, id: Int, vararg args: Any): String = localized(context).getString(id, *args)
    fun errorMessage(context: Context, error: Throwable): String? = when (error.message) {
        "读取分享已取消" -> text(context, R.string.native_storage_0)
        "分享文本超过 256 KiB" -> text(context, R.string.native_storage_1)
        "分享内容必须为非空文本" -> text(context, R.string.native_storage_2)
        "无法创建分享暂存目录" -> text(context, R.string.native_storage_3)
        "无效的分享 ID" -> text(context, R.string.native_storage_4)
        "分享 ID 重复" -> text(context, R.string.native_storage_5)
        "分享读取已取消" -> text(context, R.string.native_storage_6)
        "分享附件不能超过 32 MiB" -> text(context, R.string.native_storage_7)
        "无法读取分享暂存目录" -> text(context, R.string.native_storage_8)
        "分享暂存空间已满，请先处理待导入分享" -> text(context, R.string.native_storage_9)
        "分享文件为空或读取已取消" -> text(context, R.string.native_storage_10)
        "无法移除分享暂存文件" -> text(context, R.string.native_storage_11)
        "分享文件大小无效" -> text(context, R.string.native_storage_12)
        "分享文件不完整，请重新分享" -> text(context, R.string.native_storage_13)
        "分享文件不完整" -> text(context, R.string.native_storage_14)
        "分享文件已变化" -> text(context, R.string.native_storage_15)
        else -> error.message
    }
}
