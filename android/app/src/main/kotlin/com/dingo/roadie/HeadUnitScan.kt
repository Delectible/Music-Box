package com.dingo.roadie

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import org.xmlpull.v1.XmlPullParser
import java.io.DataInputStream
import java.util.zip.ZipFile

/**
 * Looks through the head unit for private ways its Bluetooth music app
 * talks to the rest of the system (its own broadcasts, services, content
 * providers, system properties and settings), and listens for those
 * broadcasts, so a way in for Roadie can be found. Read-only.
 */
object HeadUnitScan {
    private val words = listOf(
        "bt", "blue", "a2dp", "avrcp", "music", "media", "microntek", "mtc", "hct", "syu", "fyt",
        "mcu", "canbus", "carserv", "dasaita", "hal9k", "zxw", "ts10", "topway",
    )
    private val deepWords = listOf("bt", "blue", "a2dp", "avrcp", "microntek", "mtc", "hct", "syu", "fyt")
    private val interesting = Regex(
        "bt|blue|music|id3|track|title|artist|album|play|pause|avrcp|a2dp|connect|song|lyric|media|mcu",
        RegexOption.IGNORE_CASE,
    )
    private val dotted = Regex("^[A-Za-z][\\w$]*(\\.[\\w$]+){2,}$")

    /** Every action worth listening for, gathered by the last scan. */
    val actions = linkedSetOf<String>()
    private val log = ArrayDeque<String>()
    private var receiver: BroadcastReceiver? = null

    private fun matches(text: String) = text.lowercase().let { t ->
        words.any { w -> if (w.length <= 3) Regex("(^|[^a-z])$w").containsMatchIn(t) else t.contains(w) }
    }

    fun scan(ctx: Context): String {
        val out = StringBuilder()
        fun h(t: String) = out.append("\n== $t ==\n")
        val pm = ctx.packageManager

        h("Device")
        out.append("${Build.MANUFACTURER} ${Build.MODEL} · board ${Build.BOARD} · hardware ${Build.HARDWARE}\n")
        out.append("Android ${Build.VERSION.RELEASE} (${Build.VERSION.SDK_INT}) · ${Build.DISPLAY}\n")

        h("System properties")
        exec("getprop").lines().filter { matches(it) || it.contains("mcu") || it.contains("version") && it.contains("ro.") }
            .take(120).forEach { out.append(it).append('\n') }

        h("Apps")
        @Suppress("DEPRECATION")
        val flags = PackageManager.GET_ACTIVITIES or PackageManager.GET_SERVICES or
            PackageManager.GET_RECEIVERS or PackageManager.GET_PROVIDERS or PackageManager.GET_DISABLED_COMPONENTS
        val all = try {
            @Suppress("DEPRECATION")
            pm.getInstalledPackages(0)
        } catch (e: Exception) { emptyList<PackageInfo>() }
        val picks = all.filter { p ->
            p.packageName != ctx.packageName &&
                (matches(p.packageName) || matches(p.applicationInfo?.loadLabel(pm)?.toString() ?: ""))
        }.sortedByDescending { p -> if (deepWords.any { p.packageName.lowercase().contains(it) }) 1 else 0 }
        out.append("${all.size} installed, ${picks.size} look relevant\n")
        for (p0 in picks.take(25)) {
            val p = try {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(p0.packageName, flags)
            } catch (e: Throwable) { p0 }
            val ai = p.applicationInfo
            val system = ai != null && ai.flags and ApplicationInfo.FLAG_SYSTEM != 0
            out.append("\n# ${ai?.loadLabel(pm)} (${p.packageName}) v${p.versionName}" +
                (if (system) " · system" else "") + (p.sharedUserId?.let { " · uid $it" } ?: "") + "\n")
            p.services?.forEach { out.append("  service ${short(p.packageName, it.name)}${if (it.exported) " exported" else ""}${it.permission?.let { x -> " needs $x" } ?: ""}\n") }
            p.receivers?.forEach { out.append("  receiver ${short(p.packageName, it.name)}${if (it.exported) " exported" else ""}\n") }
            p.providers?.forEach { out.append("  provider ${it.authority}${if (it.exported) " exported" else ""}${it.readPermission?.let { x -> " needs $x" } ?: ""}\n") }
            p.activities?.filter { it.exported }?.take(8)?.forEach { out.append("  screen ${short(p.packageName, it.name)}\n") }
            val acts = manifestActions(ctx, p.packageName)
            if (acts.isNotEmpty()) out.append("  listens for: ${acts.joinToString(", ")}\n")
            acts.filter { !it.startsWith("android.intent.action.MAIN") }.forEach { actions.add(it) }
            // Providers: what a plain read returns.
            p.providers?.filter { it.exported && it.readPermission == null }?.forEach { pr ->
                out.append("  read ${pr.authority}: ${peek(ctx, pr.authority)}\n")
            }
        }

        h("Strings inside the Bluetooth apps")
        for (p in picks.filter { pk -> deepWords.any { pk.packageName.lowercase().contains(it) } }.take(5)) {
            val src = p.applicationInfo?.sourceDir ?: continue
            val strs = dexStrings(src).filter { dotted.matches(it) && interesting.containsMatchIn(it) && !it.startsWith("android.support") && !it.startsWith("androidx") && !it.contains("$") }
            val keys = dexStrings(src).filter { it.length in 3..40 && Regex("^[a-z_]*(title|artist|album|track|id3|playstate|play_state|bt_music|music_info|song)[a-z_]*$", RegexOption.IGNORE_CASE).matches(it) }
            out.append("\n# ${p.packageName}: ${strs.size} names\n")
            strs.take(200).forEach { out.append("  $it\n") }
            if (keys.isNotEmpty()) out.append("  keys: ${keys.distinct().take(60).joinToString(", ")}\n")
            strs.take(300).forEach { actions.add(it) }
        }

        h("System services")
        exec("service list").lines().filter { l ->
            val n = l.substringAfter('\t').substringBefore(':').lowercase()
            matches(n) || l.contains("car", true) || l.contains("mcu", true)
        }.take(60).forEach { out.append(it.trim()).append('\n') }

        h("Settings")
        for ((name, uri) in listOf("system" to "content://settings/system", "global" to "content://settings/global", "secure" to "content://settings/secure")) {
            try {
                ctx.contentResolver.query(Uri.parse(uri), arrayOf("name", "value"), null, null, null)?.use { c ->
                    while (c.moveToNext()) {
                        val k = c.getString(0) ?: continue
                        if (matches(k) || interesting.containsMatchIn(k) && !k.startsWith("haptic")) out.append("$name/$k = ${c.getString(1)?.take(80)}\n")
                    }
                }
            } catch (e: Exception) { out.append("$name: ${e.javaClass.simpleName}\n") }
        }

        h("Listening for")
        out.append("${actions.size} broadcast names (start Listen, then play / skip on the phone)\n")
        return out.toString()
    }

    private fun short(pkg: String, name: String) = if (name.startsWith(pkg)) name.removePrefix(pkg) else name

    private fun exec(cmd: String): String = try {
        val p = Runtime.getRuntime().exec(cmd)
        val text = p.inputStream.bufferedReader().readText()
        p.waitFor()
        text
    } catch (e: Exception) { "($cmd: ${e.message})" }

    private fun peek(ctx: Context, authority: String): String = try {
        ctx.contentResolver.query(Uri.parse("content://$authority"), null, null, null, null)?.use { c ->
            val row = if (c.moveToFirst()) (0 until c.columnCount).joinToString(", ") { i ->
                "${c.getColumnName(i)}=${try { c.getString(i)?.take(40) } catch (e: Exception) { "?" }}"
            } else ""
            "${c.count} rows [${c.columnNames.joinToString(",")}] $row".take(400)
        } ?: "nothing"
    } catch (e: Throwable) { e.javaClass.simpleName }

    /** The actions in an app's manifest intent filters. */
    private fun manifestActions(ctx: Context, pkg: String): List<String> = try {
        val res = ctx.packageManager.getResourcesForApplication(pkg)
        val parser = res.assets.openXmlResourceParser("AndroidManifest.xml")
        val found = mutableListOf<String>()
        while (parser.next() != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType == XmlPullParser.START_TAG && parser.name == "action") {
                for (i in 0 until parser.attributeCount) {
                    if (parser.getAttributeName(i) == "name") found.add(parser.getAttributeValue(i))
                }
            }
        }
        found.distinct()
    } catch (e: Throwable) { emptyList() }

    /** Every string constant in an APK's code (its dex string tables). */
    private val dexCache = mutableMapOf<String, List<String>>()

    private fun dexStrings(apk: String): List<String> = dexCache.getOrPut(apk) {
        val out = mutableListOf<String>()
        try {
            ZipFile(apk).use { zip ->
                for (e in zip.entries()) {
                    if (!Regex("classes\\d*\\.dex").matches(e.name)) continue
                    val b = zip.getInputStream(e).use { s -> DataInputStream(s).let { d -> ByteArray(e.size.toInt()).also { d.readFully(it) } } }
                    fun u32(o: Int) = (b[o].toInt() and 0xff) or ((b[o + 1].toInt() and 0xff) shl 8) or
                        ((b[o + 2].toInt() and 0xff) shl 16) or ((b[o + 3].toInt() and 0xff) shl 24)
                    val count = u32(56)
                    val ids = u32(60)
                    for (i in 0 until count) {
                        var o = u32(ids + i * 4)
                        var len = 0; var shift = 0
                        while (true) { val v = b[o++].toInt() and 0xff; len = len or ((v and 0x7f) shl shift); if (v < 0x80) break; shift += 7 }
                        if (len !in 3..120) continue
                        var end = o
                        while (end < b.size && b[end] != 0.toByte()) end++
                        out.add(String(b, o, end - o, Charsets.UTF_8))
                    }
                }
            }
        } catch (e: Throwable) { out.add("(could not read: ${e.javaClass.simpleName})") }
        out
    }

    // ---- Listening -------------------------------------------------------------

    fun listen(ctx: Context, on: Boolean) {
        receiver?.let { try { ctx.unregisterReceiver(it) } catch (e: Exception) {} }
        receiver = null
        if (!on) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                val x = i.extras ?: Bundle()
                @Suppress("DEPRECATION")
                val extras = x.keySet().joinToString(", ") { k -> "$k=${try { x.get(k) } catch (e: Exception) { "?" }}".take(120) }
                add("${java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US).format(java.util.Date())} ${i.action}" +
                    (if (extras.isEmpty()) "" else "  {$extras}"))
            }
        }
        val f = IntentFilter()
        (actions + Phone.knownActions).take(1000).forEach { f.addAction(it) }
        try {
            if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(r, f, Context.RECEIVER_EXPORTED) else ctx.registerReceiver(r, f)
            receiver = r
            add("Listening for ${f.countActions()} names. Play, pause and skip on the phone now.")
        } catch (e: Exception) { add("Couldn't listen: ${e.message}") }
    }

    @Synchronized private fun add(line: String) {
        log.addLast(line)
        while (log.size > 300) log.removeFirst()
    }

    @Synchronized fun heard(): List<String> = log.toList()
}
