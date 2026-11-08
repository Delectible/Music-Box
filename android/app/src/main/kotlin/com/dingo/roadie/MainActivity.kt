package com.dingo.roadie

import android.Manifest
import android.content.ContentUris
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
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
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

    private val permission: String
        get() = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO
        else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun granted() = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code == 7) {
            pending?.success(results.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            pending = null
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("library", e.message, null) }
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
            "album_artist",
        )
        if (Build.VERSION.SDK_INT >= 30) base += listOf("genre", "disc_number")
        val out = ArrayList<Map<String, Any?>>()
        contentResolver.query(uri, base.toTypedArray(), "${MediaStore.Audio.Media.IS_MUSIC} != 0", null, null)?.use { c ->
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
                )
            }
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
