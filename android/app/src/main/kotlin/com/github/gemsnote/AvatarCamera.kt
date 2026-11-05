package com.github.gemsnote

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.UUID

/** External camera gets access to one private staging file, never the gallery. */
class AvatarCamera(private val activity: Activity) {
    companion object {
        const val REQUEST = 4931
        private val worker = Executors.newSingleThreadExecutor()
        private val activeFiles = ConcurrentHashMap.newKeySet<String>()
    }
    private var pending: MethodChannel.Result? = null
    private val output = File(activity.cacheDir, "avatar-camera/capture_${UUID.randomUUID()}.jpg")
    fun clearAbandonedCapture() {
        output.parentFile?.listFiles()?.filter { it.name.startsWith("capture_") && it.path !in activeFiles }?.forEach { it.delete() }
    }
    fun capture(result: MethodChannel.Result) {
        if (pending != null) { result.error("cameraBusy", NativeLanguage.text(activity, R.string.native_23), null); return }
        pending = result
        try {
            val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
            check(intent.resolveActivity(activity.packageManager) != null) { NativeLanguage.text(activity, R.string.native_24) }
            output.parentFile!!.mkdirs()
            output.delete()
            activeFiles.add(output.path)
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.avatar_camera", output)
            intent.putExtra(MediaStore.EXTRA_OUTPUT, uri)
            intent.clipData = ClipData.newRawUri("Avatar", uri)
            intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            activity.startActivityForResult(intent, REQUEST)
        } catch (error: Exception) { finish(null, error) }
    }
    fun result(request: Int, code: Int): Boolean {
        if (request != REQUEST) return false
        if (pending == null || code != Activity.RESULT_OK) { finish(null, null); return true }
        worker.execute {
            var bitmap: Bitmap? = null
            var rotated: Bitmap? = null
            try {
                val file = output
                require(file.length() in 1..(16L * 1024 * 1024)) { NativeLanguage.text(activity, R.string.native_25) }
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(file.path, bounds)
                require(bounds.outWidth in 1..8192 && bounds.outHeight in 1..8192) { NativeLanguage.text(activity, R.string.native_26) }
                var sample = 1
                while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 1024) sample *= 2
                bitmap = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: error(NativeLanguage.text(activity, R.string.native_27))
                val matrix = Matrix()
                when (ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
                    ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
                    ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.setRotate(270f); matrix.postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(270f)
                }
                rotated = Bitmap.createBitmap(bitmap!!, 0, 0, bitmap!!.width, bitmap!!.height, matrix, true)
                val bytes = ByteArrayOutputStream().use { stream ->
                    check(rotated!!.compress(Bitmap.CompressFormat.JPEG, 90, stream))
                    stream.toByteArray().also { require(it.size <= 2 * 1024 * 1024) }
                }
                activity.runOnUiThread { finish(bytes, null) }
            } catch (error: Exception) { activity.runOnUiThread { finish(null, error) } }
            finally { if (rotated !== bitmap) rotated?.recycle(); bitmap?.recycle() }
        }
        return true
    }
    private fun finish(bytes: ByteArray?, error: Exception?) {
        val result = pending
        pending = null
        try {
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.avatar_camera", output)
            activity.revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        } catch (_: Exception) { }
        output.delete()
        activeFiles.remove(output.path)
        if (error == null) result?.success(bytes) else result?.error("avatarCamera", NativeLanguage.errorMessage(activity, error), null)
    }
}
