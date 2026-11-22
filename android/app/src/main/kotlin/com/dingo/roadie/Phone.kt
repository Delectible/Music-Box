package com.dingo.roadie

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.browse.MediaBrowser
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.view.KeyEvent
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/** Lets Roadie see other apps' media sessions (Android asks for "notification access"). */
class MediaListener : NotificationListenerService() {
    override fun onListenerConnected() {
        Phone.refresh()
    }
}

/**
 * What another app (above all the head unit's Bluetooth music app, which
 * relays the phone) is playing, and its controls. Several ways in, best
 * first, so whichever this head unit allows can be used:
 *  1. session: every app's media session (needs notification access): full info and control.
 *  2. browser: connecting to a Bluetooth app's media browser service: full, no permission.
 *  3. broadcast: track-change broadcasts some apps send: info only.
 *  4. keys: media buttons sent to whatever is playing: control only.
 *  5. open: just opening the head unit's own app.
 * Plus what Bluetooth itself reports (phone connected as an audio source).
 */
@SuppressLint("MissingPermission")
object Phone : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var ctx: Context
    private var sink: EventChannel.EventSink? = null
    private val controllers = mutableMapOf<String, Pair<MediaController, MediaController.Callback>>()
    private var sessionsListener: MediaSessionManager.OnActiveSessionsChangedListener? = null
    private var browser: MediaBrowser? = null
    private var browserApp: String? = null
    private var browserState = "off"
    private var receiver: BroadcastReceiver? = null
    private var lastBroadcast: Map<String, Any?>? = null
    private val bt = mutableMapOf<String, Any?>()
    private var proxies = mutableMapOf<Int, BluetoothProfile>()
    private val artCache = mutableMapOf<String, String?>()

    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        ctx = activity.applicationContext
        try {
            when (call.method) {
                "snapshot" -> { start(); result.success(snapshot()) }
                "openAccess" -> result.success(openAccess(activity))
                "control" -> result.success(control(call.argument<String>("app"), call.argument<String>("action")!!, call.argument<Number>("ms")?.toLong()))
                "key" -> result.success(key(call.argument<String>("action")!!))
                "browse" -> { connectBrowser(call.argument<String>("app"), call.argument<String>("service")); result.success(true) }
                "launch" -> result.success(launch(activity, call.argument<String>("app")!!))
                "apps" -> result.success(apps())
                "askBluetooth" -> {
                    val perm = "android.permission.BLUETOOTH_CONNECT"
                    val need = Build.VERSION.SDK_INT >= 31 &&
                        activity.checkSelfPermission(perm) != android.content.pm.PackageManager.PERMISSION_GRANTED
                    if (need) activity.requestPermissions(arrayOf(perm), 11)
                    // Look again once it's been answered.
                    main.postDelayed({ listenBluetooth(); push() }, if (need) 5000L else 0L)
                    result.success(!need)
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("phone", e.message ?: e.toString(), null)
        }
    }

    override fun onListen(args: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (::ctx.isInitialized) { start(); push() }
    }

    override fun onCancel(args: Any?) { sink = null }

    fun attach(c: Context) { ctx = c.applicationContext }

    private var started = false

    private fun start() {
        if (!started) {
            started = true
            listenBroadcasts()
            listenBluetooth()
        }
        refresh()
    }

    // ---- 1. Media sessions -------------------------------------------------

    fun hasAccess(): Boolean {
        if (!::ctx.isInitialized) return false
        val list = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners") ?: return false
        return list.split(':').any { it.startsWith(ctx.packageName + "/") }
    }

    fun refresh() {
        if (!::ctx.isInitialized) return
        main.post {
            if (hasAccess()) {
                try {
                    val msm = ctx.getSystemService(MediaSessionManager::class.java)
                    val comp = ComponentName(ctx, MediaListener::class.java)
                    if (sessionsListener == null) {
                        val l = MediaSessionManager.OnActiveSessionsChangedListener { list -> track(list ?: emptyList()) }
                        msm.addOnActiveSessionsChangedListener(l, comp, main)
                        sessionsListener = l
                    }
                    track(msm.getActiveSessions(comp))
                } catch (e: SecurityException) {
                    sessionsListener = null
                }
            }
            push()
        }
    }

    private fun track(list: List<MediaController>) {
        val keep = list.filter { it.packageName != ctx.packageName }.associateBy { it.packageName }
        for ((pkg, pair) in controllers.toMap()) {
            if (pkg !in keep && pkg != "browser:$browserApp") {
                pair.first.unregisterCallback(pair.second)
                controllers.remove(pkg)
            }
        }
        for ((pkg, c) in keep) if (pkg !in controllers) watch(pkg, c)
        push()
    }

    private fun watch(key: String, c: MediaController) {
        val cb = object : MediaController.Callback() {
            override fun onMetadataChanged(metadata: MediaMetadata?) = push()
            override fun onPlaybackStateChanged(state: PlaybackState?) = push()
            override fun onSessionDestroyed() {
                controllers.remove(key)
                push()
            }
        }
        c.registerCallback(cb, main)
        controllers[key] = c to cb
    }

    private fun label(pkg: String): String = try {
        val pm = ctx.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (e: Exception) { pkg }

    private fun describe(key: String, c: MediaController, via: String): Map<String, Any?> {
        val m = c.metadata
        val s = c.playbackState
        fun text(vararg keys: String): String? = keys.firstNotNullOfOrNull { k ->
            m?.getString(k)?.takeIf { it.isNotBlank() }
        }
        val title = text(MediaMetadata.METADATA_KEY_TITLE, MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
        val artist = text(MediaMetadata.METADATA_KEY_ARTIST, MediaMetadata.METADATA_KEY_ALBUM_ARTIST,
            MediaMetadata.METADATA_KEY_AUTHOR, MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE)
        val album = text(MediaMetadata.METADATA_KEY_ALBUM, MediaMetadata.METADATA_KEY_DISPLAY_DESCRIPTION)
        var pos = s?.position ?: 0L
        if (s != null && s.state == PlaybackState.STATE_PLAYING && s.lastPositionUpdateTime > 0) {
            pos += ((SystemClock.elapsedRealtime() - s.lastPositionUpdateTime) * s.playbackSpeed).toLong()
        }
        return mapOf(
            "key" to key,
            "app" to c.packageName,
            "label" to label(c.packageName),
            "via" to via,
            "title" to title,
            "artist" to artist,
            "album" to album,
            "duration" to (m?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L),
            "position" to pos.coerceAtLeast(0),
            "state" to (s?.state ?: 0),
            "playing" to (s?.state == PlaybackState.STATE_PLAYING || s?.state == PlaybackState.STATE_BUFFERING),
            "actions" to (s?.actions ?: 0L),
            "art" to art(c.packageName, m, title, artist, album),
        )
    }

    /** The session's picture saved as a file (once per track). */
    private fun art(pkg: String, m: MediaMetadata?, title: String?, artist: String?, album: String?): String? {
        if (m == null) return null
        val id = "$pkg|$title|$artist|$album".hashCode().toUInt().toString(16)
        artCache[id]?.let { return it }
        if (artCache.containsKey(id)) return null
        var bmp: Bitmap? = m.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: m.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: m.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
        if (bmp == null) {
            val uri = m.getString(MediaMetadata.METADATA_KEY_ALBUM_ART_URI)
                ?: m.getString(MediaMetadata.METADATA_KEY_ART_URI)
                ?: m.getString(MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI)
            if (uri != null) bmp = try {
                ctx.contentResolver.openInputStream(Uri.parse(uri))?.use { BitmapFactory.decodeStream(it) }
            } catch (e: Exception) { null }
        }
        val path = bmp?.let {
            try {
                val dir = File(ctx.cacheDir, "phone").apply { mkdirs() }
                dir.listFiles()?.sortedBy { f -> f.lastModified() }?.dropLast(20)?.forEach { f -> f.delete() }
                val f = File(dir, "$id.jpg")
                FileOutputStream(f).use { out -> it.compress(Bitmap.CompressFormat.JPEG, 92, out) }
                f.path
            } catch (e: Exception) { null }
        }
        // Remembered only once there is a picture, or the track has a title
        // (a picture often arrives a moment after the name).
        if (path != null) artCache[id] = path
        return path
    }

    fun openAccess(activity: Activity): Boolean {
        for (action in listOf(
            "android.settings.NOTIFICATION_LISTENER_DETAIL_SETTINGS",
            Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS,
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        )) {
            try {
                val i = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (action.endsWith("DETAIL_SETTINGS") && Build.VERSION.SDK_INT >= 30) {
                    i.putExtra("android.provider.extra.NOTIFICATION_LISTENER_COMPONENT_NAME",
                        ComponentName(ctx, MediaListener::class.java).flattenToString())
                } else if (action.endsWith("DETAIL_SETTINGS")) continue
                if (action == Settings.ACTION_APPLICATION_DETAILS_SETTINGS) i.data = Uri.parse("package:${ctx.packageName}")
                activity.startActivity(i)
                return action != Settings.ACTION_APPLICATION_DETAILS_SETTINGS
            } catch (e: Exception) { /* next */ }
        }
        return false
    }

    // ---- 2. Media browser --------------------------------------------------

    private fun browserServices(): List<Map<String, String>> {
        val pm = ctx.packageManager
        return pm.queryIntentServices(Intent("android.media.browse.MediaBrowserService"), 0)
            .map { it.serviceInfo }
            .filter { it.packageName != ctx.packageName }
            .map { mapOf("app" to it.packageName, "service" to it.name, "label" to label(it.packageName)) }
    }

    private fun connectBrowser(app: String?, service: String?) {
        main.post {
            browser?.disconnect()
            browser = null
            controllers.remove("browser:$browserApp")?.let { it.first.unregisterCallback(it.second) }
            if (app == null || service == null) { browserApp = null; browserState = "off"; push(); return@post }
            browserApp = app
            browserState = "connecting"
            push()
            var b: MediaBrowser? = null
            b = MediaBrowser(ctx, ComponentName(app, service), object : MediaBrowser.ConnectionCallback() {
                override fun onConnected() {
                    try {
                        val c = MediaController(ctx, b!!.sessionToken)
                        watch("browser:$app", c)
                        browserState = "connected"
                    } catch (e: Exception) { browserState = "failed: ${e.message}" }
                    push()
                }
                override fun onConnectionFailed() { browserState = "refused"; push() }
                override fun onConnectionSuspended() { browserState = "lost"; push() }
            }, null)
            browser = b
            try { b?.connect() } catch (e: Exception) { browserState = "failed: ${e.message}"; push() }
        }
    }

    // ---- 3. Broadcasts -----------------------------------------------------

    private val broadcastActions = listOf(
        "com.android.music.metachanged", "com.android.music.playstatechanged",
        "com.spotify.music.metadatachanged", "com.spotify.music.playbackstatechanged",
        "com.amazon.mp3.metachanged", "com.htc.music.metachanged", "fm.last.android.metachanged",
        "com.sec.android.app.music.metachanged", "com.miui.player.metachanged",
        "android.bluetooth.avrcp-controller.profile.action.TRACK_EVENT",
        "android.bluetooth.avrcp-controller.profile.action.CONNECTION_STATE_CHANGED",
        "android.bluetooth.a2dp-sink.profile.action.CONNECTION_STATE_CHANGED",
        "android.bluetooth.a2dp-sink.profile.action.PLAYING_STATE_CHANGED",
        "android.bluetooth.a2dp-sink.profile.action.AUDIO_CONFIG_CHANGED",
        BluetoothDevice.ACTION_ACL_CONNECTED, BluetoothDevice.ACTION_ACL_DISCONNECTED,
    )

    private fun listenBroadcasts() {
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                val extras = i.extras ?: Bundle()
                val out = mutableMapOf<String, Any?>("action" to i.action, "at" to System.currentTimeMillis())
                fun s(vararg keys: String) = keys.firstNotNullOfOrNull { k -> extras.get(k)?.toString()?.takeIf { it.isNotBlank() } }
                @Suppress("DEPRECATION")
                val meta = extras.get("android.bluetooth.avrcp-controller.profile.extra.METADATA") as? MediaMetadata
                @Suppress("DEPRECATION")
                val play = extras.get("android.bluetooth.avrcp-controller.profile.extra.PLAYBACK") as? PlaybackState
                out["title"] = meta?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: s("track", "title", "trackName", "name")
                out["artist"] = meta?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: s("artist", "artistName")
                out["album"] = meta?.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: s("album", "albumName")
                out["duration"] = meta?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: (extras.get("duration") as? Number)?.toLong()
                out["position"] = play?.position ?: (extras.get("position") as? Number)?.toLong() ?: (extras.get("playbackPosition") as? Number)?.toLong()
                out["playing"] = play?.let { it.state == PlaybackState.STATE_PLAYING } ?: (extras.get("playing") as? Boolean) ?: (extras.get("isPlaying") as? Boolean)
                out["extras"] = extras.keySet().joinToString(", ") { k -> "$k=${extras.get(k)}".take(80) }
                if (i.action?.contains("CONNECTION_STATE") == true || i.action?.startsWith("android.bluetooth.device") == true) {
                    readBluetooth()
                }
                if (out["title"] != null || out["playing"] != null) lastBroadcast = out
                else if (lastBroadcast == null) lastBroadcast = out
                push()
            }
        }
        val f = IntentFilter().apply { broadcastActions.forEach { addAction(it) } }
        try {
            if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(r, f, Context.RECEIVER_EXPORTED)
            else ctx.registerReceiver(r, f)
            receiver = r
        } catch (e: Exception) { /* not allowed here */ }
    }

    // ---- 4. Media buttons --------------------------------------------------

    private fun key(action: String): Boolean {
        val code = when (action) {
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "toggle" -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            "stop" -> KeyEvent.KEYCODE_MEDIA_STOP
            else -> return false
        }
        val am = ctx.getSystemService(AudioManager::class.java)
        val now = SystemClock.uptimeMillis()
        am.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
        am.dispatchMediaKeyEvent(KeyEvent(now, now + 20, KeyEvent.ACTION_UP, code, 0))
        return true
    }

    private fun control(key: String?, action: String, ms: Long?): Boolean {
        val c = (key?.let { controllers[it]?.first }) ?: return key(action)
        val t = c.transportControls
        when (action) {
            "play" -> t.play()
            "pause" -> t.pause()
            "toggle" -> if (c.playbackState?.state == PlaybackState.STATE_PLAYING) t.pause() else t.play()
            "next" -> t.skipToNext()
            "previous" -> t.skipToPrevious()
            "seek" -> t.seekTo(ms ?: 0)
            "stop" -> t.stop()
            else -> return false
        }
        return true
    }

    // ---- 5. The head unit's own app -----------------------------------------

    private fun apps(): List<Map<String, Any?>> {
        val pm = ctx.packageManager
        val launch = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val words = listOf("bt", "blue", "a2dp", "music", "media", "audio", "phone link")
        return pm.queryIntentActivities(launch, 0)
            .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
            .filter { (p, _) -> p != ctx.packageName }
            .distinctBy { it.first }
            .map { (p, l) ->
                val text = "$p $l".lowercase()
                val score = when {
                    text.contains("a2dp") || text.contains("bluetooth") || Regex("\\bbt").containsMatchIn(text) -> 2
                    words.any { text.contains(it) } -> 1
                    else -> 0
                }
                mapOf("app" to p, "label" to l, "score" to score)
            }
            .filter { (it["score"] as Int) > 0 }
            .sortedByDescending { it["score"] as Int }
    }

    private fun launch(activity: Activity, app: String): Boolean {
        val i = activity.packageManager.getLaunchIntentForPackage(app) ?: return false
        activity.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return true
    }

    // ---- Bluetooth itself --------------------------------------------------

    @Suppress("DEPRECATION")
    private fun listenBluetooth() {
        val adapter = try { BluetoothAdapter.getDefaultAdapter() } catch (e: Exception) { null }
        if (adapter == null) { bt["adapter"] = false; return }
        bt["adapter"] = true
        // 11 = audio sink (this device plays a phone's audio), 12 = remote control of that phone.
        for (profile in listOf(11, 12)) {
            try {
                val ok = adapter.getProfileProxy(ctx, object : BluetoothProfile.ServiceListener {
                    override fun onServiceConnected(p: Int, proxy: BluetoothProfile) {
                        proxies[p] = proxy
                        readBluetooth()
                        push()
                    }
                    override fun onServiceDisconnected(p: Int) { proxies.remove(p); readBluetooth(); push() }
                }, profile)
                bt[if (profile == 11) "sinkProfile" else "remoteProfile"] = if (ok) "asked" else "not on this device"
            } catch (e: Throwable) {
                bt[if (profile == 11) "sinkProfile" else "remoteProfile"] = "blocked: ${e.javaClass.simpleName}"
            }
        }
    }

    private fun readBluetooth() {
        for ((p, proxy) in proxies) {
            val name = if (p == 11) "sink" else "remote"
            bt["${name}Profile"] = "available"
            bt["${name}Devices"] = try {
                proxy.connectedDevices.map { d -> try { d.name ?: d.address } catch (e: SecurityException) { "a device" } }
            } catch (e: SecurityException) { listOf("(no permission to see)") } catch (e: Throwable) { emptyList<String>() }
        }
    }

    // ---- Snapshot ------------------------------------------------------------

    private fun snapshot(): Map<String, Any?> {
        val sessions = controllers.map { (k, p) -> describe(k, p.first, if (k.startsWith("browser:")) "browser" else "session") }
        return mapOf(
            "access" to hasAccess(),
            "sessions" to sessions,
            "browsers" to browserServices(),
            "browser" to mapOf("app" to browserApp, "state" to browserState),
            "broadcast" to lastBroadcast,
            "bluetooth" to bt.toMap(),
        )
    }

    private var pushQueued = false

    private fun push() {
        if (sink == null || pushQueued) return
        pushQueued = true
        main.postDelayed({
            pushQueued = false
            try { sink?.success(snapshot()) } catch (e: Throwable) { /* gone */ }
        }, 60)
    }
}
