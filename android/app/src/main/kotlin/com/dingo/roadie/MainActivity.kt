package com.dingo.roadie

import android.Manifest
import android.content.ContentUris
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.util.Date
import java.util.concurrent.Executors

/**
 * The library comes from Android's own media index (fast, no tag parsing of
 * our own). Covers are cut to size once and kept in the cache folder.
 * AudioServiceActivity keeps the player's media session tied to this screen.
 */
class MainActivity : AudioServiceActivity() {
    private val io = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingRecord: MethodChannel.Result? = null
    private var pendingStorage: MethodChannel.Result? = null
    private val viz = VizStream()

    /** Native crashes go to a file the app shows under Settings > Problem reports. */
    private fun catchCrashes() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        val file = File(filesDir, "native_crash.txt")
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            try {
                val sw = StringWriter()
                e.printStackTrace(PrintWriter(sw))
                file.appendText("=== ${Date()} (thread ${thread.name}, Android ${Build.VERSION.SDK_INT}, ${Build.MANUFACTURER} ${Build.MODEL})\n$sw\n")
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(thread, e)
        }
    }

    private fun canWrite(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    private fun canRecord() = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** Internal storage first, then SD cards / USB sticks. */
    private fun roots(): List<String> {
        val out = mutableListOf(Environment.getExternalStorageDirectory().path)
        for (d in getExternalFilesDirs(null)) {
            val p = d?.path ?: continue
            val i = p.indexOf("/Android/")
            if (i > 0) p.substring(0, i).let { if (it !in out) out += it }
        }
        return out
    }

    private val permission: String
        get() = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO
        else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun granted() = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        catchCrashes()
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "roadie/visualizer").setStreamHandler(viz)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "roadie/library").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(granted())
                "requestPermission" ->
                    if (granted()) result.success(true)
                    else {
                        pending?.success(false)
                        pending = result
                        requestPermissions(arrayOf(permission), 7)
                    }
                "songs" -> background(result) { songs() }
                "art" -> {
                    val id = (call.argument<Number>("albumId") ?: -1).toLong()
                    val size = (call.argument<Number>("size") ?: 400).toInt()
                    background(result) { art(id, size) }
                }
                "scan" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    MediaScannerConnection.scanFile(this, paths.toTypedArray(), null, null)
                    result.success(null)
                }
                "filesDir" -> result.success(filesDir.path)
                "musicDir" -> result.success(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC).path,
                )
                "roots" -> result.success(roots())
                "listDirs" -> {
                    val path = call.argument<String>("path") ?: ""
                    background(result) {
                        File(path).listFiles()?.filter { it.isDirectory && !it.name.startsWith(".") }
                            ?.map { it.name }?.sortedBy { it.lowercase() } ?: emptyList<String>()
                    }
                }
                "canWrite" -> result.success(canWrite())
                "requestWrite" ->
                    if (canWrite()) result.success(true)
                    else if (Build.VERSION.SDK_INT >= 30) {
                        pendingStorage?.success(false)
                        pendingStorage = result
                        try {
                            startActivity(
                                Intent(
                                    android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                    Uri.parse("package:$packageName"),
                                ),
                            )
                        } catch (_: Exception) {
                            startActivity(Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                        }
                    } else {
                        pendingStorage?.success(false)
                        pendingStorage = result
                        requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 9)
                    }
                "canRecord" -> result.success(canRecord())
                "requestRecord" ->
                    if (canRecord()) result.success(true)
                    else {
                        pendingRecord?.success(false)
                        pendingRecord = result
                        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 8)
                    }
                "readTags" -> {
                    val path = call.argument<String>("path") ?: ""
                    background(result) { Tags.read(path) }
                }
                "writeTags" -> {
                    val path = call.argument<String>("path") ?: ""
                    val values = call.argument<Map<String, Any?>>("values") ?: emptyMap()
                    val cover = call.argument<String>("cover")
                    background(result) {
                        Tags.write(path, values, cover)
                        true
                    }
                }
                "downloading" -> {
                    val active = call.argument<Number>("active")?.toInt() ?: 0
                    val done = call.argument<Number>("done")?.toInt() ?: 0
                    try {
                        DownloadService.update(this, active, done)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("downloads", e.message ?: e.toString(), null)
                    }
                }
                "fileInfo" -> {
                    val path = call.argument<String>("path") ?: ""
                    val id = (call.argument<Number>("id") ?: -1).toLong()
                    background(result) { fileInfo(path, id) }
                }
                "nativeCrashes" -> {
                    val f = File(filesDir, "native_crash.txt")
                    val text = if (f.exists()) f.readText() else ""
                    if (call.argument<Boolean>("clear") == true) f.delete()
                    result.success(text)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        val ok = results.firstOrNull() == PackageManager.PERMISSION_GRANTED
        when (code) {
            7 -> { pending?.success(ok); pending = null }
            8 -> { pendingRecord?.success(ok); pendingRecord = null }
            9 -> { pendingStorage?.success(ok); pendingStorage = null }
        }
    }

    override fun onResume() {
        super.onResume()
        // Back from the "All files access" settings page.
        if (Build.VERSION.SDK_INT >= 30) pendingStorage?.let { it.success(canWrite()); pendingStorage = null }
    }

    override fun onDestroy() {
        viz.stop()
        super.onDestroy()
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("library", e.message ?: e.toString(), e.stackTraceToString().take(4000)) }
            }
        }
    }

    private fun songs(): List<Map<String, Any?>> {
        val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val genres = if (Build.VERSION.SDK_INT >= 30) emptyMap() else genresByAudioId()
        val base = mutableListOf(
            MediaStore.Audio.Media._ID, MediaStore.Audio.Media.TITLE, MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM, MediaStore.Audio.Media.ALBUM_ID, MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.TRACK, MediaStore.Audio.Media.YEAR, MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.DATE_MODIFIED, MediaStore.Audio.Media.SIZE, MediaStore.Audio.Media.DATA,
            "album_artist", MediaStore.Audio.Media.IS_PODCAST,
        )
        if (Build.VERSION.SDK_INT >= 30) base += listOf("genre", "disc_number")
        val out = ArrayList<Map<String, Any?>>()
        // Music and podcasts (episodes in Podcasts/ folders aren't "music" to Android).
        val where = "${MediaStore.Audio.Media.IS_MUSIC} != 0 OR ${MediaStore.Audio.Media.IS_PODCAST} != 0"
        contentResolver.query(uri, base.toTypedArray(), where, null, null)?.use { c ->
            fun str(name: String): String? = c.getColumnIndex(name).let { if (it < 0) null else c.getString(it) }
            fun num(name: String): Long = c.getColumnIndex(name).let { if (it < 0 || c.isNull(it)) 0L else c.getLong(it) }
            while (c.moveToNext()) {
                val id = num(MediaStore.Audio.Media._ID)
                out += mapOf(
                    "id" to id,
                    "uri" to ContentUris.withAppendedId(uri, id).toString(),
                    "path" to str(MediaStore.Audio.Media.DATA),
                    "title" to str(MediaStore.Audio.Media.TITLE),
                    "artist" to str(MediaStore.Audio.Media.ARTIST),
                    "album" to str(MediaStore.Audio.Media.ALBUM),
                    "albumArtist" to str("album_artist"),
                    "albumId" to num(MediaStore.Audio.Media.ALBUM_ID),
                    "genre" to (str("genre") ?: genres[id]),
                    "year" to num(MediaStore.Audio.Media.YEAR),
                    "track" to num(MediaStore.Audio.Media.TRACK),
                    "disc" to (str("disc_number")?.substringBefore('/')?.trim()?.toIntOrNull() ?: 0),
                    "duration" to num(MediaStore.Audio.Media.DURATION),
                    "added" to num(MediaStore.Audio.Media.DATE_ADDED),
                    "modified" to num(MediaStore.Audio.Media.DATE_MODIFIED),
                    "size" to num(MediaStore.Audio.Media.SIZE),
                    "podcast" to num(MediaStore.Audio.Media.IS_PODCAST),
                )
            }
        }
        return out
    }

    /** The file on disk, its storage, Android's media index row and the tags inside. */
    private fun fileInfo(path: String, id: Long): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        val f = File(path)
        out["exists"] = f.exists()
        out["bytes"] = f.length()
        out["modified"] = f.lastModified()
        out["canRead"] = f.canRead()
        out["canWrite"] = f.canWrite()
        val root = roots().firstOrNull { path.startsWith("$it/") }
        out["root"] = root
        out["removable"] = root != null && root != Environment.getExternalStorageDirectory().path
        if (root != null) {
            try {
                val st = android.os.StatFs(root)
                out["volumeFree"] = st.availableBytes
                out["volumeTotal"] = st.totalBytes
            } catch (_: Exception) {
            }
        }
        if (id >= 0) {
            val row = LinkedHashMap<String, String>()
            try {
                contentResolver.query(
                    ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id), null, null, null, null,
                )?.use { c ->
                    if (c.moveToFirst()) {
                        for (i in 0 until c.columnCount) {
                            if (c.getType(i) == android.database.Cursor.FIELD_TYPE_BLOB || c.isNull(i)) continue
                            val v = c.getString(i) ?: continue
                            if (v.isNotBlank()) row[c.getColumnName(i)] = v
                        }
                    }
                }
            } catch (_: Exception) {
            }
            out["mediaStore"] = row
        }
        try {
            out["tags"] = Tags.details(path)
        } catch (e: Throwable) {
            out["tagsError"] = e.message ?: e.toString()
        }
        return out
    }

    /** Android 10 and older keep genres in their own table. */
    private fun genresByAudioId(): Map<Long, String> {
        val map = HashMap<Long, String>()
        try {
            contentResolver.query(
                MediaStore.Audio.Genres.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Audio.Genres._ID, MediaStore.Audio.Genres.NAME), null, null, null,
            )?.use { g ->
                while (g.moveToNext()) {
                    val gid = g.getLong(0)
                    val name = g.getString(1) ?: continue
                    contentResolver.query(
                        MediaStore.Audio.Genres.Members.getContentUri("external", gid),
                        arrayOf(MediaStore.Audio.Genres.Members.AUDIO_ID), null, null, null,
                    )?.use { m -> while (m.moveToNext()) map[m.getLong(0)] = name }
                }
            }
        } catch (_: Exception) {
        }
        return map
    }

    private fun art(albumId: Long, size: Int): String? {
        if (albumId < 0) return null
        val dir = File(cacheDir, "art").apply { mkdirs() }
        val file = File(dir, "${albumId}_$size.jpg")
        val none = File(dir, "${albumId}_$size.none")
        if (file.exists()) return file.path
        if (none.exists()) return null
        val bmp: Bitmap? = try {
            if (Build.VERSION.SDK_INT >= 29) {
                val uri = ContentUris.withAppendedId(MediaStore.Audio.Albums.EXTERNAL_CONTENT_URI, albumId)
                contentResolver.loadThumbnail(uri, Size(size, size), null)
            } else {
                @Suppress("DEPRECATION")
                contentResolver.query(
                    MediaStore.Audio.Albums.EXTERNAL_CONTENT_URI, arrayOf(MediaStore.Audio.Albums.ALBUM_ART),
                    "${MediaStore.Audio.Albums._ID} = ?", arrayOf("$albumId"), null,
                )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
                    ?.let { BitmapFactory.decodeFile(it) }
                    ?.let { Bitmap.createScaledBitmap(it, size, size * it.height / maxOf(1, it.width), true) }
            }
        } catch (_: Exception) {
            null
        }
        if (bmp == null) {
            none.createNewFile()
            return null
        }
        FileOutputStream(file).use { bmp.compress(Bitmap.CompressFormat.JPEG, 88, it) }
        return file.path
    }
}
