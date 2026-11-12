package com.dingo.roadie

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * yt-dlp (the same downloader Seal and YTDLnis use), bundled with Python and
 * ffmpeg by youtubedl-android. yt-dlp itself updates from its GitHub releases
 * at runtime, so a site change is fixed by an update, not a new app.
 */
object Ytdlp {
    private val pool = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var ready = false
    private var progress: EventChannel.EventSink? = null

    val progressHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) { progress = events }
        override fun onCancel(arguments: Any?) { progress = null }
    }

    @Synchronized
    fun init(context: Context) {
        if (ready) return
        YoutubeDL.getInstance().init(context.applicationContext)
        FFmpeg.getInstance().init(context.applicationContext)
        ready = true
    }

    private fun channel(name: String?) = when (name) {
        "nightly" -> YoutubeDL.UpdateChannel._NIGHTLY
        else -> YoutubeDL.UpdateChannel._STABLE
    }

    /** "DONE" / "ALREADY_UP_TO_DATE". */
    fun update(context: Context, channelName: String?): String {
        init(context)
        return YoutubeDL.getInstance().updateYoutubeDL(context.applicationContext, channel(channelName))?.name ?: "UNKNOWN"
    }

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        fun bg(work: () -> Any?) = pool.execute {
            try {
                init(context)
                val v = work()
                main.post { result.success(v) }
            } catch (e: YoutubeDL.CanceledException) {
                main.post { result.error("cancelled", "Cancelled", null) }
            } catch (e: Throwable) {
                main.post { result.error("ytdlp", e.message ?: e.toString(), e.stackTraceToString().take(3000)) }
            }
        }
        when (call.method) {
            "version" -> bg {
                mapOf(
                    "version" to YoutubeDL.getInstance().version(context.applicationContext),
                    "name" to YoutubeDL.getInstance().versionName(context.applicationContext),
                )
            }
            "update" -> bg { update(context, call.argument<String>("channel")) }
            // Runs yt-dlp with [args] (and [url] last); returns its output.
            "run" -> bg {
                val args = call.argument<List<String>>("args") ?: emptyList()
                val url = call.argument<String>("url") ?: ""
                val req = YoutubeDLRequest(url)
                req.addCommands(args)
                val id = call.argument<String>("id")
                val r = if (id == null) YoutubeDL.getInstance().execute(req) else YoutubeDL.getInstance().execute(req, id)
                mapOf("exit" to r.exitCode, "out" to r.out, "err" to r.err)
            }
            // Same, with progress events {id, progress (0..100), eta, line}.
            "download" -> {
                val id = call.argument<String>("id") ?: "dl"
                bg {
                    val req = YoutubeDLRequest(call.argument<String>("url") ?: "")
                    req.addCommands(call.argument<List<String>>("args") ?: emptyList())
                    var last = 0L
                    val r = YoutubeDL.getInstance().execute(req, id) { p, eta, line ->
                        val now = System.currentTimeMillis()
                        if (now - last > 300) {
                            last = now
                            main.post { progress?.success(mapOf("id" to id, "progress" to p.toDouble(), "eta" to eta, "line" to line)) }
                        }
                    }
                    mapOf("exit" to r.exitCode, "out" to r.out, "err" to r.err)
                }
            }
            "cancel" -> result.success(YoutubeDL.getInstance().destroyProcessById(call.argument<String>("id") ?: ""))
            // Background update check (daily, on any network); off when disabled.
            "schedule" -> {
                val wm = WorkManager.getInstance(context.applicationContext)
                if (call.argument<Boolean>("enabled") == true) {
                    val req = PeriodicWorkRequestBuilder<UpdateWorker>(1, TimeUnit.DAYS)
                        .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                        .addTag(call.argument<String>("channel") ?: "stable")
                        .build()
                    wm.enqueueUniquePeriodicWork("ytdlp-update", ExistingPeriodicWorkPolicy.UPDATE, req)
                } else {
                    wm.cancelUniqueWork("ytdlp-update")
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** The daily check: keeps yt-dlp current so SoundCloud keeps working. */
    class UpdateWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
        override fun doWork(): Result = try {
            val channel = if (tags.contains("nightly")) "nightly" else "stable"
            val status = update(applicationContext, channel)
            applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
                .putString("flutter.ytdlpLastCheck", "${System.currentTimeMillis()}|$status")
                .apply()
            Result.success()
        } catch (_: Throwable) {
            Result.retry()
        }
    }
}
